import Testing

@testable import DJCore

// Flame beams (SPEC mode 15). Expected numbers are stage.js's renderFlame arithmetic run in node
// (the 1000 x 800 stage, centre (500, 400), inner radius 40; see StageFlameModel.swift).

private func pt(_ x: Double, _ y: Double) -> StagePoint { StagePoint(x: x, y: y) }

private func near(_ p: StagePoint, _ x: Double, _ y: Double, _ tol: Double = 1e-9) -> Bool {
  stageNear(p.x, x, tol) && stageNear(p.y, y, tol)
}

struct StageFlameNumbersTests {
  @Test func theConstantsAreTheJS() {
    #expect(StageFlame.bump == 0.9 && StageFlame.decayRate == 4 && StageFlame.floor == 0.01)
    #expect(StageFlame.maxHalfAngle == 0.10 && StageFlame.innerRadiusOfCentre == 0.10)
    #expect(StageFlame.tipTaper == 0.25 && StageFlame.minReach == 4)
  }

  @Test func aFireAddsNineTenthsAndCapsAtOne() {
    #expect(StageFlame.bumped(0) == 0.9)
    #expect(stageNear(StageFlame.bumped(0.05), 0.95, 1e-15))
    #expect(StageFlame.bumped(0.2) == 1 && StageFlame.bumped(1) == 1)
  }

  @Test func energyDecaysByEToTheMinusFourDt() {
    // node: exp(-0.05 * 4) = 0.81873075307798182, exp(-0.1 * 4) = 0.67032004603563933
    #expect(stageNear(StageFlame.decayed(1, dt: 0.05), 0.81873075307798182, 1e-15))
    #expect(stageNear(StageFlame.decayed(0.5, dt: 0.1), 0.5 * 0.67032004603563933, 1e-15))
    #expect(StageFlame.decayed(0.7, dt: 0) == 0.7)
  }

