import Testing

@testable import DJCore

// The measured spectrogram reads once per drawn frame on the main thread: after the first read
// (which makes the frame ring) it must not touch the heap, however long it runs. Measured like the
// audio-thread contract is (countAllocations: malloc/free on this thread), warmed up first, and
// checked to have really read (otherwise zero allocations would prove nothing).
//
// Release builds only: an unoptimised build allocates once per loop iteration (unspecialised
// stdlib generics), which says nothing about the shipped code.
//
// NAME COUPLING: `make swift-rt-test` selects suites with the regex
// 'RealTime|WaveDeckSourceTests|AllocationCounterTests' (Makefile), so the struct below must keep
// "RealTime" in its name or these tests silently drop out of the real-time run.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

@MainActor
struct MeasuredReaderNoAllocRealTimeTests {
  /// The analysis, the 33 row sums, the bar accumulation and the frame push.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func ingestRealTimeDoesNotAllocate() {
    let reader = MeasuredReader()
    let window = sineWindow(hz: 1000, rate: 44100)
    let anchor = ScopeAnchor(time: 9.5, frame: 0, step: 32, tempo: 120, generation: 1)
    for i in 0..<5 {  // warm-up: the first push makes the ring
      reader.ingest(
        window: window, sampleRate: 44100, time: 10 + Double(i) * 0.03, anchor: anchor,
        tickSec: 0.125)
    }
    let before = reader.reads
    // the window is kept alive across the measured region on purpose: the optimiser may end a
    // local's life at its last use, and the release of the one buffer nothing else holds would
    // show up as a "free" inside the window
    let report = withExtendedLifetime((reader, window)) {
      countAllocations {
        for i in 5..<705 {  // more than the ring holds: it wraps
          reader.ingest(
            window: window, sampleRate: 44100, time: 10 + Double(i) * 0.03, anchor: anchor,
            tickSec: 0.125)
        }
      }
    }
    #expect(report.allocations == 0, "allocated \(report.allocations) times")
    #expect(report.frees == 0, "freed \(report.frees) times")
    // not vacuous: every read made a frame, the ring wrapped, the bars were filled
    #expect(reader.reads == before + 700 && reader.frames.count == 512)
    #expect(reader.maxBar >= 2 && reader.measCnt.reduce(0, +) == 705)
    let frame = (0..<28).map { reader.frames.value(newest: 1, row: $0) }
    #expect(frame.indices.max { frame[$0] < frame[$1] } == 15, "a real spectrum: \(frame)")
  }

  /// The whole per-frame call a view makes, from a live feed: the window copy, the analysis, the
  /// reads of the feed's anchors and clock.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func updateFromAFeedRealTimeDoesNotAllocate() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    for _ in 0..<12 {  // warm-up
      rig.render(seconds: 0.05)
      rig.hub.pump()
      reader.update(feed: feed, enabled: true)
    }
    let before = reader.reads
    var allocations = 0
    var frees = 0
    for _ in 0..<100 {
      rig.render(seconds: 0.05)
      rig.hub.pump()
      let report = countAllocations { reader.update(feed: feed, enabled: true) }
      allocations += report.allocations
      frees += report.frees
    }
    #expect(allocations == 0, "allocated \(allocations) times")
    #expect(frees == 0, "freed \(frees) times")
    #expect(reader.reads - before >= 90, "reads \(reader.reads - before)")
    #expect(reader.maxBar >= 3 && reader.frames.count > 100)
    // and a read the engine had nothing new for costs nothing either
    let idle = countAllocations {
      for _ in 0..<50 { reader.update(feed: feed, enabled: true) }
    }
    #expect(idle.allocations == 0 && idle.frees == 0)
  }
}
