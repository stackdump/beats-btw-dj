import Darwin
import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

// The master chain runs on the audio thread: `apply` and `process` must not allocate, lock or
// free. Measured (malloc_logger), release builds only (`make swift-rt-test`).

struct MasterChainRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func everyStageAtItsExtremesDoesNotAllocate() {
    let sr = 48_000.0
    let chain = MasterChain(sampleRate: sr)
    let n = 512
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    var phase = 0.0
    var block = 0
    // a block of a loud chord, or silence (the tails must die to exact zeros)
    func fill(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ silent: Bool) {
      for k in 0..<n {
        let s = silent ? 0 : 0.9 * sin(phase) + 0.3 * sin(3.1 * phase)
        l[k] = Float(s)
        r[k] = Float(-s)
        phase += 2 * Double.pi * 220 / sr
      }
    }
    // the moves: every slider to both ends, mid-ramp re-sets, curve rebuilds, pitch sign flips,
    // all landing inside blocks (split segments) as the deck does
    let moves: [(MasterFxKey, Int)] = [
      (.hpFreq, 100), (.lpFreq, 0), (.phaserWet, 100), (.phaserDepth, 100), (.phaserFreq, 100),
      (.crushBits, 100), (.distortion, 100), (.masterPitch, 12), (.masterPitch, -12),
      (.distortion, 37), (.crushBits, 1), (.phaserFreq, 0), (.lpFreq, 100), (.hpFreq, 0),
      (.masterPitch, -1), (.phaserDepth, 0), (.distortion, 0), (.crushBits, 0), (.phaserWet, 0),
      (.masterPitch, 0),
    ]
    func run(_ blocks: Int, silent: Bool = false) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<blocks {
            fill(lp.baseAddress!, rp.baseAddress!, silent)
            let split = (block * 97) % n
            chain.process(lp.baseAddress!, rp.baseAddress!, from: 0, to: split)
            let (k, v) = moves[block % moves.count]
            chain.apply(k, v, at: chain.time(at: split))
            chain.process(lp.baseAddress!, rp.baseAddress!, from: split, to: n)
            chain.finish(frames: n)
            block += 1
          }
        }
      }
    }
    run(50)  // warm-up
    let report = countAllocations {
      run(2000)
      run(400, silent: true)
      run(500)
    }
    #expect(report.allocations == 0, "the chain allocated \(report.allocations) times")
    #expect(report.frees == 0, "the chain freed \(report.frees) times")
    #expect(l.allSatisfy { $0.isFinite } && r.allSatisfy { $0.isFinite })
  }
}
