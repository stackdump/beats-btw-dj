import Testing

@testable import DJCore

// The model driven by a real feed: an offline engine plays composed songs, the hub pumps,
// `ModelEngine.consume` takes in the fires. Songs run at 300 BPM (a step is 50 ms, a bar 0.8 s)
// unless a test says otherwise. Kernels are rendered once per test file into `cache` ahead of
// the run where the test is about something else than the render.

/// Kernels are rendered once per test run and cloned into a private cache per test: the tests
/// that are not about the render start warm, and none sees another's entries.
@MainActor private let warmPool = ModelKernelCache(capacity: 400)
@MainActor private var warmedItems = Set<String>()

@MainActor
func warmedCache(_ items: [(String, Double, String, Double)]) -> ModelKernelCache {
  for (genre, seed, structure, tempo) in items {
    let id = "\(genre)|\(seed)|\(structure)|\(tempo)"
    if warmedItems.insert(id).inserted {
      _ = ModelEngine.prepared(
        project: scopeProject(genre, seed: seed, structure: structure), tempo: tempo, deck: "A",
        cache: warmPool)
    }
  }
  let copy = ModelKernelCache()
  for k in warmPool.keys { copy.insert(warmPool.kernel(for: k)!, for: k) }
  return copy
}

/// How long a test waits for a song's kernels that no warmed cache holds. The app's 30 s default
/// is plenty alone, but a full parallel test run starves the background render well past it.
let coldKernelTimeout = 300.0

/// Render in half-second pumps, consuming after each.
@MainActor
func play(
  _ rig: ScopeRig, _ model: ModelEngine, _ feed: ScopeFeed, seconds: Double,
  meter: EnergyMeter? = nil
) {
  var t = 0.0
  while t < seconds {
    rig.render(seconds: 0.5)
    rig.hub.pump()
    model.consume(feed)
    meter?.update()
    t += 0.5
  }
}

@MainActor
struct ModelEngineFeedTests {
  @Test func aDeckFeedFillsTheBarsAndColumnsWhereTheEnginePlayed() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, structure: "loop", tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    model.fxPoint = .matchTap  // compared with the deck TAP's energy: before the EQ and the fader
    let meter = EnergyMeter(feed)
    play(rig, model, feed, seconds: 7, meter: meter)

    #expect(model.status == "model · 15 kernels", "all in the cache: no render, no timing")
    #expect(model.tablesReady && model.lanes == feed.lanes)
    #expect(model.fires == feed.fireCount && model.fires > 200, "every fire taken in once")
    #expect(model.modelFrom == 0 && model.maxBar >= 7, "bar \(model.maxBar)")
    // every complete bar has energy in all five bands, E is their sum, the kick keeps the low
    // end up and the hats the top
    for bar in 0..<model.maxBar {
      let row = (0..<6).map { model.modelBars[bar * 6 + $0] }
      #expect(row[0..<5].allSatisfy { $0 > 0 }, "bar \(bar): \(row)")
      #expect(abs(row[5] - row[0..<5].reduce(0, +)) <= 1e-9 * row[5], "E is the sum")
      #expect(row[0] + row[1] > 10 * row[4], "bar \(bar): kick over hat")
      #expect(row[4] > 0.001 * row[1], "bar \(bar): and the hat is there")
    }
    // a looped song repeats: the bars are alike
    let energies = (1..<model.maxBar).map { model.modelBars[$0 * 6 + 5] }
    let mid = energies.sorted()[energies.count / 2]
    #expect(energies.allSatisfy { $0 > mid / 3 && $0 < mid * 3 }, "\(energies)")
    // the spectrogram: finished columns up to the sounding step, the low bins louder than the high
    #expect(model.specCur > 100 && model.specCur <= feed.clock.tick)
    for step in 10..<(model.specCur - 1) { #expect(model.specStep[step % 2048] == Int32(step)) }
    var low = 0.0
    var high = 0.0
    for step in 10..<(model.specCur - 1) {
      for j in 0..<14 { low += Double(model.specCol[(step % 2048) * 28 + j]) }
      for j in 14..<28 { high += Double(model.specCol[(step % 2048) * 28 + j]) }
    }
    #expect(low > 3 * high && high > 0, "below 700 Hz \(low), above \(high)")
    // The model predicts the energy the deck tap carried: E in the units of Σx². This rig runs
    // at 22.05 kHz and the kernels are 44.1 kHz, and Σx² of the same sound is proportional to the
    // rate it is sampled at, so the tap carries half of what the model says (measured 0.59); the
    // rest of the offset (1.18 normalised) is coherent overlap and the tanh. Being within a
    // factor of 1.6 of one after the rate is taken out catches a misplaced factor of N or 2 or 10;
    // `ModelEngineEnergyTests` pins the level tightly at 44.1 kHz.
    var modelEnergy = 0.0
    for bar in 0...model.maxBar { modelEnergy += model.modelBars[bar * 6 + 5] }
    let ratio = meter.total / (modelEnergy * feed.sampleRate / ModelKernels.sampleRate)
    #expect(ratio > 0.6 && ratio < 1.6, "measured/model at the kernel rate = \(ratio)")
  }

