import Testing

@testable import DJCore

// The audio-thread contract for the left-channel taps (the stage's corona): switching them on,
// feeding them and switching them off allocates and frees nothing on the render thread. Measured
// (`countAllocations`), release builds only (`make swift-rt-test`), warmed up first, and every
// test also checks that the tap really received data, otherwise zero allocations prove nothing.
//
// NAME COUPLING: the Makefile's real-time run selects suites by the regex
// 'RealTime|WaveDeckSourceTests|AllocationCounterTests': keep "RealTime" in these names.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private func project(_ genre: String, _ seed: Double) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["structure"] = .string("loop")
  return compose(genre: genre, overrides: .object(ov))
}

struct DeckLeftTapRealTimeTests {
  /// Blocks of `size` frames rendered on this thread the way the audio thread drives a deck.
  private func blocks(_ deck: Deck, _ n: Int, size: Int, l: inout [Float], r: inout [Float]) {
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        for _ in 0..<n {
          deck.renderBlock(frames: size, left: lp.baseAddress!, right: rp.baseAddress!)
        }
      }
    }
  }

  @Test(
    .enabled(if: optimized, "allocation is only meaningful in optimized builds"),
    arguments: [false, true])
  func aDeckWithTheLeftTapOnDoesNotAllocate(net: Bool) throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 48_000)
    let deck = try #require(dj["A"])
    if net {
      deck.loadNet(project("techno", 42))
      deck.wave.setTempo(480)
    } else {
      deck.loadDemo()
    }
    deck.setPlaying(true)
    var l = [Float](repeating: 0, count: 8192)
    var r = [Float](repeating: 0, count: 8192)
    deck.leftTap.acquire()
    deck.tap.acquire()
    blocks(deck, 300, size: 128, l: &l, r: &r)  // warm up: everything allocates once
    let before = deck.leftTap.frames
    let report = countAllocations {
      blocks(deck, 1500, size: 128, l: &l, r: &r)
      blocks(deck, 200, size: 37, l: &l, r: &r)
      blocks(deck, 30, size: 4096, l: &l, r: &r)  // bigger than the tap's scratch chunk
      blocks(deck, 3, size: 8192, l: &l, r: &r)
      // and a block with one channel buffer only
      l.withUnsafeMutableBufferPointer {
        deck.renderBlock(frames: 512, left: $0.baseAddress!, right: nil)
      }
    }
    #expect(report.allocations == 0, "the deck's block allocated \(report.allocations) times")
    #expect(report.frees == 0, "and freed \(report.frees) times")
    let expected = 1500 * 128 + 200 * 37 + 30 * 4096 + 3 * 8192 + 512
    #expect(deck.leftTap.frames - before == expected)
    #expect(deck.leftTap.endFrame == deck.renderedFrames && deck.leftTap.gapFrames == 0)
    var heard = [Float](repeating: 0, count: 4096)
    let got = heard.withUnsafeMutableBufferPointer {
      deck.leftTap.read(from: deck.leftTap.frames - 4096, into: $0)
    }
    #expect(got.count == 4096 && got.lost == 0 && heard.contains { abs($0) > 0.01 })
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func switchingTheLeftTapOnAndOffAroundTheBlocksDoesNotAllocate() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 48_000)
    let deck = try #require(dj["A"])
    deck.loadNet(project("techno", 42))
    deck.wave.setTempo(480)
    deck.setPlaying(true)
    var l = [Float](repeating: 0, count: 4096)
    var r = [Float](repeating: 0, count: 4096)
    blocks(deck, 200, size: 128, l: &l, r: &r)
    var report = countAllocations { blocks(deck, 500, size: 128, l: &l, r: &r) }
    #expect(deck.leftTap.frames == 0, "idle: nothing reaches the ring")
    deck.leftTap.acquire()
    report.merge(countAllocations { blocks(deck, 500, size: 128, l: &l, r: &r) })
    let first = deck.leftTap.frames
    #expect(first == 500 * 128)
    deck.leftTap.release()
    report.merge(countAllocations { blocks(deck, 400, size: 128, l: &l, r: &r) })
    #expect(deck.leftTap.frames == first, "released: untouched")
    // back after a gap shorter than the ring, then after one longer than the whole ring
    deck.leftTap.acquire()
    report.merge(countAllocations { blocks(deck, 30, size: 1024, l: &l, r: &r) })
    #expect(deck.leftTap.gapFrames == 400 * 128)
    deck.leftTap.release()
    report.merge(countAllocations { blocks(deck, 700, size: 128, l: &l, r: &r) })
    deck.leftTap.acquire()
    report.merge(countAllocations { blocks(deck, 300, size: 128, l: &l, r: &r) })
    #expect(deck.leftTap.endFrame == deck.renderedFrames)
    #expect(report.allocations == 0 && report.frees == 0, "\(report)")
    deck.leftTap.release()
  }
}

struct EngineLeftTapRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theWholeEngineWithEveryLeftTapOnDoesNotAllocate() throws {
    // The real source-node closures, the frame clock, the output unit's render notification that
    // feeds the master taps, and AVAudioEngine around them.
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    a.loadDemo()
    b.loadNet(project("techno", 42))
    b.wave.setTempo(480)
    a.setPlaying(true)
    b.setPlaying(true)
    a.leftTap.acquire()
    b.leftTap.acquire()
    dj.masterLeftTap.acquire()
    dj.masterTap.acquire()
    try dj.start()
    defer { dj.stop() }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 400, frames: 512)  // warm up
    let frameBefore = dj.frame
    var report = countAllocations { pullEngine(dj, buffer, cycles: 1000, frames: 512) }
    report.merge(countAllocations { pullEngine(dj, buffer, cycles: 30, frames: 4096) })
    report.merge(countAllocations { pullEngine(dj, buffer, cycles: 200, frames: 37) })
    #expect(report.allocations == 0, "the engine's render path allocated \(report.allocations)")
    #expect(report.frees == 0, "and freed \(report.frees)")
    #expect(dj.frame == frameBefore + 1000 * 512 + 30 * 4096 + 200 * 37)
    #expect(a.leftTap.endFrame == dj.frame && b.leftTap.endFrame == dj.frame)
    #expect(dj.masterLeftTap.endFrame == dj.frame && dj.masterLeftTap.gapFrames == 0)
    var heard = [Float](repeating: 0, count: 4096)
    let got = heard.withUnsafeMutableBufferPointer {
      dj.masterLeftTap.read(from: dj.masterLeftTap.frames - 4096, into: $0)
    }
    #expect(got.count == 4096 && got.lost == 0)
    #expect(heard.contains { abs($0) > 0.01 }, "the master's left tap carries the mix")
  }
}

extension AllocationReport {
  fileprivate mutating func merge(_ other: AllocationReport) {
    allocations += other.allocations
    frees += other.frees
  }
}
