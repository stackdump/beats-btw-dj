import Testing

@testable import DJCore

// The raster's loop test runs at every bar line of a 64-bar tick: "is every net's marking and the
// mute table back where they started". It compares the graph's own arrays in place, so it must
// not touch the heap. Measured like the audio-thread contract is (countAllocations: malloc/free
// on this thread), warmed up first, and checked to have actually compared (a true answer needs a
// full scan of every net; a false one stops at the first difference).
//
// The graphs and the saved mute table are kept alive across the measured region on purpose: the
// optimiser may end a local's life at its last use, and the release of a buffer that nothing else
// holds (here the saved mute table, once the graph's own has been edited) would show up as a
// "free" inside the window.
//
// Release builds only: an unoptimised build allocates once per loop iteration (unspecialised
// stdlib generics), which says nothing about the shipped code.
//
// NAME COUPLING: `make swift-rt-test` selects suites with the regex
// 'RealTime|WaveDeckSourceTests|AllocationCounterTests' (Makefile), so the struct below must keep
// "RealTime" in its name or this test silently drops out of the real-time run.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct RasterAtStartNoAllocRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theLoopComparisonRealTimeDoesNotAllocate() {
    let project = scopeProject("techno", seed: 42)
    let home = WaveGraph(project: project)
    let away = WaveGraph(project: project)
    let muted0 = home.muted
    for _ in 0..<7 { away.advance() }
    var places = 0
    for n in home.nets { places += n.nPlaces }
    #expect(places > 100, "a real project: the scan has something to do")

    var trues = 0
    var falses = 0
    func frame() {
      if RasterModel.isAtStart(home, muted0: muted0) { trues += 1 }
      if !RasterModel.isAtStart(away, muted0: muted0) { falses += 1 }
    }
    for _ in 0..<10 { frame() }  // warm-up
    trues = 0
    falses = 0
    let report = withExtendedLifetime((home, away, muted0)) {
      countAllocations {
        for _ in 0..<2000 { frame() }
      }
    }
    #expect(report.allocations == 0, "allocated \(report.allocations) times")
    #expect(report.frees == 0, "freed \(report.frees) times")
    // not vacuous: the graph at the start answered true every time, the advanced one false
    #expect(trues == 2000 && falses == 2000)
  }

  /// The comparison sees a difference in the mute table too, and still does not allocate.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aMuteDifferenceRealTimeIsFoundWithoutAllocating() {
    let project = scopeProject("house", seed: 3)
    let g = WaveGraph(project: project)
    let muted0 = g.muted
    g.muted[g.muted.count - 1] ^= 1
    var found = 0
    for _ in 0..<5 where !RasterModel.isAtStart(g, muted0: muted0) { found += 1 }  // warm-up
    found = 0
    let report = withExtendedLifetime((g, muted0)) {
      countAllocations {
        for _ in 0..<1000 where !RasterModel.isAtStart(g, muted0: muted0) { found += 1 }
      }
    }
    #expect(report.allocations == 0 && report.frees == 0)
    #expect(found == 1000)
  }
}
