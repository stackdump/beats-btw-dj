import Testing

@testable import DJCore

// The background model's state (SPEC mode 18) and the card model's honest "not available"
// (SPEC mode 19, not ported).

@MainActor
struct StageBackgroundModelTests {
  @Test func voidSpawnsNothingAndKeepsTheClockStill() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 1))
    for _ in 0..<10 { m.advance(backdropContext(.void, dt: 0.5)) }
    #expect(m.mode == .void && m.stars.isEmpty && m.planets.isEmpty)
    #expect(m.phase == 0 && m.spawns == 0)
  }

  @Test func starsSpawnTheFieldOnTheFirstFrameAndTheClockCountsDt() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 1))
    m.advance(backdropContext(.stars, dt: 0))
    #expect(m.stars.count == 150 && (2...3).contains(m.planets.count) && m.spawns == 1)
    #expect(m.phase == 0, "the first frame has no elapsed time")
    m.advance(backdropContext(.stars, dt: 0.25))
    m.advance(backdropContext(.stars, dt: 0.5))
    #expect(stageNear(m.phase, 0.75) && m.spawns == 1)
  }

  @Test func theFieldIsTheGeneratorsOutputForTheSameRandomSource() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 21))
    m.advance(backdropContext(.stars, dt: 0.1))
    // spawnStars draws the 150 stars first, then spawnPlanets, from one source
    let random = backdropRandom(seed: 21)
    #expect(m.stars == StageBackdrop.makeStars(random: random))
    #expect(m.planets == StageBackdrop.makePlanets(random: random))
  }

  @Test func switchingAwayAndBackKeepsTheStarsAndTheClockStandsStillInVoid() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 4))
    m.advance(backdropContext(.stars, dt: 0.1))
    m.advance(backdropContext(.stars, dt: 0.4))
    let stars = m.stars
    let planets = m.planets
    for _ in 0..<5 { m.advance(backdropContext(.void, dt: 1)) }
    #expect(stageNear(m.phase, 0.5), "void draws nothing, so its clock does not run")
    m.advance(backdropContext(.stars, dt: 0.1))
    #expect(m.stars == stars && m.planets == planets, "stars respawn only when empty")
    #expect(m.spawns == 1 && stageNear(m.phase, 0.6))
  }

  @Test func theAuroraAndTheStarsShareOneClock() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 4))
    m.advance(backdropContext(.stars, dt: 1.0))
    m.advance(backdropContext(.aurora, dt: 0.5))
    #expect(m.mode == .aurora && stageNear(m.phase, 1.5))
    #expect(m.spawns == 1, "the aurora never spawns a starfield")
    m.advance(backdropContext(.stars, dt: 0.25))
    #expect(stageNear(m.phase, 1.75) && m.spawns == 1)
  }

  @Test func theAuroraAloneNeverSpawnsAnything() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 4))
    m.advance(backdropContext(.aurora, dt: 2))
    #expect(m.stars.isEmpty && m.planets.isEmpty && m.spawns == 0 && stageNear(m.phase, 2))
  }

  @Test func anExplicitSpawnReplacesTheFieldWithTheNextDraws() {
    let m = StageBackgroundModel(random: backdropRandom(seed: 4))
    m.advance(backdropContext(.stars, dt: 0))
    let first = m.stars
    m.spawn()
    #expect(m.stars != first && m.stars.count == 150 && m.spawns == 2)
  }

  @Test func aBadFrameTimeDoesNotPoisonTheClockForGood() {
    // the model lives as long as the app: a NaN, an infinity or a negative dt from a caller must
    // be a frame that took no time, not a phase that is NaN for every later star and blob
    for mode in [StageBackground.stars, .aurora] {
      let m = StageBackgroundModel(random: backdropRandom(seed: 4))
      m.advance(backdropContext(mode, dt: 0.5))
      for bad in [Double.nan, .infinity, -.infinity, -3, -0.001] {
        m.advance(backdropContext(mode, dt: bad))
        #expect(m.phase == 0.5, "\(mode): dt \(bad) leaves the clock where it was")
      }
      m.advance(backdropContext(mode, dt: 0.25))
      #expect(stageNear(m.phase, 0.75), "\(mode): and it keeps counting afterwards")
      if mode == .stars {
        #expect(m.stars.allSatisfy { !$0.alpha(at: m.phase).isNaN })
      } else {
        let blobs = StageBackdrop.auroraBlobs(phase: m.phase)
        #expect(blobs.allSatisfy { !$0.cx.isNaN && !$0.cy.isNaN })
      }
    }
  }

  @Test func aFixedSceneKeepsItsStarsAndPlanetsAndSpawnsNothing() {
    let star = StageStar(x: 0.3, y: 0.4, size: 1.2, bright: 0.5, twinkleRate: 1, phase: 0)
    let planet = StagePlanet(
      x: 0.5, y: 0.5, r: 30, ringRatio: 2, ringWidth: 0.2, tilt: 0, tiltRate: 0,
      body: StageBackdrop.skyGlow, ring: StageBackdrop.starColor)
    let m = StageBackgroundModel(stars: [star], planets: [planet])
    m.advance(backdropContext(.stars, dt: 0.1))
    m.advance(backdropContext(.aurora, dt: 0.1))
    m.advance(backdropContext(.stars, dt: 0.1))
    #expect(m.stars == [star] && m.planets == [planet] && m.spawns == 0)
    #expect(stageNear(m.phase, 0.3))
  }

  @Test func theBackgroundIsNotClearedByARebuildOfThePanels() {
    // stage.js clears pulses, bolts, seeds and flame energy on a rebuild; stars and the clock stay
    let layers = StageLayerModels()
    #expect(!layers.clearedOnRebuild.contains { $0 === layers.background })
    let m = StageBackgroundModel(random: backdropRandom(seed: 4))
    m.advance(backdropContext(.stars, dt: 0.5))
    m.reset()
    #expect(m.stars.count == 150 && stageNear(m.phase, 0.5))
  }

  @Test func theRegistryBuildsTheModelWithNoArguments() {
    let layers = StageLayerModels()
    layers.background.advance(backdropContext(.stars, dt: 0.1))
    #expect(layers.background.stars.count == 150)
    #expect(layers.all.contains { $0 === layers.background })
  }

  // MARK: the card (mode 19, not ported)

  @Test func theCardFlashIsNotPortedAndItsButtonSaysSo() {
    let card = StageCardModel()
    #expect(!card.isAvailable)
    #expect(card.unavailableReason.contains("no share card"))
    #expect(card.unavailableReason == StageCardModel.reason)
  }

  @Test func theTKeyThroughTheStageDoesNotFlipAFlagForAFeatureThatIsNotThere() throws {
    // StageModel.handleKey falls back to the card toggle only when the card is available
    let h = try StageHarness(play: false, attach: false)
    defer { h.stop() }
    #expect(!h.model.layers.card.isAvailable)
    #expect(h.model.handleKey(.t) == false)
    #expect(!h.model.settings.cardOnChange)
  }

  @Test func aTrackChangeStartsNoFlash() {
    let card = StageCardModel()
    var ctx = backdropContext(.void, dt: 0.016)
    ctx.cardOnChange = true
    ctx.trackChanged = true
    card.advance(ctx)
    card.advance(backdropContext(.void, dt: 7))
    #expect(!card.isAvailable)
  }
}
