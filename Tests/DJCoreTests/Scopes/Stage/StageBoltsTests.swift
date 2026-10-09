import Testing

@testable import DJCore

// Macro bolts, seeds and the halo (SPEC mode 17). Expected numbers are stage.js's renderBolts /
// renderSeeds arithmetic run in node. The 1000 x 800 stage has 4 panels: centre (500, 400), dark
// planet radius 56.8.

private func pt(_ x: Double, _ y: Double) -> StagePoint { StagePoint(x: x, y: y) }

private func near(_ p: StagePoint, _ x: Double, _ y: Double, _ tol: Double = 1e-9) -> Bool {
  stageNear(p.x, x, tol) && stageNear(p.y, y, tol)
}

struct StageBoltsNumbersTests {
  @Test func theConstantsAreTheJS() {
    #expect(StageBolts.boltLifeMs == 480 && StageBolts.maxBolts == 32)
    #expect(StageBolts.seedLifeMs == 1100 && StageBolts.maxSeeds == 48)
    #expect(StageBolts.fallbackPlanetRadius == 48 && StageBolts.planetMargin == 2)
    #expect(StageBolts.segments == 12 && StageBolts.amplitude == 26)
    #expect(StageBolts.outerWidth == 2.2 && StageBolts.coreWidth == 1)
    #expect(StageBolts.outerBlur == 10 && StageBolts.coreBlur == 4)
    #expect(StageBolts.sigma(ofBlur: 10) == 5, "a canvas shadow's deviation is half its blur")
    #expect(StageBolts.glowPerEnergy == 0.55)
    #expect(StageBolts.outerColor == ScopeColor(r8: 200, g8: 225, b8: 255))
    #expect(StageBolts.shadowColor == ScopeColor(r8: 120, g8: 180, b8: 255))
    #expect(StageBolts.seedColor == ScopeColor(r8: 255, g8: 240, b8: 210))
    #expect(StageBolts.seedShadowColor == ScopeColor(r8: 255, g8: 220, b8: 150))
    #expect(StageBolts.haloInnerColor == ScopeColor(r8: 150, g8: 190, b8: 255))
    #expect(StageBolts.haloRimColor == ScopeColor(r8: 180, g8: 210, b8: 255))
  }

  @Test func aCanvasShadowBlurIsInDevicePixelsSoItNarrowsOnAHiDPIDisplay() {
    // Chrome, a canvas under setTransform(dpr, 0, 0, dpr, 0, 0) with shadowBlur 10: the glow
    // covers the same ~12 DEVICE pixels at dpr 1 and at dpr 2 (the canvas does not scale the
    // blur), so in points it is half as wide on a 2x display.
    #expect(StageBolts.sigma(ofBlur: 10, displayScale: 1) == 5)
    #expect(StageBolts.sigma(ofBlur: 10, displayScale: 2) == 2.5)
    #expect(StageBolts.sigma(ofBlur: 4, displayScale: 2) == 1)
    #expect(stageNear(StageBolts.sigma(ofBlur: 10, displayScale: 3), 5.0 / 3, 1e-15))
    #expect(StageBolts.sigma(ofBlur: 10, displayScale: 0) == 5, "no scale known: 1")
    #expect(StageBolts.sigma(ofBlur: 10, displayScale: -2) == 5)
  }

  @Test func theTaperIsZeroAtTheEndsAndOneInTheMiddle() {
    #expect(StageBolts.taper(segment: 6) == 1)
    #expect(stageNear(StageBolts.taper(segment: 3), 0.5, 1e-15))
    #expect(stageNear(StageBolts.taper(segment: 9), 0.5, 1e-15))
    #expect(stageNear(StageBolts.taper(segment: 1), 1 - 5.0 / 6, 1e-15))
    #expect(stageNear(StageBolts.taper(segment: 11), 1 - 5.0 / 6, 1e-15))
    #expect(StageBolts.taper(segment: 0) == 0 && StageBolts.taper(segment: 12) == 0)
  }

