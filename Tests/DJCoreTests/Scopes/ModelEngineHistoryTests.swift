import Testing

@testable import DJCore

// What the model keeps of a run, and who feeds it: a model opened on a song that is already
// playing (cold kernels), a model that falls further behind than the feed's log, the hub keeping
// a model consuming whatever mode is on screen.

@MainActor
struct ModelEngineHistoryTests {
  @Test func aColdKernelCacheDoesNotCostTheHistoryTheFeedStillHolds() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    // 8 s of a song nobody consumes: a model mode is opened on a song that is already playing
    for _ in 0..<16 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    let held = feed.fireCount
    #expect(held > 200 && held < ScopeFireLog.capacity)

    let cold = ModelEngine(engine: rig.dj, cache: ModelKernelCache())
    cold.consume(feed)
    #expect(cold.status.hasPrefix("model · rendering "), "\(cold.status)")
    if !cold.tablesReady {
      #expect(cold.fires == 0, "while the kernels render the fires stay in the feed's log")
    }
    // Nothing but consume() picks the finished render up (no waitForKernels, no pollKernels): it
    // is what the app does, once per frame.
    let ready = pollUntil(60) {
      cold.consume(feed)
      return cold.tablesReady && cold.fires > 0
    }
    #expect(ready, "the kernels arrive through consume: \(cold.status)")
    #expect(cold.status.hasPrefix("model · ") && cold.status.hasSuffix(" ms)"), "\(cold.status)")
    #expect(cold.fires == held && cold.missedFires == 0, "every held fire, none dropped")
    #expect(cold.modelFrom == 0 && cold.maxBar >= 6)

    // and it is exactly what a model with warm kernels takes from the same log
    let warm = ModelEngine(engine: rig.dj, cache: warmedCache([("techno", 42, "loop", 300)]))
    warm.consume(feed)
    #expect(warm.fires == held)
    #expect(warm.modelBars == cold.modelBars && warm.maxBar == cold.maxBar)
  }

  @Test func fallingMoreThanTheLogBehindStartsOverFromWhatTheLogHolds() throws {
    // 2400 BPM: a step is 6 ms and a bar 0.1 s, so the 4096 fires of the log are a few seconds
    let rig = try ScopeRig(net: ["A"], genre: "house", seed: 42, tempo: 2400)
    defer { rig.stop() }
    let cache = warmedCache([("house", 42, "loop", 2400)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    play(rig, model, feed, seconds: 2)
    let seen = feed.fireCount
    #expect(model.fires == seen && model.fires > 200 && model.missedFires == 0)
    let oldBars = model.maxBar
    #expect(oldBars >= 5)

    // pump without consuming until more than a log has gone by
    var pumps = 0
    while feed.fireCount - seen < ScopeFireLog.capacity + 800 && pumps < 200 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      pumps += 1
    }
    let log = feed.fireLog
    let lost = log.firstNumber - seen
    #expect(lost >= 800 && log.count == ScopeFireLog.capacity, "lost \(lost) of the unread")

    model.consume(feed)
    #expect(model.missedFires == lost, "the fires that left the log are counted")
    #expect(model.fires - seen == ScopeFireLog.capacity, "and every fire it could still read is in")
    // the old history was emptied: the bars start where the log does, with no hole inside
    let first = model.modelFrom >> 4
    #expect(first > oldBars, "starts at bar \(first), the old history ended at bar \(oldBars)")
    #expect(model.modelBars[0..<(ModelGrid.rows * first)].allSatisfy { $0 == 0 })
    for bar in (first + 1)..<model.maxBar {
      #expect(model.modelBars[bar * ModelGrid.rows + 5] > 0, "bar \(bar) has a hole")
    }
    // it is what a model that only ever saw the held log builds
    let fresh = ModelEngine(engine: rig.dj, cache: cache)
    fresh.consume(feed)
    #expect(fresh.modelBars == model.modelBars && fresh.modelFrom == model.modelFrom)
    #expect(fresh.missedFires == log.firstNumber - feed.generationFireStart)

    // and it carries on from there
    let top = model.maxBar
    play(rig, model, feed, seconds: 0.5)
    #expect(model.missedFires == lost && model.maxBar > top)
  }

  @Test func theHubKeepsAModelThatExistsConsumingWhateverModeIsOnScreen() throws {
    let rig = try ScopeRig(net: ["A", "B"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 300), ("techno", 43, "loop", 300)])
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    a.acquire()
    b.acquire()
    let model = ModelEngine.model(for: a, engine: rig.dj, cache: cache)
    #expect(ModelEngine.existing(for: a) === model && ModelEngine.existing(for: b) == nil)
    // eight seconds of pumping only: a mode that does not draw the model is on screen
    for _ in 0..<16 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    #expect(model.fires == a.fireCount && model.fires > 200 && model.maxBar >= 6)
    #expect(model.missedFires == 0 && model.modelFrom == 0)
    #expect(ModelEngine.existing(for: b) == nil, "the hub never makes a model")
    // a feed nobody subscribes to is not pumped, so its model is left alone
    a.release()
    let before = model.fires
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(model.fires == before)
  }

  @Test func startMakesTheModelAndBeginsTheKernelsBeforeAnyModeIsDrawn() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 1)
    rig.hub.pump()
    let cache = ModelKernelCache()
    let model = ModelEngine.start(for: feed, engine: rig.dj, cache: cache)
    #expect(ModelEngine.existing(for: feed) === model)
    #expect(ModelEngine.start(for: feed, engine: rig.dj, cache: cache) === model, "one per feed")
    #expect(model.status.hasPrefix("model · rendering "), "the kernels are on their way")
    #expect(model.lanes == feed.lanes)
    model.waitForKernels(timeout: coldKernelTimeout)
    rig.hub.pump()  // the hub takes it from here
    #expect(model.tablesReady && model.fires == feed.fireCount && model.fires > 0)
  }
}
