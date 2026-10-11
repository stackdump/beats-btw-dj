import Testing

@testable import DJCore

// Resets, identity across feeds, subscriptions that come and go, rings that overflow between
// pumps. The numbers that pin the rules (32 steps, a 128-anchor ring ...) are literals.

@MainActor
private func logged(_ feed: ScopeFeed) -> [ScopeFire] {
  feed.fireLog.numbers(since: 0).compactMap { feed.fireLog.fire(number: $0) }
}

@MainActor
struct ScopeFeedLifecycleTests {
  // MARK: generation identity

  @Test func noTwoFeedsEverShareAGenerationNumber() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let feeds = [rig.hub.feed(.deck("A")), rig.hub.feed(.deck("B")), rig.hub.feed(.master)]
    for f in feeds { f.acquire() }
    for _ in 0..<2 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    #expect(Set(feeds.map(\.generation)).count == 3, "\(feeds.map(\.generation))")
    // a panel that switches A -> B -> Master -> A sees a different number every time
    let seen = [feeds[0], feeds[1], feeds[2], feeds[0]].map(\.generation)
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 != $1 })
    // and a number is never reused, whatever bumps it
    var all = Set(seen)
    for f in feeds {
      f.release()
      f.acquire()
      #expect(all.insert(f.generation).inserted, "re-acquiring gives a number nobody had")
    }
  }

  @Test func aFireCursorFromAnotherFeedIsNotATrap() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let master = rig.hub.feed(.master)
    let b = rig.hub.feed(.deck("B"))
    master.acquire()
    for _ in 0..<4 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    let cursor = master.fireCount
    #expect(cursor > 20)
    b.acquire()  // fresh: nothing logged yet
    #expect(b.fireCount == 0)
    #expect(b.fireLog.numbers(since: cursor).isEmpty && b.fireLog.lostSince(cursor) == 0)
  }

  @Test func reacquiringKeepsTheFireCountGrowingAndStartsOver() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 2)
    rig.hub.pump()
    let cursor = feed.fireCount
    let g = feed.generation
    #expect(cursor > 20)
    feed.release()
    feed.acquire()
    #expect(feed.fireCount >= cursor, "the count never goes backwards")
    #expect(feed.generation != g)
    #expect(feed.fireLog.numbers(since: cursor).isEmpty && feed.fireLog.isEmpty)
    rig.render(seconds: 1)
    rig.hub.pump()
    let fresh = feed.fireLog.numbers(since: cursor)
    #expect(!fresh.isEmpty, "the cursor kept from before finds only what came after")
    #expect(
      fresh.allSatisfy { feed.fireLog.fire(number: $0)!.frame >= 44_100 },
      "...nothing of the first two seconds")
  }

  // MARK: reset rule

  @Test func theRestartRuleIsMoreThanThirtyTwoStepsBackAndNoLoop() {
    let restart = ScopeFeed.isRestart(step:lastStep:looping:)
    #expect(!restart(280, 300, false), "20 steps back: a jump, not a restart")
    #expect(!restart(268, 300, false), "exactly 32 back is still not")
    #expect(restart(267, 300, false), "33 back is")
    #expect(restart(260, 300, false), "40 back is")
    #expect(restart(0, 300, false))
    #expect(!restart(0, 300, true), "inside a loop region the step counter is expected to wrap")
    #expect(!restart(0, -1, false), "nothing to go back from")
    #expect(!restart(301, 300, false) && !restart(300, 300, false))
  }

  @Test func aTwentyStepJumpBackKeepsTheHistoryAndFortyResetsIt() throws {
    let rig = try ScopeRig(structure: "standard")
    defer { rig.stop() }
    rig.dj.deterministic = true
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 7)  // ~140 steps
    rig.hub.pump()
    /// Jump to `back` steps behind the newest step. The swap lands at the next bar line, so what
    /// the feed sees is a regression of between `back + 1` and `back + 16` steps: measured here
    /// from the last step pumped before the swap anchor arrived (a pump takes in at most one
    /// anchor: 512 frames are shorter than a 50 ms step).
    func jump(back: Int) throws -> (regression: Int, reset: Bool) {
      let g0 = feed.generation
      var last = try #require(feed.anchors.newest).step
      a.relocate(toTick: last - back)
      for _ in 0..<150 {
        rig.render(frames: 512)
        rig.hub.pump()
        let newest = try #require(feed.anchors.newest)
        if newest.swap {
          // "when did this net last fire" belongs to the generation that is running: nothing
          // from before the swap may be reported for it
          let layout = try #require(feed.marking()?.layout)
          for net in 0..<layout.netCount {
            if let fired = feed.lastFired(net: net) {
              #expect(fired.frame >= newest.frame, "net \(net) fired before the swap")
            }
          }
          return (last - newest.step, feed.generation != g0)
        }
        last = newest.step
      }
      Issue.record("the queued project never took over")
      return (0, false)
    }
    let small = try jump(back: 12)
    #expect(small.regression > 12 && small.regression <= 32, "regression \(small.regression)")
    #expect(!small.reset, "a short jump back is not a restart")
    rig.render(seconds: 2)
    rig.hub.pump()
    let big = try jump(back: 60)
    #expect(big.regression > 60, "regression \(big.regression)")
    #expect(big.reset, "a long jump back is")
  }

  // MARK: overflow

  @Test func aTapThatOverflowedBetweenPumpsIsCountedAndTheFeedCarriesOn() throws {
    let rig = try ScopeRig()
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(frames: 70_144)  // the tap's ring holds 65,536 samples
    rig.hub.pump()
    #expect(a.renderedFrames == 70_144 && feed.nowFrame == 70_144)
    #expect(feed.lostSamples > 0 && feed.lostSamples <= 70_144 - 65_536 + 512)
    #expect(feed.history.endFrame == feed.nowFrame, "the axis is whole: the hole is zeros")
    let tail = feed.window(count: 4096)
    #expect(tail.contains { abs($0) > 0.01 }, "and the newest audio is the real thing")
    // carries on cleanly
    rig.render(frames: 4096)
    rig.hub.pump()
    #expect(feed.history.endFrame == a.renderedFrames)
    #expect(feed.history.lostFrames == feed.lostSamples)
  }

  @Test func ringsThatLostRecordsGiveAContiguousNewestRunAndKeepWorking() throws {
    // 12,000 BPM is 800 steps and about 1,600 fires a second: both rings wrap within six
    let rig = try ScopeRig(tempo: 12_000, block: 1024)
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 6)
    #expect(a.wave.fires.written > a.wave.fireCapacity, "more fires than the ring holds")
    #expect(a.wave.anchors.written > a.wave.anchorCapacity)
    rig.hub.pump()
    #expect(feed.lostAnchors > 0 && feed.lostFires > 0)
    #expect(feed.lostAnchors <= a.wave.anchors.written && feed.lostFires <= a.wave.fires.written)
    // the newest 128 anchors are a contiguous run, ending at the engine's newest
    let ring = feed.anchors
    #expect(ring.count == ring.capacity && ring.capacity == 128)
    for i in 1..<ring.count {
      #expect(ring[i].step == ring[i - 1].step + 1 && !ring[i].startsRun)
    }
    #expect(ring.newest?.step == a.wave.tick - 1)
    // the fire log holds the newest 4096 of what survived, in time order, on valid lanes
    let fires = logged(feed)
    #expect(fires.count == ScopeFireLog.capacity)
    #expect(zip(fires, fires.dropFirst()).allSatisfy { $0.frame <= $1.frame })
    #expect(fires.allSatisfy { feed.lanes.indices.contains($0.lane) && $0.frame < feed.nowFrame })
    #expect(feed.history.endFrame == feed.nowFrame && feed.nowFrame == a.renderedFrames)
    // and the next second is ordinary
    let count = feed.fireCount
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(feed.fireCount > count && feed.anchors.newest?.step == a.wave.tick - 1)
  }
}
