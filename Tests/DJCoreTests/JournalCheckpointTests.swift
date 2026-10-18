import Testing

@testable import DJCore

private let rate = 11_025.0

/// Checkpoints that carry the decks' playheads (`JournalState(engine:stores:playheads: true)`).
@MainActor
struct JournalCheckpointTests {
  static let spec = TrackSpec(genre: "techno", seed: 7, structure: "standard")

  static var withPositions: JournalState {
    JournalState(
      sampleRate: 48_000,
      decks: [
        "A": DeckCheckpoint(
          source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil),
          position: 12_345.5),
        "B": DeckCheckpoint(source: .net(spec), playing: true, position: 96),
        "C": DeckCheckpoint(source: .net(spec)),
      ])
  }

  @Test func aPositionRoundTripsThroughTheCheckpointLine() throws {
    let e = JournalEntry(
      seq: 0, time: journalDate(1_760_000_000), frame: 0, event: .checkpoint(Self.withPositions))
    let back = try #require(JournalEntry(line: e.line))
    #expect(back == e)
    #expect(back.line == e.line, "re-encodes to the same bytes")
    guard case .checkpoint(let s) = back.event else {
      Issue.record("not a checkpoint")
      return
    }
    #expect(s.decks["A"]?.position == 12_345.5)
    #expect(s.decks["B"]?.position == 96)
    #expect(s.decks["C"]?.position == nil, "written only when set")
  }

  @Test func anOldCheckpointHasNoPositionAndStaysByteForByte() throws {
    var old = Self.withPositions
    for k in old.decks.keys { old.decks[k]?.position = nil }
    let text = old.json.canonicalJS
    #expect(!text.contains("\"position\""), "no key without a position")
    #expect(text.contains(JournalState.schema), "schema stays v1")
    let back = try #require(JournalState(json: try JSONValue.parse(text)))
    #expect(back.decks.values.allSatisfy { $0.position == nil })
    #expect(back.json.canonicalJS == text)
  }

  @Test func aCheckpointKeepsPlayheadsOnlyWhenAsked() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    try dj.start()
    defer { dj.stop() }
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    for b in 0..<40 {
      _ = try conductor.step {
        if b == 0 {
          dj.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
          )
          dj.perform(.load(deck: "B", source: .net(Self.spec)))
          dj.perform(.play(deck: "A", on: true))
          dj.perform(.play(deck: "B", on: true))
        }
      }
    }
    let plain = JournalState(engine: dj)
    #expect(plain.decks.values.allSatisfy { $0.position == nil }, "opt-in")
    #expect(!plain.json.canonicalJS.contains("\"position\""))
    let kept = JournalState(engine: dj, playheads: true)
    #expect((kept.decks["A"]?.position ?? 0) > 0)
    #expect(kept.decks["B"]?.position == Double(try #require(dj["B"]).wave.tick))
  }

  /// A live run that plays both decks a while, stops them and lets them settle; its state with
  /// playheads, restored into a fresh engine, stands where it stood.
  @Test func aRestoreSeeksTheDecksToTheirPlayheads() throws {
    let live = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    live.deterministic = true
    try live.start()
    let conductor = OfflineConductor(engine: live, router: ControllerRouter(engine: live))
    for b in 0..<400 {
      _ = try conductor.step {
        switch b {
        case 0:
          live.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
          )
          live.perform(.load(deck: "B", source: .net(Self.spec)))
          live.perform(.play(deck: "A", on: true))
          live.perform(.play(deck: "B", on: true))
        case 250:
          live.perform(.play(deck: "A", on: false))
          live.perform(.play(deck: "B", on: false))
        default: break
        }
      }
    }
    let state = JournalState(engine: live, playheads: true)
    live.stop()
    let samplePos = try #require(state.decks["A"]?.position)
    let tick = try #require(state.decks["B"]?.position)
    #expect(samplePos > 0 && tick > 0, "the decks moved: \(samplePos) \(tick)")
    // through the checkpoint's JSON, as a journal file holds it
    let read = try #require(JournalState(json: try JSONValue.parse(state.json.canonicalJS)))

    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let warnings = read.restore(into: dj, clip: { _ in nil })
    #expect(warnings.isEmpty, "\(warnings)")
    try dj.start()
    defer { dj.stop() }
    let replay = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    _ = try replay.step()
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    #expect(!a.playing && !b.playing)
    #expect(b.wave.tick == Int(tick), "the net tick is exact")
    #expect(
      abs(a.turntable.position - samplePos) <= 128,
      "sample within a block: \(a.turntable.position) vs \(samplePos)")
  }
}
