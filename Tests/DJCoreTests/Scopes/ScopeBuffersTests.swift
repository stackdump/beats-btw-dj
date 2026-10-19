import Testing

@testable import DJCore

private func anchor(
  _ t: Double, _ step: Int, d: Bool = false, s: Bool = false, tempo: Double = 300
) -> ScopeAnchor {
  ScopeAnchor(
    time: t, frame: Int(t * 1000), step: step, tempo: tempo, generation: 1, discontinuity: d,
    swap: s)
}

private func fire(_ i: Int) -> ScopeFire {
  ScopeFire(
    time: Double(i), frame: i, lane: i, net: 0, transition: 0, note: 60, velocity: 100,
    durSec: 0.1, channel: 1, step: i, generation: 1)
}

struct ScopeAnchorRingTests {
  @Test func pushDedupsByStepLikePushAnchor() {
    var r = ScopeAnchorRing()
    let first = r.push(anchor(1.0, 5))
    let same = r.push(anchor(1.2, 5))
    #expect(first && !same, "same step as the newest: ignored")
    #expect(r.count == 1 && r.newest?.time == 1.0, "the first one stays")
    let disc = r.push(anchor(1.3, 5, d: true))
    let swap = r.push(anchor(1.4, 5, s: true))
    let next = r.push(anchor(1.5, 6))
    #expect(disc && swap && next, "a run start is a new fact even on the same step")
    #expect(r.count == 4)
  }

  @Test func theRingKeepsTheNewestAndReadsOldestFirst() {
    var r = ScopeAnchorRing(capacity: 4)
    for i in 0..<6 { r.push(anchor(Double(i), i)) }
    #expect(r.count == 4 && r.capacity == 4)
    #expect((0..<4).map { r[$0].step } == [2, 3, 4, 5])
    #expect(r.oldest?.step == 2 && r.newest?.step == 5)
    #expect(ScopeAnchorRing().capacity == 128 && ScopeAnchorRing().newest == nil)
    r.removeAll()
    #expect(r.isEmpty && r.indexAt(time: 1) == nil)
  }

  @Test func anchorAtIsTheLatestAtOrBeforeElseTheOldest() {
    var r = ScopeAnchorRing(capacity: 5)
    for i in 0..<8 { r.push(anchor(Double(i), i)) }  // holds steps 3...7 at times 3...7
    #expect(r.indexAt(time: 5.5) == 2 && r.anchor(at: 5.5)?.step == 5)
    #expect(r.anchor(at: 5)?.step == 5, "at exactly an anchor's time")
    #expect(r.anchor(at: 99)?.step == 7)
    #expect(r.anchor(at: 0)?.step == 3, "before all of them: the oldest")
    #expect(ScopeAnchorRing().anchor(at: 1) == nil)
  }

  @Test func stepInterpolatesInsideARunAndExtrapolatesAtTheEdges() throws {
    var r = ScopeAnchorRing()
    r.push(anchor(1.00, 0))
    r.push(anchor(1.05, 1))
    r.push(anchor(1.12, 2))  // the tempo slowed: this step took 70 ms
    #expect(abs(try #require(r.step(at: 1.085, tickSec: 0.05)) - 1.5) < 1e-12)
    #expect(abs(try #require(r.step(at: 1.025, tickSec: 0.05)) - 0.5) < 1e-12)
    #expect(try #require(r.step(at: 1.12, tickSec: 0.05)) == 2)
    // after the newest anchor: tickSec per step (scope.js stepOf)
    #expect(abs(try #require(r.step(at: 1.22, tickSec: 0.05)) - 4) < 1e-12)
    // before the oldest
    #expect(abs(try #require(r.step(at: 0.9, tickSec: 0.05)) - (-2)) < 1e-12)
    #expect(ScopeAnchorRing().step(at: 1, tickSec: 0.05) == nil)
  }

