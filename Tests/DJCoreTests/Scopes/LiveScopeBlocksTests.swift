import Testing

@testable import DJCore

// Block reduction (readWaveform), the 8192-block ring (WF_CAP) and the per-column reduction
// (drawLive). Expected values are worked by hand; the arithmetic is in the comments.
struct LiveScopeBlocksTests {
  private func reduce(_ x: [Float]) -> (min: Float, max: Float, meanSq: Float) {
    x.withUnsafeBufferPointer { LiveScopeBlocks.reduce($0) }
  }

  @Test func aRampReducesToItsEnds() {
    // x_i = i / 256, i = 0 ..< 256: min 0, max 255/256, mean square (sum i^2 = 5559680) / 256^3
    let r = reduce((0..<256).map { Float($0) / 256 })
    #expect(r.min == 0 && r.max == 0.99609375)
    #expect(r.meanSq == 0.33138275146484375)
  }

  @Test func aSquareWaveIsItsAmplitude() {
    let r = reduce((0..<256).map { $0 % 2 == 0 ? Float(0.5) : -0.5 })
    #expect(r.min == -0.5 && r.max == 0.5 && r.meanSq == 0.25)
    // peak of that block is max(-min, max)
    var ring = LiveScopeBlocks()
    ring.reset(at: 0)
    let span = ScopeSamples(
      startFrame: 0, samples: (0..<256).map { $0 % 2 == 0 ? Float(0.5) : -0.5 })
    #expect(ring.ingest(span, sampleRate: 22_050) == 0.5)
  }

  @Test func silenceIsZeroAndAnOverRangeBlockKeepsTheJsInitialValues() {
    let z = reduce([Float](repeating: 0, count: 256))
    #expect(z.min == 0 && z.max == 0 && z.meanSq == 0)
    // min starts at 1 and max at -1 (scope.js `let mn = 1, mx = -1`): a block entirely above 1
    // keeps min 1, one entirely below -1 keeps max -1
    let hot = reduce([Float](repeating: 1.5, count: 256))
    #expect(hot.min == 1 && hot.max == 1.5 && hot.meanSq == 2.25)
    let cold = reduce([Float](repeating: -1.5, count: 256))
    #expect(cold.min == -1.5 && cold.max == -1)
  }

  @Test func wholeBlocksAreCutAndTheRestWaitsForTheNextLook() {
    var b = LiveScopeBlocks()
    b.reset(at: 1000)
    let sr = 22_050.0
    // 600 samples = 2 blocks + 88 left over
    let all = (0..<600).map { Float($0 % 7) / 7 }
    let first = ScopeSamples(startFrame: 1000, samples: Array(all[0..<600]))
    let pk = b.ingest(first, sampleRate: sr)
    #expect(b.ring.count == 2 && b.cursor == 1000 + 512)
    #expect(pk == Double(Float(6) / 7))
    // block end times are the engine time of the LAST sample of each block
    #expect(b.ring.block(newest: 1).t == Double(1000 + 512) / sr)
    #expect(b.ring.block(newest: 2).t == Double(1000 + 256) / sr)
    // the next look starts at the cursor: 88 old + 200 new = 288 samples = one more block
    let next = ScopeSamples(startFrame: 1512, samples: Array(repeating: 0.25, count: 288))
    _ = b.ingest(next, sampleRate: sr)
    #expect(b.ring.count == 3 && b.cursor == 1512 + 256)
    let n = b.ring.block(newest: 1)
    #expect(n.min == 0.25 && n.max == 0.25 && n.meanSq == 0.0625)
    #expect(n.t == Double(1512 + 256) / sr)
    // fewer than 256 new samples: nothing happens
    #expect(b.ingest(ScopeSamples(startFrame: 1768, samples: [0.1]), sampleRate: sr) == nil)
    #expect(b.cursor == 1768 && b.ring.count == 3)
  }

  @Test func aSpanThatStartsLaterThanTheCursorStartsItsBlocksThere() {
    var b = LiveScopeBlocks()
    b.reset(at: 0)
    // the history no longer reached back to the cursor: the span begins at 5000
    _ = b.ingest(
      ScopeSamples(startFrame: 5000, samples: Array(repeating: 0.5, count: 256), missed: 4000),
      sampleRate: 1000)
    #expect(b.ring.block(newest: 1).t == 5.256 && b.cursor == 5256)
  }

  @Test func theRingKeepsTheNewest8192Blocks() {
    var b = LiveScopeBlocks()
    b.reset(at: 0)
    let sr = 44_100.0
    let n = LiveScopeBlockRing.capacity + 10
    for i in 0..<n {
      // block i has the constant value (i % 100) / 100
      let v = Float(i % 100) / 100
      b.ingest(
        ScopeSamples(startFrame: i * 256, samples: [Float](repeating: v, count: 256)),
        sampleRate: sr)
    }
    #expect(LiveScopeBlockRing.capacity == 8192 && LiveScopeBlocks.blockSize == 256)
    #expect(b.ring.count == 8192, "capped")
    let newest = b.ring.block(newest: 1)
    #expect(newest.t == Double(n * 256) / sr && newest.max == Float((n - 1) % 100) / 100)
    let oldest = b.ring.block(newest: 8192)
    #expect(oldest.t == Double((n - 8191) * 256) / sr, "the first 10 blocks are gone")
    #expect(oldest.max == Float((n - 8192) % 100) / 100)
    // continuous in between
    var last = newest.t
    for k in 2...8192 {
      let t = b.ring.block(newest: k).t
      #expect(t < last)
      last = t
    }
  }

