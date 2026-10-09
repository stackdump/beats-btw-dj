import Darwin
import Testing

@testable import DJCore

// The scopes call AnalyserFFT once per UI frame on the main thread, so after init it must not
// touch the heap. Measured like the audio-thread contract is (countAllocations: malloc/free on
// this thread), warmed up first, and checked to have produced a real spectrum (otherwise zero
// allocations would prove nothing).
//
// Release builds only: an unoptimised build allocates once per loop iteration (unspecialised
// stdlib generics, e.g. Range iteration), which says nothing about the shipped code.
//
// NAME COUPLING: `make swift-rt-test` selects suites with the regex
// 'RealTime|WaveDeckSourceTests|AllocationCounterTests' (Makefile), so the struct below must keep
// "RealTime" in its name or these tests silently drop out of the real-time run. (The function
// names carry it too, as a second line of defence; keep both.)

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private func sine(_ n: Int, bin k: Double, amp: Double = 1) -> [Float] {
  (0..<n).map { Float(amp * sin(2 * Double.pi * k * Double($0) / Double(n))) }
}

struct AnalyserNoAllocRealTimeTests {
  /// Every per-frame call, at the sizes the scopes use (4096 measured spectro/bands, 256 corona
  /// and flame), with an exact, a short and a long window, through all three `analyse` overloads
  /// (a caller will pass an UnsafeBufferPointer, an array or a slice of its sample history).
  @Test(
    .enabled(if: optimized, "allocation is only meaningful in optimized builds"),
    arguments: [(4096, 0.0), (256, 0.4), (256, 0.78)] as [(Int, Float)])
  func perFrameRealTimeCallsDoNotAllocate(size: Int, tau: Float) {
    let a = AnalyserFFT(fftSize: size, smoothingTimeConstant: tau)
    let bin = size / 16
    let exact = sine(size, bin: Double(bin))
    let short = Array(exact.suffix(size / 3))
    let long = sine(size * 3, bin: Double(bin * 3))  // same frequency, three windows long
    var db = [Float](repeating: 0, count: size / 2)
    var lin = [Float](repeating: 0, count: size / 2)
    var bytes = [UInt8](repeating: 0, count: size / 2)
    var td = [Float](repeating: 0, count: size)

    var settled = [Float]()  // the smoothed magnitudes right after the measured loop
    exact.withUnsafeBufferPointer { e in
      short.withUnsafeBufferPointer { s in
        long.withUnsafeBufferPointer { l in
          db.withUnsafeMutableBufferPointer { dbp in
            lin.withUnsafeMutableBufferPointer { linp in
              bytes.withUnsafeMutableBufferPointer { bp in
                td.withUnsafeMutableBufferPointer { tdp in
                  func frame() {
                    a.analyse(e)
                    a.analyse(s)
                    a.analyse(l)
                    a.analyse(exact)  // [Float]
                    a.analyse(long[size..<(size * 2 - 3)])  // ArraySlice, startIndex != 0, short
                    a.analyse(long[(size / 2)...])  // ArraySlice, longer than the window
                    a.floatFrequencyData(into: dbp)
                    a.magnitudes(into: linp)
                    a.byteFrequencyData(into: bp)
                    a.floatTimeDomainData(window: e, into: tdp)
                  }
                  for _ in 0..<5 { frame() }  // warm-up
                  let report = countAllocations {
                    for _ in 0..<200 { frame() }
                  }
                  #expect(report.allocations == 0, "allocated \(report.allocations) times")
                  #expect(report.frees == 0, "freed \(report.frees) times")
                  settled = Array(linp)
                }
              }
            }
          }
        }
      }
    }
    // Not vacuous: the loop built up a real spectrum (the sine's bin is the peak), the dB, byte
    // and time-domain outputs were written, and a fresh analysis gives the analytic answer.
    #expect(settled.indices.max { settled[$0] < settled[$1] } == bin)
    #expect(settled[bin] > 0.01, "\(settled[bin])")
    #expect(td[size - 1] == exact[size - 1] && td[size / 2] == exact[size / 2])
    #expect(bytes[bin] > 0 && db[bin] > -40, "\(db[bin]) dB, byte \(bytes[bin])")
    a.reset()
    a.analyse(exact)
    let want = 20 * log10(Double(1 - tau) * 0.21)
    let got = a.decibels()
    #expect(got.indices.max { got[$0] < got[$1] } == bin)
    #expect(abs(Double(got[bin]) - want) < 1e-3, "\(got[bin]) vs \(want)")
  }

  /// Changing the size allocates (a new plan) and nothing else does: analysis afterwards is
  /// allocation-free again.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func analysisAfterASizeChangeRealTimeDoesNotAllocate() {
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0.4)
    let x = sine(4096, bin: 64)
    var db = [Float](repeating: 0, count: 2048)
    x.withUnsafeBufferPointer { w in
      db.withUnsafeMutableBufferPointer { dbp in
        a.setFFTSize(4096)
        for _ in 0..<3 {
          a.analyse(w)
          a.floatFrequencyData(into: dbp)
        }
        let report = countAllocations {
          for _ in 0..<100 {
            a.analyse(w)
            a.floatFrequencyData(into: dbp)
          }
        }
        #expect(report.allocations == 0 && report.frees == 0)
      }
    }
    // Settled: with the same frame again and again s -> 0.21 (0.21 * (1 - 0.4^n)), i.e. the
    // raw -13.5556 dB of a bin-centred unit sine, so the measured loop really analysed it.
    #expect(abs(db[64] + 13.5556) < 0.01, "\(db[64]) dB")
  }
}
