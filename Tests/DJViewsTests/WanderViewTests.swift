import SwiftUI
import Testing

@testable import DJCore
@testable import DJViews

/// Wander in the app: the control socket, dj_state, what is remembered, and the panel.
@MainActor
struct WanderViewTests {
  func model(_ defaults: UserDefaults = scratchDefaults()) throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites())
    m.defaults = defaults
    m.start()
    return m
  }

  func call(_ m: AppModel, _ method: String, _ params: String = "{}") async throws -> JSONValue {
    try await m.control(method, try JSONValue.parse(params))
  }

  @Test func djStateShowsTheWalkAndPerformSetsItUp() async throws {
    let m = try model()
    _ = try await call(
      m, "generate", #"{"deck":"A","genre":"techno","seed":42,"structure":"minimal"}"#)
    let rec = try SessionRecorder.start(on: try #require(m.engine))
    _ = try await call(m, "perform", #"{"action":{"op":"wanderPace","deck":"A","bars":4}}"#)
    _ = try await call(
      m, "perform", #"{"action":{"op":"wanderLock","deck":"A","dimension":"genre","on":true}}"#)
    let a = try await call(m, "perform", #"{"action":{"op":"wander","deck":"A","on":true}}"#)
    let w = try #require(a["wander"])
    #expect(w["on"]?.bool == true && w["pace"]?.int == 4 && w["paused"]?.bool == false)
    #expect(w["locks"]?.array == [.string("genre")])
    #expect(w["nextMoveInBars"]?.int == 3, "bar 1 of 4: the move is taken entering bar 4")
    #expect(w["log"]?.array?.isEmpty == true)
    // moves show in the log, newest first
    let d = try #require(m.engine?["A"])
    for bar in 1..<8 { d.advanceWander(toBar: bar, lockedActions: []) }
    let log = try await call(m, "state")["decks"]?["A"]?["wander"]?["log"]?.array
    #expect(log?.count == 2 && log?.first?["step"]?.int == 1 && log?.first?["bar"]?.int == 8)
    // the pokes are recorded; the moves are not
    #expect(
      rec.finish().events.map(\.kind) == [
        .action(.wanderPace(deck: "A", bars: 4)),
        .action(.wanderLock(deck: "A", dimension: "genre", on: true)),
        .action(.wander(deck: "A", on: true)),
      ])
    // a sample deck says why it stands still
    _ = try await call(m, "perform", #"{"action":{"op":"wander","deck":"B","on":true}}"#)
    let b = try await call(m, "state")["decks"]?["B"]?["wander"]
    #expect(b?["idle"]?.string?.contains("sample") == true)
  }

  @Test func badWanderRequestsSayWhatIsWrong() async throws {
    let m = try model()
    for (params, words) in [
      (#"{"action":{"op":"wanderPace","deck":"A","bars":5}}"#, "4, 8, 16, 32"),
      (#"{"action":{"op":"wanderLock","deck":"A","dimension":"mood","on":true}}"#, "keep:<role>"),
    ] {
      await #expect { try await call(m, "perform", params) } throws: { "\($0)".contains(words) }
    }
  }

  @Test func locksAndPaceAreRememberedAcrossLaunches() throws {
    let defaults = scratchDefaults()
    let m = try model(defaults)
    m.setWanderLock("A", "tempo", true)
    m.setWanderLock("A", WanderLock.keep("bass"), true)
    m.setWanderPace("A", 8)
    m.setWander("A", true)
    let m2 = try model(defaults)
    let a = try #require(m2.engine?["A"])
    #expect(a.wander.locks == ["tempo", "keep:bass"] && a.wander.pace == 8)
    #expect(!a.wander.on, "the walk itself starts off")
    #expect(m2.engine?["B"]?.wander.locks.isEmpty == true)
  }

  @Test func aStarOnAMoveKeepsTheTrackItLedTo() throws {
    let m = try model()
    let spec = TrackSpec(genre: "house", seed: 7, structure: "minimal")
    let move = WanderMove(
      step: 0, bar: 16, kind: .seed, detail: "seed 6 → 7", spec: spec,
      cid: BeatsCID.shareCID(spec.payload))
    #expect(!m.isFavoriteSpec(spec))
    let f = try #require(m.keepWanderMove(move))
    #expect(f.source == .net(spec) && m.isFavoriteSpec(spec))
    m.keepWanderMove(move)
    #expect(!m.isFavoriteSpec(spec), "again: unstarred")
  }

  @Test func thePanelDrawsTheWalk() throws {
    let m = try model()
    var s = DeckState()
    s.isNet = true
    s.roles = ["kick", "bass", "melody"]
    s.wander.on = true
    s.wander.pace = 8
    s.wander.locks = ["genre", WanderLock.keep("bass")]
    s.wanderCountdown = 3
    let spec = TrackSpec(genre: "techno", seed: 43, structure: "minimal")
    s.wander.log = [
      WanderMove(step: 0, bar: 8, kind: .role, detail: "bass off", spec: spec, cid: nil),
      WanderMove(step: 1, bar: 16, kind: .seed, detail: "seed 42 → 43", spec: spec, cid: "x"),
    ]
    let panel = WanderPanel(name: "A", state: s, model: m, tint: .orange)
    #expect(panel.status == "next move in 3 bars")
    s.wander.paused = true
    #expect(
      WanderPanel(name: "A", state: s, model: m, tint: .orange).status.hasPrefix(
        "paused — you're steering"))
    // the log's rows (ImageRenderer draws no ScrollView, so the rows on their own)
    let rows = VStack(alignment: .leading, spacing: 0) {
      ForEach(s.wander.log.reversed(), id: \.step) { mv in
        WanderMoveRow(move: mv, kept: mv.step == 1, tint: .orange) {}
      }
    }
    savePNG(rows.background(Color.black), width: 360, height: 60, name: "wander-rows")
    let px = try #require(renderPixels(rows, width: 360, height: 60))
    #expect(px.count(inX: 0..<360, y: 0..<60) { r, g, b in r + g + b > 300 } > 50)
  }
}
