import Testing

@testable import DJCore

// Pulse particles (SPEC mode 14). Expected numbers are stage.js's renderPulses arithmetic run in
// node (see StagePulseModel.swift for the formulas).

private func pt(_ x: Double, _ y: Double) -> StagePoint { StagePoint(x: x, y: y) }

struct StagePulseNumbersTests {
  // a particle from (100, 200) to (400, 500), born at 1000 ms, 700 ms long
  private let p = StagePulseParticle(x0: 100, y0: 200, cx: 400, cy: 500, bornMs: 1000)

  @Test func theConstantsAreTheJS() {
    #expect(StagePulse.lifeMs == 700 && StagePulse.shiftAbove == 64)
    #expect(StagePulse.maxRadius == 10 && StagePulse.minRadius == 1.5)
    #expect(StagePulse.peakAlpha == 0.7)
    #expect(p.lifeMs == 700, "life defaults to 700 ms")
  }

  @Test func atBirthItSitsOnItsTransitionFullSizeAtSevenTenthsAlpha() throws {
    let d = try #require(StagePulse.dot(of: p, nowMs: 1000))
    #expect(stageNear(d.x, 100) && stageNear(d.y, 200))
    #expect(stageNear(d.radius, 10) && stageNear(d.alpha, 0.7))
  }

  @Test func aQuarterOfTheWayItHasCoveredFortyThreePointSevenFivePercent() throws {
    // t = 0.25: e = 1 - 0.75^2 = 0.4375
    let d = try #require(StagePulse.dot(of: p, nowMs: 1175))
    #expect(stageNear(d.x, 100 + 300 * 0.4375, 1e-9) && stageNear(d.y, 200 + 300 * 0.4375, 1e-9))
    #expect(stageNear(d.radius, 7.5, 1e-9) && stageNear(d.alpha, 0.525, 1e-9))
  }

  @Test func halfWayIsThreeQuartersOfTheWayThere() throws {
    // t = 0.5: e = 0.75, r = 5, alpha = 0.35
    let d = try #require(StagePulse.dot(of: p, nowMs: 1350))
    #expect(stageNear(d.x, 325, 1e-9) && stageNear(d.y, 425, 1e-9))
    #expect(stageNear(d.radius, 5, 1e-9) && stageNear(d.alpha, 0.35, 1e-9))
  }

  @Test func theRadiusNeverShrinksBelowOneAndAHalf() throws {
    // t = 0.9: r = max(1.5, 1) = 1.5; e = 0.99; alpha = 0.07
    let d = try #require(StagePulse.dot(of: p, nowMs: 1630))
    #expect(stageNear(d.radius, 1.5, 1e-12))
    #expect(
      stageNear(d.x, 397, 1e-9) && stageNear(d.y, 497, 1e-9) && stageNear(d.alpha, 0.07, 1e-9))
    // 85% through, the linear radius is 1.5 exactly (10 * 0.15)
    let e = try #require(StagePulse.dot(of: p, nowMs: 1000 + 0.85 * 700))
    #expect(stageNear(e.radius, 1.5, 1e-9))
    let f = try #require(StagePulse.dot(of: p, nowMs: 1000 + 0.8 * 700))
    #expect(stageNear(f.radius, 2, 1e-9), "still shrinking before that")
  }

  @Test func atSevenHundredMillisecondsItIsGone() {
    #expect(StagePulse.dot(of: p, nowMs: 1700) == nil)
    #expect(StagePulse.dot(of: p, nowMs: 5000) == nil)
    #expect(StagePulse.dot(of: p, nowMs: 1699.9) != nil)
  }

  @Test func aClockThatStepsBackHoldsTheParticleAtItsStart() throws {
    let d = try #require(StagePulse.dot(of: p, nowMs: 900))
    #expect(stageNear(d.x, 100) && stageNear(d.radius, 10) && stageNear(d.alpha, 0.7))
  }
}

@MainActor
struct StagePulseModelTests {
  /// Panel 0 of the 4-ring is at (500, 144); the ring centre is (500, 400).
  private let origin = pt(520, 170)

