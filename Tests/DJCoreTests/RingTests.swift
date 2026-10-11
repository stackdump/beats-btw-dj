import Testing

@testable import DJCore

private func popAll(_ r: SPSCRing<Int>) -> [Int] {
  var out: [Int] = []
  while let v = r.pop() { out.append(v) }
  return out
}

private func push(_ r: SPSCRing<Int>, _ values: [Int]) -> Int {
  values.withUnsafeBufferPointer { r.push(contentsOf: $0) }
}

private func pop(_ r: SPSCRing<Int>, max: Int) -> [Int] {
  var buf = [Int](repeating: -1, count: max)
  let n = buf.withUnsafeMutableBufferPointer { r.pop(into: $0) }
  return Array(buf[0..<n])
}

struct SPSCRingGrowthTests {
  @Test func capacityAvailableAndFreeSlots() {
    let r = SPSCRing<Int>(capacity: 4)
    #expect(r.capacity == 4)
    #expect(r.available == 0 && r.freeSlots == 4)
    r.push(1)
    r.push(2)
    #expect(r.available == 2 && r.freeSlots == 2)
    #expect(r.pop() == 1)
    #expect(r.available == 1 && r.freeSlots == 3)
    r.push(3)
    r.push(4)
    r.push(5)
    #expect(r.available == 4 && r.freeSlots == 0, "full")
    #expect(popAll(r) == [2, 3, 4, 5])
    #expect(r.available == 0 && r.freeSlots == 4, "empty again after wrapping")
  }

  @Test func droppedCountsEveryRefusedPush() {
    let r = SPSCRing<Int>(capacity: 2)
    #expect(r.droppedCount == 0)
    #expect(r.push(1) && r.push(2))
    #expect(!r.push(3))
    #expect(!r.push(4))
    #expect(r.droppedCount == 2)
    #expect(r.pop() == 1)
    #expect(r.push(5))
    #expect(r.droppedCount == 2, "an accepted push is not a drop")
    #expect(popAll(r) == [2, 5], "refused values never appear")
  }

  @Test func batchPushTakesWhatFitsAndCountsTheRest() {
    let r = SPSCRing<Int>(capacity: 5)
    #expect(push(r, [1, 2, 3]) == 3)
    #expect(push(r, [4, 5, 6, 7, 8]) == 2, "only two slots were left")
    #expect(r.droppedCount == 3)
    #expect(r.freeSlots == 0 && r.available == 5)
    #expect(push(r, [9]) == 0)
    #expect(r.droppedCount == 4)
    #expect(popAll(r) == [1, 2, 3, 4, 5])
    #expect(push(r, []) == 0)
    #expect(r.droppedCount == 4)
  }

  @Test func batchesWrapAroundThePhysicalEnd() {
    let r = SPSCRing<Int>(capacity: 5)  // 6 physical slots
    #expect(push(r, [1, 2, 3, 4]) == 4)
    #expect(pop(r, max: 3) == [1, 2, 3])
    // head is at 4, tail at 3: this batch crosses the end of the storage
    #expect(push(r, [5, 6, 7, 8]) == 4)
    #expect(r.available == 5)
    #expect(pop(r, max: 2) == [4, 5])
    #expect(pop(r, max: 10) == [6, 7, 8], "asks for more than there is: gets what there is")
    #expect(pop(r, max: 4) == [])
    // and again with the batch pop being the one that wraps
    #expect(push(r, [10, 11, 12, 13, 14]) == 5)
    #expect(pop(r, max: 5) == [10, 11, 12, 13, 14])
  }

  @Test func batchPopIntoASmallBufferLeavesTheRest() {
    let r = SPSCRing<Int>(capacity: 8)
    #expect(push(r, Array(1...8)) == 8)
    #expect(pop(r, max: 3) == [1, 2, 3])
    #expect(r.available == 5 && r.freeSlots == 3)
    #expect(pop(r, max: 0) == [])
    #expect(r.pop() == 4)
    #expect(pop(r, max: 100) == [5, 6, 7, 8])
  }

  @Test func discardAllEmptiesTheConsumerSideOnly() {
    let r = SPSCRing<Int>(capacity: 4)
    #expect(push(r, [1, 2, 3, 4]) == 4)
    r.discardAll()
    #expect(r.available == 0 && r.freeSlots == 4)
    #expect(r.pop() == nil)
    #expect(r.droppedCount == 0, "discarding is not dropping")
    #expect(push(r, [5, 6]) == 2)
    #expect(popAll(r) == [5, 6])
  }