  @Test func theBeamStaysNarrowWhateverThePanelCount() {
    // min(0.10, (pi / n) * 0.15): node values for n = 0, 1...5, 8, 16
    #expect(StageFlame.halfAngle(panelCount: 0) == 0.10)
    for n in 1...4 { #expect(StageFlame.halfAngle(panelCount: n) == 0.10, "n = \(n)") }
    // the cross-over: pi / n * 0.15 = 0.10 at n = 4.71
    #expect(stageNear(StageFlame.halfAngle(panelCount: 5), 0.09424777960769379, 1e-15))
    #expect(stageNear(StageFlame.halfAngle(panelCount: 8), 0.058904862254808621, 1e-15))
    #expect(stageNear(StageFlame.halfAngle(panelCount: 16), 0.02945243112740431, 1e-15))
  }

  @Test func theInnerRadiusIsATenthOfTheShorterHalf() {
    #expect(StageFlame.innerRadius(centre: pt(500, 400)) == 40)
    #expect(StageFlame.innerRadius(centre: pt(300, 400)) == 30)
  }

  @Test func theGradientRunsAmberRoseBlue() {
    let s = StageFlame.stops(energy: 0.5)
    #expect(s.map(\.location) == [0, 0.5, 1])
    #expect(s[0].color == ScopeColor(r8: 255, g8: 200, b8: 64, a: 0.425))
    #expect(s[1].color == ScopeColor(r8: 233, g8: 69, b8: 96, a: 0.35))
    #expect(s[2].color == ScopeColor(r8: 74, g8: 144, b8: 217, a: 0))
  }

  @Test func aFullEnergyBeamToTheTopPanel() {
    // panel at (500, 144), no fired transition yet: target = its ring position
    let b = StageFlame.beam(
      panelId: "x", energy: 1, target: pt(500, 144), centre: pt(500, 400), halfAngle: 0.1,
      innerRadius: 40)
    #expect(stageNear(b.theta, -1.5707963267948966, 1e-15))
    #expect(stageNear(b.barLength, 243.20000000000002, 1e-12), "dist 256 * (0.55 + 0.4)")
    #expect(near(b.base1, 496.00666333412687, 360.19983338887897, 1e-9))
    #expect(near(b.base2, 503.99333666587313, 360.19983338887897, 1e-9))
    #expect(near(b.tip2, 506.07936668645806, 156.87599604174912, 1e-9))
    #expect(near(b.tip1, 493.92063331354200, 156.87599604174912, 1e-9))
    #expect(near(b.gradientEnd, 500, 156.79999999999998, 1e-9) && near(b.gradientStart, 500, 400))
    #expect(b.polygon == [b.base1, b.base2, b.tip2, b.tip1])
  }

  @Test func aBeamTowardAFiredTransitionOffTheRingPoint() {
    let b = StageFlame.beam(
      panelId: "x", energy: 0.5, target: pt(560, 180), centre: pt(500, 400), halfAngle: 0.1,
      innerRadius: 40)
    #expect(stageNear(b.theta, -1.3045442776439713, 1e-15))
    #expect(stageNear(b.barLength, 171.02631376487068, 1e-10), "228.035 * (0.55 + 0.2)")
    #expect(near(b.base1, 506.61948984755537, 360.55152279037742, 1e-9))
    #expect(near(b.base2, 514.32474333006837, 362.65295555833552, 1e-9))
    #expect(near(b.tip2, 549.11050855833412, 236.17644263067112, 1e-9))
    #expect(near(b.tip1, 540.86136790647913, 233.92667699834703, 1e-9))
    #expect(near(b.gradientEnd, 545, 235, 1e-9))
  }

  @Test func withEightPanelsTheBeamIsNarrowerStill() {
    let b = StageFlame.beam(
      panelId: "x", energy: 0.25, target: pt(756, 400), centre: pt(500, 400),
      halfAngle: StageFlame.halfAngle(panelCount: 8), innerRadius: 40)
    #expect(b.theta == 0)
    #expect(stageNear(b.barLength, 166.40000000000001, 1e-12), "256 * (0.55 + 0.1)")
    #expect(near(b.base1, 539.93062440738868, 397.64516785395244, 1e-9))
    #expect(near(b.base2, 539.93062440738868, 402.35483214604756, 1e-9))
    #expect(near(b.tip2, 666.38195745551877, 402.45035370302668, 1e-9))
    #expect(near(b.tip1, 666.38195745551877, 397.54964629697332, 1e-9))
  }

  @Test func aTargetOnTheCentreUsesADistanceOfOneAndTheMinimumReach() {
    // `Math.hypot(dx, dy) || 1`, barLen = max(innerR + 4, 1 * 0.95)
    let b = StageFlame.beam(
      panelId: "x", energy: 1, target: pt(500, 400), centre: pt(500, 400), halfAngle: 0.1,
      innerRadius: 40)
    #expect(b.theta == 0 && b.barLength == 44)
    #expect(near(b.base1, 539.80016661112109, 396.00666333412687, 1e-9))
    #expect(near(b.tip2, 543.98625071613094, 401.09988542024735, 1e-9))
    // and a short beam is held at innerR + 4 as well
    let c = StageFlame.beam(
      panelId: "x", energy: 0.1, target: pt(510, 395), centre: pt(500, 400), halfAngle: 0.1,
      innerRadius: 40)
    #expect(c.barLength == 44)
    #expect(near(c.base1, 533.81247677492672, 378.62907549156932, 1e-9))
    #expect(near(c.gradientEnd, 539.35479640399626, 380.32260179800187, 1e-9))
  }
}

@MainActor
struct StageFlameModelTests {
  /// Panel 0 of the 4-ring is at (500, 144); the centre is (500, 400).
  private let origin = pt(560, 180)

  private func fire(_ panel: Int = 0, _ origin: StagePoint? = pt(560, 180), wall: Double = 10)
    -> StageFire
  { OverlayFixture.fire(panel: panel, origin: origin, wall: wall) }

  @Test func aFireBumpsItsPanelAndRemembersTheTransitionAsTheOrigin() throws {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(dt: 0.05, fires: [fire()]))
    // 0.9, then this frame's decay
    let v = try #require(m.energies["A/n0"])
    #expect(stageNear(v, 0.9 * 0.81873075307798182, 1e-14))
    #expect(m.origins["A/n0"] == origin)
    #expect(m.energies.count == 1, "only that panel")
  }

