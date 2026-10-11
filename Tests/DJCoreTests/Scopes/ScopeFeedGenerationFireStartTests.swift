import Testing

@testable import DJCore

// `ScopeFeed.generationFireStart`: the fire number at which the current generation began, so a
// mode that accumulates over the fire log (the model) can reset on a new generation and carry
// on without losing the first step of the new one or counting the old ones again.

@MainActor
struct ScopeFeedGenerationFireStartTests {
  @Test func itIsTheFireCountAtEveryAcquireAndNeverMovesWhileThingsPlay() throws {
    let rig = try ScopeRig(net: ["A"], tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    #expect(feed.generationFireStart == 0)
    feed.acquire()
    #expect(feed.generationFireStart == 0 && feed.fireCount == 0)
    for _ in 0..<6 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    // the first anchor of the song installs its lanes (a new generation, an empty log): from
    // then on the start stays where it was while fires pile up
    let start = feed.generationFireStart
    #expect(feed.fireCount > 50 && start < feed.fireCount)
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(feed.generationFireStart == start)
    let before = feed.fireCount
    feed.release()
    feed.acquire()
    #expect(feed.generationFireStart == before && feed.fireCount == before)
    #expect(feed.fireLog.numbers(since: feed.generationFireStart).isEmpty)
  }

  @Test func aRestartDrawsTheLineBetweenTheFiresOfTheOldRunAndTheNew() throws {
    let rig = try ScopeRig(net: ["A"], structure: "standard", tempo: 300)
    defer { rig.stop() }
    rig.dj.deterministic = true
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    for _ in 0..<14 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    let g0 = feed.generation
    let start0 = feed.generationFireStart
    a.relocate(toTick: 0)
    var pumps = 0
    while feed.generation == g0 && pumps < 200 {
      rig.render(frames: 512)
      rig.hub.pump()
      pumps += 1
    }
    #expect(feed.generation != g0)
    pumps = 0
    while feed.fireCount == feed.generationFireStart && pumps < 200 {
      rig.render(frames: 512)
      rig.hub.pump()
      pumps += 1
    }
    let start = feed.generationFireStart
    #expect(start > start0, "the restart moved the line")
    #expect(feed.fireCount > start && start > 100)
    // everything before the line is the old run, everything after is the new one
    let runStart = try #require(feed.anchors.oldest).frame
    let old = try #require(feed.fireLog.fire(number: start - 1))
    let new = try #require(feed.fireLog.fire(number: start))
    #expect(old.frame < runStart && old.step > 100, "step \(old.step)")
    #expect(new.frame >= runStart && new.step < 16, "step \(new.step)")
    for n in start..<feed.fireCount {
      #expect(try #require(feed.fireLog.fire(number: n)).frame >= runStart)
    }
  }

  @Test func aNewTrackEmptiesTheLogAndTheLineIsTheTotal() throws {
    let rig = try ScopeRig(net: ["A"], tempo: 300)
    defer { rig.stop() }
    rig.dj.deterministic = true
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    for _ in 0..<4 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
    }
    let old = feed.lanes
    rig.load(scopeProject("house", seed: 3))
    var pumps = 0
    while feed.lanes == old && pumps < 300 {
      rig.render(frames: 512)
      rig.hub.pump()
      pumps += 1
    }
    #expect(feed.lanes != old)
    #expect(feed.generationFireStart >= 60, "counted on from the old track's fires")
    #expect(
      feed.fireLog.firstNumber == feed.generationFireStart, "the log holds only the new track")
  }
}