  @Test func theJitterAtPinnedSeedSegmentAndTime() {
    // node: sin(seed + i*11.3 + now*0.035) * amp + sin(seed*0.7 + i*3.1 + now*0.07) * amp * 0.35
    #expect(
      stageNear(StageBolts.jitter(seed: 100, segment: 3, nowMs: 5000), 15.155248078857554, 1e-9))
    #expect(stageNear(StageBolts.jitter(seed: 0, segment: 6, nowMs: 0), -27.401727873085676, 1e-9))
    #expect(
      stageNear(StageBolts.jitter(seed: 999.5, segment: 11, nowMs: 1e6), 3.1707594048768981, 1e-8))
    // it crackles: the same bolt a frame later has moved
    let a = StageBolts.jitter(seed: 100, segment: 3, nowMs: 5000)
    let b = StageBolts.jitter(seed: 100, segment: 3, nowMs: 5016)
    #expect(a != b)
    // and it never exceeds its taper's share of amp * 1.35
    for i in 1..<12 {
      for ms in stride(from: 0.0, to: 2000, by: 37) {
        let j = StageBolts.jitter(seed: 321, segment: i, nowMs: ms)
        #expect(abs(j) <= 26 * StageBolts.taper(segment: i) * 1.35 + 1e-9)
      }
    }
  }

  @Test func theStrikeIsOnThePlanetsSurfaceFacingTheOrigin() throws {
    let s = try #require(
      StageBolts.strike(origin: pt(500, 144), centre: pt(500, 400), planetR: 56.8))
    #expect(s.ux == 0 && s.uy == 1 && s.nx == -1 && s.ny == 0)
    #expect(near(s.end, 500, 343.19999999999999) && stageNear(s.length, 199.19999999999999, 1e-9))
    let r = try #require(
      StageBolts.strike(origin: pt(756, 400), centre: pt(500, 400), planetR: 56.8))
    #expect(r.ux == -1 && r.uy == 0 && near(r.end, 556.8, 400, 1e-9))
    let d = try #require(
      StageBolts.strike(origin: pt(300, 250), centre: pt(500, 400), planetR: 56.8))
    #expect(stageNear(d.ux, 0.8, 1e-15) && stageNear(d.uy, 0.6, 1e-15))
    #expect(near(d.end, 454.56, 365.92, 1e-9) && stageNear(d.length, 193.2, 1e-9))
  }

  @Test func anOriginWithinTwoOfThePlanetIsSkippedButOneBeyondIsNot() {
    // distance 58.8 = R + 2 is skipped (<=); 58.9 is drawn
    #expect(
      StageBolts.strike(origin: pt(500 + 58.8, 400), centre: pt(500, 400), planetR: 56.8) == nil)
    #expect(StageBolts.strike(origin: pt(500, 400), centre: pt(500, 400), planetR: 56.8) == nil)
    #expect(StageBolts.strike(origin: pt(530, 440), centre: pt(500, 400), planetR: 56.8) == nil)
    #expect(
      StageBolts.strike(origin: pt(500 + 58.9, 400), centre: pt(500, 400), planetR: 56.8) != nil)
  }

  @Test func thePolylineAtPinnedValues() throws {
    // node: origin (500, 144), seed 123.456, now 5000, planet 56.8
    let s = try #require(
      StageBolts.strike(origin: pt(500, 144), centre: pt(500, 400), planetR: 56.8))
    let pts = StageBolts.polyline(origin: pt(500, 144), strike: s, seed: 123.456, nowMs: 5000)
    let want: [(Double, Double)] = [
      (500, 144), (496.32573135708429, 160.6), (493.98306419502381, 177.2),
      (509.61363213995742, 193.8), (513.77096071978667, 210.4), (502.48297523220668, 227),
      (470.42072640956229, 243.6), (492.38669250841986, 260.2), (507.78614996198831, 276.8),
      (514.69310381721368, 293.4), (497.29542174283807, 310), (496.76321043981750, 326.6),
      (500, 343.2),
    ]
    #expect(pts.count == 13, "the origin, 11 jittered points, the strike")
    for (p, w) in zip(pts, want) { #expect(near(p, w.0, w.1, 1e-9), "\(p) vs \(w)") }
    // a bolt that comes from the right, normal (0, -1): node values for seed 900 at 123456.789 ms
    let r = try #require(
      StageBolts.strike(origin: pt(756, 400), centre: pt(500, 400), planetR: 56.8))
    let q = StageBolts.polyline(origin: pt(756, 400), strike: r, seed: 900, nowMs: 123_456.789)
    #expect(
      near(q[1], 739.4, 402.98337192838210, 1e-8) && near(q[6], 656.4, 432.95612462455745, 1e-8))
    #expect(near(q[11], 573.4, 403.34441247048153, 1e-8) && near(q[12], 556.8, 400, 1e-9))
    // and a diagonal one (the normal is (-0.6, 0.8))
    let d = try #require(
      StageBolts.strike(origin: pt(300, 250), centre: pt(500, 400), planetR: 56.8))
    let e = StageBolts.polyline(origin: pt(300, 250), strike: d, seed: 42.5, nowMs: 777.25)
    #expect(near(e[1], 315.10128557951680, 256.69828589397764, 1e-9))
    #expect(near(e[8], 398.76157077906367, 332.98457229458165, 1e-9))
    #expect(near(e[12], 454.56, 365.92, 1e-9))
  }

  @Test func theGlowIsFiftyFiveHundredthsOfTheEnergyCappedAtOne() {
    #expect(stageNear(StageBolts.glow(energy: 0.5), 0.275, 1e-15))
    #expect(stageNear(StageBolts.glow(energy: 1), 0.55, 1e-15))
    #expect(StageBolts.glow(energy: 2) == 1 && StageBolts.glow(energy: 3) == 1)
    #expect(stageNear(StageBolts.glow(energy: 1.8181), 0.99995, 1e-4))
    #expect(StageBolts.glow(energy: 0) == 0)
  }

  @Test func aSeedDriftsInwardEasingOutAndShrinksToAPointEight() throws {
    let seed = StageSeed(x: 500, y: 343.2, ux: 0, uy: 1, bornMs: 1000)
    // planet 56.8: inward = 56.8 * 0.35 * (1 - (1 - t)^2); core = max(0.8, 2.2 (1 - t) + 0.5)
    let d0 = try #require(StageBolts.dot(of: seed, planetR: 56.8, nowMs: 1000))
    #expect(stageNear(d0.y, 343.2, 1e-12) && stageNear(d0.radius, 2.7, 1e-12) && d0.alpha == 1)
    let d1 = try #require(StageBolts.dot(of: seed, planetR: 56.8, nowMs: 1000 + 0.25 * 1100))
    #expect(stageNear(d1.y, 343.2 + 8.6975, 1e-9) && stageNear(d1.radius, 2.15, 1e-12))
    #expect(stageNear(d1.alpha, 0.75, 1e-12) && stageNear(d1.x, 500, 1e-12))
    let d2 = try #require(StageBolts.dot(of: seed, planetR: 56.8, nowMs: 1000 + 0.5 * 1100))
    #expect(stageNear(d2.y, 343.2 + 14.91, 1e-9) && stageNear(d2.radius, 1.6, 1e-12))
    let d3 = try #require(StageBolts.dot(of: seed, planetR: 56.8, nowMs: 1000 + 0.9 * 1100))
    #expect(stageNear(d3.y, 343.2 + 19.6812, 1e-9) && d3.radius == 0.8)
    #expect(stageNear(d3.alpha, 0.1, 1e-12))
    #expect(StageBolts.dot(of: seed, planetR: 56.8, nowMs: 2100) == nil, "gone at 1100 ms")
  }
}

