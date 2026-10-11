import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Pulse particles (SPEC mode 14), rendered through the real layer stack. The stage is the
// 4-panel OverlayStage (centre (500, 400); panel 0 at (500, 144)); a dot's colour is #e94560 at
// 0.7 (1 - t) over the stage background #0a0a1a, computed here (not read off the render).

@MainActor
struct StagePulseRenderTests {
  private let top = StagePoint(x: 500, y: 144)

  @Test func aParticleAQuarterOfTheWayIsASevenAndAHalfPointDotOnTheLineToTheCentre() throws {
    var s = try OverlayStage(overlays: [.pulse])
    // spawned 175 ms ago: t = 0.25, e = 0.4375 -> y = 144 + 256 * 0.4375 = 256, r = 7.5, a = 0.525
    s.step(dt: 0, fires: [s.fire(origin: top, age: 0.175)])
    #expect(s.layers.pulse.particles.count == 1)
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-pulse-quarter")
    let want = OverlaySwatch.over(Sw.red, 0.525, Sw.background)
    #expect(px.near(500, 256, want, tol: 4), "the dot's centre: \(px.color(500, 256))")
    #expect(px.near(504, 256, want, tol: 4) && px.near(500, 252, want, tol: 4), "inside r = 7.5")
    #expect(px.near(509, 256, Sw.background, tol: 3), "outside it: \(px.color(509, 256))")
    #expect(px.near(500, 265, Sw.background, tol: 3) && px.near(500, 247, Sw.background, tol: 3))
    // it is not at its start any more, nor at the centre yet
    #expect(px.near(500, 144, Sw.background, tol: 3) && px.near(500, 400, Sw.background, tol: 3))
    // and the area: pi * 7.5^2 = 176.7 pixels of the dot
    let dot = px.count(inX: 480..<520, y: 236..<276) { r, g, b in r > 80 }
    #expect(dot > 150 && dot < 205, "a 7.5 point disc: \(dot) pixels")
  }

  @Test func aNewParticleIsAFullSizeDotOnItsTransition() throws {
    var s = try OverlayStage(overlays: [.pulse])
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: 700, y: 300))])
    let px = try s.pixels()
    let want = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    #expect(px.near(700, 300, want, tol: 4), "r = 10, alpha 0.7: \(px.color(700, 300))")
    #expect(px.near(708, 300, want, tol: 4) && px.near(700, 308, want, tol: 4), "inside 10")
    #expect(px.near(712, 300, Sw.background, tol: 3), "outside 10")
    let area = px.count(inX: 680..<720, y: 280..<320) { r, g, b in r > 80 }
    #expect(area > 290 && area < 340, "pi 10^2 = 314: \(area)")
  }

  @Test func theDotFadesAndShrinksTowardTheCentreAndIsGone() throws {
    var s = try OverlayStage(overlays: [.pulse])
    s.step(dt: 0, fires: [s.fire(origin: top)])
    let red = { (px: Pixels, y: Int) in px.color(500, y).r }
    let first = try s.pixels()
    #expect(red(first, 144) > 120)
    s.step(dt: 0.35)  // t = 0.5: e = 0.75 -> y = 144 + 192 = 336, r = 5, alpha 0.35
    let mid = try s.pixels()
    let want = OverlaySwatch.over(Sw.red, 0.35, Sw.background)
    #expect(mid.near(500, 336, want, tol: 4), "half way: \(mid.color(500, 336))")
    #expect(mid.near(500, 144, Sw.background, tol: 3), "it has left")
    #expect(mid.near(500, 343, Sw.background, tol: 3), "r = 5: 7 below the centre is outside")
    s.step(dt: 0.349)  // t = 0.998
    s.step(dt: 0.1)  // dead
    let end = try s.pixels()
    let lit = end.count(inX: 0..<1000, y: 100..<800) { r, g, b in r > 60 }
    #expect(lit == 0, "nothing left at 700 ms (\(lit))")
  }

  @Test func theToggleStopsNewDotsButTheOnesInFlightFinish() throws {
    var s = try OverlayStage(overlays: [.pulse])
    s.step(dt: 0, fires: [s.fire(origin: top)])
    let off: Set<StageOverlay> = []
    s.step(dt: 0.175, overlays: off)
    let px = try s.pixels()
    let want = OverlaySwatch.over(Sw.red, 0.525, Sw.background)
    #expect(px.near(500, 256, want, tol: 4), "still flying with the toggle off")
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: 700, y: 300))], overlays: off)
    let after = try s.pixels()
    #expect(after.near(700, 300, Sw.background, tol: 3), "but no new one")
  }

  @Test func aPanelsNetIsDrawnOverTheDots() throws {
    // The pulses live in the meta svg, which sits under the panels (stage.js DOM order): a dot
    // flying out of a panel's own transition is hidden by that panel's net while it is over it.
    // Control: with the nets not drawn, the same dot at the same place is plainly there.
    var bare = try OverlayStage(overlays: [.pulse])
    var netted = try OverlayStage(overlays: [.pulse], visibleNets: true)
    let t = try #require(netted.context.panels[0].nodeCenterInStage(transition: 0))
    // the transition's body is drawn one point right and down of its model position (the panel's
    // 1 point border); probe its middle
    let cx = Int(t.x.rounded()) + 1
    let cy = Int(t.y.rounded()) + 1
    bare.step(dt: 0, fires: [bare.fire(origin: t)])
    netted.step(dt: 0, fires: [netted.fire(origin: t)])
    var plain = try OverlayStage(overlays: [], visibleNets: true)
    plain.step(dt: 0)
    let dot = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    let seen = try bare.pixels()
    #expect(seen.near(cx, cy, dot, tol: 6), "the dot over the bare stage: \(seen.color(cx, cy))")
    let over = try netted.pixels()
    let without = try plain.pixels()
    for (dx, dy) in [(0, 0), (-5, 0), (5, 0), (0, -5), (0, 5)] {
      let a = over.color(cx + dx, cy + dy)
      let b = without.color(cx + dx, cy + dy)
      #expect(
        abs(a.r - b.r) <= 3 && abs(a.g - b.g) <= 3 && abs(a.b - b.b) <= 3,
        "the panel covers the dot at (\(dx), \(dy)): \(a) vs \(b)")
    }
  }

  @Test func theDotsSitBetweenTheMetaNetAndThePanels() throws {
    // meta on: the dot is drawn over the arcs (the panels' half is `aPanelsNetIsDrawnOverTheDots`)
    var s = try OverlayStage(overlays: [.pulse], meta: true)
    let place = s.context.layout.placeCenters[0]
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: place.x, y: place.y))])
    let px = try s.pixels()
    // over the faint place circle: the red dot's colour still dominates
    let want = OverlaySwatch.over(Sw.red, 0.7, OverlaySwatch.over(Sw.arcBlue, 0.06, Sw.background))
    #expect(
      px.near(Int(place.x), Int(place.y), want, tol: 6), "\(px.color(Int(place.x), Int(place.y)))")
  }
}
