import Foundation

/// A constant-tempo beat grid over a sample buffer.
public struct BeatGrid: Equatable, Sendable {
  public var bpm: Double
  /// Sample index of a beat (the first one at or after 0).
  public var offset: Double
  /// 0…1-ish: how clearly the tempo stood out (peak over mean of the autocorrelation).
  public var confidence: Double

  public init(bpm: Double, offset: Double = 0, confidence: Double = 1) {
    self.bpm = bpm
    self.offset = offset
    self.confidence = confidence
  }

  public func samplesPerBeat(sampleRate: Double) -> Double { sampleRate * 60 / bpm }
}

/// Finds the tempo and beat phase of a loop or track from its onsets.
///
///  1. an energy-onset envelope at 200 Hz (half-wave rectified energy rise);
///  2. its autocorrelation, summed over a few beat multiples with a gentle prior toward
///     dance tempos, picks the tempo to ~1 %;
///  3. a comb filter swept finely over tempo and phase refines both.
public enum BPMAnalyzer {
  public static func analyze(_ buffer: SampleBuffer, range: ClosedRange<Double> = 70...180)
    -> BeatGrid?
  {
    let sr = buffer.sampleRate
    let hop = max(1, Int(sr / 200))
    let n = buffer.length / hop
    guard n > 400 else { return nil }  // < 2 s: nothing to measure

    // Energy per hop, then its half-wave-rectified rise.
    var energy = [Double](repeating: 0, count: n)
    for i in 0..<n {
      var sum = 0.0
      let base = i * hop
      for j in 0..<hop {
        let l = Double(buffer.left[base + j])
        let r = Double(buffer.right[base + j])
        let m = (l + r) * 0.5
        sum += m * m
      }
      energy[i] = (sum / Double(hop)).squareRoot()
    }
    var onset = [Double](repeating: 0, count: n)
    for i in 1..<n { onset[i] = max(0, energy[i] - energy[i - 1]) }
    let mean = onset.reduce(0, +) / Double(n)
    guard mean > 1e-9 else { return nil }
    let centred = onset.map { $0 - mean }

    let envRate = sr / Double(hop)
    let lagMin = Int(envRate * 60 / range.upperBound)
    let lagMax = min(n / 2, Int(envRate * 60 / range.lowerBound))
    guard lagMin >= 2, lagMax > lagMin else { return nil }

    // Autocorrelation up to 4 beats of the slowest tempo.
    let maxLag = min(n - 1, lagMax * 4)
    var ac = [Double](repeating: 0, count: maxLag + 1)
    for lag in 1...maxLag {
      var s = 0.0
      for i in 0..<(n - lag) { s += centred[i] * centred[i + lag] }
      ac[lag] = s / Double(n - lag)
    }
    func acAt(_ lag: Double) -> Double {
      let l = Int(lag)
      guard l >= 1, l + 1 <= maxLag else { return 0 }
      let f = lag - Double(l)
      return ac[l] + (ac[l + 1] - ac[l]) * f
    }

    var best = (score: -Double.infinity, lag: 0)
    for lag in lagMin...lagMax {
      var s = acAt(Double(lag))
      s += 0.5 * acAt(Double(lag * 2))
      s += 0.25 * acAt(Double(lag * 4))
      let bpm = envRate * 60 / Double(lag)
      let prior = exp(-0.5 * pow(log2(bpm / 125) / 0.7, 2))
      s *= 0.6 + 0.4 * prior
      if s > best.score { best = (s, lag) }
    }
    guard best.score > 0 else { return nil }
    let acMean = ac[lagMin...lagMax].reduce(0, +) / Double(lagMax - lagMin + 1)
    let coarseBPM = envRate * 60 / Double(best.lag)

    // Comb refinement: tempo ±2.5 % in 0.05 bpm steps, every phase.
    func interp(_ x: Double) -> Double {
      let i = Int(x)
      guard i >= 0, i + 1 < n else { return 0 }
      return onset[i] + (onset[i + 1] - onset[i]) * (x - Double(i))
    }
    var fine = (score: -Double.infinity, bpm: coarseBPM, phase: 0.0)
    var bpm = coarseBPM * 0.975
    while bpm <= coarseBPM * 1.025 {
      let period = envRate * 60 / bpm
      var phase = 0.0
      while phase < period {
        var s = 0.0
        var x = phase
        while x < Double(n - 1) {
          s += interp(x)
          x += period
        }
        if s > fine.score { fine = (s, bpm, phase) }
        phase += 0.5
      }
      bpm += 0.05
    }
    // Onset i = energy rose within hop i, so the event sits mid-hop.
    let offset = (fine.phase + 0.5) * Double(hop)
    let beat = sr * 60 / fine.bpm
    return BeatGrid(
      bpm: fine.bpm, offset: offset.truncatingRemainder(dividingBy: beat),
      confidence: acMean > 0 ? best.score / (acMean * 1.0 + 1e-12) : 0)
  }
}
