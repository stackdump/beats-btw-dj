import Darwin
import Testing

@testable import DJCore

@Suite struct SessionPublishTests {
  func session() -> Session {
    var s = Session(
      sampleRate: 44100, frames: 44100 * 3,
      decks: ["A": .net(TrackSpec(genre: "techno", seed: 42, structure: "standard"))],
      params: ["A": DeckParams()], crossfader: 0.5, master: 0.8,
      events: [SessionEvent(frame: 100, kind: .action(.play(deck: "A", on: true)))])
    s.master = 0.8
    return s
  }

  @Test func bundleIsNamedByItsOwnHash() throws {
    let s = session()
    let b = try SessionBundle(session: s, renderedAt: "2026-10-08T00:00:00Z")
    #expect(b.cid == s.cid)
    #expect(b.files.map(\.name) == ["session.json", "index.md"])  // index.md last
    let json = String(decoding: b.files[0].data, as: UTF8.self)
    #expect(json.hasSuffix("\n"))
    let back = try Session.decode(String(json.dropLast()), cid: b.cid)
    #expect(back == s)
    let md = String(decoding: b.files[1].data, as: UTF8.self)
    #expect(md.contains("cid: \(b.cid)"))
    #expect(md.contains("source: beats-btw-dj"))
    #expect(md.contains("genre: techno"))
    #expect(!md.contains("draft"))
    #expect(b.publicURL == "https://cdn.stackdump.com/ipfs/\(b.cid)/")
  }

  @Test func audioAndDraftAreOptional() throws {
    let b = try SessionBundle(
      session: session(), audioWAV: [1, 2, 3], renderedAt: "t", draft: true)
    #expect(b.files.map(\.name) == ["session.json", "audio.wav", "index.md"])
    #expect(String(decoding: b.files.last!.data, as: UTF8.self).contains("draft: true"))
  }

  @Test func titlesAreYamlSafe() {
    #expect(SessionBundle.yamlString("plain") == "plain")
    #expect(SessionBundle.yamlString("a: b") == "\"a: b\"")
    #expect(SessionBundle.yamlString("say \"hi\"") == "\"say \\\"hi\\\"\"")
  }

  @Test func unsafeCIDsNeverReachAShell() {
    #expect(SessionBundle.isSafeCID("bafyrei" + String(repeating: "a", count: 20)))
    #expect(!SessionBundle.isSafeCID("bafy; rm -rf ~"))
    #expect(!SessionBundle.isSafeCID("../etc"))
    #expect(SessionBundle.isSafeCID("z4EBG9izgLW5Wfg3eGgh7YdtsgKgypw5g7S6uZFnFfxjkdPv9QE"))
    #expect(!SessionBundle.isSafeCID("abc"))
    #expect(!SessionBundle.isSafeCID(""))
  }

