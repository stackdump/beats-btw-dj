import Testing

@testable import DJCore

// The master feed: what it weighs, who leads, and when "now" is safe to read.

@MainActor
private func logged(_ feed: ScopeFeed) -> [ScopeFire] {
  feed.fireLog.numbers(since: 0).compactMap { feed.fireLog.fire(number: $0) }
}

@MainActor
struct ScopeFeedMasterTests {
  // MARK: weights and lead

  @Test func aDecksWeightIsItsStripGainSquared() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let master = rig.hub.feed(.master)
    let a = rig.hub.feed(.deck("A"))
    master.acquire()
    a.acquire()
    // A: trim 2^((0.75 - 0.5) * 2) = sqrt 2, volume 0.5, crossfader at the centre cos(pi/4):
    //   sqrt 2 * 0.5 * (sqrt 2 / 2) = 0.5, squared 0.25.
    // B: trim 1, volume 0.8, sin(pi/4): 0.8 * (sqrt 2 / 2) = 0.5657, squared 0.32.
    rig.dj["A"]!.gain = 0.75
    rig.dj["A"]!.volume = 0.5
    rig.render(frames: 1024)
    rig.hub.pump()
    #expect(abs(master.deckWeights["A"]! - 0.25) < 1e-12)
    #expect(abs(master.deckWeights["B"]! - 0.32) < 1e-12)
    #expect(master.weight(ofLane: 0) == master.deckWeights["A"])
    #expect(master.weight(ofLane: master.lanes.count - 1) == master.deckWeights["B"])
    #expect(master.weight(ofLane: -1) == 0 && master.weight(ofLane: 999) == 0)
    // a deck feed hears its own deck at full strength: the mix is not its business
    #expect(a.deckWeights == ["A": 1])
  }

  @Test func aStoppedDeckNeverLeadsEvenWhenItIsTheLouderOne() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let master = rig.hub.feed(.master)
    master.acquire()
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(master.leadDeck == "A")
    rig.dj["A"]!.setPlaying(false)
    rig.dj.crossfader = 0  // all A, no B
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(master.deckWeights["B"]! < 1e-9 && master.deckWeights["A"]! > 0.1)
    #expect(master.leadDeck == "B", "B is the one playing")
    #expect(master.clock.transport == .playing)
    // and with both stopped, the louder one
    rig.dj["B"]!.setPlaying(false)
    rig.render(frames: 2048)
    rig.hub.pump()
    #expect(master.leadDeck == "A", "nothing plays: the louder deck")
    #expect(master.clock.transport == .stopped && master.statusText.hasSuffix("stopped"))
  }

  @Test func theLeadNeedsAClearMarginToChange() throws {
    // two decks playing; weights are 0.64 cos^2 and 0.64 sin^2 of the crossfader angle, so their
    // ratio is tan^2(x pi / 2): B is 1.20x A at x = 0.529, 1.37x at x = 0.55; A is 1.46x B at 0.44
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let master = rig.hub.feed(.master)
    master.acquire()
    func lead(at x: Double) -> String? {
      rig.dj.crossfader = x
      rig.render(frames: 1024)
      rig.hub.pump()
      return master.leadDeck
    }
    #expect(lead(at: 0.5) == "A", "a tie goes to A")
    #expect(lead(at: 0.529) == "A", "B is 1.2x louder: not enough to take over")
    #expect(lead(at: 0.55) == "B", "1.37x is")
    #expect(lead(at: 0.529) == "B", "and A needs the same margin to win it back")
    #expect(lead(at: 0.5) == "B")
    #expect(lead(at: 0.44) == "A", "A is 1.46x louder")
    #expect(ScopeFeed.leadHysteresis == 1.25)
  }

  // MARK: "now" of a master feed

  @Test func aMasterAcquiredMidCycleNeverLogsOutOfTimeOrder() throws {
    // The frame clock counts a cycle before the decks render it. Acquire between the two, pump
    // after deck A's block and again after deck B's: B's fires of the same cycle must not land
    // after A's later ones.
    let rig = try ScopeRig(net: ["A", "B"], tempo: 900, start: false)
    let cycles = ManualCycles(rig.dj)
    let master = rig.hub.feed(.master)
    for _ in 0..<20 { cycles.cycle() }
    var inversions = 0
    var bothDecks = 0
    for _ in 0..<150 {
      cycles.tickClock()
      master.acquire()  // the UI subscribes in the middle of the cycle
      cycles.render("A")
      rig.hub.pump()  // ... and its first frame lands before deck B has rendered
      cycles.render("B")
      rig.hub.pump()
      let fires = logged(master)
      inversions += zip(fires, fires.dropFirst()).filter { $0.frame > $1.frame }.count
      if Set(fires.map { master.lanes[$0.lane].deck }).count == 2 { bothDecks += 1 }
      master.release()
    }
    #expect(inversions == 0)
    #expect(bothDecks > 5, "the trials did put both decks' fires in one log (\(bothDecks))")
  }

  @Test func theMasterNowIsWhatEveryDeckHasFinished() throws {
    let rig = try ScopeRig(net: ["A", "B"], tempo: 900, start: false)
    let cycles = ManualCycles(rig.dj)
    let master = rig.hub.feed(.master)
    for _ in 0..<4 { cycles.cycle() }
    master.acquire()
    #expect(master.nowFrame == 4 * 512)
    cycles.tickClock()
    cycles.render("A")  // the clock and A are ahead; B has not rendered the cycle
    rig.hub.pump()
    #expect(rig.dj.frame == 5 * 512 && rig.dj["A"]!.renderedFrames == 5 * 512)
    #expect(master.nowFrame == 4 * 512, "B has only rendered up to here")
    cycles.render("B")
    rig.hub.pump()
    #expect(master.nowFrame == 5 * 512)
    rig.hub.pump()
    #expect(master.nowFrame == 5 * 512, "and it never goes back")
  }

  @Test func aMasterTapThatNeverDeliversFallsBackToTheDecks() throws {
    // The decks render (the clock counts, as it does when the output unit is pulled), but the
    // output unit's notification never reaches the master tap.
    let rig = try ScopeRig(net: ["A"], tempo: 600, start: false)
    let cycles = ManualCycles(rig.dj)
    let a = try #require(rig.dj["A"])
    let master = rig.hub.feed(.master)
    let deck = rig.hub.feed(.deck("A"))
    master.acquire()
    deck.acquire()
    for i in 0..<400 {  // 9.3 s at 22.05 kHz
      cycles.cycle()
      rig.hub.pump()
      if i == 10 { #expect(!master.masterTapSilent, "not yet: it takes half a second to be sure") }
    }
    #expect(rig.dj.masterTap.frames == 0, "the tap got nothing")
    #expect(master.masterTapSilent && master.statusText.hasSuffix("master tap silent"))
    #expect(!deck.statusText.contains("silent"))
    #expect(master.nowFrame == a.renderedFrames && master.nowFrame == deck.nowFrame)
    #expect(master.fireCount > 20 && master.fireCount == deck.fireCount)
    #expect(master.history.isEmpty, "there is no audio to show")
    #expect(master.anchors.newest?.step == a.wave.tick - 1)
    // a master feed with a silent tap does not hoard what it cannot place
    #expect(master.hasNet && master.lanes.count == deck.lanes.count)
  }

  @Test func aWorkingMasterTapIsWhatTheMasterNowFollows() throws {
    let rig = try ScopeRig(net: ["A"], tempo: 600)
    let master = rig.hub.feed(.master)
    master.acquire()
    for _ in 0..<4 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    #expect(!master.masterTapSilent && master.nowFrame == rig.dj.masterTap.endFrame)
    #expect(master.history.endFrame == master.nowFrame)
    #expect(master.history.count == master.history.capacity, "four half-seconds fill 32768")
    #expect(!master.statusText.contains("silent") && master.statusText.hasSuffix("600 bpm"))
    rig.stop()
  }
}
