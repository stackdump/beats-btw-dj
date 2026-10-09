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
    #expect(md.contains("source: dj-vevr-se"))
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
    #expect(log.calls[0].argv.prefix(4) == ["ssh", "-o", "BatchMode=yes", "valoper.local"])
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
}
