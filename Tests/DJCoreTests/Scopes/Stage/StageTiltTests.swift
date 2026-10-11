import Testing

@testable import DJCore

// Tilt (SPEC mode 16): the angle series and the container's transform. The projection matrix
// itself (CSS order, perspective m34 = -1/1400, point projection) is pinned in
// StageProjectionTests; here the numbers are stage.js's tilt block run in node.

@MainActor
struct StageTiltTests {
  private func ctx(tilt: Bool, dt: Double = 0.05, metaRotation: Double = 0) -> StageContext {
    var overlays = StageOverlay.defaults
    if tilt { overlays.insert(.tilt) } else { overlays.remove(.tilt) }
    return OverlayFixture.context(dt: dt, overlays: overlays, metaRotation: metaRotation)
  }

  @Test func theConstantsAreTheJS() {
    #expect(StageTilt.degreesPerSecond == 12)
    #expect(StageTilt.rotateXAmplitude == 18 && StageTilt.rotateXRate == 0.6)
    #expect(StageTilt.rotateYAmplitude == 22 && StageTilt.rotateYRate == 0.4)
    #expect(StageProjection.defaultPerspective == 1400)
  }

  @Test func rxAndRyAtZeroThirtyAndNinetyDegrees() {
    // node: 18 * sin(a * PI / 180 * 0.6) and 22 * cos(a * PI / 180 * 0.4)
    #expect(StageTilt.rotateX(angle: 0) == 0 && StageTilt.rotateY(angle: 0) == 22)
    #expect(stageNear(StageTilt.rotateX(angle: 30), 5.5623058987490523, 1e-13))
    #expect(stageNear(StageTilt.rotateY(angle: 30), 21.519247216143725, 1e-13))
    #expect(stageNear(StageTilt.rotateX(angle: 90), 14.562305898749054, 1e-13))
    #expect(stageNear(StageTilt.rotateY(angle: 90), 17.798373876248846, 1e-13))
    // the slow orbit: rx peaks (18) at 150 degrees, ry crosses zero at 225
    #expect(stageNear(StageTilt.rotateX(angle: 150), 18, 1e-12))
    #expect(stageNear(StageTilt.rotateY(angle: 225), 0, 1e-12))
  }

  @Test func theAngleAccumulatesTwelveDegreesASecondWhileOn() {
    let m = StageTiltModel()
    #expect(m.angle == 0 && !m.isTilting)
    m.advance(ctx(tilt: true, dt: 0.05))
    #expect(stageNear(m.angle, 0.6, 1e-15) && m.isTilting, "the first frame already counts")
    for _ in 0..<19 { m.advance(ctx(tilt: true, dt: 0.05)) }
    // twenty 50 ms frames: node accumulates 11.999999999999996
    #expect(stageNear(m.angle, 12, 1e-12))
    let p = m.projection(metaRotation: 0)
    #expect(stageNear(p.rotateX, 2.2559982041574753, 1e-12))
    #expect(stageNear(p.rotateY, 21.922842903489098, 1e-12))
  }

  @Test func theAngleSeriesFollowsTheClampedFrameTime() {
    let m = StageTiltModel()
    m.advance(ctx(tilt: true, dt: 0.1))  // the longest frame the model hands out
    #expect(stageNear(m.angle, 1.2, 1e-15))
    m.advance(ctx(tilt: true, dt: 0))
    #expect(stageNear(m.angle, 1.2, 1e-15), "a frame of no time moves nothing")
    // 30 degrees takes 2.5 seconds
    let n = StageTiltModel()
    for _ in 0..<50 { n.advance(ctx(tilt: true, dt: 0.05)) }
    #expect(stageNear(n.angle, 30, 1e-12))
    let p = n.projection(metaRotation: 0)
    #expect(stageNear(p.rotateX, 5.5623058987490523, 1e-10))
    #expect(stageNear(p.rotateY, 21.519247216143725, 1e-10))
  }

  @Test func theTiltedTransformIsPerspectiveRxRyRzWithTheTrackSpin() {
    let m = StageTiltModel()
    m.advance(ctx(tilt: true, dt: 0.05, metaRotation: 90))
    let p = m.projection(metaRotation: 90)
    #expect(p == StageProjection.tilt(rotateX: p.rotateX, rotateY: p.rotateY, rotateZ: 90))
    #expect(p.perspective == 1400 && p.rotateZ == 90 && !p.isPlanar)
    #expect(stageNear(p.rotateX, StageTilt.rotateX(angle: 0.6), 1e-15))
    // the pivot stays put under the whole string
    let c = p.project(x: 500, y: 400, centerX: 500, centerY: 400)
    #expect(c.map { stageNear($0, 500, 400, 1e-9) } == true)
  }