  @Test func anEmptyRingHoldsNothingAndFillsOnItsFirstPush() {
    var r = LiveScopeBlockRing()
    #expect(r.isEmpty && r.count == 0)
    r.push(LiveScopeBlock(t: 3, min: -0.5, max: 0.25, meanSq: 0.125))
    #expect(r.count == 1 && !r.isEmpty)
    #expect(r.block(newest: 1) == LiveScopeBlock(t: 3, min: -0.5, max: 0.25, meanSq: 0.125))
    r.removeAll()
    #expect(r.isEmpty)
    r.push(LiveScopeBlock(t: 4, min: 0, max: 1, meanSq: 0.5))
    #expect(r.count == 1 && r.block(newest: 1).t == 4)
  }

  @Test func aCursorAheadOfTheHistoryStartsOver() {
    var b = LiveScopeBlocks()
    b.reset(at: 1000)
    b.ingest(
      ScopeSamples(startFrame: 1000, samples: [Float](repeating: 0.5, count: 256)), sampleRate: 1)
    b.clamp(toEnd: 5000)
    #expect(b.cursor == 1256 && b.ring.count == 1, "behind the edge: untouched")
    b.clamp(toEnd: 200)
    #expect(b.cursor == 200 && b.ring.isEmpty, "ahead of the edge: reset to it")
  }
}

struct LiveScopeColumnsTests {
  // 8 s window ending at t = 10 (tickSec 0.125 * 64), 640 px wide: 80 px per second, t0 = 2
  private let axis = ScopeTimeAxis(tickSec: 0.125, tNow: 10, anchor: nil, x0: 0, w: 640)

  private func ring(_ blocks: [(Double, Float, Float, Float)]) -> LiveScopeBlockRing {
    var r = LiveScopeBlockRing()
    for b in blocks { r.push(LiveScopeBlock(t: b.0, min: b.1, max: b.2, meanSq: b.3)) }
    return r
  }

  @Test func theAxisIsEightSecondsOf640Pixels() {
    #expect(axis.win == 8 && axis.t0 == 2 && axis.ok)
    #expect(axis.xOf(2) == 0 && axis.xOf(10) == 640 && axis.xOf(6) == 320)
  }

  @Test func blocksOfOnePixelColumnMergeMinMaxAndMeanOfMeanSquares() {
    // t = 6.0 and 6.005 both land in column 320 (x = 320, 320.4); 6.0126 in 321 (x = 321.008)
    let r = ring([
      (6.0, -0.25, 0.5, 0.125), (6.005, -0.75, 0.25, 0.25), (6.0126, -0.5, 0.5, 0.5),
    ])
    var c = LiveScopeColumns()
    c.reduce(r, axis: axis, width: 640)
    #expect(c.count == 640)
    #expect(c.blocks[320] == 2 && c.lo[320] == -0.75 && c.hi[320] == 0.5)
    #expect(c.sq[320] == 0.375, "sum of the two mean squares; the RMS divides by the count")
    #expect(c.blocks[321] == 1 && c.lo[321] == -0.5 && c.hi[321] == 0.5 && c.sq[321] == 0.5)
    #expect(c.blocks.reduce(0, { $0 + Int($1) }) == 3, "no other column has a block")
    #expect(c.lo[0] == 1 && c.hi[0] == -1 && c.sq[0] == 0, "an empty column keeps the sentinels")
  }

  @Test func theWalkStopsAtTheLeftEdgeAndSkipsWhatIsOutsideTheWidth() {
    let r = ring([
      (1.9, -1, 1, 1),  // older than t0 = 2: the walk stops here...
      (2.0, -0.5, 0.5, 0.25),  // x = 0: the first column
      (9.99, -0.1, 0.1, 0.01),  // x = 639.2: the last column
      (10.0, -1, 1, 1),  // x = 640 = n: outside
      (10.5, -1, 1, 1),  // beyond "now": outside
    ])
    var c = LiveScopeColumns()
    c.reduce(r, axis: axis, width: 640)
    #expect(c.blocks.reduce(0, { $0 + Int($1) }) == 2)
    #expect(c.blocks[0] == 1 && c.hi[0] == 0.5)
    #expect(c.blocks[639] == 1 && c.lo[639] == -0.1)
  }

  @Test func theWalkIsNewestFirstSoAnOldBlockBeyondTheEdgeStopsIt() {
    // (the ring is time ordered: the first block older than t0 ends the walk)
    let r = ring([(1.0, -1, 1, 1), (5.0, -0.5, 0.5, 0.25)])
    var c = LiveScopeColumns()
    c.reduce(r, axis: axis, width: 640)
    #expect(c.blocks.reduce(0, { $0 + Int($1) }) == 1 && c.blocks[240] == 1)
  }

  @Test func theWidthIsTruncatedAndTheArraysReused() {
    var c = LiveScopeColumns()
    c.reduce(ring([(6.0, -0.5, 0.5, 0.25)]), axis: axis, width: 639.7)
    #expect(c.count == 639)
    c.reduce(LiveScopeBlockRing(), axis: axis, width: 100)
    #expect(c.count == 100 && c.blocks.prefix(100).allSatisfy { $0 == 0 }, "cleared each frame")
    c.reduce(LiveScopeBlockRing(), axis: axis, width: 0)
    #expect(c.count == 0)
    c.reduce(LiveScopeBlockRing(), axis: axis, width: .nan)
    #expect(c.count == 0)
  }
}