  @Test func twoFiresInAFrameCapAtOneBeforeTheDecay() throws {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(dt: 0.05, fires: [fire(), fire()]))
    #expect(stageNear(try #require(m.energies["A/n0"]), 0.81873075307798182, 1e-14))
  }

  @Test func energyDecaysFrameByFrameAndIsDeletedBelowOneHundredth() throws {
    let m = StageFlameModel()
    let k = 0.81873075307798182
    m.advance(OverlayFixture.context(dt: 0.05, fires: [fire()]))
    var want = 0.9 * k
    for _ in 0..<10 {
      m.advance(OverlayFixture.context(dt: 0.05))
      want *= k
      #expect(stageNear(try #require(m.energies["A/n0"]), want, 1e-13))
    }
    // keep going: the first v below 0.01 removes the entry
    var frames = 0
    while m.energies["A/n0"] != nil, frames < 100 {
      m.advance(OverlayFixture.context(dt: 0.05))
      want *= k
      frames += 1
      if want >= 0.01 { #expect(m.energies["A/n0"] != nil) }
    }
    #expect(want < 0.01 && m.energies["A/n0"] == nil)
    #expect(m.origins["A/n0"] == origin, "the origin stays on the panel")
  }

  @Test func theLongestFrameStillDecays() throws {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(dt: 0.1, fires: [fire()]))
    #expect(stageNear(try #require(m.energies["A/n0"]), 0.9 * 0.67032004603563933, 1e-14))
  }

  @Test func eachPanelHasItsOwnBeam() throws {
    let m = StageFlameModel()
    m.advance(
      OverlayFixture.context(
        dt: 0, fires: [fire(0), fire(2, pt(520, 600)), fire(2, pt(530, 610))]))
    #expect(try #require(m.energies["A/n0"]) == 0.9)
    #expect(try #require(m.energies["A/n2"]) == 1)
    #expect(m.energies["A/n1"] == nil)
    #expect(m.origins["A/n2"] == pt(530, 610), "the last fired transition")
  }

  @Test func aFireWithoutAnOriginKeepsTheOneBefore() {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(dt: 0, fires: [fire()]))
    m.advance(OverlayFixture.context(dt: 0, fires: [fire(0, nil)]))
    #expect(m.origins["A/n0"] == origin)
    #expect(m.energies["A/n0"] == 1)
  }

  @Test func theToggleGatesAndClears() {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(dt: 0.05, fires: [fire()]))
    #expect(!m.energies.isEmpty)
    var off = StageOverlay.defaults
    off.remove(.flame)
    // turned off: the energies are dropped, nothing new is collected, no beams
    m.advance(OverlayFixture.context(dt: 0.05, fires: [fire()], overlays: off))
    #expect(m.energies.isEmpty)
    #expect(m.beams(in: OverlayFixture.context(overlays: off)).isEmpty)
    // and back on, it starts from nothing
    m.advance(OverlayFixture.context(dt: 0.05))
    #expect(m.energies.isEmpty)
  }

  @Test func aLonePanelAndAPanelessFireMakeNoBeam() {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(panels: 1, dt: 0, fires: [fire()]))
    #expect(m.energies.isEmpty)
    m.advance(
      OverlayFixture.context(
        dt: 0, fires: [OverlayFixture.fire(panel: nil, origin: nil, wall: 10)]))
    #expect(m.energies.isEmpty)
  }

  @Test func aRebuildForgetsEnergiesAndOrigins() {
    let m = StageFlameModel()
    m.advance(OverlayFixture.context(dt: 0.05, fires: [fire()]))
    m.reset()
    #expect(m.energies.isEmpty && m.origins.isEmpty)
    #expect(m.beams(in: OverlayFixture.context()).isEmpty)
  }

  @Test func theBeamsComeFromTheStoredEnergyAndTheContextsGeometry() throws {
    let m = StageFlameModel()
    let ctx = OverlayFixture.context(dt: 0.05, fires: [fire(), fire(1, nil)])
    m.advance(ctx)
    let beams = m.beams(in: ctx)
    #expect(beams.map(\.panelId) == ["A/n0", "A/n1"], "in panel order")
    let b0 = beams[0]
    let v = 0.9 * 0.81873075307798182
    #expect(stageNear(b0.energy, v, 1e-14))
    // aimed at the remembered transition, not the ring point
    let direct = StageFlame.beam(
      panelId: "A/n0", energy: b0.energy, target: origin, centre: pt(500, 400), halfAngle: 0.1,
      innerRadius: 40)
    #expect(b0 == direct)
    // panel 1 has no origin: its ring position (756, 400) is the target, straight along +x
    #expect(beams[1].theta == 0)
    #expect(stageNear(beams[1].barLength, 256 * (0.55 + 0.4 * v), 1e-10))
  }
}

