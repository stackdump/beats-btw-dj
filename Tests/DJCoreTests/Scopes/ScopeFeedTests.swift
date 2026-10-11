import Testing

@testable import DJCore

@MainActor
struct ScopeFeedTests {
  @Test func historyHasEveryFrameRenderedSinceAcquire() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 20_480)
    rig.hub.pump()
    let a = try #require(rig.dj["A"])
    #expect(a.renderedFrames == 20_480 && feed.nowFrame == 20_480)
    #expect(feed.history.endFrame == 20_480 && feed.history.count == 20_480)
    #expect(feed.history.startFrame == 0 && feed.history.lostFrames == 0)
    #expect(feed.sampleRate == ScopeRig.rate)
    // the samples are the tap's own
    var raw = [Float](repeating: 0, count: 1024)
    let r = raw.withUnsafeMutableBufferPointer { a.tap.read(from: 5000, into: $0) }
    #expect(r.count == 1024 && r.lost == 0)
    #expect(feed.history.window(count: 1024, endingAt: 6024) == raw)
    #expect(raw.contains { abs($0) > 0.01 }, "the net is making sound")
  }

  @Test func theHistoryIsAWindowOfTheNewestSamples() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 50_000)  // more than the 32768-sample history
    rig.hub.pump()
    #expect(feed.history.count == feed.history.capacity)
    #expect(feed.history.endFrame == rig.dj["A"]!.renderedFrames)
    #expect(feed.history.capacity >= 8192)
    let span = feed.newSamples(since: 0)
    #expect(span.startFrame == feed.history.startFrame && span.missed == feed.history.startFrame)
    #expect(span.samples.count == feed.history.count)
    #expect(feed.window(count: 4096).count == 4096)
  }

  @Test func theFireLogCountsEveryAudibleFireOfTheLanes() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    let a = try #require(rig.dj["A"])
    let raw = a.wave.fires.written
    #expect(raw > 20, "the song fires")
    #expect(feed.lanes.count > 0 && feed.lanes.count <= 32)
    #expect(feed.fireCount == raw, "every music net has a lane here, so none is dropped")
    #expect(feed.fireLog.firstNumber == 0 && feed.fireLog.count == raw)
    var lastFrame = -1
    for n in feed.fireLog.numbers(since: 0) {
      let f = try #require(feed.fireLog.fire(number: n))
      #expect(feed.lanes.indices.contains(f.lane), "fire \(n): lane \(f.lane)")
      #expect(f.frame < feed.nowFrame && f.frame >= lastFrame, "time ordered, none after now")
      #expect(f.time == Double(f.frame) / ScopeRig.rate)
      #expect((1...127).contains(f.velocity) && (0...127).contains(f.note))
      #expect(f.durSec > 0)
      lastFrame = f.frame
    }
    // a drum fire sits in a drum lane, with the lane's channel
    let drums = feed.fireLog.numbers(since: 0).compactMap { feed.fireLog.fire(number: $0) }
      .filter { feed.lanes[$0.lane].drum }
    #expect(!drums.isEmpty && drums.allSatisfy { (10...15).contains($0.channel) })
  }

  @Test func aStingerOfALaneNetShowsInItsLane() throws {
    let rig = try ScopeRig(play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(feed.fireCount == 0, "nothing played yet")
    // fire a stinger: hit1 has a lane, so it shows
    rig.dj["A"]!.setPlaying(true)
    rig.dj["A"]!.wave.fireStinger("hit1")
    rig.render(seconds: 2)
    rig.hub.pump()
    let hits = feed.fireLog.numbers(since: 0).compactMap { feed.fireLog.fire(number: $0) }
      .filter { feed.lanes[$0.lane].group == "stinger" }
    #expect(!hits.isEmpty, "the stinger lane got its fire")
    #expect(hits.allSatisfy { feed.lanes.indices.contains($0.lane) })
    #expect(hits.allSatisfy { $0.flags.contains(.stinger) })
  }

  @Test func anchorsComeFromTheEnginesTicks() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    let ring = feed.anchors
    #expect(ring.count > 40)
    #expect(ring.oldest?.discontinuity == true || ring.count == ring.capacity)
    for i in 1..<ring.count {
      let a = ring[i - 1]
      let b = ring[i]
      #expect(b.time > a.time && b.frame > a.frame, "monotonic")
      if !b.startsRun { #expect(b.step == a.step + 1, "steps consecutive within a run") }
    }
    let spacing = ring[ring.count - 1].time - ring[ring.count - 2].time
    #expect(abs(spacing - 0.05) < 1.0 / ScopeRig.rate + 1e-9, "300 BPM: a step is 50 ms")
    #expect(feed.clock.tempo == 300 && abs(feed.clock.tickSec - 0.05) < 1e-12)
    // the step at the newest anchor's time is that anchor's step
    let newest = try #require(ring.newest)
    #expect(feed.stepAt(newest.time) == Double(newest.step))
    #expect(abs(try #require(feed.timeAt(step: Double(newest.step))) - newest.time) < 1e-9)
    // halfway between two anchors
    let mid = (ring[ring.count - 2].time + newest.time) / 2
    #expect(abs(try #require(feed.stepAt(mid)) - (Double(newest.step) - 0.5)) < 1e-9)
    #expect(feed.anchorAt(newest.time + 100)?.step == newest.step)
    #expect(feed.anchorAt(-1)?.step == ring.oldest?.step, "before the oldest: the oldest")
  }

  @Test func theTimeAxisIsTheJsAxisOnTheLatestAnchor() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    let ax = feed.timeAxis(x0: 30, w: 640)
    #expect(ax.ok && ax.hasAnchor)
    #expect(abs(ax.win - 64 * 0.05) < 1e-12 && ax.tNow == feed.nowTime)
    #expect(abs(ax.xOf(ax.t0) - 30) < 1e-9 && abs(ax.xOf(ax.tNow) - 670) < 1e-9)
    let anchor = try #require(feed.anchorAt(feed.nowTime))
    #expect(ax.aT == anchor.time && ax.aS == Double(anchor.step))
    #expect(abs(ax.timeOf(ax.stepOf(1.234)) - 1.234) < 1e-12)
  }

  @Test func theLanesAreTheDecksLanes() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 4096)
    rig.hub.pump()
    let p = scopeProject("techno", seed: 42)
    #expect(p.tempo != 300, "the deck runs at a tempo of its own, not the project's")
    // note lengths are built at the tempo the deck runs (the rig's 300), see the feed's header
    let want = ScopeLaneSet.build(project: p, tempo: 300, deck: "A")
    #expect(feed.lanes == want.lanes)
    #expect(feed.laneSet.laneOf == want.laneOf && feed.sections == want.sections)
    #expect(feed.hasNet && feed.leadDeck == "A")
    #expect(feed.trackSerial == rig.dj["A"]!.wave.latest?.trackSerial)
    // the song the lanes came from, for the modes that walk the whole arrangement
    let project = try #require(feed.leadProject)
    #expect(project.nets.keys == p.nets.keys && project.tempo == p.tempo)
    #expect(feed.project(deck: "A")?.nets.keys == p.nets.keys && feed.project(deck: "Z") == nil)
  }

  @Test func loadingATrackResetsAndSwitchesLanes() throws {
    let rig = try ScopeRig(genre: "techno", play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 2048)
    rig.hub.pump()
    let g0 = feed.generation
    let serial0 = feed.trackSerial
    let keys0 = feed.lanes.map(\.key)
    #expect(serial0 != 0 && !keys0.isEmpty, "lanes show before the first play")
    // a different song on the stopped deck: installed at once
    rig.dj["A"]!.loadSynthNet(scopeProject("ambient", seed: 7))
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(feed.generation > g0 && feed.trackSerial != serial0)
    let ambient = ScopeLaneSet.build(
      project: scopeProject("ambient", seed: 7), tempo: 72, deck: "A")
    #expect(feed.lanes.map(\.key) == ambient.lanes.map(\.key))
    #expect(feed.fireLog.isEmpty, "nothing has played since the new song loaded")
  }

  @Test func aTrackQueuedBehindAPlayingDeckTakesOverAtTheBar() throws {
    let rig = try ScopeRig(genre: "techno")
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 2)
    rig.hub.pump()
    let serial0 = feed.trackSerial
    let g0 = feed.generation
    rig.dj["A"]!.loadSynthNet(scopeProject("ambient", seed: 7))
    rig.hub.pump()
    #expect(feed.trackSerial == serial0, "still the sounding song")
    rig.render(seconds: 2)  // a bar is 0.8 s at 300 BPM
    rig.hub.pump()
    #expect(feed.trackSerial != serial0 && feed.generation > g0)
    #expect(feed.anchors.oldest?.swap == true, "the new song's history starts at the swap anchor")
    #expect(
      feed.lanes.map(\.key)
        == ScopeLaneSet.build(
          project: scopeProject("ambient", seed: 7), tempo: 72, deck: "A"
        ).lanes.map(\.key))
    #expect(feed.fireCount > 0, "the new song's fires land in its lanes")
    #expect(
      feed.fireLog.numbers(since: 0).allSatisfy {
        feed.lanes.indices.contains(feed.fireLog.fire(number: $0)!.lane)
      })
  }

  @Test func aRestartFromTheTopResetsButASectionJumpForwardDoesNot() throws {
    let rig = try ScopeRig(structure: "standard")
    defer { rig.stop() }
    rig.dj.deterministic = true
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 4)  // > 33 steps
    rig.hub.pump()
    let g0 = feed.generation
    let serial = feed.trackSerial
    // jump forward within the song: same trackSerial, new engine generation, no reset
    a.relocate(toTick: 400)
    rig.render(seconds: 2)
    rig.hub.pump()
    #expect(a.wave.latest?.trackSerial == serial)
    #expect(feed.trackSerial == serial)
    #expect(feed.generation == g0, "a forward jump is not a reset")
    #expect(feed.anchors.contains { $0.swap }, "the engine says a queued project took over")
    #expect(feed.anchors.newest!.step > 300)
    // jump back to the top: the step counter regresses by far more than 32
    a.relocate(toTick: 0)
    rig.render(seconds: 2)
    rig.hub.pump()
    #expect(feed.trackSerial == serial, "same song")
    #expect(feed.generation > g0, "but its history restarted")
    // stop and play from the top does the same
    let g1 = feed.generation
    rig.render(seconds: 4)  // far enough in that tick 0 is more than 32 steps back
    rig.hub.pump()
    #expect(feed.anchors.newest!.step > 33, "tick 0 is more than 32 steps back")
    a.wave.stop()  // back to tick 0
    rig.render(frames: 2048)
    a.wave.play()
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(feed.generation > g1)
  }

  @Test func theMasterMergesBothDecks() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let master = rig.hub.feed(.master)
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    master.acquire()
    a.acquire()
    b.acquire()
    for _ in 0..<6 {  // the tap rings hold ~3 s: pump as the UI would
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    #expect(a.lanes.count > 0 && b.lanes.count > 0)
    #expect(master.lanes.count == a.lanes.count + b.lanes.count)
    #expect(master.lanes.prefix(a.lanes.count).allSatisfy { $0.deck == "A" })
    #expect(master.lanes.suffix(b.lanes.count).allSatisfy { $0.deck == "B" })
    #expect(master.fireCount == a.fireCount + b.fireCount)
    let fires = master.fireLog.numbers(since: 0).compactMap { master.fireLog.fire(number: $0) }
    #expect(
      fires.contains { $0.lane < a.lanes.count } && fires.contains { $0.lane >= a.lanes.count })
    #expect(zip(fires, fires.dropFirst()).allSatisfy { $0.frame <= $1.frame }, "time ordered")
    // history is the master tap's
    #expect(master.history.endFrame == rig.dj.masterTap.endFrame)
    #expect(master.nowFrame == rig.dj.frame && master.history.endFrame == master.nowFrame)
    #expect(master.history.count == master.history.capacity && master.history.lostFrames == 0)
    // lead: equal weights, tie goes to A; B wins once the crossfader is across
    #expect(master.leadDeck == "A")
    #expect(abs(master.deckWeights["A"]! - master.deckWeights["B"]!) < 1e-12)
    rig.dj.crossfader = 1
    rig.render(frames: 1024)
    rig.hub.pump()
    #expect(master.leadDeck == "B")
    #expect(master.deckWeights["A"]! < 1e-9 && master.deckWeights["B"]! > 0.1)
    #expect(master.trackSerial == rig.dj["B"]!.wave.latest?.trackSerial)
    #expect(master.sections == b.sections)
    // lane lookup by deck + net id
    let id = try #require(
      rig.dj["B"]!.netProject?.nets.pairs.first { $0.key == "kick-0" || $0.key == "kick" }?.key)
    let li = try #require(master.lane(forNet: id, deck: "B"))
    #expect(master.lanes[li].deck == "B" && master.lanes[li].ids.contains(id))
    #expect(master.weight(ofLane: li) == master.deckWeights["B"])
  }

  @Test func aSampleDeckHasNoNetButStillHasAWaveform() throws {
    let rig = try ScopeRig(net: ["A"], samples: ["B"])
    defer { rig.stop() }
    let b = rig.hub.feed(.deck("B"))
    let master = rig.hub.feed(.master)
    b.acquire()
    master.acquire()
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(!b.hasNet && b.lanes.isEmpty && b.fireCount == 0 && b.anchors.isEmpty)
    #expect(b.clock.transport == .noNet && b.statusText == "needs a net deck")
    #expect(b.history.count > 20_000 && b.history.window(count: 4096).contains { abs($0) > 0.01 })
    #expect(b.marking() == nil && b.leadDeck == nil)
    #expect(master.hasNet && master.lanes.allSatisfy { $0.deck == "A" } && master.leadDeck == "A")
  }

  @Test func pumpingTwiceChangesNothing() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let feeds = [rig.hub.feed(.deck("A")), rig.hub.feed(.master)]
    for f in feeds { f.acquire() }
    rig.render(seconds: 2)
    rig.hub.pump()
    let before = feeds.map {
      ($0.revision, $0.fireCount, $0.history.endFrame, $0.nowFrame, $0.generation, $0.anchors.count)
    }
    rig.hub.pump()
    rig.hub.pump()
    let after = feeds.map {
      ($0.revision, $0.fireCount, $0.history.endFrame, $0.nowFrame, $0.generation, $0.anchors.count)
    }
    #expect(before.count == after.count)
    for (x, y) in zip(before, after) { #expect(x == y) }
    // and nothing is drained for an unsubscribed hub
    for f in feeds { f.release() }
    let n = rig.hub.pumpCount
    rig.hub.pump()
    #expect(rig.hub.pumpCount == n)
  }

  @Test func theTapsFollowTheSubscriptions() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    let b = try #require(rig.dj["B"])
    let feedA = rig.hub.feed(.deck("A"))
    let master = rig.hub.feed(.master)
    #expect(!a.tap.isEnabled && !rig.dj.masterTap.isEnabled && rig.hub.activeFeeds.isEmpty)
    feedA.acquire()
    feedA.acquire()
    master.acquire()
    #expect(a.tap.subscribers == 1 && a.tap.isEnabled && !b.tap.isEnabled)
    #expect(rig.dj.masterTap.subscribers == 1)
    #expect(rig.hub.feed(.deck("A")) === feedA, "one feed per source")
    feedA.release()
    #expect(a.tap.isEnabled, "still one subscriber")
    feedA.release()
    #expect(!a.tap.isEnabled && feedA.subscribers == 0)
    feedA.release()  // extra release is ignored
    #expect(!a.tap.isEnabled && a.tap.subscribers == 0)
    master.release()
    #expect(!rig.dj.masterTap.isEnabled)
    // an unsubscribed feed is inert
    rig.render(frames: 4096)
    feedA.pump()
    #expect(feedA.history.isEmpty && feedA.fireCount == 0)
  }

  @Test func resubscribingStartsAtNowWithoutOldAudio() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 8192)
    rig.hub.pump()
    let gBefore = feed.generation
    feed.release()
    rig.render(frames: 8192)  // tap off: the history must not pretend to have this
    feed.acquire()
    #expect(feed.history.isEmpty && feed.nowFrame == 16_384)
    #expect(feed.generation != gBefore, "a (re)subscribed feed starts over")
    rig.render(frames: 4096)
    rig.hub.pump()
    #expect(feed.history.startFrame == 16_384 && feed.history.endFrame == 20_480)
    #expect(feed.history.count == 4096 && feed.history.lostFrames == 0)
  }

  @Test func aTempoChangeShowsInTheClock() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 4096)
    rig.hub.pump()
    #expect(feed.clock.tempo == 300 && abs(feed.tickSec - 0.05) < 1e-12)
    rig.dj["A"]!.wave.setTempo(120)
    rig.render(frames: 4096)
    rig.hub.pump()
    #expect(feed.clock.tempo == 120 && abs(feed.tickSec - 0.125) < 1e-12)
    #expect(feed.anchors.newest?.tempo == 120)
    #expect(feed.clock.transport == .playing && feed.clock.tick > 0)
    #expect(ScopeClock.tickSec(forTempo: .nan) == 0.125 && ScopeClock.tickSec(forTempo: 0) == 0.125)
  }

  @Test func theMarkingAndLastFiredComeFromTheMirror() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 2)
    rig.hub.pump()
    let m = try #require(feed.marking())
    let layout = try #require(m.layout)
    #expect(m.tokens.count == layout.placeCount && m.muted.count == layout.netCount)
    #expect(m.tick > 0 && m.generation == rig.dj["A"]!.wave.activeGeneration)
    #expect(m.tokens.contains { $0 > 0 }, "some place holds a token")
    // once per pump: the same stamp gives the same snapshot
    #expect(try #require(feed.marking()).header == m.header)
    // the net that owns the first logged fire has a last-fired record at or after it
    let f = try #require(feed.fireLog.fire(number: feed.fireLog.firstNumber))
    let last = try #require(feed.lastFired(net: f.net))
    #expect(last.frame >= f.frame && last.frame < feed.nowFrame)
    #expect(feed.lastFired(net: 100_000) == nil && feed.lastFired(net: -1) == nil)
  }

  @Test func aDeckGoingBackToASampleDropsTheNet() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(feed.hasNet && !feed.lanes.isEmpty)
    let g = feed.generation
    rig.dj["A"]!.loadDemo()
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(!feed.hasNet && feed.lanes.isEmpty && feed.generation > g)
    #expect(feed.history.endFrame == feed.nowFrame, "the waveform carries on")
  }

  @Test func anUnknownDeckIsAnEmptyFeed() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("Z"))
    feed.acquire()
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(!feed.hasNet && feed.history.isEmpty && feed.lanes.isEmpty)
    feed.release()
    #expect(!rig.dj["A"]!.tap.isEnabled && !rig.dj.masterTap.isEnabled)
  }
}
