import Darwin
import Testing

@testable import DJCore

// The gain a live model applies (how the deck's faders compose with the source gain), when it
// re-reads the engine, and that it agrees with what the feed publishes about the same decks.

@MainActor
struct ModelEngineFxStateTests {
  /// One tonal lane on `deck` whose kernel is 1 in every row at 60: a deposit at velocity 100
  /// then adds exactly `fx` to every band of bar 0, so `modelBars` reads the response.
  private func rig() throws -> (ScopeRig, ModelEngine) {
    let rig = try ScopeRig(net: ["A", "B"], play: false)
    let lane = ScopeLane(
      key: "k", ids: ["k"], channel: 1, group: "main", drum: false, instrument: "bass",
      notes: [60], durationsMs: [200], lo: 60, hi: 60, color: ScopeColors.defaultLaneColor,
      deck: "A")
    let table = ModelKernelTable(
      notes: [60], logR: [Float](repeating: 0, count: ModelGrid.nr), drum: false, durMs: 200,
      tau: 0.1)
    let model = ModelEngine(engine: rig.dj, cache: ModelKernelCache())
    model.setLanes([lane], tables: [table])
    return (rig, model)
  }

  private func hit(_ model: ModelEngine, bar: Int = 0) {
    model.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 16 * bar, tickSec: 0.1)
  }

  @Test func theGainIsSourceTrimVolumeCrossfaderAndMasterEachSquared() throws {
    let (rig, model) = try rig()
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    // trim 2^((0.75 - 0.5) * 2) = 1.4142, volume 0.6, crossfader cos(0.25 pi/2) = 0.9239, master 0.7
    a.gain = 0.75
    a.volume = 0.6
    rig.dj.crossfader = 0.25
    rig.dj.master = 0.7
    hit(model)
    // 0.8² * 2 * 0.36 * 0.853553 * 0.49: every one of them is off unity, so a dropped or doubled
    // factor shows
    let want = 0.19272552716883645
    for b in 0..<ModelGrid.nb {
      #expect(abs(model.modelBars[b] - want) < 1e-6, "band \(b): \(model.modelBars[b])")
    }
    #expect(abs(model.modelBars[ModelGrid.nb] - 5 * want) < 5e-6, "E is their sum")
    #expect(abs(Double(model.fxRow(forLane: 0)[0]) - want) < 1e-6)
  }

  @Test func theEngineIsReReadAtMostEveryTwoHundredMilliseconds() throws {
    let (rig, model) = try rig()
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    a.volume = 0.6
    var now = 100.0
    model.fxClock = { now }
    hit(model)  // the first look
    let first = Double(model.fxRow(forLane: 0)[0])
    #expect(abs(first - 0.64 * 0.36 * pow(rig.dj.crossfadeGain("A") * rig.dj.master, 2)) < 1e-6)
    a.volume = 0.3  // a quarter of the power
    now = 100.1
    hit(model)
    #expect(Double(model.fxRow(forLane: 0)[0]) == first, "100 ms later: not looked again")
    now = 100.19
    hit(model)
    #expect(Double(model.fxRow(forLane: 0)[0]) == first, "190 ms later: still not")
    now = 100.21
    hit(model)
    #expect(abs(Double(model.fxRow(forLane: 0)[0]) - first / 4) < 1e-6, "210 ms: looked again")
    // the bars took each hit with the response of its moment: 1 + 1 + 1 hits at `first`, then
    // one at a quarter
    #expect(abs(model.modelBars[0] - (3 * first + first / 4)) < 1e-5)
    // a pinned response is replaced by the next look
    model.setFx(deck: "A", rows: [Float](repeating: 2, count: ModelGrid.nr))
    now = 100.3
    hit(model)
    #expect(Double(model.fxRow(forLane: 0)[0]) == 2, "inside 200 ms of the pin: kept")
    now = 100.6
    hit(model)
    #expect(abs(Double(model.fxRow(forLane: 0)[0]) - first / 4) < 1e-6)
  }

  @Test func aMasterModelUsesTheFeedsDeckWeightsTimesTheSourceGainAndTheMaster() throws {
    // The feed publishes (trim x volume x crossfader)² per deck for the model modes; the model
    // derives the same from the engine. They must stay one definition.
    let rig = try ScopeRig(net: ["A", "B"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    let b = try #require(rig.dj["B"])
    a.gain = 0.75
    a.volume = 0.6
    b.gain = 0.3
    b.volume = 0.9
    rig.dj.crossfader = 0.4
    rig.dj.master = 0.7
    let cache = warmedCache([("techno", 42, "loop", 300), ("techno", 43, "loop", 300)])
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    play(rig, model, feed, seconds: 1)
    model.refreshFx()
    for deck in ["A", "B"] {
      let lane = try #require(model.lanes.firstIndex { $0.deck == deck })
      let want = feed.weight(ofLane: lane) * ModelEngine.sourceGain * ModelEngine.sourceGain * 0.49
      #expect(want > 0.01, "deck \(deck) is audible: \(want)")
      let row = model.fxRow(forLane: lane)
      #expect(row.allSatisfy { abs(Double($0) - want) < 1e-6 * max(1, want) }, "deck \(deck)")
    }
  }

  @Test func theLabelSaysWhatPointTheFxAreTakenAt() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let deckFeed = rig.hub.feed(.deck("A"))
    let masterFeed = rig.hub.feed(.master)
    deckFeed.acquire()
    masterFeed.acquire()
    rig.render(seconds: 0.5)
    rig.hub.pump()
    let d = ModelEngine(engine: rig.dj, cache: cache)
    let m = ModelEngine(engine: rig.dj, cache: cache)
    d.consume(deckFeed)
    m.consume(masterFeed)
    #expect(d.fxPointLabel == "pre-fader tap" && m.fxPointLabel == "master")
    d.fxPoint = .deckOutput
    #expect(d.fxPointLabel == "deck output")
    m.fxPoint = .matchTap
    #expect(m.fxPointLabel == "master", "a master feed always has the deck chain")
  }
}