  @Test func aFireSpawnsAParticleFromItsTransitionTowardTheCentre() {
    let m = StagePulseModel()
    let ctx = OverlayFixture.context(
      now: 10, fires: [OverlayFixture.fire(origin: origin, wall: 9.9)])
    m.advance(ctx)
    #expect(m.particles.count == 1)
    let p = m.particles[0]
    #expect(p.x0 == 520 && p.y0 == 170 && p.cx == 500 && p.cy == 400)
    #expect(stageNear(p.bornMs, 9900, 1e-9) && p.lifeMs == 700)
    // 100 ms old: t = 1/7
    let d = StagePulse.dot(of: p, nowMs: 10_000)!
    #expect(stageNear(d.alpha, 0.7 * (1 - 1.0 / 7), 1e-9))
  }

  @Test func withoutAnOriginItStartsFromThePanelsRingPosition() {
    let m = StagePulseModel()
    m.advance(
      OverlayFixture.context(fires: [OverlayFixture.fire(panel: 1, origin: nil, wall: 10)]))
    // panel 1 of the 4-ring: (756, 400)
    #expect(m.particles.first.map { $0.x0 == 756 && $0.y0 == 400 } == true)
  }

  @Test func theToggleGatesNewParticles() {
    let m = StagePulseModel()
    var on = StageOverlay.defaults
    on.remove(.pulse)
    m.advance(
      OverlayFixture.context(
        fires: [OverlayFixture.fire(origin: origin, wall: 10)], overlays: on))
    #expect(m.particles.isEmpty, "pulse off: nothing spawns")
  }

  @Test func aLonePanelHasNoRingPositionAndSpawnsNothing() {
    let m = StagePulseModel()
    let ctx = OverlayFixture.context(
      panels: 1, fires: [OverlayFixture.fire(origin: origin, wall: 10)])
    #expect(ctx.panels[0].ring == nil)
    m.advance(ctx)
    #expect(m.particles.isEmpty)
  }

  @Test func aFireOfANetWithoutAPanelSpawnsNothing() {
    let m = StagePulseModel()
    m.advance(
      OverlayFixture.context(fires: [OverlayFixture.fire(panel: nil, origin: nil, wall: 10)]))
    #expect(m.particles.isEmpty)
  }

  @Test func particlesKeepDrainingAfterTheToggleIsTurnedOff() {
    let m = StagePulseModel()
    m.advance(
      OverlayFixture.context(now: 10, fires: [OverlayFixture.fire(origin: origin, wall: 10)]))
    #expect(m.particles.count == 1)
    var off = StageOverlay.defaults
    off.remove(.pulse)
    m.advance(OverlayFixture.context(now: 10.3, overlays: off))
    #expect(m.particles.count == 1, "mid-flight it is not cleared")
    #expect(m.dots(nowMs: 10_300).count == 1)
    m.advance(OverlayFixture.context(now: 10.75, overlays: off))
    #expect(m.particles.isEmpty, "gone after 700 ms")
  }

  @Test func theDeadAreEvictedEachFrame() {
    let m = StagePulseModel()
    m.advance(
      OverlayFixture.context(
        now: 10,
        fires: [
          OverlayFixture.fire(origin: origin, wall: 9.0),  // already 1000 ms old
          OverlayFixture.fire(origin: origin, wall: 9.9),
        ]))
    #expect(m.particles.count == 1 && stageNear(m.particles[0].bornMs, 9900, 1e-9))
  }

