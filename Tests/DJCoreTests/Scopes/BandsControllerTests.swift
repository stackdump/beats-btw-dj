import Darwin
import Testing

@testable import DJCore

// The Bands controller: what it reads from a real ModelEngine and MeasuredReader (the bar mapping
// of both sides against each other), the 250 ms redraw limit, the rebuilds that cannot wait, and a
// real offline engine feeding it (kernels from a warmed cache).

/// A clock the test moves.
@MainActor
final class BandsClock {
  var t = 100.0
  func read() -> Double { t }
}

@MainActor
struct BandsSourceTests {
  private func anchor(time: Double = 9.5, step: Int = 32) -> ScopeAnchor {
    ScopeAnchor(time: time, frame: 0, step: step, tempo: 120, generation: 1)
  }

  /// A model with one lane whose kernel is 1 in every row: a deposit at velocity 100 adds exactly
  /// 1 to each band of its bar, 5 to E.
  private func unitModel() -> ModelEngine {
    let lane = ScopeLane(
      key: "k", ids: ["k"], channel: 1, group: "main", drum: false, instrument: "bass",
      notes: [60], durationsMs: [200], lo: 60, hi: 60, color: ScopeColors.defaultLaneColor,
      deck: "A")
    let table = ModelKernelTable(
      notes: [60], logR: [Float](repeating: 0, count: ModelGrid.nr), drum: false, durMs: 200,
      tau: 0.1)
    let model = ModelEngine(engine: nil, cache: ModelKernelCache())
    model.setLanes([lane], tables: [table])
    return model
  }

  @Test func bothSidesPutAStepInTheSameBarAndBandsModelReadsThemAsTheyAre() {
    let model = unitModel()
    // fires at steps 33, 40 (vel 100) and 47 (vel 50): bar 2 = 1 + 1 + 0.25; step 48: bar 3
    for (step, vel) in [(33, 100), (40, 100), (47, 50), (48, 100)] {
      model.deposit(lane: 0, note: 60, velocity: vel, durMs: 200, step: step, tickSec: 0.125)
    }
    let reader = MeasuredReader()
    let w = sineWindow(hz: 1000, rate: 44100)
    // the anchor: step 32 at 9.5 s, 0.125 s a step. Step 47.875 is at 11.484375 s (the last
    // eighth of bar 2) and step 48 at 11.5 s (the first of bar 3)
    reader.ingest(
      window: w, sampleRate: 44100, time: 11.484375, anchor: anchor(), tickSec: 0.125)
    reader.ingest(window: w, sampleRate: 44100, time: 11.5, anchor: anchor(), tickSec: 0.125)

    let on = BandsModel(model: model, reader: reader)
    #expect(model.maxBar == 3 && reader.maxBar == 3 && on.maxBar == 3)
    // the model: bar 2 holds 2.25 in every band (E 11.25), bar 3 holds 1 (E 5)
    #expect(abs(on.modelDb(bar: 2, row: 0)! - 10 * log10(2.25)) < 1e-9)
    #expect(abs(on.modelDb(bar: 2, row: 5)! - 10 * log10(11.25)) < 1e-9)
    #expect(abs(on.modelDb(bar: 3, row: 4)! - 0) < 1e-9)
    #expect(on.modelDb(bar: 1, row: 0) == nil, "nothing before step 33")
    // the reader: one read in each of bars 2 and 3
    #expect(reader.measCnt[2] == 1 && reader.measCnt[3] == 1)
    // and BandsModel returns what the objects themselves return, cell for cell
    for bar in 0..<5 {
      for row in 0..<6 {
        #expect(on.modelDb(bar: bar, row: row) == model.modelDb(bar: bar, row: row))
        #expect(on.measDb(bar: bar, row: row) == reader.measDb(bar: bar, row: row))
      }
    }
    #expect(on.modelFrom == 33 && model.modelFrom == 33)
    #expect(on.measFrom == 47.875 && on.measAt == 48)
  }

  @Test func withMeasuredOffTheReaderIsLeftOutWhateverItHolds() {
    let model = unitModel()
    model.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 2, tickSec: 0.125)
    let reader = MeasuredReader()
    reader.ingest(
      window: sineWindow(hz: 1000, rate: 44100), sampleRate: 44100, time: 12, anchor: anchor(),
      tickSec: 0.125)  // step 52: bar 3
    let off = BandsModel(model: model, reader: nil)
    #expect(off.maxBar == 0, "the reader's bar 3 would make the picture wider than the model")
    #expect(off.measDb(bar: 3, row: 0) == nil && off.measFrom == .infinity && off.measAt == -1)
    #expect(BandsModel(model: model, reader: reader).maxBar == 3)
  }
}