@MainActor
struct StageBoltsModelTests {
  /// A model whose random draws are the given fractions in turn.
  private func model(_ draws: [Double] = [0.1234567]) -> StageBoltsModel {
    var i = 0
    return StageBoltsModel(random: {
      defer { i += 1 }
      return draws[i % draws.count]
    })
  }

  private func fire(
    _ origin: StagePoint? = pt(500, 144), panel: Int? = 0, wall: Double = 10, macro: Bool = true
  ) -> StageFire {
    OverlayFixture.fire(panel: panel, origin: origin, wall: wall, macro: macro)
  }

  @Test func aFireDuringAMacroThrowsABoltFromItsTransition() throws {
    let m = model([0.5])
    let ctx = OverlayFixture.context(now: 10, fires: [fire()])
    m.advance(ctx)
    #expect(m.bolts.count == 1)
    let b = m.bolts[0]
    #expect(b.origin == pt(500, 144) && b.bornMs == 10_000 && b.lifeMs == 480)
    #expect(b.seed == 500, "Math.random() * 1000")
    #expect(b.seeded, "and it has already been drawn once, so it dropped its seed")
    #expect(m.seeds.count == 1)
  }

  @Test func theSeedIsDroppedOnceAtTheStrikeAndOutlivesItsBolt() throws {
    let m = model()
    // The hit was read 50 ms before this frame: the bolt is born at the hit, but the seed at the
    // frame that first draws the bolt (JS: `born: now`, the rAF timestamp, not the bolt's).
    m.advance(OverlayFixture.context(now: 10, fires: [fire(wall: 9.95)]))
    #expect(m.seeds.count == 1)
    #expect(m.bolts[0].bornMs == 9_950)
    let s = m.seeds[0]
    #expect(stageNear(s.x, 500, 1e-12) && stageNear(s.y, 343.2, 1e-9))
    #expect(s.ux == 0 && s.uy == 1 && s.bornMs == 10_000 && s.lifeMs == 1100)
    // later frames add no more
    m.advance(OverlayFixture.context(now: 10.1))
    m.advance(OverlayFixture.context(now: 10.2))
    #expect(m.seeds.count == 1 && m.bolts.count == 1)
    // the bolt dies at 480 ms, the seed lives to 1100 ms
    m.advance(OverlayFixture.context(now: 10.5))
    #expect(m.bolts.isEmpty && m.seeds.count == 1)
    m.advance(OverlayFixture.context(now: 11.05))
    #expect(m.seeds.count == 1, "1050 ms old")
    m.advance(OverlayFixture.context(now: 11.125))
    #expect(m.seeds.isEmpty, "1125 ms old")
  }

