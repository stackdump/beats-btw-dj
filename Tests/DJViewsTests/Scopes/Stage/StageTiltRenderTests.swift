import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Tilt (SPEC mode 16), rendered through the real layer stack. The container applies ONE
// transform to the pulse particles, the flame beams, the meta-net and the panels, so every probe
// below is looked for at `StageProjection.project(point)` of the point it would be at untilted
// (the projection of the model's own transform, itself pinned against the CSS composition in
// StageTiltTests and StageProjectionTests). The 1000 x 800 stage has its pivot at (500, 400).

@MainActor
struct StageTiltRenderTests {
  private let centre = StagePoint(x: 500, y: 400)

  /// A stage with tilt on, stepped `steps` frames of 50 ms (12 degrees a second: 20 steps = 12
  /// degrees), with the track spin at `spin` degrees.
  private func tilted(
    _ overlays: Set<StageOverlay>, steps: Int, spin: Double = 0, meta: Bool = false,
    visibleNets: Bool = false
  ) throws -> OverlayStage {
    var s = try OverlayStage(
      overlays: overlays.union([.tilt]), metaRotation: spin, meta: meta, visibleNets: visibleNets)
    for _ in 0..<steps { s.step(dt: 0.05, metaRotation: spin) }
    return s
  }

  private func projected(_ s: OverlayStage, _ p: StagePoint) throws -> (Int, Int) {
    let proj = s.layers.tilt.projection(metaRotation: s.context.metaRotation)
    return Sw.ipt(try #require(proj.project(x: p.x, y: p.y, centerX: 500, centerY: 400)))
  }

  @Test func aDotIsWhereTheCSSMatrixPutsItAtThirtyDegrees() throws {
    var s = try tilted([.pulse], steps: 50, spin: 90)  // 2.5 s: accumulated angle 30
    #expect(abs(s.layers.tilt.angle - 30) < 1e-9)
    let at = StagePoint(x: 700, y: 300)
    s.step(dt: 0, fires: [s.fire(origin: at)])
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-tilt-dot")
    // node: perspective(1400) rotateX(5.56) rotateY(21.52) rotateZ(90) about (500, 400)
    let want = StagePoint(x: 591.90536943193365, y: 600.16556165776979)
    let q = try projected(s, at)
    #expect(abs(Double(q.0) - want.x) <= 1 && abs(Double(q.1) - want.y) <= 1, "\(q) vs \(want)")
    let colour = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    #expect(Sw.anyNear(px, q.0, q.1, r: 2, colour, tol: 14), "the dot at \(q)")
    #expect(px.near(700, 300, Sw.background, tol: 3), "not at its flat place")
  }

  @Test func theRingCentreStaysAtTheCentre() throws {
    var s = try tilted([.pulse], steps: 50, spin: 90)
    s.step(dt: 0, fires: [s.fire(origin: centre)])
    let px = try s.pixels()
    let colour = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    #expect(px.near(500, 400, colour, tol: 8), "the pivot does not move: \(px.color(500, 400))")
    let q = try projected(s, centre)
    #expect(q.0 == 500 && q.1 == 400)
  }

  @Test func aPointOnThePlusXAxisMovesAsPredicted() throws {
    // with no spin and the first frame's angle (0 -> ry 22 only), +x is pulled in toward the
    // pivot by the foreshortening: node 835.0166 (the matrix for ry = 22 about (500, 400))
    var s = try tilted([.pulse], steps: 0)
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: 900, y: 400))])
    #expect(s.layers.tilt.angle == 0 && s.layers.tilt.isTilting, "the first frame, no time yet")
    let px = try s.pixels()
    let q = try projected(s, StagePoint(x: 900, y: 400))
    #expect(abs(Double(q.0) - 835.01656622359565) <= 1 && q.1 == 400, "\(q)")
    let colour = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    #expect(Sw.anyNear(px, q.0, q.1, r: 2, colour, tol: 14), "found at \(q): \(px.color(q.0, q.1))")
    #expect(px.near(900, 400, Sw.background, tol: 3), "and not at 900")
  }

  @Test func theAngleSeriesReachesTheContainerFrameByFrame() throws {
    // the same particle, three accumulated angles: 12 degrees (20 frames), 30, 90
    let at = StagePoint(x: 700, y: 300)
    var seen: [(Int, Int)] = []
    for steps in [20, 50, 150] {
      var s = try tilted([.pulse], steps: steps)
      s.step(dt: 0, fires: [s.fire(origin: at)])
      let px = try s.pixels()
      let q = try projected(s, at)
      let colour = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
      #expect(Sw.anyNear(px, q.0, q.1, r: 2, colour, tol: 14), "steps \(steps): dot at \(q)")
      seen.append(q)
    }
    // node (no spin): 12 -> (676.0, 305.1) is the ry 22 pull; 90 -> (679.61, 323.21)
    #expect(abs(Double(seen[2].0) - 679.61081032753873) <= 1)
    #expect(abs(Double(seen[2].1) - 323.20819481936746) <= 1)
    #expect(seen[0] != seen[1] && seen[1] != seen[2], "the orbit moves between them")
  }

  @Test func withTiltOffTheContainerIsAPlainQuarterTurn() throws {
    var s = try OverlayStage(overlays: [.pulse], metaRotation: 90)
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: 700, y: 300))], metaRotation: 90)
    #expect(s.layers.tilt.projection(metaRotation: 90).isPlanar)
    let px = try s.pixels()
    // (700, 300) is (+200, -100) from the pivot; a clockwise quarter turn sends it to (+100, +200)
    let colour = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    #expect(px.near(600, 600, colour, tol: 6), "\(px.color(600, 600))")
    #expect(px.near(700, 300, Sw.background, tol: 3))
  }

  @Test func everyLayerOfTheContainerIsProjectedByTheSameMatrix() throws {
    var s = try tilted(
      [.pulse, .flame], steps: 50, spin: 90, meta: true, visibleNets: true)
    let layout = s.context.layout
    let bottomPanel = s.context.panels[2]  // (500, 656)
    s.step(
      dt: 0,
      fires: [
        s.fire(origin: StagePoint(x: 700, y: 300)),  // a pulse dot in the open
        s.fire(panel: 2, origin: StagePoint(x: 500, y: 600)),  // a beam straight down, a dot too
      ])
    let proj = s.layers.tilt.projection(metaRotation: 90)
    let px = try s.pixels()
    savePNG(s.scene, width: 1000, height: 800, name: "stage-tilt-layers")
    func at(_ x: Double, _ y: Double) throws -> (Int, Int) {
      Sw.ipt(try #require(proj.project(x: x, y: y, centerX: 500, centerY: 400)))
    }
    func found(_ x: Double, _ y: Double, _ c: (Int, Int, Int), tol: Int, r: Int = 2) throws -> Bool
    {
      let q = try at(x, y)
      return Sw.anyNear(px, q.0, q.1, r: r, c, tol: tol)
    }
    // 1. pulse particle
    let dot = OverlaySwatch.over(Sw.red, 0.7, Sw.background)
    #expect(try found(700, 300, dot, tol: 14), "pulse dot")
    // 2. flame beam: 100 along the line from the centre to the bottom transition, amber-rose
    let q = try at(500, 500)
    let beam = px.color(q.0, q.1)
    #expect(beam.r > 90 && beam.r > beam.b + 30, "flame beam at \(q): \(beam)")
    // 3. meta-net: the top of the first place circle, #4a90d9 at 0.45 (39, 70, 112) over the stage
    let place = layout.placeCenters[0]
    let placeR = try #require(layout.placeR)
    #expect(
      try found(place.x, place.y - placeR, (39, 70, 112), tol: 30, r: 3), "meta place circle")
    // 4. a panel's net: its transition's red border, top edge
    let t = try #require(bottomPanel.nodeCenterInStage(transition: 0))
    #expect(try found(t.x + 1, t.y + 1 - 19, Sw.red, tol: 50, r: 3), "panel transition border")
    // and the unprojected places hold none of it
    #expect(px.near(700, 300, Sw.background, tol: 3), "no dot at the flat place")
  }

  @Test func theTiltedStageOfARealEngineIsDrawnWhole() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.overlays = [.pulse, .flame, .tilt]
    try rig.run(seconds: 3)  // angle 36 degrees
    let ctx = rig.model.context
    let tilt = rig.model.layers.tilt
    #expect(abs(tilt.angle - 36) < 0.01)
    let proj = tilt.projection(metaRotation: ctx.metaRotation)
    #expect(!proj.isPlanar && proj.perspective == 1400)
    let px = try #require(
      renderPixels(
        StageScene(model: rig.model, context: ctx), width: Int(rig.width), height: Int(rig.height)))
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-tilt-engine")
    let lit = px.count(inX: 0..<1000, y: 0..<800) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
    }
    #expect(lit > 15_000, "not blank (\(lit) lit pixels)")
    // the first place circle of the meta-net is where the matrix puts it
    let place = ctx.layout.placeCenters[0]
    let placeR = try #require(ctx.layout.placeR)
    let q = Sw.ipt(
      try #require(
        proj.project(
          x: place.x, y: place.y - placeR, centerX: ctx.width / 2, centerY: ctx.height / 2)
      ))
    #expect(Sw.anyNear(px, q.0, q.1, r: 3, (39, 70, 112), tol: 30), "meta circle at \(q)")
    // and it is not where the untilted stage has it
    #expect(hypot(Double(q.0) - place.x, Double(q.1) - (place.y - placeR)) > 4)
  }
}
