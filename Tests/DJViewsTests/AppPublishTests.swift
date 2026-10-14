import DJCore
import Testing

@testable import DJViews

/// The app's Publish action, driven past the confirmation dialog into `AppModel.publish` with a
/// directory standing in for the CDN master and a canned public probe.
@MainActor
struct AppPublishTests {
  func model() throws -> (AppModel, Session) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj)
    m.start()
    let rec = try SessionRecorder.start(on: dj)
    dj.perform(.param(deck: "B", name: "filter", value: 0.2))
    let session = rec.finish()
    m.lastSessionValue = session
    return (m, session)
  }

  @Test func publishStagesTheBundleAndReportsThePublicURL() async throws {
    let (m, session) = try model()
    let blobs = makeScratchDir()
    defer { removeTree(blobs) }
    let probe = PublicProbe(attempts: 1, interval: 0, head: { _ in 200 })
    await m.publish(
      options: .init(title: "Friday set", includeAudio: true),
      transport: DirectoryTransport(path: blobs), probe: probe)

    let dir = "\(blobs)/\(session.cid)"
    #expect(listDirectory(dir) == ["audio.wav", "index.md", "session.json"])
    let md = readText("\(dir)/index.md")
    #expect(md.contains("title: Friday set") && md.contains("cid: \(session.cid)"))
    #expect(
      m.publishState
        == .published(
          url: "https://cdn.stackdump.com/ipfs/\(session.cid)/", live: true, reloaded: true))
    #expect(m.status.hasPrefix("published "))
  }

  @Test func aDraftIsMarkedAndAMirrorThatHasNotLandedIsNotCalledLive() async throws {
    let (m, session) = try model()
    let blobs = makeScratchDir()
    defer { removeTree(blobs) }
    let probe = PublicProbe(attempts: 2, interval: 0, head: { _ in 404 })
    await m.publish(
      options: .init(draft: true, includeAudio: false),
      transport: DirectoryTransport(path: blobs), probe: probe)
    let md = readText("\(blobs)/\(session.cid)/index.md")
    #expect(md.contains("draft: true"))
    #expect(
      m.publishState
        == .published(
          url: "https://cdn.stackdump.com/ipfs/\(session.cid)/", live: false, reloaded: true))
    #expect(m.status.contains("mirror still syncing"))
  }

  struct Refusing: CDNTransport {
    func stage(_ bundle: SessionBundle) throws {
      throw PublishError.commandFailed("stage session.json", 255, "ssh: connection refused")
    }
    func reload(cid: String) throws -> Bool { true }
    func mirror() throws {}
  }

  @Test func aFailureIsShownAndTheButtonComesBack() async throws {
    let (m, _) = try model()
    await m.publish(
      options: .init(includeAudio: false), transport: Refusing(),
      probe: PublicProbe(attempts: 1, interval: 0, head: { _ in 200 }))
    guard case .failed(let why) = m.publishState else {
      Issue.record("expected .failed, got \(m.publishState)")
      return
    }
    #expect(why.contains("connection refused"))
    #expect(!m.publishState.isWorking)
    #expect(m.status.hasPrefix("publish failed"))
  }

  @Test func nothingHappensWithoutARecordedSet() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let m = AppModel(engine: dj)
    await m.publish(transport: Refusing())
    #expect(m.publishState == .idle)
  }
}