  @Test func theBoltsEnergyIsTheSumOfItsAlphasAndDrivesTheGlow() throws {
    let m = model()
    // two bolts: born at 10.0 (t = 0.25 at 10.12) and at 10.06 (t = 0.125)
    m.advance(OverlayFixture.context(now: 10.12, fires: [fire(wall: 10), fire(wall: 10.06)]))
    let want = (1 - 0.12 / 0.48) + (1 - 0.06 / 0.48)
    #expect(stageNear(m.energy, want, 1e-9))
    let halo = try #require(m.halo(in: OverlayFixture.context(now: 10.12)))
    #expect(stageNear(halo.glow, min(1, want * 0.55), 1e-9))
    #expect(halo.centre == pt(500, 400) && stageNear(halo.planetRadius, 56.8, 1e-9))
  }

  @Test func theHaloIsGoneWhenTheBoltsAre() {
    let m = model()
    m.advance(OverlayFixture.context(now: 10, fires: [fire()]))
    #expect(m.halo(in: OverlayFixture.context(now: 10)) != nil)
    m.advance(OverlayFixture.context(now: 10.5))
    #expect(m.energy == 0 && m.halo(in: OverlayFixture.context(now: 10.5)) == nil)
  }

  @Test func theGlowSaturatesWhenManyBoltsLandTogether() throws {
    let m = model()
    let fires = (0..<10).map { _ in fire(wall: 10) }
    m.advance(OverlayFixture.context(now: 10, fires: fires))
    #expect(stageNear(m.energy, 10, 1e-12))
    #expect(try #require(m.halo(in: OverlayFixture.context(now: 10))).glow == 1)
  }