@MainActor
struct BandsControllerTests {
  private func rig(_ net: [String] = ["A"], samples: [String] = []) throws -> ScopeRig {
    try ScopeRig(
      net: net, samples: samples, genre: "techno", seed: 42, structure: "loop", tempo: 300)
  }

  private func controller(_ clock: BandsClock, cache: ModelKernelCache) -> BandsController {
    BandsController(cache: cache, readers: MeasuredReaderStore(), now: { clock.read() })
  }

  /// Run the rig in tenths of a second as a UI at 10 Hz would, updating the controller each time.
  private func run(
    _ rig: ScopeRig, _ c: BandsController, _ feed: ScopeFeed, seconds: Double, measured: Bool
  ) {
    for _ in 0..<Int((seconds * 10).rounded()) {
      rig.render(seconds: 0.1)
      rig.hub.pump()
      c.update(feed: feed, engine: rig.dj, measured: measured)
    }
  }

  @Test func theSceneIsHeldForTwoHundredFiftyMillisecondsAndThenRebuilt() throws {
    let rig = try rig()
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    run(rig, c, feed, seconds: 3, measured: false)

    let first = c.scene(feed: feed, width: 800, measured: false)
    #expect(c.builds == 1 && first.revision == 1)
    #expect(first.layout != nil, "three seconds of a 0.8 s bar is a few bars")
    // the same instant, 100 ms and 249 ms later: the held scene, whatever the engine did
    run(rig, c, feed, seconds: 1, measured: false)
    #expect(c.scene(feed: feed, width: 800, measured: false).revision == 1)
    clock.t += 0.1
    #expect(c.scene(feed: feed, width: 800, measured: false).revision == 1)
    clock.t += 0.149
    #expect(c.scene(feed: feed, width: 800, measured: false).revision == 1 && c.builds == 1)
    // 250 ms after the build: rebuilt, from the bars as they are now
    clock.t += 0.001
    let second = c.scene(feed: feed, width: 800, measured: false)
    #expect(second.revision == 2 && c.builds == 2)
    #expect((second.layout?.barCount ?? 0) >= (first.layout?.barCount ?? 0))
    #expect(BandsController.redrawInterval == 0.25)
    // a clock that went backwards does not hold a scene forever
    clock.t -= 10
    #expect(c.scene(feed: feed, width: 800, measured: false).revision == 3)
  }

  @Test func aNewWidthAMeasuredToggleOrANewGenerationRebuildsAtOnce() throws {
    let rig = try rig()
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    run(rig, c, feed, seconds: 2, measured: true)
    _ = c.scene(feed: feed, width: 800, measured: false)
    #expect(c.builds == 1)
    _ = c.scene(feed: feed, width: 800, measured: false)
    #expect(c.builds == 1)
    // the window was resized
    _ = c.scene(feed: feed, width: 801, measured: false)
    #expect(c.builds == 2)
    // "measured" ticked: the third block must not wait for the next quarter second
    let withMeasured = c.scene(feed: feed, width: 801, measured: true)
    #expect(c.builds == 3 && withMeasured.blocks.count == (withMeasured.layout == nil ? 0 : 3))
    // the feed started over (re-acquire bumps the generation): a picture of the old song goes
    let g = feed.generation
    feed.release()
    feed.acquire()
    #expect(feed.generation != g)
    _ = c.scene(feed: feed, width: 801, measured: true)
    #expect(c.builds == 4)
  }

  @Test func theReaderIsOnlyReadWhileMeasuredIsOnAndTheSourceHasANet() throws {
    let rig = try rig(["A"], samples: ["B"])
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let clock = BandsClock()
    let net = rig.hub.feed(.deck("A"))
    net.acquire()
    let c = controller(clock, cache: cache)
    run(rig, c, net, seconds: 1, measured: false)
    #expect(c.model != nil && c.reader == nil, "no reader until measured is on")
    run(rig, c, net, seconds: 1.5, measured: true)
    let reader = try #require(c.reader)
    #expect(reader.reads > 5 && reader.maxBar >= 0)
    // measured off again: no more reads
    let reads = reader.reads
    run(rig, c, net, seconds: 1, measured: false)
    #expect(reader.reads == reads)
    // a sample deck has no net, no anchors, nothing for bars to be about: no reads either
    let sample = rig.hub.feed(.deck("B"))
    sample.acquire()
    let s = controller(clock, cache: cache)
    run(rig, s, sample, seconds: 1, measured: true)
    #expect(s.reader == nil)
  }