  @Test func reacquiringStartsTheHistoryOverAndTakesOnlyNewFires() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    play(rig, model, feed, seconds: 4)
    #expect(model.maxBar >= 3)
    let firesBefore = model.fires
    feed.release()
    feed.acquire()
    #expect(
      feed.generationFireStart == feed.fireCount,
      "nothing of the old fires belongs to the new generation")
    model.consume(feed)
    #expect(model.maxBar == -1 && model.modelFrom == Int.max && model.specCur == -1)
    #expect(model.modelBars.allSatisfy { $0 == 0 } && model.fires == firesBefore)
    play(rig, model, feed, seconds: 2.5)
    #expect(model.fires - firesBefore == feed.fireCount - feed.generationFireStart)
    #expect(model.maxBar >= 1, "it fills again")
    #expect(
      model.modelFrom > 50, "from the step the feed was re-acquired at, not the top of the song")
  }

  @Test func aRestartStartsTheBarsAgainAndKeepsTheFirstStep() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, structure: "standard", tempo: 300)
    defer { rig.stop() }
    rig.dj.deterministic = true
    let cache = warmedCache([("techno", 42, "standard", 300)])
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    play(rig, model, feed, seconds: 7)
    #expect(model.maxBar >= 6)
    let firesBefore = model.fires
    let g0 = feed.generation
    a.relocate(toTick: 0)  // lands at the next bar line: the step counter jumps from ~140 to 0
    var pumps = 0
    while feed.generation == g0 && pumps < 200 {
      rig.render(frames: 512)
      rig.hub.pump()
      pumps += 1
    }
    #expect(feed.generation != g0, "the feed saw the restart")
    // keep pumping WITHOUT consuming until the new generation has fired: what is unread now
    // holds fires from before the restart (old bars, ~step 140) and from after it
    pumps = 0
    while feed.fireCount == feed.generationFireStart && pumps < 200 {
      rig.render(frames: 512)
      rig.hub.pump()
      pumps += 1
    }
    for _ in 0..<2 {
      rig.render(frames: 512)
      rig.hub.pump()
    }
    let after = feed.fireCount - feed.generationFireStart
    let unread = feed.fireCount - firesBefore
    #expect(
      after > 0 && unread > after,
      "fires on both sides of the restart: \(unread) unread, \(after) after")
    let first = try #require(feed.fireLog.fire(number: feed.generationFireStart))
    #expect(
      first.step < 16,
      "the first fire of the new generation is in the first bar: step \(first.step)")
    model.consume(feed)
    #expect(model.fires - firesBefore == after, "only the new generation's fires")
    #expect(model.modelFrom == first.step, "the first step of the restarted song is in")
    #expect(model.maxBar <= 1, "and none of the old bars (~8) are: bar \(model.maxBar)")
    #expect(model.modelBars[0..<6].contains { $0 > 0 })
  }

  @Test func aNewTrackRebuildsTheLanesAndTheirKernels() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    play(rig, model, feed, seconds: 2)
    let oldLanes = model.lanes
    #expect(model.tablesReady && model.maxBar >= 1)
    rig.load(scopeProject("dnb", seed: 5))
    for _ in 0..<12 {  // the song takes over at the next bar
      rig.render(seconds: 0.25)
      rig.hub.pump()
      if feed.lanes != oldLanes { break }
    }
    #expect(feed.lanes != oldLanes, "the feed follows the new song")
    model.consume(feed)
    #expect(model.lanes == feed.lanes && model.maxBar == -1)
    #expect(
      model.status.hasPrefix("model · rendering "), "the kernels are not there yet: \(model.status)"
    )
    model.waitForKernels(timeout: coldKernelTimeout)
    model.consume(feed)
    try #require(model.tablesReady, "the kernels did not arrive in time: \(model.status)")
    #expect(model.status.hasSuffix(" ms)"))
    play(rig, model, feed, seconds: 3)
    #expect(model.maxBar >= 2 && model.modelBars[0..<(6 * (model.maxBar + 1))].contains { $0 > 0 })
  }

  @Test func oneModelPerFeed() throws {
    let rig = try ScopeRig(net: ["A", "B"], tempo: 300, play: false)
    defer { rig.stop() }
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    let m1 = ModelEngine.model(for: a, engine: rig.dj)
    #expect(ModelEngine.model(for: a, engine: rig.dj) === m1, "the Spectro and the Bands share it")
    #expect(ModelEngine.model(for: b, engine: rig.dj) !== m1)
    #expect(m1.engine === rig.dj)
  }
}