  @Test func theMatrixAtThirtyDegreesIsTheCSSCompositionAboutTheStageCentre() {
    // node, composing the CSS functions by hand (translate(c) perspective(1400) rotateX rotateY
    // rotateZ translate(-c), rotate3d definitions, m34 = -1/1400) for the 1000 x 800 stage:
    // accumulated angle 30 -> rx 5.5623..., ry 21.5192..., track spin 90
    let p = StageTilt.projection(angle: 30, metaRotation: 90)
    let want: [Double] = [
      -0.034617190121753891, -1.0606824595826001, 0.036130188070968960, 941.58157889391691,
      0.96759763094622731, -0.13986502203595258, -0.35471855499727584, -27.852806658732675,
      0.096928132340911036, 0.36508657321057575, 0.92591399774615224, -194.49869545468582,
      -0.000069234380243507886, -0.00026077612372183985, -0.00066136714124725158,
      1.1389276396104899,
    ]
    let m = p.matrix(centerX: 500, centerY: 400)
    #expect(m.count == 16)
    for (i, (a, b)) in zip(m, want).enumerated() {
      #expect(stageNear(a, b, 1e-9), "m[\(i)] = \(a), the CSS composition says \(b)")
    }
    #expect(
      stageNear(m[12], -0.000069234380243507886, 1e-15), "perspective lives in the bottom row")
  }

  @Test func pointsMoveAsTheCSSMatrixSaysAndTheCentreStaysPut() {
    // node: the same matrix applied to (x, y, 0, 1) and divided by w
    let p = StageTilt.projection(angle: 30, metaRotation: 90)
    func at(_ x: Double, _ y: Double) -> StagePoint? {
      p.project(x: x, y: y, centerX: 500, centerY: 400)
    }
    #expect(at(500, 400).map { stageNear($0, 500, 400, 1e-9) } == true, "the pivot")
    #expect(
      at(700, 300).map { stageNear($0, 591.90536943193365, 600.16556165776979, 1e-8) } == true)
    // a point on the +x axis: the quarter turn swings it onto +y and the tilt foreshortens it
    #expect(at(900, 400).map { stageNear($0, 500, 809.45592407355832, 1e-8) } == true)
    #expect(
      at(500, 144).map { stageNear($0, 723.25139562378695, 408.53236132713766, 1e-8) } == true)
    // no track spin, accumulated angle 90 (rx 14.56, ry 17.80)
    let q = StageTilt.projection(angle: 90, metaRotation: 0)
    #expect(
      q.project(x: 700, y: 300, centerX: 500, centerY: 400).map {
        stageNear($0, 679.61081032753873, 323.20819481936746, 1e-8)
      } == true)
    #expect(
      q.project(x: 100, y: 100, centerX: 500, centerY: 400).map {
        stageNear($0, 107.10256392768798, 68.742609270308606, 1e-8)
      } == true)
    // at angle 0 only ry (22) tilts: a point on +x moves in by the foreshortening
    let z = StageTilt.projection(angle: 0, metaRotation: 0)
    #expect(
      z.project(x: 900, y: 400, centerX: 500, centerY: 400).map {
        stageNear($0, 835.01656622359565, 400, 1e-8)
      } == true)
  }

  @Test func offItIsJustTheTrackSpin() {
    let m = StageTiltModel()
    #expect(m.projection(metaRotation: 0) == .spin(0))
    #expect(m.projection(metaRotation: 135) == .spin(135))
    m.advance(ctx(tilt: false, dt: 0.05))
    #expect(m.projection(metaRotation: 135) == StageProjection(rotateZ: 135))
    #expect(m.projection(metaRotation: 135).isPlanar)
  }

  @Test func turningItOffResetsTheAngle() {
    let m = StageTiltModel()
    for _ in 0..<10 { m.advance(ctx(tilt: true)) }
    #expect(m.angle > 5 && m.isTilting)
    m.advance(ctx(tilt: false))
    #expect(m.angle == 0 && !m.isTilting)
    #expect(m.projection(metaRotation: 90) == .spin(90))
    // and on again: the orbit starts afresh from the first frame's step
    m.advance(ctx(tilt: true, dt: 0.05))
    #expect(stageNear(m.angle, 0.6, 1e-15))
  }

  @Test func theAngleKeepsCountingWhileASoloVisualizerHidesTheContainer() {
    // the JS rAF loop accumulates it whatever the visualizer
    var c = ctx(tilt: true, dt: 0.05)
    c.visualizer = .corona
    c.selection = .corona
    let m = StageTiltModel()
    m.advance(c)
    #expect(stageNear(m.angle, 0.6, 1e-15))
  }

  @Test func theRegistryHasIt() {
    let models = StageLayerModels()
    #expect(models.all.contains { $0 === models.tilt })
    #expect(!models.clearedOnRebuild.contains { $0 === models.tilt }, "a rebuild does not reset it")
  }
}
