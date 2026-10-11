import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Macro bolts, seeds and the halo (SPEC mode 17), rendered through the real layer stack on the
// 4-panel OverlayStage (centre (500, 400), dark planet radius 56.8). The bolt of panel 0 starts
// at (500, 144); with the bolt's random draw fixed at 0.123456 (seed 123.456) and the clock at
// 5 s (5000 ms) its polyline is the one stage.js's renderBolts computes, worked out in node:
//
//    (500,144) (496.3257,160.6) (493.9831,177.2) (509.6136,193.8) (513.7710,210.4)
//    (502.4830,227) (470.4207,243.6) (492.3867,260.2) (507.7861,276.8) (514.6931,293.4)
//    (497.2954,310) (496.7632,326.6) (500,343.2)

@MainActor
struct StageBoltsRenderTests {
  private let top = StagePoint(x: 500, y: 144)
  private let centre = StagePoint(x: 500, y: 400)
  /// The node polyline (origin, 11 jittered points, the strike).
  private let jsPolyline: [(Double, Double)] = [
    (500, 144), (496.32573135708429, 160.6), (493.98306419502381, 177.2),
    (509.61363213995742, 193.8), (513.77096071978667, 210.4), (502.48297523220668, 227),
    (470.42072640956229, 243.6), (492.38669250841986, 260.2), (507.78614996198831, 276.8),
    (514.69310381721368, 293.4), (497.29542174283807, 310), (496.76321043981750, 326.6),
    (500, 343.2),
  ]

  /// A stage whose bolt model draws 0.123456 for every seed, clock at `now`.
  private func stage(
    now: Double = 5, panels: Int = 4, overlays: Set<StageOverlay> = [.flame, .bolts],
    meta: Bool = false
  ) throws -> OverlayStage {
    try OverlayStage(
      panels: panels, overlays: overlays, meta: meta, now: now,
      models: StageLayerModels(bolts: StageBoltsModel(random: { 0.123456 })))
  }

  /// A bolt thrown from `origin` during a macro, then only the bolts toggle on (the flame beam the
  /// fire also made is cleared, so the bolt is alone on the stage).
  private func thrown(_ s: inout OverlayStage, from origin: StagePoint? = nil, panel: Int = 0) {
    s.step(
      dt: 0, fires: [s.fire(panel: panel, origin: origin ?? top, macro: true)],
      overlays: [.flame, .bolts])
    s.step(dt: 0, overlays: [.bolts])
  }

  private func bright(_ px: Pixels, _ p: (Double, Double), r: Int = 1) -> Bool {
    let x = Int(p.0.rounded())
    let y = Int(p.1.rounded())
    for yy in (y - r)...(y + r) {
      for xx in (x - r)...(x + r) {
        let c = px.color(xx, yy)
        if c.r > 150 && c.g > 170 && c.b > 200 { return true }
      }
    }
    return false
  }

  @Test func theBoltFollowsTheJSPolylineWithAWhiteHotCore() throws {
    var s = try stage()
    thrown(&s)
    let strokes = s.layers.bolts.strokes(in: s.context)
    #expect(strokes.count == 1)
    let pts = strokes[0].points
    #expect(pts.count == 13)
    for (p, w) in zip(pts, jsPolyline) {
      #expect(Sw.near(p.x, w.0, 1e-8) && Sw.near(p.y, w.1, 1e-8), "\(p) vs \(w)")
    }
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-bolt")
    // the interior vertices and the middle of each segment are on the bright line
    for i in 1..<12 { #expect(bright(px, jsPolyline[i]), "vertex \(i): \(jsPolyline[i])") }
    for i in 0..<12 {
      let mid = (
        (jsPolyline[i].0 + jsPolyline[i + 1].0) / 2, (jsPolyline[i].1 + jsPolyline[i + 1].1) / 2
      )
      #expect(bright(px, mid), "middle of segment \(i): \(mid)")
    }
    // it crackles: vertex 6 is 29.6 points off the straight line down to the planet, which is bare
    #expect(px.near(500, 244, Sw.background, tol: 6), "\(px.color(500, 244))")
    // the stroke is a white core inside a blue-white body: across vertex 6 (a horizontal-ish line)
    let core = px.color(470, 244)
    #expect(core.r > 150 && core.b > 220 && core.b > core.r + 25, "bright blue-white \(core)")
  }

  @Test func theBoltGlowsBlueAroundItself() throws {
    var s = try stage()
    thrown(&s)
    let px = try s.pixels()
    // 4 points from the line at vertex 6 the glow (shadow blur 10: sigma 5) is a clear blue wash
    // over the stage: node estimate (22.6, 29.5, 52.3) from the Gaussian's tail
    let near = px.color(466, 244)
    #expect(near.b > Sw.background.2 + 12 && near.b > near.r + 15, "glow: \(near)")
    // far away it is the background, nothing else is on the stage but the halo and the bolt
    #expect(px.near(800, 600, Sw.background, tol: 2))
    #expect(px.near(300, 200, Sw.background, tol: 2))
  }

  @Test func theBoltFadesWithAlphaAndIsGoneAtFourHundredEightyMilliseconds() throws {
    var s = try stage()
    thrown(&s)
    let full = try s.pixels()
    s.step(dt: 0.24, overlays: [.bolts])  // t = 0.5
    let half = try s.pixels()
    let strokes = s.layers.bolts.strokes(in: s.context)
    #expect(Sw.near(strokes[0].alpha, 0.5, 1e-9))
    // the line is dimmer at half life (a different crackle: probe along the new polyline)
    func peak(_ px: Pixels, _ pts: [(Double, Double)]) -> Int {
      var best = 0
      for p in pts {
        let x = Int(p.0.rounded())
        let y = Int(p.1.rounded())
        for yy in (y - 1)...(y + 1) {
          for xx in (x - 1)...(x + 1) {
            let c = px.color(xx, yy)
            best = max(best, c.r + c.g + c.b)
          }
        }
      }
      return best
    }
    let fullPeak = peak(full, Array(jsPolyline[1..<12]))
    let halfPeak = peak(half, strokes[0].points[1..<12].map { ($0.x, $0.y) })
    #expect(
      halfPeak < fullPeak - 60 && halfPeak > 200, "dimmer at half life: \(halfPeak) < \(fullPeak)")
    s.step(dt: 0.25, overlays: [.bolts])  // t = 1.02
    #expect(s.layers.bolts.bolts.isEmpty)
    let gone = try s.pixels()
    let lit = gone.count(inX: 380..<640, y: 130..<360) { r, g, b in r > 60 || b > 80 }
    #expect(lit < 80, "only the drifting spark is left (\(lit) pixels)")
  }

