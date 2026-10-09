import Testing

@testable import DJCore

// SpectroController over a real offline engine: the model fills the image where the kick is, a
// sample deck has no model, and the sounding step is the last column that is final.

/// Per image row (0 = top): the largest and the mean level.
private func rowStats(_ img: SpectroBitmap) -> (max: [Int], mean: [Int]) {
  var mx: [Int] = []
  var mean: [Int] = []
  for y in 0..<img.height {
    let row = (0..<img.width).map { Int(img.level($0, y)) }
    mx.append(row.max()!)
    mean.append(row.reduce(0, +) / row.count)
  }
  return (mx, mean)
}

@MainActor
struct SpectroControllerTests {
  private func spectro(_ cache: ModelKernelCache) -> SpectroController {
    SpectroController(cache: cache)
  }

  /// Render in half-second pumps as a UI would, updating the controller after each.
  private func run(
    _ rig: ScopeRig, _ feed: ScopeFeed, _ s: SpectroController, seconds: Double
  ) {
    var t = 0.0
    while t < seconds {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      s.update(feed: feed, engine: rig.dj)
      t += 0.5
    }
  }

  @Test func aTechnoDeckLightsTheLowRowsOnTheKickAndTheTopRowsLess() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, structure: "loop", tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let s = spectro(cache)
    run(rig, feed, s, seconds: 7)
    let scene = s.scene(feed: feed, width: 800, height: 330)
    let m = try #require(scene.model)
    let img = try #require(m.bitmap)
    // 7 s at 300 BPM is step ~140; the 64-step window is final from its left edge up to the
    // sounding step: the image is valid except the last few columns
    func column(_ x: Int) -> [Int] { (0..<28).map { Int(img.level(x, $0)) } }
    let valid = (0..<66).filter { column($0).contains { $0 != 0 } }
    #expect(valid.count >= 60, "valid columns: \(valid.count)")
    #expect(img.peakDb.isFinite && img.peakDb > -100)
    // The kick and the bass (bins 2 ... 11, image rows 16 ... 25, 40 ... 450 Hz) are the
    // loudest: the 255 cell is in them, and they are lit more than the top of the spectrum
    // (hats and noise: bins 18 ... 27, image rows 0 ... 9) in every column on average.
    let st = rowStats(img)
    #expect(st.max[16...27].max()! == 255, "the loudest cell is in the low rows: \(st.max)")
    #expect(st.max[0..<12].max()! <= 255 - 40, "and the top does not reach it: \(st.max[0..<12])")
    let lowMean = st.mean[17..<26].reduce(0, +) / 9
    let highMean = st.mean[0..<10].reduce(0, +) / 10
    #expect(lowMean > highMean + 40, "mean level low \(lowMean) vs high \(highMean)")
    // the kick lands every 4 steps: the lowest rows pulse, bright on kick columns, dark between
    let kick = (0..<66).map { Int(img.level($0, 25)) }
    #expect(kick.max()! >= 240 && kick.contains { $0 < 200 }, "a kick row pulses: \(kick)")
    // and the title is plain 'model': the kernels are in the cache
    #expect(m.title.text == "model" && m.note?.text == "pre-fader tap")
    #expect(s.statusText(feed: feed) == "model · \(s.model!.kernelCount) kernels · pre-fader tap")
  }

  @Test func theColumnsAreFinalUpToTheSoundingStep() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, structure: "loop", tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let s = spectro(cache)
    run(rig, feed, s, seconds: 4)
    let model = try #require(s.model)
    let a = try #require(feed.anchorAt(feed.nowTime))
    let sounding =
      Int(
        (Double(a.step) + (feed.nowTime - a.time) / feed.tickSec).rounded(.down)) - 1
    // a fire at the step that is sounding now finalises everything before it, so the columns
    // are final up to `sounding` (no fire there yet) or one more (one has been deposited)
    #expect(
      model.specCur == sounding || model.specCur == sounding + 1,
      "specCur \(model.specCur) vs sounding-1 \(sounding)")
    // the scene's image shows exactly the final steps: its last valid column is specCur - 1
    let img = try #require(
      s.scene(feed: feed, width: 800, height: 330).model?.bitmap)
    let axis = feed.timeAxis(x0: 30, w: 770)
    let first = Int(axis.stepOf(axis.t0).rounded(.down))
    let lastLit = (0..<66).last { x in (0..<28).contains { img.level(x, $0) != 0 } }
    #expect(lastLit != nil && first + lastLit! <= model.specCur - 1)
    #expect(first + (lastLit ?? 0) >= model.specCur - 6, "within the last few steps")
  }

  @Test func theMasterIsAModelToo() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, structure: "loop", tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let s = spectro(cache)
    run(rig, feed, s, seconds: 5)
    let m = try #require(s.scene(feed: feed, width: 800, height: 330).model)
    #expect(m.bitmap?.levels.contains { $0 != 0 } == true)
    #expect(m.note?.text == "master")
  }

  @Test func aSampleDeckHasNoModel() throws {
    let rig = try ScopeRig(net: [], samples: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let s = spectro(ModelKernelCache())
    run(rig, feed, s, seconds: 3)
    let m = try #require(s.scene(feed: feed, width: 800, height: 330).model)
    #expect(m.message?.text == "needs a net deck" && m.bitmap == nil && m.note == nil)
    #expect(m.grid.lines.isEmpty, "a sample deck has no steps")
    #expect(s.statusText(feed: feed) == "needs a net deck")
    // on a master with nothing but a sample deck it says no net deck
    let master = rig.hub.feed(.master)
    master.acquire()
    run(rig, master, s, seconds: 1)
    #expect(s.scene(feed: master, width: 800, height: 330).model?.message?.text == "no net deck")
    #expect(s.statusText(feed: master) == "no net deck")
  }

  @Test func theModelOutlivesTheControllerAndStaysTheSameForTheFeed() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, structure: "loop", tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let first = spectro(cache)
    run(rig, feed, first, seconds: 2)
    let model = try #require(first.model)
    #expect(ModelEngine.existing(for: feed) === model, "registered for the feed")
    let fires = model.fires
    // the host rebuilds the view (a new controller) on a switch of scope kind: same model, and
    // the history it kept while this one was away is not lost
    let second = spectro(cache)
    run(rig, feed, second, seconds: 1)
    #expect(second.model === model && model.fires > fires)
    #expect(model.modelFrom == 0, "from the top: nothing was dropped")
  }

  @Test func aFeedSwitchStartsOverFromTheNewFeedsModel() throws {
    let rig = try ScopeRig(
      net: ["A", "B"], genre: "techno", seed: 42, structure: "loop", tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300), ("techno", 43, "loop", 300)])
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    a.acquire()
    b.acquire()
    let s = spectro(cache)
    run(rig, a, s, seconds: 1)
    let ma = s.model
    rig.render(seconds: 0.5)
    rig.hub.pump()
    s.update(feed: b, engine: rig.dj)
    #expect(s.model !== ma && s.model === ModelEngine.existing(for: b))
  }
}