  @Test func beforeTheOldestAnchorItExtrapolatesAtTickSecWhateverTheFirstIntervalWas() throws {
    var r = ScopeAnchorRing()
    r.push(anchor(1.00, 0))
    r.push(anchor(1.07, 1))  // the first step took 70 ms, tickSec says 50
    // 100 ms before step 0 is two steps at tickSec, not 100/70
    #expect(abs(try #require(r.step(at: 0.9, tickSec: 0.05)) - (-2)) < 1e-12)
    #expect(abs(try #require(r.time(ofStep: -2, tickSec: 0.05)) - 0.9) < 1e-12, "round trip")
    // inside the first interval it still interpolates, exactly at the ends too
    #expect(abs(try #require(r.step(at: 1.035, tickSec: 0.05)) - 0.5) < 1e-12)
    #expect(try #require(r.step(at: 1.0, tickSec: 0.05)) == 0)
    #expect(try #require(r.step(at: 1.07, tickSec: 0.05)) == 1)
  }

  @Test func nothingIsInterpolatedAcrossADiscontinuityOrASwap() throws {
    var r = ScopeAnchorRing()
    r.push(anchor(1.00, 0))
    r.push(anchor(1.05, 1))
    r.push(anchor(3.00, 7, d: true))  // paused, then resumed on another step
    // in the gap: continue from step 1 at tickSec, not a slide towards step 7
    #expect(abs(try #require(r.step(at: 2.0, tickSec: 0.05)) - 20) < 1e-9)
    #expect(try #require(r.step(at: 3.0, tickSec: 0.05)) == 7)
    r.push(anchor(3.05, 8))
    r.push(anchor(3.10, 0, s: true))  // a queued project took over: the counter restarted
    #expect(abs(try #require(r.step(at: 3.07, tickSec: 0.05)) - 8.4) < 1e-9)
    #expect(r.newestRunStart == 4)
  }

  @Test func timeOfStepLooksInTheNewestRunOnly() throws {
    var r = ScopeAnchorRing()
    r.push(anchor(1.00, 0))
    r.push(anchor(1.05, 1))
    r.push(anchor(3.00, 7, d: true))
    r.push(anchor(3.05, 8))
    r.push(anchor(3.12, 9))
    #expect(r.newestRunStart == 2)
    #expect(try #require(r.time(ofStep: 7, tickSec: 0.05)) == 3.0)
    #expect(abs(try #require(r.time(ofStep: 8.5, tickSec: 0.05)) - 3.085) < 1e-12)
    #expect(try #require(r.time(ofStep: 9, tickSec: 0.05)) == 3.12)
    // beyond the newest anchor and before the run's first one: tickSec per step
    #expect(abs(try #require(r.time(ofStep: 11, tickSec: 0.05)) - 3.22) < 1e-12)
    #expect(abs(try #require(r.time(ofStep: 5, tickSec: 0.05)) - 2.9) < 1e-12)
    // a single run: step <-> time agree
    var q = ScopeAnchorRing()
    for i in 0..<10 { q.push(anchor(2 + Double(i) * 0.05, i + 100)) }
    for s in [100.0, 103.25, 109.0, 112.5] {
      let t = try #require(q.time(ofStep: s, tickSec: 0.05))
      #expect(abs(try #require(q.step(at: t, tickSec: 0.05)) - s) < 1e-9)
    }
    #expect(ScopeAnchorRing().time(ofStep: 1, tickSec: 0.05) == nil)
  }
}