  @Test func anOriginInsideThePlanetStillCountsForTheHaloButDropsNoSeed() {
    let m = model()
    // 50 away from the centre, inside 56.8 + 2
    m.advance(OverlayFixture.context(now: 10, fires: [fire(pt(530, 440))]))
    #expect(m.bolts.count == 1 && !m.bolts[0].seeded && m.seeds.isEmpty)
    #expect(stageNear(m.energy, 1, 1e-12), "the JS adds the alpha before it skips")
    #expect(m.strokes(in: OverlayFixture.context(now: 10)).isEmpty, "nothing is drawn for it")
  }

  @Test func aBoltOnlySpawnsDuringAMacro() {
    let m = model()
    m.advance(OverlayFixture.context(now: 10, fires: [fire(macro: false)]))
    #expect(m.bolts.isEmpty)
  }

  @Test func aBoltNeedsTheBoltsToggleAndTheFlameToggle() {
    var noBolts = StageOverlay.defaults
    noBolts.remove(.bolts)
    let a = model()
    a.advance(OverlayFixture.context(now: 10, fires: [fire()], overlays: noBolts))
    #expect(a.bolts.isEmpty)
    var noFlame = StageOverlay.defaults
    noFlame.remove(.flame)
    let b = model()
    b.advance(OverlayFixture.context(now: 10, fires: [fire()], overlays: noFlame))
    #expect(b.bolts.isEmpty, "the JS spawns inside the flame branch")
  }

  @Test func boltsAlreadyFlyingKeepDrawingWhenFlameIsTurnedOff() {
    let m = model()
    m.advance(OverlayFixture.context(now: 10, fires: [fire()]))
    var noFlame = StageOverlay.defaults
    noFlame.remove(.flame)
    m.advance(OverlayFixture.context(now: 10.1, overlays: noFlame))
    #expect(m.bolts.count == 1 && m.strokes(in: OverlayFixture.context(now: 10.1)).count == 1)
  }

  @Test func turningBoltsOffClearsBoltsAndSeedsAtOnce() {
    let m = model()
    m.advance(OverlayFixture.context(now: 10, fires: [fire()]))
    #expect(m.bolts.count == 1 && m.seeds.count == 1)
    var off = StageOverlay.defaults
    off.remove(.bolts)
    m.advance(OverlayFixture.context(now: 10.1, overlays: off))
    #expect(m.bolts.isEmpty && m.seeds.isEmpty && m.energy == 0)
    #expect(m.halo(in: OverlayFixture.context(now: 10.1)) == nil)
  }

  @Test func aFireWithoutAnOriginOrPanelThrowsNothing() {
    let m = model()
    m.advance(
      OverlayFixture.context(
        now: 10,
        fires: [fire(nil, panel: 0), fire(nil, panel: nil), fire(pt(500, 144), panel: nil)]
      ))
    #expect(m.bolts.isEmpty)
    // a lone panel has no ring position
    let n = model()
    n.advance(OverlayFixture.context(panels: 1, now: 10, fires: [fire()]))
    #expect(n.bolts.isEmpty)
  }

  @Test func theBoltListIsCappedAtThirtyTwoAfterThePush() {
    let m = model((0..<40).map { Double($0) / 40 })
    func wall(_ i: Int) -> Double { 10 + Double(i) / 1024 }
    let fires = (0..<40).map { fire(wall: wall($0)) }
    m.advance(OverlayFixture.context(now: 10.1, fires: fires))
    #expect(m.bolts.count == 32)
    // the 8 oldest were shifted out: the survivors are fires 8...39 with their own seeds
    #expect(m.bolts.first?.bornMs == wall(8) * 1000 && m.bolts.last?.bornMs == wall(39) * 1000)
    #expect(m.bolts.first?.seed == 8.0 / 40 * 1000)
  }

