import Observation
import Testing

@testable import DJCore

/// The monitor and its wiring to the hub, driven by a fake clock: whole sessions in microseconds.
@MainActor
struct PerfMonitorTests {
  /// A hub over an idle offline engine, a monitor on a fake clock, started.
  func rig(
    preference: VizPreference = .auto, store: PerfPreferenceStore? = nil
  ) throws -> (hub: ScopeHub, perf: PerfMonitor, clock: FakeClock) {
    let clock = FakeClock()
    let s =
      store
      ?? PerfPreferenceStore(load: { preference }, save: { _ in })
    let perf = PerfMonitor(clock: { clock.now }, store: s)
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let hub = ScopeHub(engine: dj, perf: perf)
    perf.start()
    return (hub, perf, clock)
  }

  /// One main-thread iteration per `intervalMs`: a visual draw of `drawMs` (timed as `kind`) and
  /// then the heartbeat. A draw longer than the interval stretches it.
  func session(
    _ r: (hub: ScopeHub, perf: PerfMonitor, clock: FakeClock), seconds: Double,
    intervalMs: Double = 1000.0 / 60, drawMs: Double = 0, kind: VizKind = .scope
  ) {
    var elapsed = 0.0
    while elapsed < seconds {
      var spent = 0.0
      if drawMs > 0 {
        r.hub.timed(kind) { r.clock.advance(ms: drawMs) }
        spent = drawMs
      }
      let rest = max(0, intervalMs - spent)
      r.clock.advance(ms: rest)
      r.perf.frame()
      elapsed += (spent + rest) / 1000
    }
  }

  @Test func aSmoothSessionKeepsFullVisuals() throws {
    let r = try rig()
    session(r, seconds: 21, drawMs: 1)
    #expect(r.perf.history.count >= 9)
    #expect(r.perf.history.allSatisfy { $0.cause == .none })
    #expect(r.perf.level == 0 && r.hub.vizLevel == 0 && r.perf.notice == nil)
    let last = try #require(r.perf.last)
    #expect(last.fps > 55 && last.vizSharePct > 0 && last.vizSharePct < 12)
  }

  @Test func aSlowDrawDrivesTheLevelDownTwoWindowsAtATime() throws {
    let r = try rig()
    var told: [Int] = []
    let chained = r.perf.onLevelChange
    r.perf.onLevelChange = {
      told.append($0)
      chained?($0)
    }
    // every iteration is a 40 ms scope draw: 25 fps, all of it the visuals
    session(r, seconds: 3.9, intervalMs: 40, drawMs: 40)
    #expect(r.perf.history.count == 1 && r.perf.history[0].cause == .visualization)
    #expect(r.perf.level == 0, "one bad window is not enough")
    session(r, seconds: 2.1, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 1 && r.hub.vizLevel == 1, "the hub's level follows the monitor")
    #expect(told == [1])
    #expect(r.hub.minFrameInterval == ScopeFramePacer.minInterval(level: 1))
    let notice = try #require(r.perf.notice)
    #expect(notice.text == "Visuals reduced (reduced) to keep playback smooth")
    #expect(notice.level == 1)
    // still bad: down again, to minimal, then paused
    session(r, seconds: 8, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 3 && r.hub.vizLevel == 3)
    #expect(told == [1, 2, 3])
    session(r, seconds: 8, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 3, "paused is the bottom")
  }

  @Test func theSameSlowDrawsOnEachPathAreTimedAsThatPath() throws {
    for kind in VizKind.allCases {
      let r = try rig()
      session(r, seconds: 0.5, intervalMs: 40, drawMs: 20, kind: kind)
      let v = r.perf.currentViz(kind)
      #expect(abs(v.ms - 20 * Double(v.calls)) < 1e-6 && v.calls >= 12, "\(kind)")
      for other in VizKind.allCases where other != kind {
        #expect(r.perf.currentViz(other).calls == 0, "\(kind) leaks into \(other)")
      }
    }
  }

  @Test func jankThatIsNotTheVisualsDoesNotReduceThem() throws {
    let r = try rig()
    // 25 fps with no visual work at all: the machine is busy with something else
    session(r, seconds: 12, intervalMs: 40)
    #expect(r.perf.history.count >= 5)
    #expect(r.perf.history.allSatisfy { $0.cause == .other })
    #expect(r.perf.level == 0 && r.perf.notice == nil)
  }

