import Foundation

/// The pitch of a held note, offline (`djctl measure --note`, reference files): what the
/// sampler's load-time check hears (`pitchClassError`, which this wraps and leaves where it is,
/// so `normalize`'s picks don't move), plus a period estimate that needs no note to compare to.
public enum PitchMeasure {
  public struct Reading: Sendable, Equatable {
    /// The strongest partial near the note's pitch class, Hz (0 for silence).
    public var hz: Double
    /// How far it sits from the note's pitch class, cents (whatever octave it speaks in).
    public var cents: Double
    /// The octave it speaks in, against the note (a glockenspiel reads +2).
    public var octave: Int
    /// That partial's amplitude, linear (a full-scale sine reads about 1; silence 0).
    public var level: Double
  }

  /// Fundamental of `samples` (mono, the first 8192 frames), Hz, by YIN's cumulative-mean
  /// normalised difference with a parabolic fit, 30 Hz – 2 kHz. nil for silence or no clear
  /// period (noise, a full mix).
  public static func fundamental(_ samples: [Float], sampleRate sr: Double) -> Double? {
    let n = min(samples.count, 8192)
    let minLag = max(2, Int(sr / 2000))
    let maxLag = min(n / 2, Int(sr / 30))
    guard sr > 0, maxLag > minLag + 2 else { return nil }
    var energy = 0.0
    for i in 0..<n { energy += Double(samples[i]) * Double(samples[i]) }
    guard energy / Double(n) > 1e-12 else { return nil }
    let w = n - maxLag - 1
    var d = [Double](repeating: 1, count: maxLag + 2)
    var running = 0.0
    for tau in 1...(maxLag + 1) {
      var s = 0.0
      for i in 0..<w {
        let e = Double(samples[i]) - Double(samples[i + tau])
        s += e * e
      }
      running += s
      d[tau] = running > 0 ? s * Double(tau) / running : 1
    }
    var pick: Int?
    var tau = minLag
    while tau <= maxLag {
      if d[tau] < 0.1 {
        while tau + 1 <= maxLag && d[tau + 1] < d[tau] { tau += 1 }
        pick = tau
        break
      }
      tau += 1
    }
    if pick == nil, let m = (minLag...maxLag).min(by: { d[$0] < d[$1] }), d[m] < 0.3 { pick = m }
    guard let t = pick else { return nil }
    let (a, b, c) = (d[t - 1], d[t], d[t + 1])
    let den = a - 2 * b + c
    let shift = den != 0 ? max(-1, min(1, 0.5 * (a - c) / den)) : 0
    return sr / (Double(t) + shift)
  }

  /// Where `samples` (a held `note`, mono) sits against that note: the sampler's own check
  /// (`pitchClassError`: the strongest partial within ±100 cents of the note in octaves −2…+3,
  /// 1-cent steps), with the partial's frequency and amplitude. Cost grows with the length:
  /// a second at 48 kHz is a few hundred milliseconds in a release build.
  public static func error(_ samples: [Float], note: Int, sampleRate sr: Double) -> Reading {
    let e = pitchClassError(samples[...], note: note, sampleRate: sr)
    guard e.level > 0, samples.count > 16 else {
      return Reading(hz: 0, cents: 0, octave: 0, level: 0)
    }
    // the Hann window's sum: a sine of amplitude A reads |X| = A · Σw / 2
    let sumW = Double(samples.count - 1) / 2
    let hz = 440 * pow(2, (Double(note + 12 * e.octave - 69) + e.cents / 100) / 12)
    return Reading(hz: hz, cents: e.cents, octave: e.octave, level: 2 * e.level.squareRoot() / sumW)
  }
}