  @Test func aSourceWithNoNetSaysSoAndABrandNewModelSaysItsStatus() throws {
    let rig = try rig(["A"], samples: ["B"])
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let clock = BandsClock()
    let sample = rig.hub.feed(.deck("B"))
    sample.acquire()
    let c = controller(clock, cache: cache)
    run(rig, c, sample, seconds: 1, measured: true)
    let scene = c.scene(feed: sample, width: 800, measured: true)
    #expect(scene.message == LiveScopeText("needs a net deck", x: 8, y: 8))
    #expect(c.statusText(feed: sample) == "needs a net deck")
    // a net deck whose song has not made a bar yet says it fills in as it plays (the model has
    // its tables from the warmed cache); before any update there is no model at all
    let net = rig.hub.feed(.deck("A"))
    net.acquire()
    let n = controller(clock, cache: cache)
    #expect(n.scene(feed: net, width: 800, measured: false).message?.text == BandsScene.waitingText)
    n.update(feed: net, engine: rig.dj, measured: false)
    #expect(n.statusText(feed: net).hasSuffix(" · pre-fader tap"), "\(n.statusText(feed: net))")
  }

  @Test func aNetDeckThatBecomesASampleDeckDropsTheOldSongsMeasuredBars() throws {
    let rig = try rig()
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    run(rig, c, feed, seconds: 4, measured: true)
    let before = c.scene(feed: feed, width: 800, measured: true)
    #expect(before.blocks.map(\.kind) == [.model, .measured, .residual])
    let reader = try #require(c.reader)
    #expect(reader.maxBar >= 3, "the old song has measured bars: \(reader.maxBar)")
    // the user loads a sample into the deck whose Bands panel is open, "measured" still ticked
    let generation = feed.generation
    rig.dj["A"]!.loadDemo()
    run(rig, c, feed, seconds: 1, measured: true)
    #expect(!feed.hasNet && feed.generation != generation)
    clock.t += 1
    let after = c.scene(feed: feed, width: 800, measured: true)
    #expect(after.message == LiveScopeText("needs a net deck", x: 8, y: 8), "\(after.blocks.count)")
    #expect(after.blocks.isEmpty && after.layout == nil, "no picture of the old song")
    #expect(c.statusText(feed: feed) == "needs a net deck")
    // the net comes back (a new song, a new generation): the reader forgot the old bars first
    rig.dj["A"]!.loadNet(scopeProject("techno", seed: 42))
    rig.dj["A"]!.wave.setTempo(300)
    rig.dj["A"]!.setPlaying(true)
    run(rig, c, feed, seconds: 1.5, measured: true)
    #expect(reader.maxBar <= 2, "a new song starts the measured side over: \(reader.maxBar)")
  }