// The layer on a real offline engine, through the real StageModel.
@MainActor
struct StageFlameEngineTests {
  @Test func eachPanelsEnergyFollowsItsFiresAndDecaysByEToTheMinusFourDt() throws {
    let h = try StageHarness()
    defer { h.stop() }
    let flame = h.model.layers.flame
    var lastFire: [String: StageFire] = [:]
    var previous: [String: Double] = [:]
    var checkedDecay = 0
    var checkedBump = 0
    for _ in 0..<60 {
      h.step()
      let ctx = h.ctx
      // this frame's fires per panel, in order
      var fires: [String: Int] = [:]
      for f in ctx.fires {
        guard let p = f.panel, ctx.panels[p].ring != nil else { continue }
        fires[ctx.panels[p].id, default: 0] += 1
        lastFire[ctx.panels[p].id] = f
      }
      // the model's number for each panel, worked out here from last frame's stored energy
      for p in ctx.panels {
        var e = previous[p.id] ?? 0
        for _ in 0..<(fires[p.id] ?? 0) { e = StageFlame.bumped(e) }
        let want = e > 0 ? StageFlame.decayed(e, dt: ctx.dt) : 0
        let got = flame.energies[p.id]
        if want >= StageFlame.floor {
          #expect(
            stageNear(got ?? -1, want, 1e-12), "\(p.id): \(String(describing: got)) vs \(want)")
          if fires[p.id] != nil { checkedBump += 1 } else { checkedDecay += 1 }
        } else {
          #expect(got == nil, "\(p.id) is below the floor")
        }
      }
      #expect(flame.energies.keys.allSatisfy { id in ctx.panels.contains { $0.id == id } })
      previous = flame.energies
    }
    #expect(
      checkedBump > 10 && checkedDecay > 10, "both paths ran (\(checkedBump), \(checkedDecay))")
    // the remembered origin is the transition that fired last on that panel
    for (id, f) in lastFire {
      if let o = flame.origins[id], let want = f.origin { #expect(o == want, "\(id) origin") }
    }
    #expect(!flame.origins.isEmpty)
  }

  @Test func theBeamsOfTheRealStageAreAimedAtTheirPanels() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(1.5)
    let beams = h.model.layers.flame.beams(in: h.ctx)
    #expect(!beams.isEmpty)
    for b in beams {
      let panel = try #require(h.ctx.panels.first { $0.id == b.panelId })
      let target = h.model.layers.flame.origins[b.panelId] ?? panel.ring!
      let c = h.ctx.ringCenter
      #expect(stageNear(b.theta, stageAtan2(target.y - c.y, target.x - c.x), 1e-12))
      #expect(b.gradientStart == c)
      #expect(b.barLength >= StageFlame.innerRadius(centre: c) + 4)
    }
  }

  @Test func theToggleClearsIt() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(1)
    let flame = h.model.layers.flame
    #expect(!flame.energies.isEmpty)
    h.model.settings.overlays.remove(.flame)
    h.step()
    #expect(flame.energies.isEmpty && h.model.layers.flame.beams(in: h.ctx).isEmpty)
    h.model.settings.overlays.insert(.flame)
    h.run(0.5)
    #expect(!flame.energies.isEmpty)
  }

  @Test func theStageClearsItOnARebuild() {
    // the registry hands the model to StageModel, which resets it with the other cleared layers
    let models = StageLayerModels()
    #expect(models.clearedOnRebuild.contains { $0 === models.flame })
  }

  @Test func theStagesRebuildClearsTheBeamsLikeRebuildStagePanels() throws {
    // stage.js rebuildStagePanels: `flameEnergy.clear()`. A beam left over would keep glowing
    // from the old track's panel for about a second.
    let h = try StageHarness()
    defer { h.stop() }
    h.run(1)
    let flame = h.model.layers.flame
    let before = Set(flame.energies.keys)
    #expect(!before.isEmpty && !flame.origins.isEmpty)
    let epoch = h.ctx.epoch
    h.model.settings.expandVariants = true  // rebuilds the panels
    h.step()
    #expect(h.ctx.epoch == epoch + 1)
    // all that is left was fired in the rebuild frame itself
    let ctx = h.ctx
    let fired = Set(ctx.fires.compactMap { f in f.panel.map { ctx.panels[$0].id } })
    #expect(Set(flame.origins.keys) == fired)
    #expect(Set(flame.energies.keys) == fired)
    #expect(
      !before.subtracting(fired).isEmpty,
      "something was glowing that did not fire again: the test saw it cleared (\(before.count) glowing, \(fired.count) fired)"
    )
  }
}