struct ScopeTimeAxisTests {
  @Test func theAxisIsScopeJsTimeAxis() {
    // tickSec 0.05, now = 10 s, the latest anchor is step 100 at 9.9 s; pixels 30...670
    let ax = ScopeTimeAxis(
      tickSec: 0.05, tNow: 10, anchor: anchor(9.9, 100), x0: 30, w: 640)
    #expect(ax.ok && ax.hasAnchor)
    #expect(abs(ax.win - 3.2) < 1e-12 && abs(ax.t0 - 6.8) < 1e-12)
    #expect(abs(ax.xOf(6.8) - 30) < 1e-9 && abs(ax.xOf(10) - 670) < 1e-9)
    #expect(abs(ax.xOf(8.4) - 350) < 1e-9)
    #expect(abs(ax.stepOf(10) - 102) < 1e-9 && abs(ax.stepOf(9.9) - 100) < 1e-12)
    #expect(abs(ax.timeOf(98) - 9.8) < 1e-12)
    let half = ScopeTimeAxis(tickSec: 0.05, tNow: 10, anchor: nil, x0: 0, w: 100, windowSteps: 32)
    #expect(abs(half.win - 1.6) < 1e-12 && !half.hasAnchor && half.aT.isNaN && half.ok)
  }

  @Test func aBrokenWindowIsNotOk() {
    #expect(!ScopeTimeAxis(tickSec: 0, tNow: 10, anchor: nil, x0: 0, w: 1).ok)
    #expect(!ScopeTimeAxis(tickSec: .nan, tNow: 10, anchor: nil, x0: 0, w: 1).ok)
    #expect(!ScopeTimeAxis(tickSec: 0.05, tNow: .nan, anchor: nil, x0: 0, w: 1).ok)
    #expect(ScopeTimeAxis.windowSteps == 64)
  }
}

struct ScopeFireLogTests {
  @Test func itKeepsTheNewest4096AndCountsOnForever() {
    var log = ScopeFireLog()
    #expect(log.isEmpty && log.total == 0 && log.firstNumber == 0)
    for i in 0..<5000 { log.append(fire(i)) }
    #expect(log.total == 5000 && log.count == 4096 && log.firstNumber == 904)
    #expect(log.fire(number: 903) == nil && log.fire(number: 5000) == nil)
    #expect(log.fire(number: 904)?.lane == 904 && log.fire(number: 4999)?.lane == 4999)
    #expect(log.numbers(since: 4990) == 4990..<5000)
    #expect(log.numbers(since: 0) == 904..<5000, "skips what was overwritten")
    #expect(log.lostSince(0) == 904 && log.lostSince(904) == 0 && log.lostSince(4999) == 0)
    #expect(log.numbers(since: 5000).isEmpty)
  }

  @Test func aCursorAheadOfTheLogIsCaughtUpNotATrap() {
    var log = ScopeFireLog()
    #expect(log.numbers(since: 5).isEmpty, "an empty log, a cursor from somewhere else")
    for i in 0..<10 { log.append(fire(i)) }
    #expect(log.numbers(since: 10).isEmpty && log.numbers(since: 11).isEmpty)
    #expect(log.numbers(since: 80).isEmpty && log.lostSince(80) == 0)
    log.removeAll()
    #expect(log.numbers(since: 80).isEmpty, "also after a clear")
    log.append(fire(10))
    #expect(log.numbers(since: 80).isEmpty, "still ahead: nothing to walk")
    #expect(log.numbers(since: 3) == 10..<11)
  }

  @Test func clearingKeepsTheCountMonotonic() {
    var log = ScopeFireLog()
    for i in 0..<10 { log.append(fire(i)) }
    let seen = log.total
    log.removeAll()
    #expect(log.isEmpty && log.total == 10 && log.fire(number: 5) == nil)
    #expect(log.numbers(since: seen).isEmpty && log.numbers(since: 3).isEmpty)
    log.append(fire(10))
    #expect(log.numbers(since: seen) == 10..<11 && log.fire(number: 10)?.lane == 10)
    #expect(log.lostSince(3) == 7)
  }

  @Test func newestFirstWalkStopsWhenAsked() {
    var log = ScopeFireLog()
    for i in 0..<10 { log.append(fire(i)) }
    var seen: [Int] = []
    log.forEachNewestFirst {
      seen.append($0.lane)
      return $0.lane > 6
    }
    #expect(seen == [9, 8, 7, 6])
    var all = 0
    log.forEachNewestFirst { _ in
      all += 1
      return true
    }
    #expect(all == 10)
  }
}

