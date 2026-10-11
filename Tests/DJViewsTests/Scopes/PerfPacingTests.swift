import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The drivers really run at the rate of the visual level: views are mounted in a window that is
/// never shown (its timelines tick, `onChange` runs) and their frames are counted over a second of
/// wall time. Upper bounds are tight (that is the pacing), lower bounds loose (a loaded machine).
@MainActor
struct PerfPacingTests {
  static let fps = [30, 15, 8, 4]

  /// Draws of a mounted `ScopeCanvas` in `seconds`.
  func scopeDraws(_ hub: ScopeHub, kind: VizKind = .scope, seconds: Double = 0.8) -> Int {
    let counter = DrawCounter()
    let mount = HostHarness(
      ScopeCanvas(hub: hub, kind: kind) { _, _ in counter.draws += 1 }, width: 200, height: 60)
    mount.settle(seconds)
    mount.unmount()
    return counter.draws
  }

  @Test(arguments: [0, 1, 2, 3])
  func aScopeCanvasDrawsAtTheRateOfTheLevelItIsMountedAt(_ level: Int) throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.vizLevel = level
    let want = Double(Self.fps[level]) * 0.8
    let got = scopeDraws(rig.hub)
    #expect(Double(got) <= want + 3, "level \(level): \(got) draws in 0.8 s, at most \(want) + 3")
    // a driver stuck at half the rate (15 fps at full, 2 at paused) must fail
    #expect(
      Double(got) >= want * 0.6, "level \(level): \(got) draws in 0.8 s, at least 60 % of \(want)")
  }

  @Test func aLevelChangedAfterMountingRepacesTheCanvasWithoutAnyRebuild() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let counter = DrawCounter()
    let mount = HostHarness(
      ScopeCanvas(hub: rig.hub) { _, _ in counter.draws += 1 }, width: 200, height: 60)
    mount.settle(0.5)
    #expect(counter.draws >= 8, "full level: ~30 fps (\(counter.draws) in 0.5 s)")
    rig.hub.vizLevel = 3  // nothing rebuilds the view: the frame that sees the level re-paces it
    mount.settle(0.3)
    var before = counter.draws
    mount.settle(0.8)
    let paused = counter.draws - before
    #expect(paused <= 6 && paused >= 1, "paused level: ~4 fps (\(paused) in 0.8 s)")
    // and through the monitor, which is what the menu talks to
    rig.hub.perf.setPreference(.minimal)
    #expect(rig.hub.vizLevel == 2)
    mount.settle(0.3)
    before = counter.draws
    mount.settle(0.8)
    let minimal = counter.draws - before
    mount.unmount()
    #expect(minimal <= 9 && minimal >= 3, "minimal level: ~8 fps (\(minimal) in 0.8 s)")
  }

  // MARK: small animations

  @Test func theSmallAnimationsFollowALevelChangeWithoutAnyRebuild() throws {
    // MacroButton's glow and DeviceMapView's blink ask `hub.interval(cappedAt:)` while building
    // their body: a body that asks must be built again when the monitor moves the level.
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let counter = BodyCounter()
    let mount = HostHarness(
      IntervalProbe(counter: counter).environment(\.scopeHub, rig.hub), width: 120, height: 30)
    mount.settle(0.3)
    let first = counter.bodies
    #expect(first >= 1 && counter.lastInterval == 1.0 / 30)
    rig.hub.perf.setPreference(.minimal)
    mount.settle(0.3)
    mount.unmount()
    #expect(counter.bodies > first, "the body asked again")
    #expect(counter.lastInterval == 1.0 / 8, "and got the slower interval of the level")
  }

  // MARK: the Stage

  @Test(arguments: [1, 2, 3])
  func theStageFollowsItsOwnTableOfCaps(_ level: Int) throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    rig.hub.vizLevel = level
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    let mount = HostHarness(StageView(model: rig.model), width: 400, height: 300)
    mount.settle(1.0)
    let frames = rig.model.advances
    mount.unmount()
    let want = [0, 30, 15, 4][level]
    #expect(frames <= want + 4, "level \(level): \(frames) frames, at most \(want) + 4")
    #expect(frames >= max(1, want / 2), "level \(level): \(frames) frames")
  }

  @Test func theStageRepacesWhenTheMonitorChangesTheLevel() throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    let mount = HostHarness(StageView(model: rig.model), width: 400, height: 300)
    mount.settle(0.5)
    let fast = rig.model.advances
    #expect(fast >= 10, "full level: at the display's rate (\(fast) frames in 0.5 s)")
    rig.hub.perf.setPreference(.paused)
    mount.settle(0.4)
    let before = rig.model.advances
    mount.settle(1.0)
    let paused = rig.model.advances - before
    mount.unmount()
    #expect(paused <= 6 && paused >= 2, "paused level: 4 fps (\(paused) in a second)")
  }

  @Test func theTimelineDotsGoThroughTheSamePacing() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    rig.hub.vizLevel = 3
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    let mount = HostHarness(
      TimelineDotsView(feed: feed, hub: rig.hub, active: true), width: 300, height: 30)
    mount.settle(1.0)
    let calls = rig.hub.perf.currentViz(.timeline).calls
    mount.unmount()
    #expect(calls >= 2 && calls <= 7, "the dots strip at 4 fps (\(calls))")
    #expect(rig.hub.perf.currentViz(.scope).calls == 0, "and it is booked as the timeline")
  }
}
