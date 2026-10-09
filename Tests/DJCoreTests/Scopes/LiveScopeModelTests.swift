import Testing

@testable import DJCore

// LiveScopeModel over a REAL offline engine: the blocks are the feed's own samples, the lanes and
// events the feed's own, the spring runs on the clock the test injects.
@MainActor
struct LiveScopeModelTests {
  /// Render `seconds` in steps of 0.25 s, pumping and updating the model after each, as frames do.
  private func run(
    _ rig: ScopeRig, _ model: LiveScopeModel, _ feed: ScopeFeed, seconds: Double,
    wall: inout Double, dtWall: Double = 0
  ) {
    var left = seconds
    while left > 1e-9 {
      let step = min(0.25, left)
      rig.render(seconds: step)
      rig.hub.pump()
      wall += dtWall
      model.update(feed: feed, wall: wall)
      left -= step
    }
  }

  private func reduced(_ w: [Float]) -> (min: Float, max: Float, meanSq: Float) {
    w.withUnsafeBufferPointer { LiveScopeBlocks.reduce($0) }
  }

  @Test func theBlocksAreTheFeedsHistoryCutIntoBlocksOf256() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    model.update(feed: feed, wall: wall)  // before any audio: the cursor is at the history's edge
    run(rig, model, feed, seconds: 2, wall: &wall)
    let sr = ScopeRig.rate
    let frames = feed.history.endFrame
    #expect(frames >= 44_100 && feed.history.lostFrames == 0)
    let count = model.blocks.ring.count
    #expect(count == frames / 256, "every whole block of 256 samples, the rest waits")
    #expect(model.blocks.cursor == count * 256)
    #expect(frames - model.blocks.cursor < 256)
    var loud = 0.0
    var compared = 0
    for k in 1...count {
      let b = model.blocks.ring.block(newest: k)
      let end = Int((b.t * sr).rounded())
      #expect(end == model.blocks.cursor - (k - 1) * 256, "a block is stamped with its last frame")
      loud = max(loud, Double(max(-b.min, b.max)))
      // (the feed keeps 32768 samples: older blocks cannot be compared any more)
      guard end - 256 >= feed.history.startFrame else { continue }
      compared += 1
      let r = reduced(feed.history.window(count: 256, endingAt: end))
      #expect(b.min == r.min && b.max == r.max && b.meanSq == r.meanSq, "block \(k)")
    }
    #expect(compared >= 100, "compared \(compared) blocks against the history")
    #expect(loud > 0.05, "the net is making sound")
    // attack: instant, and the clock never moved so nothing released
    #expect(model.gain.peak == max(0.1, loud))
  }

  @Test func theSpringRunsOnTheInjectedClockNotOnAudioTime() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 1000.0
    model.update(feed: feed, wall: wall)
    rig.render(seconds: 0.5)
    rig.hub.pump()
    model.update(feed: feed, wall: wall)  // same wall time: dt = 0
    var loud = 0.0
    #expect(model.blocks.ring.count > 0)
    for k in 1...model.blocks.ring.count {
      let b = model.blocks.ring.block(newest: k)
      loud = max(loud, Double(max(-b.min, b.max)))
    }
    var want = LiveScopeGain()
    want.attack(loud)
    #expect(model.gain == want, "the attack took the loudest block at once, and dt 0 moved nothing")
    // one frame of 1/64 s (exact in binary), no new audio in between
    wall += 1.0 / 64
    model.update(feed: feed, wall: wall)
    want.step(dt: 1.0 / 64)
    #expect(model.gain == want)
    // a stall is clamped to 50 ms
    wall += 5
    model.update(feed: feed, wall: wall)
    want.step(dt: 0.05)
    #expect(model.gain == want)
    #expect(model.lastFrameTime == wall)
    // audio time moving on does not move the spring: render without updating, same wall time
    rig.render(seconds: 1)
    rig.hub.pump()
    let before = model.gain
    model.update(feed: feed, wall: wall)
    #expect(model.gain.disp == before.disp && model.gain.vel == before.vel)
  }

  @Test func aFramesAudioIsAttackedBeforeTheSpringStepsOnIt() throws {
    // drawLive reads the waveform (the attack) and only then steps the gain: the loud block of a
    // frame already pulls on the spring in that frame
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    model.update(feed: feed, wall: 100)
    rig.render(seconds: 0.25)
    rig.hub.pump()
    model.update(feed: feed, wall: 100 + 1.0 / 64)  // new audio AND a real frame time
    var loud = 0.0
    #expect(model.blocks.ring.count > 10)
    for k in 1...model.blocks.ring.count {
      let b = model.blocks.ring.block(newest: k)
      loud = max(loud, Double(max(-b.min, b.max)))
    }
    #expect(loud > 0.3, "the net is loud enough to tell the orders apart")
    var want = LiveScopeGain()
    want.attack(loud)
    want.step(dt: 1.0 / 64)
    #expect(model.gain == want)
    var late = LiveScopeGain()  // the other order: the spring still chases 0.1
    late.step(dt: 1.0 / 64)
    late.attack(loud)
    #expect(late != want && model.gain != late)
  }

  @Test func theSceneIsDrawnAtTheSpringsScaleNotAtThePeaks() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    model.update(feed: feed, wall: wall)
    rig.render(seconds: 0.5)
    rig.hub.pump()
    var distinct = 0
    for frame in 0..<12 {
      wall += 1.0 / 60
      model.update(feed: feed, wall: wall)  // (only the first frame has new audio)
      let s = model.scene(feed: feed, width: 800, height: 300)
      #expect(s.scale == (s.hTop / 2 - 3) / model.gain.disp, "frame \(frame)")
      if abs(model.gain.disp - model.gain.peak) > 0.1 {
        distinct += 1
        #expect(abs(s.scale - (s.hTop / 2 - 3) / model.gain.peak) > 10, "frame \(frame)")
      }
    }
    #expect(distinct >= 5, "the spring is still far from the peak for several frames: \(distinct)")
  }

  @Test func aNewModelOverALiveFeedStartsFittedToWhatItHolds() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let first = LiveScopeModel()
    var wall = 0.0
    run(rig, first, feed, seconds: 1, wall: &wall, dtWall: 1.0 / 60)
    // a view created now: the spring does not start at 0.1 and chase a loud peak (a 7x oversize
    // first frame); the display starts fitted to the audio the feed already holds
    let second = LiveScopeModel()
    second.update(feed: feed, wall: wall)
    #expect(second.gain.peak > 0.3, "the held history is loud")
    #expect(second.gain.disp == second.gain.peak && second.gain.vel == 0)
    let s = second.scene(feed: feed, width: 800, height: 300)
    #expect(s.scale == (s.hTop / 2 - 3) / second.gain.peak)
    // a feed with nothing in it yet keeps the law's start, 0.1
    let quiet = try ScopeRig(play: false)
    defer { quiet.stop() }
    let empty = quiet.hub.feed(.deck("A"))
    empty.acquire()
    let fresh = LiveScopeModel()
    fresh.update(feed: empty, wall: 0)
    #expect(fresh.gain == LiveScopeGain())
  }

  @Test func theViewSaysItIsWaitingWhileTheTransportRunsAndNothingHasArrived() throws {
    let rig = try ScopeRig(block: 128)  // deck A is playing
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 128)  // the transport starts, but there is not a whole block of 256 yet
    rig.hub.pump()
    #expect(feed.clock.transport == .playing)
    let model = LiveScopeModel()
    model.update(feed: feed, wall: 0)
    #expect(model.blocks.ring.isEmpty)
    #expect(
      model.scene(feed: feed, width: 800, height: 300).emptyMessage?.text == "waiting for audio…")
    rig.render(seconds: 0.5)
    rig.hub.pump()
    model.update(feed: feed, wall: 0.1)
    #expect(model.scene(feed: feed, width: 800, height: 300).emptyMessage == nil)
    // and the transport decides the other message
    let still = try ScopeRig(play: false)
    defer { still.stop() }
    let stopped = still.hub.feed(.deck("A"))
    stopped.acquire()
    still.hub.pump()
    let other = LiveScopeModel()
    other.update(feed: stopped, wall: 0)
    #expect(
      other.scene(feed: stopped, width: 800, height: 300).emptyMessage?.text == "press play")
  }

  @Test func whenTheTransportStopsTheGridStopsAtTheLastStepThatBegan() throws {
    // The engine keeps rendering after a stop and "now" keeps running; only the song stops. The
    // bar numbers must not count on and the grid must not slide on from the last anchor.
    let rig = try ScopeRig()  // 300 bpm: 50 ms a step, a 3.2 s window
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    run(rig, model, feed, seconds: 3, wall: &wall, dtWall: 1.0 / 60)
    #expect(feed.clock.transport == .playing)
    #expect(!model.scene(feed: feed, width: 800, height: 300).barLabels.isEmpty)
    rig.dj["A"]!.setPlaying(false)
    run(rig, model, feed, seconds: 1, wall: &wall, dtWall: 1.0 / 60)
    #expect(feed.clock.transport == .stopped)
    let last = try #require(feed.anchors.newest)
    let ax = feed.timeAxis(x0: 0, w: 800)
    #expect(ax.aS == Double(last.step), "the axis stands on the last anchor")
    let s = model.scene(feed: feed, width: 800, height: 300)
    let xLast = ax.xOf(last.time)
    #expect(xLast > 300 && xLast < 700, "1 s of a 3.2 s window to its right: \(xLast)")
    #expect(!s.gridLines.isEmpty, "the song so far is still drawn")
    #expect(s.gridLines.allSatisfy { $0.rect.x <= xLast + 1 }, "no line after step \(last.step)")
    let lastBar = last.step / 16 + 1
    #expect(!s.barLabels.isEmpty)
    #expect(s.barLabels.allSatisfy { Int($0.text)! <= lastBar }, "bar \(lastBar) is the last")
    // the waveform is not held: it is measured, and the silence scrolls in from the right
    #expect(!s.envelope.isEmpty)
    // long after the stop the song has left the window
    run(rig, model, feed, seconds: 4, wall: &wall, dtWall: 1.0 / 60)
    let later = model.scene(feed: feed, width: 800, height: 300)
    #expect(later.gridLines.isEmpty && later.barLabels.isEmpty && later.sections.isEmpty)
    // and pressing play brings the grid back
    rig.dj["A"]!.setPlaying(true)
    run(rig, model, feed, seconds: 1, wall: &wall, dtWall: 1.0 / 60)
    #expect(feed.clock.transport == .playing)
    #expect(!model.scene(feed: feed, width: 800, height: 300).gridLines.isEmpty)
  }

  @Test func theStoreKeepsOneModelPerFeedAndItsWaveformAndGainWithIt() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    a.acquire()
    let store = LiveScopeStore()
    let model = store.model(for: a)
    #expect(store.model(for: a) === model, "the same object every time")
    #expect(store.model(for: b) !== model, "another feed, another model")
    #expect(store.count == 2)
    var wall = 0.0
    run(rig, model, a, seconds: 2, wall: &wall, dtWall: 1.0 / 60)
    let held = model.blocks.ring.count
    let gain = model.gain
    #expect(held > 100 && gain.peak > 0.3)
    // the host builds a new view (and asks again) when the user flips to another kind and back;
    // audio went on while it was away: the old blocks and the gain are still there
    rig.render(seconds: 0.5)
    rig.hub.pump()
    let again = store.model(for: a)
    #expect(again === model && again.blocks.ring.count == held && again.gain == gain)
    again.update(feed: a, wall: wall + 0.5)
    #expect(again.blocks.ring.count > held + 40, "and it goes on from there")
    #expect(again.gain.peak >= gain.peak * 0.95, "no restart at 0.1")
  }

  @Test func theStoreForgetsFeedsThatAreGone() throws {
    let store = LiveScopeStore()
    var kept: LiveScopeModel?
    do {
      let rig = try ScopeRig(start: false)
      kept = store.model(for: rig.hub.feed(.deck("A")))
      #expect(store.count == 1)
    }
    #expect(kept != nil)
    #expect(store.count == 0, "the feed died with its rig: nothing to hand out any more")
    // a new feed is never given the model of a feed that once lived at its address
    let rig = try ScopeRig(start: false)
    let fresh = store.model(for: rig.hub.feed(.deck("A")))
    #expect(fresh !== kept)
    #expect(store.count == 1)
  }

  @Test func aNewGenerationDoesNotBlankTheWaveform() throws {
    // the ring is measured audio keyed by engine time: a track change or a re-acquire leaves it
    // true (the lane-indexed fire log is the feed's to clear, and it does)
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    run(rig, model, feed, seconds: 1, wall: &wall)
    let g = feed.generation
    let held = model.blocks.ring.count
    #expect(held > 40)
    let gain = model.gain
    feed.release()
    feed.acquire()  // (re)acquire: a new generation, the history starts at now
    #expect(feed.generation != g)
    #expect(feed.fireLog.count == 0, "the feed forgot the hits")
    model.update(feed: feed, wall: wall)
    #expect(model.blocks.ring.count == held, "and the waveform did not")
    #expect(model.gain == gain)
    let lastBlock = model.blocks.ring.block(newest: 1).t
    run(rig, model, feed, seconds: 0.5, wall: &wall)
    #expect(model.blocks.ring.count > held, "it goes on filling")
    // the new blocks come after the old ones, the gap between is simply not there
    var newer = 0
    for k in 1...model.blocks.ring.count where model.blocks.ring.block(newest: k).t > lastBlock {
      newer += 1
    }
    #expect(newer == model.blocks.ring.count - held)
  }

  @Test func aViewCreatedLaterStartsFromWhatTheFeedStillHolds() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let first = LiveScopeModel()
    var wall = 0.0
    run(rig, first, feed, seconds: 1, wall: &wall)
    // another model over the same feed (the user flipped to another view and back)
    let second = LiveScopeModel()
    #expect(!second.started)
    second.update(feed: feed, wall: wall)
    #expect(second.started)
    let history = feed.history.count
    #expect(second.blocks.ring.count == history / 256, "the retained history, cut into blocks")
    #expect(second.blocks.cursor == feed.history.startFrame + (history / 256) * 256)
    // block for block what the first model made, as far back as the second reaches
    for k in 1...second.blocks.ring.count {
      #expect(second.blocks.ring.block(newest: k).t == first.blocks.ring.block(newest: k).t)
    }
  }

  @Test func aNetDeckSceneHasTheWaveformTheGridTheLanesAndTheirHits() throws {
    let rig = try ScopeRig(structure: "standard")
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    model.update(feed: feed, wall: wall)
    run(rig, model, feed, seconds: 3, wall: &wall, dtWall: 1.0 / 60)
    let s = model.scene(feed: feed, width: 800, height: 300)
    #expect(s.ok && s.hTop == 144)
    #expect(!s.envelope.isEmpty && !s.rmsLower.isEmpty && s.rmsLower.count == s.rmsUpper.count)
    #expect(s.envelope.allSatisfy { $0.x >= 0 && $0.x < 800 && $0.w == 1 && $0.h >= 1 })
    #expect(s.emptyMessage == nil && s.corner?.text.hasPrefix("x · ±") == true)
    // 300 bpm: 50 ms a step, a 3.2 s window, 12.5 px per step; the grid every 4 steps
    #expect(abs(feed.timeAxis(x0: 0, w: 800).win - 3.2) < 1e-12)
    #expect(s.gridLines.count >= 16 && s.gridLines.filter(\.bar).count >= 4)
    #expect(s.gridLines.map(\.rect.x).sorted() == s.gridLines.map(\.rect.x))
    #expect(!s.barLabels.isEmpty && s.barLabels[0].text.allSatisfy(\.isNumber))
    // the standard structure starts with its first section, in the window 3 s in
    let first = try #require(feed.sections.first)
    #expect(s.sections.first?.name.text == first.name)
    // lanes: one band each, a separator above and below every band, hits placed by time
    let n = feed.lanes.count
    #expect(n > 0 && s.laneLines.count == n + 1 && s.laneColors == feed.lanes.map(\.color))
    #expect(abs(s.laneHeight - (300 - 12 - s.laneTop) / Double(n)) < 1e-12)
    #expect(!s.events.isEmpty)
    #expect(
      s.events.allSatisfy {
        feed.lanes.indices.contains($0.lane) && $0.rect.x >= 0 && $0.rect.x < 800
      })
    // a drum lane's hits are spikes 1.5 wide that end on the lane's baseline
    let drum = try #require(feed.lanes.firstIndex { $0.drum })
    let spikes = s.events.filter { $0.lane == drum }
    #expect(!spikes.isEmpty && spikes.allSatisfy { $0.rect.w == 1.5 })
    let baseline = s.laneTop + Double(drum + 1) * s.laneHeight
    #expect(spikes.allSatisfy { abs($0.rect.y + $0.rect.h - baseline) < 1e-9 })
    #expect(s.laneLabels.count == (s.laneHeight >= 8 ? n : 0))
  }

  @Test func theEventsAreAtTheXOfTheirAudioTime() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    run(rig, model, feed, seconds: 2, wall: &wall)
    let s = model.scene(feed: feed, width: 800, height: 300)
    let ax = feed.timeAxis(x0: 0, w: 800)
    // the newest fire of the log that is a drum hit: its rect x is xOf(time)
    var newest: ScopeFire?
    feed.fireLog.forEachNewestFirst { f in
      if feed.lanes[f.lane].drum && f.time <= ax.tNow {
        newest = f
        return false
      }
      return true
    }
    let f = try #require(newest)
    let hit = try #require(s.events.first { $0.lane == f.lane })
    #expect(abs(hit.rect.x - ax.xOf(f.time)) < 1e-9)
    #expect(f.time <= ax.tNow && f.time > ax.t0, "inside the window")
  }

  @Test func aSampleDeckHasAWaveformAndNeitherGridNorLanes() throws {
    let rig = try ScopeRig(net: ["A"], samples: ["B"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("B"))
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    run(rig, model, feed, seconds: 2, wall: &wall, dtWall: 1.0 / 60)
    #expect(!feed.hasNet && feed.lanes.isEmpty)
    let s = model.scene(feed: feed, width: 800, height: 300)
    #expect(s.ok && !s.envelope.isEmpty && !s.rmsUpper.isEmpty)
    #expect(s.gridLines.isEmpty && s.sections.isEmpty && s.laneLines.isEmpty && s.events.isEmpty)
    // no net: the 120 bpm default window, 8 s
    #expect(feed.timeAxis(x0: 0, w: 800).win == 8)
  }

  @Test func theMasterShowsBothDecksLanesOnOneWaveform() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 0.0
    run(rig, model, feed, seconds: 2, wall: &wall, dtWall: 1.0 / 60)
    let s = model.scene(feed: feed, width: 640, height: 400)
    let decks = Set(feed.lanes.map(\.deck))
    #expect(decks == ["A", "B"] && s.laneLines.count == feed.lanes.count + 1)
    #expect(!s.envelope.isEmpty && s.envelope.allSatisfy { $0.x < 640 })
    #expect(Set(s.events.map { feed.lanes[$0.lane].deck }) == ["A", "B"], "hits of both decks")
  }

  @Test func withNoAudioYetTheViewSaysPressPlayWhileTheTransportIsStopped() throws {
    let rig = try ScopeRig(play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = LiveScopeModel()
    model.update(feed: feed, wall: 0)
    let s = model.scene(feed: feed, width: 800, height: 300)
    #expect(s.ok && s.envelope.isEmpty)
    #expect(s.emptyMessage?.text == "press play")
    #expect(s.emptyMessage?.x == 6 && s.emptyMessage?.y == s.mid - 5)
    #expect(s.corner?.text == "x · ±0.10", "the initial peak")
  }
}