  @Test func theSeedListIsCappedAtFortyEight() {
    let m = model()
    // 60 bolts alive at once, each dropping a seed when first drawn
    func wall(_ i: Int) -> Double { 10 + Double(i) / 4096 }
    // (the bolt list caps at 32, so feed them over two frames of 30)
    m.advance(OverlayFixture.context(now: 10.1, fires: (0..<30).map { fire(wall: wall($0)) }))
    #expect(m.seeds.count == 30)
    m.advance(OverlayFixture.context(now: 10.11, fires: (30..<60).map { fire(wall: wall($0)) }))
    // 30 + 30 = 60 pushes, `if (seeds.length > 48) shift()` keeps 48
    #expect(m.seeds.count == 48)
  }

  @Test func aRebuildClearsEverything() {
    let m = model()
    m.advance(OverlayFixture.context(now: 10, fires: [fire()]))
    m.reset()
    #expect(m.bolts.isEmpty && m.seeds.isEmpty && m.energy == 0)
  }

  @Test func theDefaultPlanetRadiusIsFortyEightWithoutARing() throws {
    // a lone panel has no dark planet; stage.js then uses `session.darkPlanetRadius || 48`
    let m = model()
    m.advance(OverlayFixture.context(now: 10, fires: [fire(pt(500, 144))]))
    let lone = OverlayFixture.context(panels: 1, now: 10)
    #expect(lone.darkPlanetRadius == nil)
    let end = try #require(m.strokes(in: lone).first?.points.last)
    #expect(near(end, 500, 400 - 48, 1e-9), "stops 48 short of the centre")
  }

  @Test func theStrokesCrackleFromFrameToFrame() throws {
    let m = model([0.5])
    m.advance(OverlayFixture.context(now: 10, fires: [fire()]))
    let a = try #require(m.strokes(in: OverlayFixture.context(now: 10.05)).first)
    let b = try #require(m.strokes(in: OverlayFixture.context(now: 10.066)).first)
    #expect(a.points.count == 13 && b.points.count == 13)
    #expect(a.points[0] == b.points[0] && a.points[12] == b.points[12], "ends are fixed")
    #expect(a.points[6] != b.points[6], "the middle moved")
    #expect(stageNear(a.alpha, 1 - 0.05 / 0.48, 1e-9) && stageNear(b.alpha, 1 - 0.066 / 0.48, 1e-9))
  }

  @Test func theStageModelResetsItOnARebuild() {
    let models = StageLayerModels()
    #expect(models.clearedOnRebuild.contains { $0 === models.bolts })
  }
}

struct StageBoltsHaloStopsTests {
  @Test func theInnerWashFadesFromThePlanetsGlowToNothing() {
    let s = StageBolts.haloInnerStops(glow: 0.55)
    #expect(s.map(\.location) == [0, 1])
    #expect(s[0].color == ScopeColor(r8: 150, g8: 190, b8: 255, a: 0.22 * 0.55))
    #expect(s[1].color == ScopeColor(r8: 120, g8: 180, b8: 255, a: 0))
  }

  @Test func theRimPeaksAtFiftyFiveHundredthsBetweenSixTenthsAndOneAndAQuarterRadii() {
    let s = StageBolts.haloRimStops(glow: 1)
    #expect(s.map(\.location) == [0, 0.55, 1])
    #expect(s[0].color == ScopeColor(r8: 120, g8: 180, b8: 255, a: 0))
    #expect(s[1].color == ScopeColor(r8: 180, g8: 210, b8: 255, a: 0.18))
    #expect(s[2].color == ScopeColor(r8: 120, g8: 180, b8: 255, a: 0))
    #expect(StageBolts.haloRimStart == 0.6 && StageBolts.haloRimEnd == 1.25)
    // the rim's strength follows the glow
    #expect(StageBolts.haloRimStops(glow: 0.5)[1].color.a == 0.09)
  }
}

