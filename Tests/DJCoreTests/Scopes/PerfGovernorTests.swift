import Testing

@testable import DJCore

/// The level state machine: monitor.js' adapt block, window by window.
struct PerfGovernorTests {
  /// Feed a list of verdicts, 2 s apart from `start`; returns the steps taken.
  func run(_ g: inout PerfGovernor, _ causes: [PerfCause], from start: Double = 0)
    -> [PerfGovernor.Step]
  {
    var out: [PerfGovernor.Step] = []
    for (i, c) in causes.enumerated() {
      out.append(g.apply(cause: c, now: start + Double(i) * 2))
    }
    return out
  }

  @Test func twoVisualizationWindowsInARowStepDown() {
    var g = PerfGovernor()
    let steps = run(&g, [.visualization, .visualization])
    #expect(steps == [.none, .down(to: 1)])
    #expect(g.level == 1 && g.bad == 0)
  }

  @Test func aWindowThatIsNotTheVisualizationBreaksTheStreak() {
    var g = PerfGovernor()
    #expect(
      run(&g, [.visualization, .other, .visualization, .none, .visualization])
        == Array(repeating: .none, count: 5))
    #expect(g.level == 0, "never two in a row")
    #expect(g.bad == 1)
  }

  @Test func eachFurtherPairStepsOneMoreLevelDownToPausedAndNoFurther() {
    var g = PerfGovernor()
    let steps = run(&g, Array(repeating: .visualization, count: 8))
    #expect(steps == [.none, .down(to: 1), .none, .down(to: 2), .none, .down(to: 3), .none, .none])
    #expect(g.level == 3)
    // more bad windows at the bottom change nothing
    #expect(
      run(&g, Array(repeating: .visualization, count: 5), from: 20).allSatisfy { $0 == .none })
    #expect(g.level == 3)
  }

  @Test func eightCleanWindowsStepBackUpOne() {
    var g = PerfGovernor()
    _ = run(&g, [.visualization, .visualization])
    #expect(g.level == 1)
    let steps = run(&g, Array(repeating: .none, count: 8), from: 100)
    #expect(steps == Array(repeating: .none, count: 7) + [.up(to: 0)])
    #expect(g.level == 0 && g.clean == 0)
  }

  @Test func anOtherWindowResetsTheCleanStreakButNotTheLevel() {
    var g = PerfGovernor()
    _ = run(&g, [.visualization, .visualization])
    _ = run(&g, Array(repeating: .none, count: 7), from: 100)
    #expect(g.clean == 7 && g.level == 1)
    _ = g.apply(cause: .other, now: 120)
    #expect(g.clean == 0 && g.level == 1, "janky but not the visuals: no progress either way")
    _ = run(&g, Array(repeating: .none, count: 8), from: 130)
    #expect(g.level == 0)
  }

  @Test func aLevelReEnteredWithin30SecondsOfSteppingUpBecomesTheFloor() {
    var g = PerfGovernor()
    _ = run(&g, [.visualization, .visualization])  // t 0, 2: level 1
    _ = run(&g, Array(repeating: .none, count: 8), from: 10)  // up at t = 24
    #expect(g.level == 0 && g.lastStepUpAt == 24)
    // back down 4 s later: inside the 30 s, so level 1 is now the floor
    #expect(run(&g, [.visualization, .visualization], from: 26) == [.none, .down(to: 1)])
    #expect(g.floor == 1)
    // sixteen clean windows cannot take it above the floor
    _ = run(&g, Array(repeating: .none, count: 16), from: 40)
    #expect(g.level == 1, "the floor holds")
    // and a further drop goes down as usual
    _ = run(&g, [.visualization, .visualization], from: 80)
    #expect(g.level == 2 && g.floor == 1)
  }

  @Test func aStepDownLongAfterTheStepUpSetsNoFloor() {
    var g = PerfGovernor()
    _ = run(&g, [.visualization, .visualization])
    _ = run(&g, Array(repeating: .none, count: 8), from: 10)  // up at t = 24
    #expect(run(&g, [.visualization, .visualization], from: 52) == [.none, .down(to: 1)])
    #expect(g.floor == 0, "the second bad window is at t = 54, exactly 30 s after the step up")
    _ = run(&g, Array(repeating: .none, count: 8), from: 100)
    #expect(g.level == 0)
  }

  @Test func theFloorRaisedByARepeatedPlungeIsTheNewLevelNotTheOldOne() {
    var g = PerfGovernor()
    _ = run(&g, Array(repeating: .visualization, count: 4))  // level 2 at t = 6
    _ = run(&g, Array(repeating: .none, count: 8), from: 10)  // up to 1 at t = 24
    #expect(g.level == 1)
    _ = run(&g, [.visualization, .visualization], from: 26)  // 2 again, 2 s after the step up
    #expect(
      g.level == 2 && g.floor == 2, "monitor.js: floor = max(floor, level + 1) before level++")
    _ = run(&g, Array(repeating: .none, count: 20), from: 40)
    #expect(g.level == 2)
  }

  @Test func resettingTheStreaksKeepsTheLevelTheFloorAndTheLastStepUp() {
    var g = PerfGovernor()
    _ = run(&g, [.visualization, .visualization])  // level 1
    _ = run(&g, Array(repeating: .none, count: 8), from: 10)  // up at t = 24
    _ = run(&g, [.visualization, .visualization], from: 26)  // level 1 again, floor 1
    _ = g.apply(cause: .visualization, now: 40)
    _ = g.apply(cause: .none, now: 42)
    _ = g.apply(cause: .none, now: 44)
    #expect(g.bad == 0 && g.clean == 2 && g.level == 1 && g.floor == 1 && g.lastStepUpAt == 24)
    _ = g.apply(cause: .visualization, now: 46)
    #expect(g.bad == 1)
    g.resetStreaks()
    #expect(g.bad == 0 && g.clean == 0, "perfStart: bad: 0, clean: 0")
    #expect(g.level == 1 && g.floor == 1 && g.lastStepUpAt == 24, "and nothing else")
  }

  // MARK: preference

  @Test func aPinnedLevelNeverMoves() {
    var g = PerfGovernor(preference: .reduced)
    #expect(g.level == 1)
    #expect(run(&g, Array(repeating: .visualization, count: 6)).allSatisfy { $0 == .none })
    #expect(run(&g, Array(repeating: .none, count: 12), from: 50).allSatisfy { $0 == .none })
    #expect(g.level == 1)
  }

  @Test func eachPreferenceMapsToItsLevel() {
    #expect(VizPreference.auto.fixedLevel == nil)
    #expect(VizPreference.full.fixedLevel == 0)
    #expect(VizPreference.reduced.fixedLevel == 1)
    #expect(VizPreference.minimal.fixedLevel == 2)
    #expect(VizPreference.paused.fixedLevel == 3)
    #expect(VizLevels.names == ["full", "reduced", "minimal", "paused"])
    #expect(
      VizPreference.allCases.map(\.rawValue) == ["auto", "full", "reduced", "minimal", "paused"])
  }

  @Test func settingAPreferenceClearsTheStreaksAndTheFloor() {
    var g = PerfGovernor()
    _ = run(&g, [.visualization, .visualization])
    _ = run(&g, Array(repeating: .none, count: 8), from: 10)
    _ = run(&g, [.visualization, .visualization], from: 26)
    _ = g.apply(cause: .visualization, now: 40)
    #expect(g.floor == 1 && g.bad == 1)
    g.setPreference(.full)
    #expect(g.level == 0 && g.floor == 0 && g.bad == 0 && g.clean == 0)
    #expect(g.preference == .full)
  }

  @Test func backToAutoAdaptsFromTheLevelThatWasPinned() {
    var g = PerfGovernor()
    g.setPreference(.minimal)
    #expect(g.level == 2)
    g.setPreference(.auto)
    #expect(g.level == 2, "auto keeps the current level and adapts from there")
    let steps = run(&g, Array(repeating: .none, count: 8))
    #expect(steps.last == .up(to: 1))
  }

  @Test func storedStringsParseAndAnythingElseIsAuto() {
    #expect(VizPreference(stored: "full") == .full)
    #expect(VizPreference(stored: "paused") == .paused)
    #expect(VizPreference(stored: "minimal") == .minimal)
    #expect(VizPreference(stored: nil) == .auto)
    #expect(VizPreference(stored: "") == .auto)
    #expect(VizPreference(stored: "ultra") == .auto)
  }

  @Test func theNoticeSaysWhatTheJsToastSays() {
    #expect(
      PerfNotice(level: 1, at: 0).text == "Visuals reduced (reduced) to keep playback smooth")
    #expect(PerfNotice(level: 2, at: 0).text.contains("(minimal)"))
    #expect(PerfNotice(level: 3, at: 0).text.contains("(paused)"))
    #expect(PerfNotice.seconds == 8)
  }
}