  @Test func theHaloIsAWashOverThePlanetWhoseStrengthIsFiftyFiveHundredthsOfTheEnergy() throws {
    var s = try stage()
    thrown(&s)  // one bolt at t = 0: energy 1, glow 0.55
    #expect(Sw.near(s.layers.bolts.energy, 1, 1e-12))
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-halo")
    // centre: rgba(150,190,255, 0.22 * 0.55) over the background (node: 26.9, 31.8, 53.7)
    let inner = OverlaySwatch.over((150, 190, 255), 0.22 * 0.55, Sw.background)
    #expect(px.near(500, 400, inner, tol: 5), "\(px.color(500, 400)) vs \(inner)")
    // the rim peaks at 0.9575 R = 54.4 from the centre: rgba(180,210,255, 0.18 * 0.55)
    let rim = OverlaySwatch.over((180, 210, 255), 0.18 * 0.55, Sw.background)
    #expect(px.near(500, 454, rim, tol: 7), "\(px.color(500, 454)) vs \(rim)")
    // beyond 1.25 R = 71 nothing is left of it
    #expect(px.near(500, 400 + 80, Sw.background, tol: 2))
    #expect(px.near(500 + 80, 400, Sw.background, tol: 2))
    // the washes are bluer than they are red
    let c = px.color(500, 400)
    #expect(c.b > c.r + 15)
  }

  @Test func manyBoltsSaturateTheGlowAtOne() throws {
    var s = try stage()
    s.step(
      dt: 0, fires: (0..<6).map { _ in s.fire(origin: top, macro: true) },
      overlays: [.flame, .bolts])
    s.step(dt: 0, overlays: [.bolts])
    #expect(Sw.near(s.layers.bolts.energy, 6, 1e-12))
    let px = try s.pixels()
    // glow = min(1, 6 * 0.55) = 1: the centre is rgba(150,190,255, 0.22) over the background
    let inner = OverlaySwatch.over((150, 190, 255), 0.22, Sw.background)
    #expect(px.near(500, 400, inner, tol: 5), "\(px.color(500, 400)) vs \(inner)")
  }

  @Test func theSparkSitsOnThePlanetAtTheStrikeAndLeavesItsBoltBehind() throws {
    var s = try stage()
    thrown(&s)
    let px = try s.pixels()
    // t = 0: radius 2.7, rgba(255,240,210,.95): warm white at the strike (500, 343.2)
    let spark = px.color(500, 343)
    #expect(spark.r > 225 && spark.g > 205 && spark.b > 160, "spark: \(spark)")
    // the bolt dies at 480 ms; at 600 ms the spark is t = 0.545 of its life, drifted inward by
    // 56.8 * 0.35 * (1 - 0.455^2) = 15.77 to (500, 358.97), radius 1.5, alpha 0.43
    s.step(dt: 0.6, overlays: [.bolts])
    #expect(s.layers.bolts.bolts.isEmpty && s.layers.bolts.seeds.count == 1)
    let later = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-seed")
    let t = 600.0 / 1100
    let inward = 56.8 * 0.35 * (1 - (1 - t) * (1 - t))
    let sy = 343.2 + inward
    let warm = later.color(500, Int(sy.rounded()))
    #expect(warm.r > 90 && warm.r > warm.b + 6 && warm.g > 85, "drifted spark: \(warm)")
    #expect(later.color(500, 343).r < warm.r, "and it is no longer at the strike")
    #expect(!bright(later, jsPolyline[6]), "the bolt's line is gone")
    // by 1.1 s it is out
    s.step(dt: 0.55, overlays: [.bolts])
    #expect(s.layers.bolts.seeds.isEmpty)
    let end = try s.pixels()
    #expect(end.count(inX: 440..<560, y: 300..<500) { r, g, b in r > 40 || b > 80 } == 0)
  }