  @Test func matchesAModelOverManyRandomOperations() {
    let r = SPSCRing<Int>(capacity: 7)
    var model: [Int] = []
    var dropped = 0
    var next = 0
    var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    func rand(_ n: Int) -> Int {
      rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((rng >> 33) % UInt64(n))
    }
    for _ in 0..<5000 {
      switch rand(5) {
      case 0:
        let ok = r.push(next)
        if model.count < 7 {
          model.append(next)
          #expect(ok)
        } else {
          dropped += 1
          #expect(!ok)
        }
        next += 1
      case 1:
        let n = rand(11)
        let batch = Array(next..<(next + n))
        let took = push(r, batch)
        let fit = min(n, 7 - model.count)
        #expect(took == fit)
        model += batch.prefix(fit)
        dropped += n - fit
        next += n
      case 2:
        #expect(r.pop() == (model.isEmpty ? nil : model.removeFirst()))
      case 3:
        let n = rand(11)
        let got = pop(r, max: n)
        let want = Array(model.prefix(n))
        model.removeFirst(want.count)
        #expect(got == want)
      default:
        if rand(8) == 0 {
          r.discardAll()
          model.removeAll()
        }
      }
      #expect(r.available == model.count)
      #expect(r.freeSlots == 7 - model.count)
      #expect(r.droppedCount == dropped)
    }
  }

  @Test func twoThreadsKeepOrderAndAccountForEveryValue() {
    // A small ring and a fast producer: it is full a lot, so drops are exercised too.
    let report = stressSPSC(total: 1_500_000, capacity: 64)
    #expect(report.pushed == 1_500_000)
    #expect(report.corrupt == 0, "a payload was torn or mixed")
    #expect(report.outOfOrder == 0, "values arrived out of order")
    #expect(report.received + report.dropped == report.pushed, "every push is received or dropped")
    #expect(report.received > 0)
  }
}

private func readAll(_ r: LatestRing<Int>, from: Int, max: Int = 1000) -> (
  values: [Int], lost: Int
) {
  var buf = [Int](repeating: -1, count: max)
  let res = buf.withUnsafeMutableBufferPointer { r.read(from: from, into: $0) }
  return (Array(buf[0..<res.count]), res.lost)
}

private func write(_ r: LatestRing<Int>, _ values: [Int]) {
  values.withUnsafeBufferPointer { r.write(contentsOf: $0) }
}

struct LatestRingTests {
  @Test func capacityRoundsUpToAPowerOfTwo() {
    #expect(LatestRing<Int>(capacity: 8).capacity == 8)
    #expect(LatestRing<Int>(capacity: 5).capacity == 8)
    #expect(LatestRing<Int>(capacity: 1).capacity == 2)
    #expect(LatestRing<Float>(capacity: 1 << 16).capacity == 1 << 16)
  }

  @Test func readsByAbsoluteSequenceNumber() {
    let r = LatestRing<Int>(capacity: 8)
    #expect(r.written == 0)
    #expect(readAll(r, from: 0).values == [])
    for i in 0..<5 { r.write(i * 10) }
    #expect(r.written == 5)
    let all = readAll(r, from: 0)
    #expect(all.values == [0, 10, 20, 30, 40] && all.lost == 0)
    #expect(readAll(r, from: 3).values == [30, 40], "any cursor, not only the oldest")
    #expect(readAll(r, from: 5).values == [], "nothing new yet")
    #expect(readAll(r, from: 99).values == [] && readAll(r, from: 99).lost == 0, "a future cursor")
    #expect(readAll(r, from: -4).values == [0, 10, 20, 30, 40], "a negative cursor starts at 0")
    #expect(readAll(r, from: 0).values == all.values, "reading does not consume")
  }