  @Test func theListIsCappedAtSixtyFiveByShiftingTheOldest() {
    let m = StagePulseModel()
    // 70 fires inside one frame, each born 1/1024 s later than the last (exact in binary)
    func wall(_ i: Int) -> Double { 10 + Double(i) / 1024 }
    func born(_ i: Int) -> Double { wall(i) * 1000 }
    let fires = (0..<70).map { OverlayFixture.fire(origin: origin, wall: wall($0)) }
    m.advance(OverlayFixture.context(now: 10.1, fires: fires))
    // `if (pulses.length > 64) shift()` before the push: 65 live, the first 5 gone
    #expect(m.particles.count == 65)
    #expect(m.particles.first?.bornMs == born(5) && m.particles.last?.bornMs == born(69))
    // 64 stay 64: no shift until it is above 64
    let n = StagePulseModel()
    n.advance(OverlayFixture.context(now: 10.1, fires: Array(fires.prefix(64))))
    #expect(n.particles.count == 64 && n.particles.first?.bornMs == born(0))
    n.advance(OverlayFixture.context(now: 10.1, fires: [fires[64]]))
    #expect(n.particles.count == 65 && n.particles.first?.bornMs == born(0), "65th just fits")
    n.advance(OverlayFixture.context(now: 10.1, fires: [fires[65]]))
    #expect(n.particles.count == 65 && n.particles.first?.bornMs == born(1), "66th shifts one")
  }

  @Test func aRebuildClearsThem() {
    let m = StagePulseModel()
    m.advance(
      OverlayFixture.context(now: 10, fires: [OverlayFixture.fire(origin: origin, wall: 10)]))
    m.reset()
    #expect(m.particles.isEmpty)
  }

  @Test func theStageClearsItOnARebuild() throws {
    // the registry hands the model to StageModel, which resets it with the other cleared layers
    let models = StageLayerModels()
    #expect(models.clearedOnRebuild.contains { $0 === models.pulse })
  }
}

// The layer on a real offline engine, through the real StageModel.
@MainActor
struct StagePulseEngineTests {
  /// Fires of `frames` that would spawn a particle still alive at `nowMs`.
  private func liveSpawns(_ frames: [StageContext], at nowMs: Double) -> [StageFire] {
    var out: [StageFire] = []
    for c in frames where c.isOn(.pulse) {
      for f in c.fires {
        guard let p = f.panel, c.panels[p].ring != nil, f.wallTime * 1000 + 700 > nowMs
        else { continue }
        out.append(f)
      }
    }
    return out
  }

  @Test func everyAudibleFireOfTheLastSevenHundredMillisecondsIsAParticle() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(2)
    let last = h.ctx
    let spawns = liveSpawns(h.frames, at: last.nowMs)
    #expect(spawns.count > 4, "the song fires several times in 700 ms (\(spawns.count))")
    let pulse = h.model.layers.pulse
    #expect(pulse.particles.count == spawns.count)
    // the first spawned of them started at its transition's stage position, aimed at the ring
    // centre
    let first = try #require(spawns.first)
    let p = try #require(pulse.particles.first { abs($0.bornMs - first.wallTime * 1000) < 1e-6 })
    let o = try #require(first.origin)
    #expect(p.x0 == o.x && p.y0 == o.y)
    #expect(p.cx == last.ringCenter.x && p.cy == last.ringCenter.y)
    #expect(pulse.particles.allSatisfy { StagePulse.progress(of: $0, nowMs: last.nowMs) < 1 })
  }

  @Test func theStagesRebuildClearsTheParticlesLikeRebuildStagePanels() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(1.5)
    let pulse = h.model.layers.pulse
    #expect(!pulse.particles.isEmpty)
    let epoch = h.ctx.epoch
    h.model.settings.expandVariants = true  // rebuilds the panels
    h.step()
    #expect(h.ctx.epoch == epoch + 1)
    let spawns = liveSpawns([h.ctx], at: h.ctx.nowMs)
    #expect(pulse.particles.count == spawns.count, "only this frame's own fires survive")
    #expect(pulse.particles.count < 6)
  }

  @Test func theToggleStopsNewParticlesOnARealStage() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.model.settings.overlays.remove(.pulse)
    h.run(1)
    #expect(h.model.layers.pulse.particles.isEmpty, "no spawns with the toggle off")
    h.model.settings.overlays.insert(.pulse)
    h.run(1)
    #expect(!h.model.layers.pulse.particles.isEmpty)
    h.model.settings.overlays.remove(.pulse)
    h.run(0.8)
    #expect(h.model.layers.pulse.particles.isEmpty, "and they drain within 700 ms")
  }
}
