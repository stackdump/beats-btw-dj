import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Flame beams (SPEC mode 15), rendered through the real layer stack on the 4-panel OverlayStage
// (centre (500, 400), inner radius 40). A beam is a polygon filled with a gradient that runs from
// the ring centre to the tip: amber rgba(255,200,64,.85 v) at 0, rgba(233,69,96,.7 v) at .5,
// rgba(74,144,217,0) at 1. The expected colours are that gradient worked out here (straight RGBA
// interpolation, then laid over the stage background), not read off the render.

@MainActor
struct StageFlameRenderTests {
  private let centre = StagePoint(x: 500, y: 400)
  private let origin = StagePoint(x: 560, y: 180)

  /// The gradient's colour at `s` (0...1 along the beam) for energy `v`, over the background.
  private func expected(_ s: Double, _ v: Double) -> (Int, Int, Int) {
    let stops: [(Double, (Double, Double, Double), Double)] = [
      (0, (255, 200, 64), 0.85 * v), (0.5, (233, 69, 96), 0.7 * v), (1, (74, 144, 217), 0),
    ]
    let hi = stops.firstIndex { $0.0 >= s } ?? 2
    let a = stops[max(0, hi - 1)]
    let b = stops[hi]
    let u = b.0 == a.0 ? 0 : (s - a.0) / (b.0 - a.0)
    let alpha = a.2 + (b.2 - a.2) * u
    func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
    let bg = Sw.background
    func over(_ c: Double, _ bg: Int) -> Int {
      Int((Double(bg) + alpha * (c - Double(bg))).rounded())
    }
    return (
      over(mix(a.1.0, b.1.0), bg.0), over(mix(a.1.1, b.1.1), bg.1), over(mix(a.1.2, b.1.2), bg.2)
    )
  }

  /// The pixel `d` points along the beam toward `target` from the ring centre.
  private func along(_ target: StagePoint, _ d: Double) -> (Int, Int) {
    let dx = target.x - centre.x
    let dy = target.y - centre.y
    let len = hypot(dx, dy)
    return (Int((centre.x + dx / len * d).rounded()), Int((centre.y + dy / len * d).rounded()))
  }

  @Test func aBeamIsAmberAtTheBaseRoseInTheMiddleAndFadesToNothingAtTheTip() throws {
    var s = try OverlayStage(overlays: [.flame])
    s.step(dt: 0, fires: [s.fire(origin: origin)])  // energy 0.9, no decay this frame
    let v = 0.9
    let model = s.layers.flame
    #expect(model.energies["A/n0"] == v)
    let barLen = hypot(origin.x - centre.x, origin.y - centre.y) * (0.55 + 0.4 * v)
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-flame-beam")
    // amber right at the base (the polygon starts at the inner radius, 40 from the centre)
    for d in [45.0, 80, 120, 160, 195] {
      let (x, y) = along(origin, d)
      let want = expected(d / barLen, v)
      #expect(px.near(x, y, want, tol: 9), "d = \(d): \(px.color(x, y)) vs \(want)")
    }
    // the base is amber-dominated, the middle rose, the tip has nearly gone
    let base = along(origin, 45)
    let mid = along(origin, barLen / 2)
    let tip = along(origin, barLen - 3)
    #expect(px.color(base.0, base.1).g > 90 && px.color(base.0, base.1).r > 150, "amber")
    #expect(px.color(mid.0, mid.1).r > 120 && px.color(mid.0, mid.1).g < 60, "rose")
    #expect(px.color(tip.0, tip.1).r < 30, "faded")
    // nothing inside the inner radius, nor past the tip, nor beside the beam
    let inside = along(origin, 30)
    #expect(px.near(inside.0, inside.1, Sw.background, tol: 3))
    let past = along(origin, barLen + 12)
    #expect(px.near(past.0, past.1, Sw.background, tol: 3))
    #expect(px.near(530, 330, Sw.background, tol: 3) || px.near(545, 330, Sw.background, tol: 3))
  }