  @Test func overwritesTheOldestWhenFullAndReportsWhatWasLost() {
    let r = LatestRing<Int>(capacity: 8)
    for i in 0..<20 { r.write(i) }
    #expect(r.written == 20)
    let late = readAll(r, from: 0)
    #expect(late.lost == 12 && late.values == Array(12..<20), "12 overwritten, newest 8 kept")
    let edge = readAll(r, from: 12)
    #expect(
      edge.lost == 0 && edge.values == Array(12..<20), "exactly one capacity behind: lossless")
    let over = readAll(r, from: 11)
    #expect(over.lost == 1 && over.values == Array(12..<20))
    let mid = readAll(r, from: 15)
    #expect(mid.lost == 0 && mid.values == [15, 16, 17, 18, 19])
  }

  @Test func aSmallOutputBufferPagesThroughTheHistory() {
    let r = LatestRing<Int>(capacity: 16)
    for i in 0..<13 { r.write(i) }
    var cursor = 0
    var seen: [Int] = []
    while true {
      let page = readAll(r, from: cursor, max: 5)
      if page.values.isEmpty { break }
      seen += page.values
      cursor += page.lost + page.values.count
    }
    #expect(seen == Array(0..<13) && cursor == 13)
  }

  @Test func batchWritesWrapAndKeepSequenceNumbers() {
    let r = LatestRing<Int>(capacity: 8)
    write(r, [0, 1, 2, 3, 4, 5])
    write(r, [6, 7, 8, 9, 10])  // crosses the end of the storage
    #expect(r.written == 11)
    let got = readAll(r, from: 3)
    #expect(got.values == Array(3..<11) && got.lost == 0)
    write(r, [])
    #expect(r.written == 11)
    // a batch bigger than the ring keeps only its tail
    write(r, Array(100..<125))
    #expect(r.written == 36)
    let big = readAll(r, from: 11)
    #expect(big.lost == 17 && big.values == Array(117..<125), "lost \(big.lost)")
    // singles and batches interleave on one sequence
    r.write(-1)
    write(r, [-2, -3])
    let tail = readAll(r, from: 35)
    #expect(tail.values == [124, -1, -2, -3] && tail.lost == 0)
  }

  @Test func floatHistoryRoundTripsExactly() {
    let r = LatestRing<Float>(capacity: 32)
    let src: [Float] = (0..<20).map { Float($0) * 0.37 - 1.5 }
    src.withUnsafeBufferPointer { r.write(contentsOf: $0) }
    var out = [Float](repeating: 0, count: 20)
    let res = out.withUnsafeMutableBufferPointer { r.read(from: 0, into: $0) }
    #expect(res.count == 20 && res.lost == 0 && out == src)
  }

  @Test func aFastProducerNeverCorruptsASlowReader() {
    // 64 slots, a producer that never waits, a reader that copies 53 at a time: laps are
    // routine. Every value returned must be whole and exactly where the cursor says it is.
    let report = stressLatest(total: 3_000_000, capacity: 64, maxBatch: 37)
    #expect(report.written == 3_000_000)
    #expect(report.corrupt == 0, "a torn value was returned")
    #expect(report.misplaced == 0, "a value came back with the wrong sequence number")
    #expect(report.lostReads > 0, "the reader really was lapped, or this proves nothing")
    #expect(report.received + report.lost == report.written, "every sequence number accounted for")
    #expect(report.received > 0)
  }

  @Test func aReaderThatKeepsUpLosesNothing() {
    // The same stress with a big ring: the reader is nowhere near a lap behind.
    let report = stressLatest(total: 200_000, capacity: 1 << 22, maxBatch: 37)
    #expect(report.corrupt == 0 && report.misplaced == 0)
    #expect(report.lost == 0 && report.received == 200_000)
  }

  @Test func aReaderLappedInTheMiddleOfItsCopyDropsTheTornPrefix() {
    // Deterministic version of the stress: the "preemption" happens between the two halves
    // of a wrapped copy, and the producer writes a bit more than a lap meanwhile.
    let r = LatestRing<Int>(capacity: 8)
    for i in 0..<12 { r.write(i) }  // sequence 4...11 are held; 4...7 sit in slots 4...7
    r.midCopyHook = {
      r.midCopyHook = nil
      for i in 12..<16 { r.write(i) }  // overwrites slots 4...7, already copied
    }
    let a = readAll(r, from: 4)
    // the first half was copied whole but could have been torn: conservatively lost
    #expect(a.lost == 4 && a.values == [8, 9, 10, 11], "lost \(a.lost) values \(a.values)")

    for i in 16..<24 { r.write(i) }  // now 16...23 held, slots 0...7
    r.midCopyHook = {
      r.midCopyHook = nil
      for i in 24..<32 { r.write(i) }  // a whole lap: every slot, including the unread half
    }
    let b = readAll(r, from: 18)
    #expect(b.values.isEmpty && b.lost == 6, "nothing of the copy is trustworthy")
    // and the ring itself is intact afterwards
    #expect(readAll(r, from: 24).values == Array(24..<32))
  }

  @Test func drainAppendsEverythingFromACursorAndAdvancesIt() {
    let r = LatestRing<Int>(capacity: 512)
    for i in 0..<300 { r.write(i) }  // more than one drain chunk
    var out: [Int] = []
    var cursor = 40
    #expect(r.drain(from: &cursor, into: &out) == 0)
    #expect(out == Array(40..<300) && cursor == 300)
    #expect(r.drain(from: &cursor, into: &out) == 0 && out.count == 260, "nothing new")
    r.write(300)
    #expect(r.drain(from: &cursor, into: &out) == 0 && out.last == 300 && cursor == 301)
    // a reader that fell a lap behind skips ahead and says how much it missed
    for i in 301..<1500 { r.write(i) }
    #expect(r.drain(from: &cursor, into: &out) == 1500 - 512 - 301)
    #expect(out.suffix(512) == Array(988..<1500) && cursor == 1500)
    // independent readers do not disturb one another
    var other = 1490
    var theirs: [Int] = []
    r.drain(from: &other, into: &theirs)
    #expect(theirs == Array(1490..<1500))
  }
}
