import Testing

@testable import DJCore

struct SetPlannerTests {
  func comp(_ id: String, _ energy: Double?, _ tempo: Double?, _ key: String? = nil)
    -> CompositionInfo
  {
    CompositionInfo(id: id, name: id, energy: energy, key: key, tempo: tempo, bars: 36)
  }

  @Test func keysMeasureStepsOnTheCircleOfFifthsWithRelativesAsOne() {
    #expect(SetPlanner.keyDistance("A minor", "C major") == 0)  // relative
    #expect(SetPlanner.keyDistance("A minor", "E minor") == 1)  // a fifth
    #expect(SetPlanner.keyDistance("A minor", "D minor") == 1)
    #expect(SetPlanner.keyDistance("F# minor", "A major") == 0)
    #expect(SetPlanner.keyDistance("A minor", "Eb minor") == 6)  // the tritone
    #expect(SetPlanner.keyDistance("Am", "Em") == 1)
    #expect(SetPlanner.keyDistance("nonsense", "A minor") == nil)
  }

  @Test func theBestFitFillsEachSlotInOrderAndEachTrackPlaysOnce() {
    let plan = [
      SetPlanSlot(label: "warm-up", energy: 0.3, bpm: 124),
      SetPlanSlot(label: "peak", energy: 0.95, bpm: 150),
      SetPlanSlot(label: "cool-down", energy: 0.4, bpm: 124),
    ]
    let pool = [
      comp("hard", 0.95, 150), comp("chill", 0.3, 124), comp("mellow", 0.35, 125),
      comp("mid", 0.6, 130),
    ]
    let r = SetPlanner.sequence(plan: plan, pool: pool)
    #expect(r.items.map(\.composition) == ["chill", "hard", "mellow"])
    #expect(r.items.map(\.slot) == [0, 1, 2] && r.gaps.isEmpty)
    // 124 → 150 is a 21 % jump: beyond the fader
    #expect(r.tempoJumps.map { [$0.from, $0.to] } == [[0, 1], [1, 2]])
  }

  @Test func aSlotNothingFitsIsAGapWithTheBriefToCompose() {
    let plan = [SetPlanSlot(label: "peak", energy: 1.0, bpm: 150, key: "A minor", bars: 36)]
    let r = SetPlanner.sequence(plan: plan, pool: [comp("lofi", 0.2, 80)])
    #expect(r.items.isEmpty && r.gaps.count == 1)
    #expect(r.gaps[0].label == "peak" && r.gaps[0].bpm == 150 && r.gaps[0].key == "A minor")
    #expect(r.gaps[0].closest?.hasPrefix("lofi") == true)
    #expect(SetPlanner.sequence(plan: plan, pool: []).gaps[0].closest == nil)
  }

  @Test func halfAndDoubleTimeCountAsMatchableAndKeyBreaksTies() {
    let slot = SetPlanSlot(label: "x", energy: 0.5, bpm: 140, key: "A minor")
    #expect(SetPlanner.cost(slot, comp("half", 0.5, 70)) < 0.01)
    #expect(
      SetPlanner.cost(slot, comp("near", 0.5, 140, "E minor"))
        < SetPlanner.cost(slot, comp("far", 0.5, 140, "Eb minor")))
    #expect(SetPlanner.cost(slot, comp("unknown", nil, nil)) == 0)  // energy defaults to 0.5
  }

  @Test func keptItemsKeepTheirMixOverrides() {
    let plan = [SetPlanSlot(label: "a", energy: 0.5)]
    let kept = [SetItem(composition: "t", mixOutBar: 28, fadeBars: 4)]
    let r = SetPlanner.sequence(plan: plan, pool: [comp("t", 0.5, 120)], kept: kept)
    #expect(r.items == [SetItem(composition: "t", slot: 0, mixOutBar: 28, fadeBars: 4)])
  }

  @Test func curvesShapeTheEnergyAndMapTempo() {
    let arc = SetPlanner.curve(shape: "arc", count: 5, bpm: 124...150)
    #expect(arc.count == 5)
    #expect(arc[2].energy > arc[0].energy && arc[2].energy > arc[4].energy)
    #expect(
      arc[2].label == "peak" && arc[0].label == "warm-up" && arc[4].label == "warm-up"
        || arc[4].label == "cool-down")
    #expect(arc[2].bpm == 150 && arc[0].bpm == 124)
    let rise = SetPlanner.curve(shape: "rise", count: 4)
    #expect(rise.map(\.energy) == rise.map(\.energy).sorted() && rise.last?.energy == 1.0)
    #expect(rise[0].bpm == nil)
    #expect(SetPlanner.curve(shape: "arc", count: 1).count == 1)
  }

  @Test func aSetSurvivesTheDisk() throws {
    let store = SetStore(directory: temporaryDirectory())
    var set = DJSet(name: "Friday Night", created: "2026-10-21T00:00:00Z", fadeBars: 6)
    set.plan = [SetPlanSlot(label: "peak", energy: 0.9, bpm: 150, key: "A minor", bars: 36)]
    set.items = [SetItem(composition: "abc", slot: 0, mixOutBar: 28)]
    try store.save(set)
    #expect(store.exists("friday night") && store.list().map(\.name) == ["Friday Night"])
    #expect(try store.load("Friday Night") == set)
    #expect(throws: SetStore.StoreError.noSet("nope")) { try store.load("nope") }
  }

  @Test func autoStartsTheFadeSoItEndsWithTheTrackAndBeginsALeadEarly() {
    let plain = SetItem(composition: "t")
    // 52 bars, 8-bar fade: the fade starts at bar 45 (1-based) and ends with bar 52
    #expect(SetAuto.startBar(bars: 52, item: plain, fadeBars: 8) == 45)
    #expect(
      SetAuto.startBar(bars: 52, item: SetItem(composition: "t", mixOutBar: 30), fadeBars: 8) == 30)
    #expect(SetAuto.startBar(bars: nil, item: plain, fadeBars: 8) == nil)
    #expect(
      SetAuto.startBar(bars: nil, item: SetItem(composition: "t", mixOutBar: 20), fadeBars: 8) == 20
    )
    #expect(SetAuto.startBar(bars: 4, item: plain, fadeBars: 8) == 1)  // a track shorter than its fade
    #expect(!SetAuto.due(bar: 43, startBar: 45, leadBars: 1))
    #expect(
      SetAuto.due(bar: 44, startBar: 45, leadBars: 1)
        && SetAuto.due(bar: 50, startBar: 45, leadBars: 1))
    #expect(
      SetAuto.due(bar: 45, startBar: 45, leadBars: 0)
        && !SetAuto.due(bar: 44, startBar: 45, leadBars: 0))
  }
}