  @Test func aMasterWhoseLeadChangesStartsBothHalvesOverTogether() throws {
    let rig = try ScopeRig(net: ["A", "B"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300), ("techno", 43, "loop", 300)])
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    rig.dj.crossfader = 0  // all deck A
    run(rig, c, feed, seconds: 4, measured: true)
    #expect(feed.leadDeck == "A")
    let before = c.scene(feed: feed, width: 800, measured: true)
    let n = try #require(before.layout).barCount
    #expect(n >= 4 && before.blocks.count == 3, "bars \(n)")
    #expect(try #require(c.model).modelFrom < 20, "A's history began with the song")
    // B takes the lead: its song is another axis, the bars of A mean nothing to it
    rig.dj.crossfader = 1
    run(rig, c, feed, seconds: 1, measured: true)
    #expect(feed.leadDeck == "B")
    clock.t += 1
    let after = c.scene(feed: feed, width: 800, measured: true)
    let reader = try #require(c.reader)
    let model = try #require(c.model)
    // both histories began again where B took over (the rig starts both decks together, so the
    // bar numbers go on from the same place), and neither holds a level before that
    let from = model.modelFrom / 16
    #expect(model.modelFrom > 20 && Int(reader.measFrom) >= model.modelFrom - 1, "from \(from)")
    for b in 0..<from {
      #expect(model.modelDb(bar: b, row: 5) == nil, "model bar \(b) is A's")
      #expect(reader.measDb(bar: b, row: 5) == nil, "measured bar \(b) is A's")
    }
    #expect(model.maxBar >= from && reader.maxBar >= from)
    // so the picture has no digits and no residual for A's bars, and the stats are B's alone
    let l = try #require(after.layout)
    #expect(l.barCount == max(model.maxBar, reader.maxBar) + 1)
    for block in after.blocks {
      for row in 0..<6 {
        for b in l.bars where b < from {
          #expect(block.cells[row * l.shown + (b - l.first)].index == nil, "\(block.kind) bar \(b)")
        }
      }
    }
    #expect((c.stats?.bars ?? 0) <= model.maxBar - from)
  }

  @Test func measuredOffLeavesTheReaderOutOfThePictureWhateverItHolds() throws {
    let rig = try rig()
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    run(rig, c, feed, seconds: 2, measured: true)
    let reader = try #require(c.reader)
    let model = try #require(c.model)
    // the reader has a read far beyond the model's last bar (step 480 = bar 30)
    let far = ScopeAnchor(
      time: 100, frame: 0, step: 480, tempo: 300, generation: 1)
    reader.ingest(
      window: sineWindow(hz: 1000, rate: ScopeRig.rate), sampleRate: ScopeRig.rate, time: 100,
      anchor: far, tickSec: 0.05)
    #expect(reader.maxBar == 30 && model.maxBar < 10)
    let on = c.scene(feed: feed, width: 800, measured: true)
    #expect(on.layout?.barCount == 31, "measured on: the picture is as wide as the reader")
    // "measured" unticked: a model-only picture, not widened to the reader's bars
    let off = c.scene(feed: feed, width: 800, measured: false)
    #expect(off.layout?.barCount == model.maxBar + 1 && off.blocks.map(\.kind) == [.model])
  }

  @Test func aStretchWithoutReadsStartsTheMeasuredCoverageOver() throws {
    // DEVIATION from scope.js, inherited from MeasuredReader (see its GAPS): only the mode that
    // is drawing reads. After a stretch of more than a second with no update (another view was
    // on screen) the coverage window restarts, so the bars before the hole stop being "full":
    // their measured digits stay, but their residual cells go empty and the statistics start
    // over. scope.js keeps them (it reads in every view and restarts only on re-ticking).
    let rig = try rig()
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    run(rig, c, feed, seconds: 3, measured: true)
    let model = try #require(c.model)
    let reader = try #require(c.reader)
    let early = BandsModel(model: model, reader: reader)
    #expect(early.fullBar(1) && early.fullBar(2), "bars 1 and 2 are covered by both")
    let beforeBars = early.stats().bars
    #expect(beforeBars >= 2)
    // two seconds go by with no frames drawn, then the view comes back
    rig.render(seconds: 1.5)
    rig.hub.pump()
    run(rig, c, feed, seconds: 3, measured: true)
    let after = BandsModel(model: model, reader: reader)
    #expect(!after.fullBar(1) && !after.fullBar(2), "the window restarted after the hole")
    #expect(after.measDb(bar: 1, row: 5) != nil, "the measured digits of the old bars stay")
    let late = (6..<after.maxBar).filter { after.fullBar($0) }
    #expect(!late.isEmpty, "bars after the hole are covered again: \(after.maxBar)")
    clock.t += 1
    let scene = c.scene(feed: feed, width: 800, measured: true)
    let res = scene.blocks[2]
    let first = try #require(scene.layout).first
    let perRow = try #require(scene.layout).shown
    for b in 1...2 where b >= first {
      #expect(res.cells[(b - first)].index == nil, "residual of bar \(b) is empty")
    }
    #expect(res.cells[0..<perRow].contains { $0.index != nil })
  }

  @Test func aRealDeckFillsTheBarsInBothHalvesAndTheStatsAreThere() throws {
    let rig = try rig()
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let clock = BandsClock()
    let c = controller(clock, cache: cache)
    run(rig, c, feed, seconds: 9, measured: true)
    let scene = c.scene(feed: feed, width: 800, measured: true)
    let l = try #require(scene.layout)
    // 90 updates of five 512-frame cycles at 22.05 kHz are 10.4 s of audio: 13 bars of 0.8 s
    #expect(l.barCount >= 11 && l.barCount <= 15, "bars \(l.barCount)")
    #expect(scene.blocks.map(\.kind) == [.model, .measured, .residual])
    // the model fills every bar it saw, the measured side every bar it read
    let model = scene.blocks[0]
    #expect(model.cells.filter { $0.index != nil }.count > 6 * (l.barCount - 2))
    let meas = scene.blocks[1]
    #expect(meas.cells.filter { $0.index != nil }.count > 6 * (l.barCount - 3))
    // the residual exists for the bars both covered; the kick keeps `sub`, `low` and E correlated
    let stats = try #require(c.stats)
    #expect(stats.bars >= 5, "bars with a fit: \(stats.bars)")
    for b in stats.bands { #expect(b.rmsResidualDb != nil && b.offsetDb != nil, "\(b.band)") }
    #expect(scene.tilt != nil && scene.tilt!.text.hasPrefix("tilt sub "))
    #expect(scene.blocks[2].cells.filter { $0.index != nil }.count > 6 * 3)
    // the model engine is the one per feed: what the Spectro of this source would use
    #expect(c.model === ModelEngine.existing(for: feed))
  }
}
