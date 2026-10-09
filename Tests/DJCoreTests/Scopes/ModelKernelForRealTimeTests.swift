import Darwin
import Testing

@testable import DJCore

// The model works on the main thread, once per UI frame, and `kernelFor` and `deposit` run once
// per FIRE inside that frame: they must not touch the heap (a burst of fires at 300 BPM is
// hundreds per second). Measured like the audio-thread contract is (`countAllocations`, malloc
// and free on this thread), warmed up first, and checked to have produced a real answer
// (otherwise zero allocations would prove nothing). Release builds only: an unoptimised build
// allocates once per loop iteration.
//
// NAME COUPLING: `make swift-rt-test` selects suites with the regex
// 'RealTime|WaveDeckSourceTests|AllocationCounterTests' (Makefile), so the struct below must keep
// "RealTime" in its name or these tests silently drop out of the real-time run.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private func table(drum: Bool, notes: [Int]) -> ModelKernelTable {
  var logR: [Float] = []
  for i in 0..<notes.count {
    for j in 0..<ModelGrid.nr { logR.append(Float(i + 1) * 0.25 + Float(j) * 0.01) }
  }
  return ModelKernelTable(notes: notes, logR: logR, drum: drum, durMs: 200, tau: 0.1)
}

@MainActor
struct ModelKernelForRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func kernelForRealTimeDoesNotAllocate() {
    let tonal = table(drum: false, notes: [40, 60, 80])
    let drums = table(drum: true, notes: [36, 38, 42, 49])
    var out = [Float](repeating: 0, count: ModelGrid.nr)
    var sum: Float = 0
    for note in 30...90 {  // warm-up
      tonal.kernelFor(note: note, into: &out)
      drums.kernelFor(note: note, into: &out)
    }
    let report = countAllocations {
      for _ in 0..<50 {
        for note in 30...90 {
          tonal.kernelFor(note: note, into: &out)
          sum += out[3]
          drums.kernelFor(note: note, into: &out)
          sum += out[3]
        }
      }
    }
    #expect(sum > 0 && out[3] > 0, "the kernels were really looked up")
    #expect(report.allocations == 0 && report.frees == 0, "\(report)")
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func depositRealTimeDoesNotAllocate() {
    let lane = ScopeLane(
      key: "k", ids: ["k"], channel: 10, group: "main", drum: true, instrument: "drums",
      notes: [36, 38, 42], durationsMs: [200], lo: 36, hi: 42, color: ScopeColors.defaultLaneColor,
      deck: "A")
    let model = ModelEngine(engine: nil, cache: ModelKernelCache())
    model.setLanes([lane], tables: [table(drum: true, notes: [36, 38, 42])])
    // warm-up: the ring slots of the first columns are written once
    for step in 0..<64 {
      model.deposit(
        lane: 0, note: 36 + (step % 3) * 3, velocity: 100, durMs: 200, step: step, tickSec: 0.05)
    }
    let report = countAllocations {
      for step in 64..<1264 {
        model.deposit(
          lane: 0, note: 36 + (step % 3) * 3, velocity: 100, durMs: 200, step: step, tickSec: 0.05)
      }
    }
    model.specAdvance(step: 1400, tickSec: 0.05)
    #expect(model.maxBar >= 70 && model.modelBars[ModelGrid.rows * 70 + 5] > 0, "deposits landed")
    #expect(model.specCur >= 1264, "and the columns advanced")
    #expect(report.allocations == 0 && report.frees == 0, "\(report)")
  }
}