// The layer on a real offline engine, through the real StageModel: the macro signal is the
// engine's own (`FireFlags.macro`, from `WaveGraph.hasActiveMacros` / the runner's tempo effect).
@MainActor
struct StageBoltsEngineTests {
  /// Frame by frame: the bolts the stage should hold after each one, worked out here from the
  /// frame's fires, against what the model holds.
  private func follow(_ h: StageHarness, frames n: Int, macroFires: inout [StageFire]) {
    let bolts = h.model.layers.bolts
    var expected: [(born: Double, origin: StagePoint)] = []
    for _ in 0..<n {
      h.step()
      let c = h.ctx
      for f in c.fires where f.macroRunning {
        guard let p = f.panel, c.panels[p].ring != nil, let o = f.origin else { continue }
        macroFires.append(f)
        expected.append((f.wallTime * 1000, o))
        if expected.count > StageBolts.maxBolts { expected.removeFirst() }
      }
      expected.removeAll { c.nowMs - $0.born >= StageBolts.boltLifeMs }
      #expect(bolts.bolts.count == expected.count, "frame at \(c.now): \(bolts.bolts.count)")
      for (b, e) in zip(bolts.bolts, expected) {
        #expect(stageNear(b.bornMs, e.born, 1e-6) && b.origin == e.origin)
      }
    }
  }

