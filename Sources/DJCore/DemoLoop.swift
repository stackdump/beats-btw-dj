import Foundation

/// A two-bar, 120 BPM drum-and-bass loop synthesized in code, so a deck has
/// something scratchable with no files. Deterministic: same rate, same samples.
public enum DemoLoop {
  public static let bpm = 120.0
  public static let bars = 2

  public static func make(sampleRate sr: Double) -> SampleBuffer {
    let beat = 60 / bpm
    let n = Int((Double(bars * 4) * beat * sr).rounded())
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    let sixteenth = beat / 4
    var seed: UInt32 = 0x9E37_79B9

    func noise() -> Float {  // xorshift32
      seed ^= seed << 13
      seed ^= seed >> 17
      seed ^= seed << 5
      return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    func add(_ start: Double, _ seconds: Double, pan: Float, _ sample: (Double) -> Float) {
      let s0 = Int(start * sr)
      for i in 0..<Int(seconds * sr) where s0 + i < n {
        let v = sample(Double(i) / sr)
        l[s0 + i] += v * (1 - pan)
        r[s0 + i] += v * (1 + pan)
      }
    }

    // Bass: a 5-in-16 Euclidean rhythm, root and fifth of A.
    let bassSteps: Set<Int> = [0, 3, 6, 10, 13]
    for step in 0..<(bars * 16) {
      let t = Double(step) * sixteenth
      if step % 4 == 0 {  // kick: pitch-swept sine
        add(t, 0.25, pan: 0) { u in
          let f = 45 + 120 * exp(-u * 30)
          return Float(sin(2 * .pi * f * u) * exp(-u * 9)) * 0.9
        }
      }
      if step % 8 == 4 {  // clap: filtered-ish noise burst
        add(t, 0.15, pan: 0.15) { u in noise() * Float(exp(-u * 30)) * 0.35 }
      }
      if step % 2 == 1 {  // hat
        add(t, 0.05, pan: -0.3) { u in noise() * Float(exp(-u * 90)) * 0.18 }
      }
      if bassSteps.contains(step % 16) {
        let f = step % 16 == 10 ? 82.41 : 55.0  // E2 / A1
        add(t, sixteenth * 1.8, pan: 0) { u in
          let saw = 2 * (u * f - floor(u * f + 0.5))
          return Float(saw * exp(-u * 6)) * 0.3
        }
      }
    }
    return SampleBuffer(left: l, right: r, sampleRate: sr)
  }
}