@MainActor
struct ModelEngineMasterTests {
  @Test func theMasterModelHasBothDecksLanesAndEachDecksOwnFx() throws {
    let rig = try ScopeRig(net: ["A", "B"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300), ("techno", 43, "loop", 300)])
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    rig.dj.crossfader = 0  // all deck A
    play(rig, model, feed, seconds: 3)
    #expect(model.lanes.count == 20 && model.fxDecks == ["A", "B"])
    #expect(Set(model.lanes.map(\.deck)) == ["A", "B"])
    let laneA = try #require(model.lanes.firstIndex { $0.deck == "A" })
    let laneB = try #require(model.lanes.firstIndex { $0.deck == "B" })
    // A: (source 0.8 · trim 1 · volume 0.8 · crossfader 1 · master)²; B: crossfader 0 -> silent
    model.refreshFx()
    let master = rig.dj.master
    let want = pow2(0.8 * 0.8 * master)
    #expect(model.fxRow(forLane: laneA).allSatisfy { abs(Double($0) - want) < 1e-6 }, "\(want)")
    #expect(model.fxRow(forLane: laneB).allSatisfy { $0 == 0 })
    // moving the crossfader to B swaps them (within the 200 ms refresh)
    rig.dj.crossfader = 1
    model.refreshFx()
    #expect(model.fxRow(forLane: laneA).allSatisfy { abs(Double($0)) < 1e-9 })
    #expect(model.fxRow(forLane: laneB).allSatisfy { abs(Double($0) - want) < 1e-6 })
    // the DJ filter on A is a low-pass: its top rows fall, the bottom ones stay
    rig.dj["A"]!.filter = 0.1
    model.refreshFx()
    rig.dj.crossfader = 0
    model.refreshFx()
    let lp = Array(model.fxRow(forLane: laneA))
    #expect(
      Double(lp[4]) < 0.01 * Double(lp[1]), "6-16 kHz against 80-250 Hz: \(lp[4]) vs \(lp[1])")
    #expect(abs(Double(lp[1]) - want) < 0.02 * want, "the low end is untouched")
    #expect(lp[32] < lp[5], "and the bins fall with frequency")
    // B has no filter and the same gain it had
    #expect(model.fxRow(forLane: laneB).allSatisfy { $0 == 0 }, "crossfader at A")
    #expect(
      model.status.hasPrefix("model · ") && model.status.hasSuffix(" kernels"), "\(model.status)")
  }

  @Test func aDeckFeedFollowsWhatIsHeardOfItsDeckUnlessAskedToMatchTheTap() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    let deck = try #require(rig.dj["A"])
    deck.volume = 0.3
    deck.filter = 0.1
    deck.eqLow = 0
    play(rig, model, feed, seconds: 1)
    // the default is the deck's output, what the performer hears of it (scope-model.js
    // `fxResponse`: strip volume², its filters and the master's)
    #expect(model.fxPoint == .deckOutput)
    model.refreshFx()
    let heard = Array(model.fxRow(forLane: 0))
    let gain = 0.8 * deck.trim * deck.volume * rig.dj.crossfadeGain("A") * rig.dj.master
    let expected = ModelFx.response(DeckFx(deck: deck, gain: gain), sampleRate: rig.dj.sampleRate)
    #expect(sameSamples(heard, expected) == .identical)
    #expect(
      heard[4] < 0.01 * heard[1] && heard[0] < 0.5 * heard[1], "low-pass and -24 dB bass shelf")
    #expect(Double(heard[1]) < gain * gain, "and every row is under the plain gain")
    // asked to match the tap, which is before the EQ and the fader: only the wave engine's soft
    // master (0.8²)
    model.fxPoint = .matchTap
    model.refreshFx()
    #expect(model.fxRow(forLane: 0).allSatisfy { abs(Double($0) - 0.64) < 1e-6 })
  }

  @Test func aSecondDeckIsPlacedOnTheLeadsStepAxisByTime() throws {
    // A at 150 BPM, B at 300: B's own steps run twice as fast as the lead's. The bars of the
    // model are the lead's, so B's fires must land in the lead's bars by their time.
    let rig = try ScopeRig(net: ["A", "B"], genre: "techno", seed: 42, tempo: 150)
    defer { rig.stop() }
    rig.dj["B"]!.wave.setTempo(300)
    let feed = rig.hub.feed(.master)
    let feedA = rig.hub.feed(.deck("A"))
    feed.acquire()
    feedA.acquire()
    let cache = warmedCache([("techno", 42, "loop", 150), ("techno", 43, "loop", 300)])
    let model = ModelEngine(engine: rig.dj, cache: cache)
    let alone = ModelEngine(engine: rig.dj, cache: cache)
    alone.fxPoint = .matchTap  // "deck-tap gain" below
    rig.render(seconds: 0.1)  // the lanes appear with the first anchor
    rig.hub.pump()
    model.consume(feed)
    alone.consume(feedA)
    model.waitForKernels()
    alone.waitForKernels()
    for _ in 0..<16 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      model.consume(feed)
      alone.consume(feedA)
    }
    #expect(feed.leadDeck == "A")
    let aStep = rig.dj["A"]!.wave.tick
    let bStep = rig.dj["B"]!.wave.tick
    #expect(bStep > aStep * 3 / 2, "B really runs faster: \(bStep) vs \(aStep)")
    #expect(
      abs(model.maxBar - aStep / 16) <= 1,
      "bar \(model.maxBar), the lead is at step \(aStep) = bar \(aStep / 16)")
    #expect(model.maxBar < bStep / 16 - 2)
    // both decks contribute: deck B's fires come on top of A's, twice as many per A bar
    #expect(alone.maxBar == model.maxBar || abs(alone.maxBar - model.maxBar) <= 1)
    // (the master carries the crossfader and the fader: compare through the two FX gains)
    model.refreshFx()
    alone.refreshFx()
    let laneA = try #require(model.lanes.firstIndex { $0.deck == "A" })
    let gain = Double(model.fxRow(forLane: laneA)[1]) / Double(alone.fxRow(forLane: 0)[1])
    #expect(gain > 0.1 && gain < 0.6, "master gain over deck-tap gain: \(gain)")
    #expect(
      model.modelBars[2 * 6 + 5] > 1.8 * gain * alone.modelBars[2 * 6 + 5],
      "bar 2: master \(model.modelBars[2 * 6 + 5]), deck A alone \(alone.modelBars[2 * 6 + 5]) x \(gain)"
    )
  }

  @Test func aNewLeadDeckStartsTheMasterHistoryOver() throws {
    let rig = try ScopeRig(net: ["A", "B"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300), ("techno", 43, "loop", 300)])
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    play(rig, model, feed, seconds: 3)
    #expect(feed.leadDeck == "A" && model.modelFrom == 0 && model.maxBar >= 2)
    rig.dj.crossfader = 1  // B takes over
    rig.render(seconds: 0.5)
    rig.hub.pump()
    #expect(feed.leadDeck == "B")
    model.consume(feed)
    #expect(
      model.modelFrom > 20,
      "the bars are B's now; the history began again at step \(model.modelFrom)")
  }
}

private func pow2(_ x: Double) -> Double { x * x }