struct ScopeSampleHistoryTests {
  private func filled() -> ScopeSampleHistory {
    var h = ScopeSampleHistory(capacity: 8)
    h.append([1, 2, 3, 4, 5])
    h.append([6, 7, 8, 9, 10])
    return h
  }

  @Test func itKeepsTheNewestCapacitySamplesOnAbsoluteFrames() {
    var h = ScopeSampleHistory(capacity: 8)
    #expect(h.isEmpty && h.endFrame == 0 && ScopeSampleHistory().capacity >= 8192)
    h.append([1, 2, 3, 4, 5])
    #expect(h.endFrame == 5 && h.count == 5 && h.startFrame == 0)
    h.append([6, 7, 8, 9, 10])
    #expect(h.endFrame == 10 && h.count == 8 && h.startFrame == 2)
    #expect(h.window(count: 8) == [3, 4, 5, 6, 7, 8, 9, 10])
    #expect(h.window(count: 4) == [7, 8, 9, 10])
    #expect(h.window(count: 4, endingAt: 6) == [3, 4, 5, 6])
  }

  @Test func windowsAreZeroPaddedWhereTheHistoryDoesNotReach() {
    let h = filled()
    #expect(h.window(count: 12) == [0, 0, 0, 0, 3, 4, 5, 6, 7, 8, 9, 10])
    #expect(h.window(count: 4, endingAt: 3) == [0, 0, 0, 3], "frames -1...2: only 2 is held")
    #expect(h.window(count: 4, endingAt: 12) == [9, 10, 0, 0], "past the right edge")
    #expect(h.window(count: 0).isEmpty)
    var buf = [Float](repeating: 9, count: 5)
    buf.withUnsafeMutableBufferPointer { h.copyWindow(into: $0, endingAt: 10) }
    #expect(buf == [6, 7, 8, 9, 10])
  }

  @Test func newSamplesSinceAFrame() {
    let h = filled()
    let a = h.newSamples(since: 6)
    #expect(a.startFrame == 6 && a.samples == [7, 8, 9, 10] && a.missed == 0 && a.endFrame == 10)
    let b = h.newSamples(since: 0)
    #expect(b.startFrame == 2 && b.samples.count == 8 && b.missed == 2)
    let c = h.newSamples(since: 10)
    #expect(c.startFrame == 10 && c.samples.isEmpty && c.missed == 0)
    #expect(h.newSamples(since: 50).samples.isEmpty)
  }

  @Test func lostSamplesBecomeZerosAndAreCounted() {
    var h = ScopeSampleHistory(capacity: 8)
    h.append([1, 2, 3])
    h.appendLost(2)
    h.append([4])
    #expect(h.endFrame == 6 && h.lostFrames == 2)
    #expect(h.window(count: 6) == [1, 2, 3, 0, 0, 4])
    h.appendLost(100)  // more than the ring: all zeros, the frame axis still advances
    #expect(
      h.endFrame == 106 && h.lostFrames == 102
        && h.window(count: 8) == [Float](repeating: 0, count: 8))
  }

  @Test func aBatchBiggerThanTheRingKeepsItsTail() {
    var h = ScopeSampleHistory(capacity: 8)
    h.append((0..<20).map(Float.init))
    #expect(h.endFrame == 20)
    #expect(h.count == 8)
    #expect(sameSamples(h.window(count: 8), (12..<20).map(Float.init)) == .identical)
  }

  @Test func resetStartsOverAtAFrame() {
    var h = filled()
    h.reset(at: 100)
    #expect(h.isEmpty && h.endFrame == 100 && h.startFrame == 100 && h.lostFrames == 0)
    h.append([5, 6])
    #expect(h.startFrame == 100 && h.endFrame == 102 && h.window(count: 3) == [0, 5, 6])
  }
}