  @Test func anOriginInsideThePlanetDrawsNoBoltYetStillAddsToTheHalo() throws {
    var s = try stage()
    thrown(&s, from: StagePoint(x: 530, y: 440))
    #expect(s.layers.bolts.bolts.count == 1 && s.layers.bolts.seeds.isEmpty)
    let px = try s.pixels()
    let inner = OverlaySwatch.over((150, 190, 255), 0.22 * 0.55, Sw.background)
    #expect(px.near(500, 400, inner, tol: 5), "halo only: \(px.color(500, 400))")
    // (the stage's own corner button has a white dot: look at the middle of the stage)
    let bolt = px.count(inX: 200..<800, y: 100..<700) { r, g, b in r > 120 && g > 150 && b > 200 }
    #expect(bolt == 0, "no line, no spark (\(bolt) bright pixels)")
  }

  @Test func withoutAMacroOrWithTheToggleOffNothingIsDrawn() throws {
    var plain = try stage()
    plain.step(dt: 0, fires: [plain.fire(origin: top, macro: false)])
    plain.step(dt: 0, overlays: [.bolts])
    #expect(plain.layers.bolts.bolts.isEmpty)
    let a = try plain.pixels()
    #expect(a.count(inX: 380..<640, y: 130..<500) { r, g, b in r > 40 || b > 60 } == 0)
    var off = try stage()
    thrown(&off)
    #expect(off.layers.bolts.bolts.count == 1)
    off.step(dt: 0, overlays: [])  // bolts toggle off
    #expect(off.layers.bolts.bolts.isEmpty && off.layers.bolts.seeds.isEmpty)
    let b = try off.pixels()
    #expect(b.count(inX: 380..<640, y: 130..<500) { r, g, b in r > 40 || b > 60 } == 0)
  }

  @Test func aBoltNeedsTheFlameToggleToBeThrown() throws {
    var s = try stage(overlays: [.bolts])
    s.step(dt: 0, fires: [s.fire(origin: top, macro: true)])
    #expect(s.layers.bolts.bolts.isEmpty, "the JS spawns inside the flame branch")
  }

  @Test func theBoltIsDrawnOverTheFlameBeamItFollows() throws {
    var s = try stage()
    // flame stays on: the beam from the centre to (500, 144) runs under the bolt's last segment
    s.step(dt: 0, fires: [s.fire(origin: top, macro: true)])
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-bolt-over-flame")
    // the middle of the last segment (498.4, 334.9) is on the beam (x = 500 +- 4.5)
    let mid = (
      (jsPolyline[11].0 + jsPolyline[12].0) / 2, (jsPolyline[11].1 + jsPolyline[12].1) / 2
    )
    #expect(bright(px, mid), "bolt core over the beam: \(px.color(Int(mid.0), Int(mid.1)))")
    // while the beam alone is rose-amber just beside it
    let beam = px.color(500, 354)
    #expect(
      beam.r > beam.b + 40 && beam.r > 130, "the beam is there too, amber at its base: \(beam)")
  }

  @Test func boltsAreProjectedWithTheRestUnderATilt() throws {
    var s = try OverlayStage(
      overlays: [.tilt], metaRotation: 90, now: 5,
      models: StageLayerModels(bolts: StageBoltsModel(random: { 0.123456 })))
    for _ in 0..<50 { s.step(dt: 0.05, overlays: [.tilt], metaRotation: 90) }
    #expect(abs(s.layers.tilt.angle - 30) < 1e-9)
    // the bolt: thrown now (flame + bolts), then only bolts + tilt
    s.step(
      dt: 0, fires: [s.fire(origin: top, macro: true)], overlays: [.flame, .bolts, .tilt],
      metaRotation: 90)
    s.step(dt: 0, overlays: [.bolts, .tilt], metaRotation: 90)
    let strokes = s.layers.bolts.strokes(in: s.context)
    let pts = try #require(strokes.first).points
    let proj = s.layers.tilt.projection(metaRotation: 90)
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-bolt-tilted")
    var hit = 0
    for i in 1..<12 {
      let q = try #require(proj.project(x: pts[i].x, y: pts[i].y, centerX: 500, centerY: 400))
      if bright(px, (q.x, q.y), r: 2) { hit += 1 }
    }
    #expect(hit >= 10, "the polyline's vertices sit at their projected points (\(hit) of 11)")
    // the halo's centre is the pivot: it stays put
    #expect(px.color(500, 400).b > px.color(500, 400).r + 10, "halo at the centre")
  }
}
