import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 28 on screen: feed.html's flame, drawn from the model's frame; the same view fed by a
// real offline engine; and its subscription to the master tap.

private let bg = (5, 10, 20)  // #050a14
private let baseline = (27, 110, 152)  // hsl(200, 70%, 35%): a bar at its 2 px floor
private let top = (255, 187, 51)  // hsl(40, 100%, 60%): a full-height bar
private let idleLine = (26, 42, 58)  // #1a2a3a

@MainActor
struct MasterFlameViewTests {
  let width = 940  // 94 bars of 10 px: the bar maths in whole pixels
  let height = 76

  func sine(bin: Int) -> [Float] {
    (0..<256).map { 0.5 * Float(sin(2 * Double.pi * Double(bin) * Double($0) / 256)) }
  }

  /// The model after `n` analyses of a steady sine, 60 Hz apart.
  func lit(bin: Int, analyses n: Int = 40) -> FlameMeterModel {
    let m = FlameMeterModel()
    for k in 0..<n { m.analyse(sine(bin: bin), at: Double(k) / 60) }
    return m
  }

  /// The pixel column through the middle of bar `i` of a `width`-wide canvas.
  func column(_ i: Int) -> Int { Int((Double(i) + 0.5) * Double(width) / 94) }

  @Test func aSineOnABinLightsItsBarAndTheWindowsLeakageAndNothingElse() throws {
    let m = lit(bin: 10)
    let frame = m.frame(width: Double(width), height: Double(height), active: true)
    let px = try #require(
      renderPixels(FlameMeterFrameView(frame: frame), width: width, height: height))
    savePNG(
      FlameMeterFrameView(frame: frame), width: width, height: height, name: "flame-sine-bin10")
    // bin 10 is bar 8: full height, the top of the gradient at its tip
    #expect(px.near(column(8), 3, top, tol: 12), "bar 8 reaches the top: \(px.color(column(8), 3))")
    // and up to the very top row, over the box's ring (CSS paints the ring under the bitmap)
    #expect(
      px.near(column(8), 0, top, tol: 12),
      "the ring does not cut the bar: \(px.color(column(8), 0))")
    #expect(
      px.near(column(3), 0, idleLine, tol: 8), "while an empty column shows the ring at the top")
    #expect(px.near(column(8), height - 5, FlameLayout.color(forValue: 1).rgb8, tol: 12))
    // bins 9 and 11 (bars 7, 9) leak 0.25 and are at full scale too; 8 and 12 (bars 6, 10) 0.04
    #expect(px.near(column(7), 3, top, tol: 12) && px.near(column(9), 3, top, tol: 12))
    #expect(!px.near(column(6), 3, top, tol: 60), "bar 6 is 218/255 high: its tip is at y = 11")
    #expect(px.near(column(6), 30, FlameLayout.color(forValue: 218.0 / 255).rgb8, tol: 14))
    #expect(px.near(column(10), 30, FlameLayout.color(forValue: 218.0 / 255).rgb8, tol: 14))
    // everything else rests at its 2 px floor, in the gradient's own bottom colour
    for i in [0, 3, 5, 11, 12, 30, 60, 93] {
      #expect(px.near(column(i), 40, bg, tol: 6), "bar \(i) is empty above the floor")
      #expect(
        px.near(column(i), height - 2, baseline, tol: 14),
        "bar \(i) has its 2 px: \(px.color(column(i), height - 2))")
    }
  }

  @Test func theBarsRiseAndFallLikeTheAnalyser() throws {
    // after one analysis the bar is attenuated by (1 - 0.78): byte 245, not 255
    let first = FlameMeterModel()
    first.analyse(sine(bin: 10), at: 0)
    let f1 = first.frame(width: Double(width), height: Double(height), active: true)
    #expect(f1.bars[8].value == 245)
    #expect(abs(f1.bars[8].rect.height - 245.0 / 255 * 76) < 1e-9)
    let px = try #require(
      renderPixels(FlameMeterFrameView(frame: f1), width: width, height: height))
    #expect(px.near(column(8), 6, FlameLayout.color(forValue: 245.0 / 255).rgb8, tol: 14))
    // then it decays
    for k in 1...20 { first.analyse([Float](repeating: 0, count: 256), at: Double(k) / 60) }
    #expect(first.bytes.allSatisfy { $0 < 100 })
  }

  @Test func silenceWhilePlayingIsABaselineOfTwoPixelBarsAndIdleIsAFlatLine() throws {
    let silent = FlameMeterModel()
    silent.analyse([Float](repeating: 0, count: 256), at: 0)
    let frame = silent.frame(width: Double(width), height: Double(height), active: true)
    let px = try #require(
      renderPixels(FlameMeterFrameView(frame: frame), width: width, height: height))
    savePNG(FlameMeterFrameView(frame: frame), width: width, height: height, name: "flame-silence")
    #expect(px.near(column(20), height - 2, baseline, tol: 14))
    #expect(px.near(column(20), 38, bg, tol: 6), "nothing above the floor, and no idle line")
    let idle = try #require(
      renderPixels(FlameIdleView().environment(\.displayScale, 1), width: width, height: height))
    savePNG(
      FlameIdleView().environment(\.displayScale, 1), width: width, height: height,
      name: "flame-idle")
    #expect(px.near(5, 38, bg, tol: 6))
    #expect(
      idle.near(column(20), 37, idleLine, tol: 6) && idle.near(column(20), 38, idleLine, tol: 6))
    #expect(idle.near(column(20), 30, bg, tol: 6) && idle.near(column(20), 45, bg, tol: 6))
    #expect(idle.near(column(20), height - 2, bg, tol: 6), "no bars while idle")
  }

  @Test func theBarsAreLaidOutInDevicePixelsAndKeepTheirOnePixelGapOnARetinaScreen() throws {
    // 94 bars of 4 device pixels on a 376 x 76 pixel canvas that is 188 x 38 points at scale 2:
    // bar 8 is x = 32.5 ..< 35.5, bar 9 x = 36.5 ..< 39.5 in device pixels
    let m = lit(bin: 10)
    let frame = m.frame(width: 376, height: 76, active: true)
    let view = FlameMeterFrameView(frame: frame, scale: 2).environment(\.displayScale, 2)
    let px = try #require(renderPixels(view, width: 188, height: 38, scale: 2))
    #expect(px.width == 376 && px.height == 76)
    savePNG(view, width: 188, height: 38, name: "flame-retina")
    #expect(px.near(34, 20, top, tol: 12), "inside bar 8: \(px.color(34, 20))")
    #expect(px.near(38, 20, top, tol: 12), "inside bar 9: \(px.color(38, 20))")
    // at 32 and 35/36 the bars' half-pixel edges blend with the box behind them
    for x in [32, 35, 36] {
      let c = px.color(x, 20)
      #expect(!px.near(x, 20, top, tol: 25) && !px.near(x, 20, bg, tol: 25), "pixel \(x): \(c)")
    }
    // laid out in points instead, bar 8 would sit at 65 ..< 71 and bar 17 (here at 68) be empty
    #expect(px.near(68, 20, bg, tol: 20), "a quiet bar above its floor: \(px.color(68, 20))")
    #expect(px.near(20, 10, bg, tol: 20), "a quiet bar leaves the box dark above its floor")
  }

  // MARK: engine-fed

  @Test func theMasterMixOfAPlayingDeckDrawsTheBarsTheModelSays() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    defer { feed.release() }
    try rig.run(seconds: 1)
    // what a first analysis of the master tap gives, bar by bar
    let oracle = FlameMeterModel()
    oracle.update(feed: feed, at: 0)
    let want = oracle.frame(width: Double(width), height: 38, active: true)
    #expect(want.bars.contains { $0.rect.height > 8 }, "the mix has something to show")
    let view = MasterFlameView(hub: rig.hub, active: true).environment(\.displayScale, 1)
    savePNG(view, width: width, height: 38, name: "flame-engine-fed")
    let px = try #require(renderPixels(view, width: width, height: 38))
    var checked = 0
    for (i, bar) in want.bars.enumerated() where bar.rect.height > 8 {
      // the bar's colour (not the background) a few pixels below its tip
      let y = Int(bar.rect.y) + 3
      #expect(
        !px.near(column(i), y, bg, tol: 30), "bar \(i) (\(bar.value)): \(px.color(column(i), y))")
      checked += 1
    }
    #expect(checked >= 1)
    for (i, bar) in want.bars.enumerated() where bar.rect.height <= 2.5 && i % 7 == 0 {
      #expect(px.near(column(i), 20, bg, tol: 30), "bar \(i) is at its floor")
    }
  }

  @Test func aStoppedEngineOnTheIdleViewIsAFlatLineWhateverTheMasterTapHolds() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    defer { feed.release() }
    try rig.run(seconds: 1)
    let idle = MasterFlameView(hub: rig.hub, active: false).environment(\.displayScale, 1)
    let px = try #require(renderPixels(idle, width: width, height: 38))
    #expect(px.near(column(10), 18, idleLine, tol: 6) || px.near(column(10), 19, idleLine, tol: 6))
    #expect(px.near(column(10), 30, bg, tol: 6) && px.near(column(40), 30, bg, tol: 6))
  }

  // MARK: the subscription

  @Test func theMeterListensToTheMasterTapOnlyWhileADeckPlaysAndItsViewIsUp() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    func mounted(active: Bool) -> MasterFlameView { MasterFlameView(hub: rig.hub, active: active) }

    let idle = HostHarness(mounted(active: false), width: 160, height: 38)
    idle.settle()
    #expect(feed.subscribers == 0 && !rig.dj.masterTap.isEnabled, "idle costs no tap")
    idle.update(mounted(active: true))
    idle.settle()
    #expect(feed.subscribers == 1 && rig.dj.masterTap.isEnabled, "a deck started playing")
    idle.update(mounted(active: false))
    idle.settle()
    #expect(feed.subscribers == 0 && !rig.dj.masterTap.isEnabled, "and stopped")
    idle.update(mounted(active: true))
    idle.settle()
    #expect(feed.subscribers == 1)
    idle.unmount()
    idle.settle()
    #expect(feed.subscribers == 0 && !rig.dj.masterTap.isEnabled, "the view went away")

    let live = HostHarness(mounted(active: true), width: 160, height: 38)
    live.settle()
    #expect(feed.subscribers == 1, "appearing while a deck already plays")
    live.unmount()
    live.settle()
    #expect(feed.subscribers == 0)
  }

  @Test func rebuildingTheViewDoesNotBuildAnAnalyserEachTime() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let before = FlameMeterModel.built
    // a parent's body, evaluated 50 times
    for _ in 0..<50 { _ = MasterFlameView(hub: rig.hub, active: true) }
    #expect(FlameMeterModel.built == before, "\(FlameMeterModel.built - before) models built")
    // the first draw makes the one it needs, and the next frames reuse it
    let mount = HostHarness(MasterFlameView(hub: rig.hub, active: true), width: 160, height: 38)
    mount.settle(0.3)
    mount.unmount()
    #expect(FlameMeterModel.built == before + 1, "\(FlameMeterModel.built - before) models built")
  }

  @Test func theMeterIsPacedByTheVisualLevelLikeTheScopes() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    rig.hub.vizLevel = 3
    let mount = HostHarness(MasterFlameView(hub: rig.hub, active: true), width: 160, height: 38)
    mount.settle(1.0)
    let calls = rig.hub.perf.currentViz(.scope).calls
    mount.unmount()
    #expect(calls >= 2 && calls <= 7, "4 fps when paused, booked as a scope path (\(calls))")
  }
}