  @Test func withoutAMacroNothingIsThrown() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(2)
    #expect(h.frames.flatMap(\.fires).count > 20, "the song is playing")
    #expect(!h.frames.flatMap(\.fires).contains { $0.macroRunning })
    #expect(h.model.layers.bolts.bolts.isEmpty && h.model.layers.bolts.seeds.isEmpty)
  }

  @Test func aMacroOnTheDeckThrowsABoltFromEveryHitItMakesUntilItEnds() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.4)
    #expect(h.model.layers.bolts.bolts.isEmpty)
    h.deck.fire(.beatRepeat, duration: 1)  // one bar: 16 ticks of 50 ms
    var macroFires: [StageFire] = []
    follow(h, frames: 24, macroFires: &macroFires)  // 1.2 s: the macro, then its aftermath
    #expect(macroFires.count >= 6, "the macro's hits throw bolts (\(macroFires.count))")
    #expect(macroFires.allSatisfy { $0.deck == "A" })
    // the macro is over and so are its bolts, within 480 ms of the last hit
    follow(h, frames: 12, macroFires: &macroFires)
    #expect(!h.ctx.macroRunning)
    #expect(h.model.layers.bolts.bolts.isEmpty, "all gone: \(h.model.layers.bolts.bolts.count)")
  }

  @Test func aMacroThatChangedNothingStillThrowsBoltsSeedsAndAHalo() throws {
    // stage.js keys on `el._runningMacro`, which beats sets for any fired macro. Here the macro
    // (solo drums) finds every net it would mute already muted, so it leaves no mute timer behind;
    // the drums go on and every hit of theirs during the macro still throws a bolt.
    let h = try StageHarness()
    defer { h.stop() }
    for role in ["bass", "melody", "harmony", "arp"] { h.deck.setRole(role, on: false) }
    h.run(0.4)
    #expect(!h.frames.flatMap(\.fires).isEmpty && h.model.layers.bolts.bolts.isEmpty)
    h.deck.fire(.soloDrums, duration: 1)  // one bar: 16 ticks of 50 ms
    var thrown = 0
    var energy = 0.0
    var seeds = 0
    for _ in 0..<24 {
      h.step()
      let c = h.ctx
      thrown +=
        c.fires.filter { f in
          f.macroRunning && f.panel.map { c.panels[$0].ring != nil } == true && f.origin != nil
        }.count
      energy = max(energy, h.model.layers.bolts.energy)
      seeds = max(seeds, h.model.layers.bolts.seeds.count)
    }
    #expect(h.deck.wave.latest?.graph.pendingMacroTimers == 0, "premise: it muted nothing")
    #expect(thrown >= 6, "the drums' hits throw bolts (\(thrown))")
    #expect(energy > 0 && seeds > 0, "and the planet glows and sparks: \(energy), \(seeds)")
    var macroFires: [StageFire] = []
    follow(h, frames: 12, macroFires: &macroFires)
    #expect(!h.ctx.macroRunning)
    #expect(h.model.layers.bolts.bolts.isEmpty, "all gone once the macro and the bolts are over")
  }

  @Test func eachBoltDropsOneSeedOnThePlanetsSurface() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.4)
    h.deck.fire(.beatRepeat, duration: 1)
    let bolts = h.model.layers.bolts
    var dropped = 0
    var thrown = 0
    var seen = Set<Double>()
    for _ in 0..<30 {
      h.step()
      let c = h.ctx
      thrown +=
        c.fires.filter { f in
          f.macroRunning && f.panel.map { c.panels[$0].ring != nil } == true && f.origin != nil
        }.count
      let planetR = try #require(c.darkPlanetRadius)
      for s in bolts.seeds where seen.insert(s.bornMs).inserted || s.bornMs == c.nowMs {
        // a seed born this frame: on the surface, pointing inward
        if abs(s.bornMs - c.nowMs) < 1e-6 {
          dropped += 1
          let d = stageHyp(s.x - c.ringCenter.x, s.y - c.ringCenter.y)
          #expect(stageNear(d, planetR, 1e-6), "on the planet's surface: \(d) vs \(planetR)")
          let inward = stageHyp(s.ux, s.uy)
          #expect(stageNear(inward, 1, 1e-12))
          // pointing at the centre: the surface point plus u * R is the centre
          #expect(stageNear(s.x + s.ux * planetR, c.ringCenter.x, 1e-6))
          #expect(stageNear(s.y + s.uy * planetR, c.ringCenter.y, 1e-6))
        }
      }
    }
    #expect(thrown >= 6)
    #expect(dropped == thrown, "one seed per bolt (\(dropped) seeds, \(thrown) bolts)")
  }

  @Test func onlyTheDeckThatRunsTheMacroThrowsBolts() throws {
    let h = try StageHarness(net: ["A", "B"], source: .master)
    defer { h.stop() }
    h.run(0.4)
    h.rig.dj["A"]!.fire(.beatRepeat, duration: 1)
    var macroFires: [StageFire] = []
    follow(h, frames: 18, macroFires: &macroFires)
    let all = h.frames.suffix(18).flatMap(\.fires)
    #expect(all.contains { $0.deck == "B" }, "deck B keeps playing through it")
    #expect(!all.contains { $0.deck == "B" && $0.macroRunning }, "but its hits carry no macro")
    #expect(macroFires.count >= 4 && macroFires.allSatisfy { $0.deck == "A" })
  }

  @Test func theFlameAndBoltsTogglesGateThrowing() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.4)
    h.model.settings.overlays.remove(.flame)
    h.deck.fire(.beatRepeat, duration: 1)
    h.run(0.8)
    #expect(h.model.layers.bolts.bolts.isEmpty, "no flame, no bolts")
    h.model.settings.overlays.insert(.flame)
    h.model.settings.overlays.remove(.bolts)
    h.deck.fire(.beatRepeat, duration: 1)
    h.run(0.8)
    #expect(h.model.layers.bolts.bolts.isEmpty, "bolts off")
    h.model.settings.overlays.insert(.bolts)
    h.deck.fire(.beatRepeat, duration: 1)
    h.run(0.6)
    #expect(!h.model.layers.bolts.bolts.isEmpty, "both on, macro running: bolts")
    h.model.settings.overlays.remove(.bolts)
    h.step()
    #expect(h.model.layers.bolts.bolts.isEmpty && h.model.layers.bolts.seeds.isEmpty)
  }

  @Test func aRebuildClearsBoltsAndSeeds() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.4)
    h.deck.fire(.beatRepeat, duration: 2)
    h.run(0.6)
    let bolts = h.model.layers.bolts
    #expect(!bolts.bolts.isEmpty && !bolts.seeds.isEmpty)
    let before = bolts.bolts.count
    h.model.settings.expandVariants = true  // rebuilds the panels
    h.step()
    #expect(bolts.bolts.count < before || bolts.bolts.count <= 3, "only this frame's own")
    #expect(bolts.seeds.count <= 3)
  }
}
