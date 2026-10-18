import Darwin
import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

// The level-matching stages that run on the audio thread (LevelMatch.swift): the net deck's
// peak limiter, a deck's loudness meter and the turntable's auto-gain. Measured
// (malloc_logger), release builds only (`make swift-rt-test`).

struct PeakLimiterRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theLimiterAndTheMeterDoNotAllocate() {
    let sr = 48_000.0
    let limiter = PeakLimiter(sampleRate: sr)
    let meter = LoudnessMeter(sampleRate: sr)
    let n = 512
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    var phase = 0.0
    func run(_ blocks: Int, level: Double) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for b in 0..<blocks {
            for k in 0..<n {
              // loud, quiet and spiky blocks: the limiter's queue fills and drains
              let s = level * sin(phase) + (k == 0 && b % 3 == 0 ? 1.5 : 0)
              lp[k] = Float(s)
              rp[k] = Float(-s)
              phase += 2 * Double.pi * 110 / sr
            }
            limiter.process(lp.baseAddress!, rp.baseAddress!, frames: n)
            meter.push(lp.baseAddress!, rp.baseAddress!, frames: n)
            limiter.process(lp.baseAddress!, nil, frames: n)  // mono too
          }
        }
      }
    }
    run(20, level: 2)
    let report = countAllocations {
      run(1000, level: 3)
      run(300, level: 0.01)
      run(300, level: 0)
      run(500, level: 1.2)
    }
    #expect(report.allocations == 0, "allocated \(report.allocations) times")
    #expect(report.frees == 0, "freed \(report.frees) times")
    #expect(meter.shortTermLUFS > -200)
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theTurntablesAutoGainDoesNotAllocate() {
    let sr = 48_000.0
    let tt = Turntable(sampleRate: sr)
    let audio = SampleBuffer(
      left: (0..<48_000).map { Float(0.1 * sin(Double($0) * 0.03)) }, sampleRate: sr)
    tt.load(audio)
    tt.send(.gain(2, now: true))
    tt.send(.start)
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        tt.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!)
        let report = countAllocations {
          for i in 0..<400 {
            if i % 50 == 0 { tt.send(.gain(i % 100 == 0 ? 0.5 : 3, now: false)) }
            tt.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!)
          }
        }
        #expect(report.allocations == 0 && report.frees == 0)
      }
    }
  }
}
