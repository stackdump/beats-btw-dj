import Testing

@testable import DJCore

// What a feed writes into a fire or an anchor, checked field by field against the engine's own
// record (the raw rings, read with a fresh cursor) and against scope.js's rules.

/// Everything the engine published for deck `name` since it started, read with a fresh cursor.
@MainActor
private func rawEvents(_ rig: ScopeRig, _ name: String = "A") throws -> (
  fires: [FireEvent], anchors: [TickAnchor]
) {
  let deck = try #require(rig.dj[name])
  var cursor = WaveDeckSource.EventCursor()
  var fires: [FireEvent] = []
  var anchors: [TickAnchor] = []
  let lost = deck.wave.readEvents(&cursor, fires: &fires, anchors: &anchors)
  #expect(lost.firesLost == 0 && lost.anchorsLost == 0, "the rings were big enough")
  return (fires, anchors)
}

@MainActor
private func logged(_ feed: ScopeFeed) -> [ScopeFire] {
  feed.fireLog.numbers(since: 0).compactMap { feed.fireLog.fire(number: $0) }
}

@MainActor
struct ScopeFeedFieldTests {
  @Test func everyFireIsTheEnginesRecordRestated() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    let raw = try rawEvents(rig).fires
    let fires = logged(feed)
    #expect(raw.count > 20 && fires.count == raw.count, "no net of the song is without a lane")
    for (f, r) in zip(fires, raw) {
      #expect(f.frame == Int(r.frame) && f.net == Int(r.net) && f.transition == Int(r.transition))
      #expect(f.time == Double(r.frame) / ScopeRig.rate)
      #expect(f.step == Int(r.tick) - 1, "step = tick - 1: the first tick of a song is 1")
      #expect(f.note == Int(r.note) & 127 && f.channel == Int(r.channel))
      #expect(f.velocity == max(1, min(127, r.velocity == 0 ? 100 : Int(r.velocity))))
      #expect(r.durMs > 0 && f.durSec == Double(r.durMs) / 1000, "the engine's length, in seconds")
      #expect(f.generation == r.generation && f.flags == r.flags)
    }
    // the very first fire of a fresh play is on step 0
    #expect(fires.first?.step == 0)
  }

  @Test func everyAnchorIsTheEnginesTickRestated() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    let raw = try rawEvents(rig).anchors
    let ring = feed.anchors
    #expect(
      raw.count > 40 && ring.count == raw.count, "one per tick, and fewer than the ring holds")
    for i in 0..<ring.count {
      let a = ring[i]
      let r = raw[i]
      #expect(a.frame == Int(r.frame) && a.time == Double(r.frame) / ScopeRig.rate)
      #expect(a.step == Int(r.tick) - 1, "step = tick - 1")
      #expect(a.tempo == Double(r.tempo) && a.generation == r.generation)
      #expect(a.discontinuity == r.flags.contains(.discontinuity) && a.swap == false)
    }
    #expect(raw[0].tick == 1 && ring[0].step == 0, "the song starts on step 0")
    #expect(ring[0].discontinuity, "the first anchor ever starts a run")
    // every fire's step is the step of the anchor on its frame
    for f in logged(feed) {
      let anchor = try #require((0..<ring.count).map { ring[$0] }.first { $0.frame == f.frame })
      #expect(f.step == anchor.step)
    }
  }

  @Test func theFirstSectionStartsOnStepZeroOfTheSameAxis() throws {
    let rig = try ScopeRig(structure: "standard")
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 2)
    rig.hub.pump()
    #expect(feed.sections.count >= 2 && feed.sections.first?.step == 0)
    let layout = try #require(rig.dj["A"]!.wave.markingLayout)
    #expect(feed.sections.map(\.step) == layout.sections.map(\.startTick))
    #expect(feed.anchors.oldest?.step == 0, "the song's first step is the first section's start")
  }

  @Test func velocityZeroMeansHundredAndTheRestIsClamped() throws {
    let base = scopeProject("techno", seed: 42)
    let zero = rewritingBindings(base) { $0.velocity = 0 }
    let loud = rewritingBindings(base) { $0.velocity = 200 }
    for (project, want) in [(zero, 100), (loud, 127)] {
      let rig = try ScopeRig(play: false)
      defer { rig.stop() }
      rig.load(project)
      let feed = rig.hub.feed(.deck("A"))
      feed.acquire()
      rig.render(seconds: 2)
      rig.hub.pump()
      let raw = try rawEvents(rig).fires
      #expect(raw.count > 10 && raw.allSatisfy { Int($0.velocity) == (want == 100 ? 0 : 200) })
      let fires = logged(feed)
      #expect(fires.count == raw.count && fires.allSatisfy { $0.velocity == want }, "\(want)")
    }
  }

  @Test func aLengthThatIsNotPositiveIsHundredMilliseconds() throws {
    // scope.js durMsOf: no steps and no (positive) milliseconds is 100 ms
    let none = rewritingBindings(scopeProject("techno", seed: 42)) {
      $0.duration = 0
      $0.durationSteps = 0
    }
    let rig = try ScopeRig(play: false)
    defer { rig.stop() }
    rig.load(none)
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 2)
    rig.hub.pump()
    let raw = try rawEvents(rig).fires
    #expect(raw.count > 10 && raw.allSatisfy { $0.durMs == 0 }, "the engine knows no length")
    let fires = logged(feed)
    #expect(fires.count == raw.count && fires.allSatisfy { $0.durSec == 0.1 })
    // the lanes agree with the fires
    #expect(feed.lanes.allSatisfy { $0.durationsMs.allSatisfy { $0 == 100 } })
  }

  @Test func laneNoteLengthsAreTheLengthsTheFiresHave() throws {
    // the project's tempo is not the deck's: step lengths differ by that ratio unless both are
    // built at the tempo the deck runs (the model modes divide one by the other)
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    let p = scopeProject("techno", seed: 42)
    #expect(p.tempo != 300)
    let fires = logged(feed)
    #expect(fires.count > 20)
    for f in fires {
      let lengths = feed.lanes[f.lane].durationsMs
      #expect(
        lengths.contains { abs($0 - f.durSec * 1000) < 0.01 },
        "lane \(feed.lanes[f.lane].key): a fire of \(f.durSec * 1000) ms is not among \(lengths)")
    }
    // and in particular a tonal lane's median length is the median length of its fires
    let tonal = try #require(feed.lanes.firstIndex { !$0.drum && $0.durationsMs.count > 2 })
    let sorted = feed.lanes[tonal].durationsMs.sorted()
    let median = sorted[sorted.count / 2]
    let mine = fires.filter { $0.lane == tonal }.map { $0.durSec * 1000 }.sorted()
    #expect(!mine.isEmpty)
    let ratio = mine[mine.count / 2] / median
    #expect(ratio > 0.5 && ratio < 2, "median fire length / median lane length = \(ratio)")
  }

  @Test func aStoppedDecksLaneLengthsUseWhatTheDeckIsSetTo() throws {
    let rig = try ScopeRig(play: false)
    defer { rig.stop() }
    rig.dj["A"]!.pitch = 0.5  // tempo fader: +4 %
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 2048)
    rig.hub.pump()
    let p = scopeProject("techno", seed: 42)
    let bpm = p.tempo * (1 + 0.5 * Deck.pitchRange) * (1 + 0)
    #expect(feed.lanes == ScopeLaneSet.build(project: p, tempo: bpm, deck: "A").lanes)
    #expect(feed.lanes != ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A").lanes)
  }

  @Test func netsBeyondTheThirtySecondLaneAreDroppedFromTheLogButNotFromLastFired() throws {
    // 40 clones of the kick on a lane key of their own sort after every real lane
    var project = scopeProject("techno", seed: 42)
    let kick = try #require(project.nets.pairs.first { $0.key.hasPrefix("kick") })
    for i in 0..<40 {
      var net = kick.value
      net.track.channel = 1  // a tonal lane, so it sorts after the drums
      net.track.group = "zz"
      net.riffGroup = ""
      project.nets["zz\(i < 10 ? "0" : "")\(i)"] = net
    }
    let set = ScopeLaneSet.build(project: project, tempo: 128, deck: "A")
    #expect(set.lanes.count == 32)
    #expect(set.laneOf["zz39"] == nil && set.laneOf["zz00"] != nil, "the last ones fall off")

    let rig = try ScopeRig(play: false)
    defer { rig.stop() }
    rig.load(project)
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 3)
    rig.hub.pump()
    #expect(feed.lanes.count == 32)
    let layout = try #require(feed.marking()?.layout)
    let dropped = try #require(layout.netIds.firstIndex(of: "zz39"))
    let kept = try #require(layout.netIds.firstIndex(of: "zz00"))
    let fires = logged(feed)
    #expect(fires.contains { $0.net == kept }, "a net with a lane is logged")
    #expect(!fires.contains { $0.net == dropped }, "a net beyond the 32nd lane is not")
    #expect(fires.allSatisfy { feed.lanes.indices.contains($0.lane) })
    // every fire counts for `lastFired`, lane or not
    #expect(feed.lastFired(net: dropped) != nil && feed.lastFired(net: kept) != nil)
    // and the engine did fire it
    let raw = try rawEvents(rig).fires
    #expect(raw.contains { Int($0.net) == dropped })
    #expect(fires.count < raw.count)
  }
}