  @Test func theBeamIsAboutNinePointsWideAndPointsAtTheFiredTransition() throws {
    var s = try OverlayStage(overlays: [.flame])
    s.step(dt: 0, fires: [s.fire(origin: origin)])
    let px = try s.pixels()
    // a cross-section 100 along the beam: base half width 40 sin(0.1) = 3.99 at the base, tip 5.2
    // at the tip: 4.42 at this distance (0.359 of the way from base to tip), so 8.8 points across;
    // the polygon's exact width is pinned by `StageFlameNumbersTests`
    let theta = atan2(origin.y - centre.y, origin.x - centre.x)
    let cx = centre.x + 100 * cos(theta)
    let cy = centre.y + 100 * sin(theta)
    var lit = 0
    for k in -12...12 {
      let x = Int((cx - Double(k) * sin(theta)).rounded())
      let y = Int((cy + Double(k) * cos(theta)).rounded())
      if px.color(x, y).r > 40 { lit += 1 }
    }
    #expect(lit >= 8 && lit <= 10, "about nine points across (\(lit))")
    // the whole beam leans toward the fired transition, not the panel's ring point (500, 144)
    let region = px.count(inX: 440..<500, y: 160..<360) { r, g, b in r > 60 }
    #expect(region == 0, "nothing to the left of the axis, nor straight up the stage: \(region)")
  }

  @Test func theBeamDimsFrameByFrameAndIsGoneWithinASecond() throws {
    var s = try OverlayStage(overlays: [.flame])
    s.step(dt: 0, fires: [s.fire(origin: origin)])
    let a = try s.pixels()
    let probe = along(origin, 80)
    let r0 = a.color(probe.0, probe.1).r
    s.step(dt: 0.1)  // x 0.67
    let b = try s.pixels()
    let r1 = b.color(probe.0, probe.1).r
    #expect(r1 < r0 && r1 > Sw.background.0, "dimmer but still there")
    let v = 0.9 * 0.67032004603563933
    let barLen = hypot(origin.x - centre.x, origin.y - centre.y) * (0.55 + 0.4 * v)
    let want = expected(80 / barLen, v)
    #expect(b.near(probe.0, probe.1, want, tol: 9), "\(b.color(probe.0, probe.1)) vs \(want)")
    for _ in 0..<12 { s.step(dt: 0.1) }  // 1.2 s: 0.9 e^-4.8 = 0.007 < 0.01
    #expect(s.layers.flame.energies.isEmpty)
    let c = try s.pixels()
    let lit = c.count(inX: 400..<700, y: 100..<400) { r, g, b in r > 40 }
    #expect(lit == 0, "the flame has died (\(lit))")
  }

  @Test func eachPanelShootsItsOwnBeamAndTheNewestIsOnTop() throws {
    var s = try OverlayStage(overlays: [.flame])
    let right = StagePoint(x: 820, y: 400)
    let down = StagePoint(x: 500, y: 600)
    s.step(
      dt: 0,
      fires: [
        s.fire(panel: 1, origin: right), s.fire(panel: 2, origin: down), s.fire(origin: origin),
      ])
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-flame-three")
    for (target, d) in [(right, 100.0), (down, 80.0), (origin, 90.0)] {
      let (x, y) = along(target, d)
      #expect(px.color(x, y).r > 120, "a beam toward \(target): \(px.color(x, y))")
    }
    // and none to the fourth panel (244, 400)
    let left = along(StagePoint(x: 244, y: 400), 100)
    #expect(px.near(left.0, left.1, Sw.background, tol: 3))
  }

  @Test func turningFlameOffClearsTheBeamsAndTurningItOnStartsClean() throws {
    var s = try OverlayStage(overlays: [.flame])
    s.step(dt: 0, fires: [s.fire(origin: origin)])
    s.step(dt: 0.05, overlays: [])
    let off = try s.pixels()
    #expect(off.count(inX: 380..<640, y: 150..<420) { r, g, b in r > 40 } == 0)
    #expect(s.layers.flame.energies.isEmpty)
    s.step(dt: 0.05, overlays: [.flame])
    let on = try s.pixels()
    #expect(on.count(inX: 380..<640, y: 150..<420) { r, g, b in r > 40 } == 0, "nothing returns")
  }

  @Test func aLonePanelHasNoBeam() throws {
    var s = try OverlayStage(panels: 1, overlays: [.flame])
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: 600, y: 300))])
    let px = try s.pixels()
    #expect(px.count(inX: 100..<900, y: 100..<700) { r, g, b in r > 40 } == 0)
  }

  @Test func theBeamSitsUnderTheBoltsAndTheMetaNet() throws {
    // the meta-net's arcs are drawn over the beam: a place circle's stroke crosses the beam
    var s = try OverlayStage(overlays: [.flame], meta: true)
    let place = s.context.layout.placeCenters[0]
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: place.x, y: place.y))])
    let px = try s.pixels()
    let r = try #require(s.context.layout.placeR)
    // the stroke at the circle's top edge is #4a90d9 at .45: blue wins over the beam under it
    let top = px.color(Int(place.x), Int((place.y - r).rounded()))
    #expect(top.b > top.r, "meta stroke over the flame: \(top)")
  }
}