  @Test func aStallOfOneLongDrawIsBlamedOnTheVisualsEvenWithASmallShare() throws {
    let r = try rig()
    // Smooth 60 fps, but once every ~2.2 s a scope draw takes 200 ms. In its window the median and
    // p95 are 16.7 ms and under 1 % of the frames are dropped, and the draw is 10 % of the time:
    // only the long-task rule sees it (150 ms beyond the threshold = 75 ms/s, and the draw alone
    // is more than half of that).
    for _ in 0..<6 {
      for _ in 0..<119 {
        r.clock.advance(ms: 1000.0 / 60)
        r.perf.frame()
      }
      r.hub.timed(.scope) { r.clock.advance(ms: 200) }
      r.perf.frame()
    }
    let bad = r.perf.history.filter { $0.cause == .visualization }
    #expect(!bad.isEmpty, "long draws give blocking time that is attributed to the visuals")
    let w = try #require(bad.first)
    #expect(w.vizSharePct < 12, "the share alone would not have said so (\(w.vizSharePct) %)")
    #expect(w.longFrames == 1 && w.blockingMsPerS > 50 && w.p95FrameMs < 20)
  }

  @Test func eightCleanWindowsBringTheVisualsBackAndTheNoticeTimesOut() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 1)
    #expect(r.perf.notice != nil)
    session(r, seconds: 8.5, drawMs: 1)
    #expect(r.perf.notice == nil, "the toast is up for 8 s")
    #expect(r.perf.level == 1, "not yet: 8 clean windows are 16 s")
    session(r, seconds: 14, drawMs: 1)
    #expect(r.perf.level == 0 && r.hub.vizLevel == 0)
  }

  @Test func theNoticeIsUpForEightSecondsExactly() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)
    let n = try #require(r.perf.notice)
    func age() -> Double { r.clock.now - n.at }
    while age() < 7.9 {
      session(r, seconds: 0.05, drawMs: 1)
      #expect(r.perf.notice != nil, "still up at \(age()) s")
    }
    while age() < 8.1 { session(r, seconds: 0.02, drawMs: 1) }
    #expect(r.perf.notice == nil, "gone by \(age()) s")
  }

  /// A window of smooth 60 fps with, on top of it, stalls of 100 ms from somewhere else and
  /// draws of `drawMs` of the scope, one after the other, until a window closes. The stalls alone
  /// make the window janky (blocking beyond 50 ms per second); the draws are a small share of it.
  func windowWithStallsAndDraws(drawMs: Double) throws -> PerfWindowStats {
    let r = try rig()
    var cycle = 0
    while r.perf.history.isEmpty {
      for _ in 0..<20 {
        r.clock.advance(ms: 1000.0 / 60)
        r.perf.frame()
      }
      if cycle % 2 == 0 {
        r.clock.advance(ms: 100)
      } else {
        r.hub.timed(.scope) { r.clock.advance(ms: drawMs) }
      }
      r.perf.frame()
      cycle += 1
    }
    return try #require(r.perf.history.first)
  }

  @Test func aDrawJustOverTheLongTaskThresholdIsBlamedOnTheVisuals() throws {
    let w = try windowWithStallsAndDraws(drawMs: 60)
    #expect(w.blockingMsPerS > 50 && w.jank, "the stalls make the window janky")
    #expect(w.vizSharePct < 12, "the draws are too small a share to be blamed by that rule")
    #expect(w.vizHeavy && w.cause == .visualization, "but 120 of its 170 blocking ms are theirs")
  }

  @Test func aDrawUnderTheLongTaskThresholdIsNotBlamed() throws {
    let w = try windowWithStallsAndDraws(drawMs: 45)
    #expect(w.jank && !w.vizHeavy && w.cause == .other)
  }

  @Test func aLevelBeingReEnteredSoonStaysTheFloor() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)  // down to 1
    // The window that was open at the step down still holds a slow tail (judged bad, which is
    // only one in a row), so eight clean windows end ~18 s later: up to 0.
    session(r, seconds: 19, drawMs: 1)
    #expect(r.perf.level == 0)
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)  // down again, right away
    #expect(r.perf.level == 1)
    session(r, seconds: 40, drawMs: 1)  // plenty of clean windows
    #expect(r.perf.level == 1, "the floor holds for the session")
  }

  // MARK: preference

  @Test func aPinnedPreferenceTakesEffectAtOnceAndNeverMoves() throws {
    let r = try rig()
    r.perf.setPreference(.minimal)
    #expect(r.perf.level == 2 && r.hub.vizLevel == 2 && r.perf.preference == .minimal)
    session(r, seconds: 12, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 2, "windows are judged, the level stays")
    #expect(r.perf.history.allSatisfy { $0.cause == .visualization && $0.level == 2 })
    r.perf.setPreference(.full)
    #expect(r.hub.vizLevel == 0)
    r.perf.setPreference(.paused)
    #expect(r.hub.vizLevel == 3)
  }

  @Test func choosingAPreferenceDismissesTheNotice() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)
    #expect(r.perf.notice != nil)
    r.perf.keepFullVisuals()
    #expect(r.perf.notice == nil && r.perf.preference == .full && r.hub.vizLevel == 0)
  }

  @Test func theHubStartsAtThePinnedLevelOfAMonitorThatRemembersOne() throws {
    let r = try rig(preference: .reduced)
    #expect(r.perf.level == 1 && r.hub.vizLevel == 1 && r.perf.preference == .reduced)
  }

  @Test func thePreferenceIsRemembered() throws {
    var saved: [VizPreference] = []
    let store = PerfPreferenceStore(load: { saved.last ?? .auto }, save: { saved.append($0) })
    let r = try rig(store: store)
    r.perf.setPreference(.reduced)
    r.perf.setPreference(.auto)
    #expect(saved == [.reduced, .auto])
    let again = PerfMonitor(store: PerfPreferenceStore(load: { .minimal }, save: { _ in }))
    #expect(again.level == 2 && again.preference == .minimal)
  }

  @Test func theDefaultsStoreKeepsItUnderMonitorJsKey() {
    let d = scratchDefaultsStore()
    defer { d.clean() }
    #expect(PerfPreferenceStore.key == "pn-viz-quality")
    #expect(d.store.load() == .auto)
    d.store.save(.minimal)
    #expect(d.read() == "minimal" && d.store.load() == .minimal)
    d.store.save(.auto)
    #expect(d.read() == "auto" && d.store.load() == .auto)
  }

  // MARK: running

  @Test func nothingIsMeasuredWhileStopped() throws {
    let r = try rig()
    r.perf.stop()
    #expect(!r.perf.isRunning)
    session(r, seconds: 6, intervalMs: 40, drawMs: 40)
    #expect(r.perf.history.isEmpty && r.perf.level == 0)
    #expect(r.perf.currentViz(.scope).calls == 0, "vizEnd is a no-op")
  }

  @Test func aPauseBetweenRunsIsNotAHugeFrame() throws {
    let r = try rig()
    session(r, seconds: 1)
    r.perf.stop()
    r.clock.advance(ms: 60_000)  // paused for a minute
    r.perf.start()
    session(r, seconds: 2.1)
    #expect(r.perf.history.count == 1)
    #expect(r.perf.history[0].cause == .none && r.perf.history[0].longFrames == 0)
  }

  @Test func theLevelSurvivesAStopAndStart() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 1)
    r.perf.stop()
    r.perf.start()
    #expect(r.perf.level == 1 && r.hub.vizLevel == 1, "perfStart keeps `m.level`")
  }

  // The next two are pinned against the real monitor.js, run in node with a hand-moved clock:
  // `perfStart` assigns `bad: 0, clean: 0` every time, so a pause breaks a streak.
  //   one bad window, perfStop, perfStart, one bad window      -> level 0, bad 1
  //   level 1, 5 clean windows, stop, start, 3 clean windows   -> level 1, clean 3

  @Test func aPauseBetweenTwoBadWindowsBreaksTheStreak() throws {
    let r = try rig()
    session(r, seconds: 2.1, intervalMs: 40, drawMs: 40)
    #expect(r.perf.history.count == 1 && r.perf.history[0].cause == .visualization)
    r.perf.stop()
    r.perf.start()
    session(r, seconds: 2.1, intervalMs: 40, drawMs: 40)
    #expect(r.perf.history.count == 2 && r.perf.history[1].cause == .visualization)
    #expect(r.perf.level == 0 && r.perf.notice == nil, "two bad windows, but not in a row")
    // the streak counts again from there
    session(r, seconds: 2.1, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 1, "two in a row since the restart")
  }

  @Test func aPauseBetweenCleanWindowsBreaksTheClimbBackUp() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)
    #expect(r.perf.level == 1)
    r.perf.stop()
    r.perf.start()
    session(r, seconds: 11, drawMs: 1)  // 5 clean windows
    #expect(r.perf.history.suffix(5).allSatisfy { $0.cause == .none } && r.perf.level == 1)
    r.perf.stop()
    r.perf.start()
    session(r, seconds: 6.5, drawMs: 1)  // 3 more: 8 in all, but not in a row
    #expect(r.perf.level == 1, "the clean count started over at the restart")
    session(r, seconds: 10, drawMs: 1)  // 8 since the restart
    #expect(r.perf.level == 0)
  }

  @Test func theFloorAndTheTimeOfTheLastStepUpSurviveAStopAndStart() throws {
    let r = try rig()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)  // down to 1
    r.perf.stop()
    r.perf.start()
    session(r, seconds: 17.5, drawMs: 1)  // eight clean windows: up to 0
    #expect(r.perf.level == 0)
    r.perf.stop()
    r.perf.start()
    session(r, seconds: 4.3, intervalMs: 40, drawMs: 40)  // down again, within 30 s of the step up
    #expect(r.perf.level == 1)
    r.perf.stop()
    r.perf.start()
    session(r, seconds: 40, drawMs: 1)
    #expect(r.perf.level == 1, "level 1 is the floor of the session, whatever was paused between")
  }

  @Test func theWindowIsTwoSecondsAndHistoryKeepsSixty() throws {
    let r = try rig()
    session(r, seconds: 130, drawMs: 1)
    #expect(r.perf.history.count == 60)
    #expect(r.perf.history.allSatisfy { $0.spanMs >= 2000 && $0.spanMs < 2030 })
  }

  @Test func theHeartbeatTimerFeedsFramesAndClosesWindows() async throws {
    var cfg = PerfConfig()
    cfg.windowMs = 100
    let perf = PerfMonitor(config: cfg, heartbeatInterval: 0.005)
    perf.start()
    spinMainRunLoop(seconds: 0.6)
    perf.stop()
    #expect(!perf.history.isEmpty, "the run loop timer called frame()")
    let w = try #require(perf.history.first)
    #expect(w.fps > 20, "a 5 ms timer is far above 20 fps (\(w.fps))")
    let n = perf.history.count
    spinMainRunLoop(seconds: 0.3)
    #expect(perf.history.count == n, "stop() cancelled the timer")
  }

  @Test func theHubWithoutAnExplicitMonitorStartsAtFullAndMeasuresNothing() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let hub = ScopeHub(engine: dj)
    #expect(hub.vizLevel == 0 && !hub.perf.isRunning && hub.perf.preference == .auto)
    var ran = 0
    let value = hub.timed(.stage) {
      ran += 1
      return 7
    }
    #expect(value == 7 && ran == 1 && hub.perf.currentViz(.stage).calls == 0)
  }

  @Test func anAnimationsIntervalIsObservedThroughTheMonitor() throws {
    // MacroButton and DeviceMapView ask `hub.interval(cappedAt:)` in their `body`; SwiftUI rebuilds
    // them when what they read changes, so the call has to read something the monitor writes.
    let r = try rig()
    let flag = ChangeFlag()
    let before = withObservationTracking {
      r.hub.interval(cappedAt: 1.0 / 30)
    } onChange: {
      flag.fire()
    }
    #expect(before == 1.0 / 30 && !flag.fired)
    r.perf.setPreference(.minimal)
    #expect(flag.fired, "the level moved: whoever asked is told")
    #expect(r.hub.interval(cappedAt: 1.0 / 30) == 1.0 / 8, "and the slower scope table now rules")
  }

  @Test func aDirectWriteToTheHubLevelStillWorksForTests() throws {
    let r = try rig()
    r.hub.vizLevel = 3
    #expect(r.hub.minFrameInterval == 0.25)
    #expect(r.perf.level == 0, "the monitor's own level is only moved by the monitor")
  }
}

/// Set from an observation callback (which is `@Sendable`).
final class ChangeFlag: @unchecked Sendable {
  private(set) var fired = false
  func fire() { fired = true }
}