  @Test func directoryTransportWritesTheTree() throws {
    var template = Array("/tmp/cdn-test-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil }
    #expect(made)
    let root = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let b = try SessionBundle(session: session(), renderedAt: "t")
    let r = try publishSession(b, via: DirectoryTransport(path: root), mirror: false)
    #expect(r.mirrored == false && r.reloaded)
    #expect(access("\(root)/\(b.cid)/index.md", F_OK) == 0)
    #expect(access("\(root)/\(b.cid)/session.json", F_OK) == 0)
    unlink("\(root)/\(b.cid)/index.md")
    unlink("\(root)/\(b.cid)/session.json")
    rmdir("\(root)/\(b.cid)")
    rmdir(root)
  }

  final class Log: @unchecked Sendable {
    var calls: [(argv: [String], stdin: [UInt8]?)] = []
  }

  @Test func sshStagesInOrderAndMirrorsOnlyOnRequest() throws {
    let log = Log()
    let t = SSHTransport(run: { argv, stdin in
      log.calls.append((argv, stdin))
      return (0, "")
    })
    let b = try SessionBundle(session: session(), audioWAV: [9], renderedAt: "t")

    let quiet = try publishSession(b, via: t, mirror: false)
    #expect(quiet.mirrored == false && quiet.reloaded)
    let cmds = log.calls.map { $0.argv.last! }
    #expect(cmds.count == 4)  // 3 files + reload
    #expect(cmds[0].contains("session.json") && cmds[1].contains("audio.wav"))
    #expect(cmds[2].contains("index.md"))  // last, so a half-copy is never indexed
    #expect(cmds[3].contains("/admin/reload?cid=\(b.cid)"))
    #expect(!cmds.contains { $0.contains("mirror-push") })
    #expect(log.calls[0].stdin == Array(b.files[0].data))
    // non-interactive and bounded: an unreachable valoper fails in seconds, never prompts
    #expect(
      log.calls[0].argv.prefix(5) == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"])
    #expect(log.calls[0].argv.dropLast().last == "valoper.local")
    #expect(cmds[0].hasPrefix("mkdir -p ~/'Workspace/cdn-stackdump-com/data/blobs'/\(b.cid)"))

    log.calls = []
    let loud = try publishSession(b, via: t, mirror: true)
    #expect(loud.mirrored)
    #expect(log.calls.last!.argv.last!.contains("mirror-push.sh"))
  }

  @Test func failedStageStopsBeforeReloadOrMirror() throws {
    let log = Log()
    let t = SSHTransport(run: { argv, stdin in
      log.calls.append((argv, stdin))
      return (255, "ssh: connect refused")
    })
    let b = try SessionBundle(session: session(), renderedAt: "t")
    #expect(throws: PublishError.self) { try publishSession(b, via: t, mirror: true) }
    #expect(log.calls.count == 1)
  }

  @Test func progressNarratesEachStepInOrder() throws {
    let t = SSHTransport(run: { _, _ in (0, "") })
    let b = try SessionBundle(session: session(), audioWAV: [9], renderedAt: "t")
    var steps: [PublishStep] = []
    _ = try publishSession(b, via: t, mirror: true) { steps.append($0) }
    #expect(
      steps == [
        .staging(file: "session.json", index: 1, of: 3),
        .staging(file: "audio.wav", index: 2, of: 3),
        .staging(file: "index.md", index: 3, of: 3),
        .reloading, .mirroring, .done,
      ])
  }

  @Test func probeWaitsForEveryFileThenGivesUp() throws {
    let b = try SessionBundle(session: session(), audioWAV: [9], renderedAt: "t")
    let urls = PublicProbe.urls(for: b).map(\.absoluteString)
    #expect(
      urls == [b.publicURL + "audio.wav", b.publicURL + "index.md"])  // session.json is not polled

    final class Calls: @unchecked Sendable { var n = 0 }
    // index.md lands on the 3rd poll round, audio.wav is there from the start
    let calls = Calls()
    let probe = PublicProbe(
      attempts: 5, interval: 0,
      head: { url in
        calls.n += 1
        if url.lastPathComponent == "audio.wav" { return 200 }
        return calls.n >= 5 ? 200 : 404
      })
    var attempts: [Int] = []
    #expect(probe.wait(for: b, sleep: { _ in }, onAttempt: { attempts.append($0) }))
    #expect(attempts == [1, 2, 3])

    let never = PublicProbe(attempts: 3, interval: 0, head: { _ in nil })
    var slept = 0
    #expect(!never.wait(for: b, sleep: { _ in slept += 1 }))
    #expect(slept == 2)  // no sleep after the last attempt
  }

  @Test func stdinWriteToAnExitedProcessFailsInsteadOfCrashing() throws {
    // `false` exits without reading; a large stdin used to raise SIGPIPE in the app.
    let r = try SSHTransport.process(["false"], [UInt8](repeating: 7, count: 4_000_000))
    #expect(r.status == 1)
    let echo = try SSHTransport.process(["cat"], Array("hello".utf8))
    #expect(echo.status == 0 && echo.out == "hello")
  }
}
