import Accelerate
import Foundation
import Synchronization

// Chrome's OscillatorNode, for the pitch shifter's LFOs (third_party/blink/renderer/modules/
// webaudio/periodic_wave_handler.cc and oscillator_handler.cc): a waveform is a set of
// band-limited wavetables — `ranges` of them, three per octave, each keeping fewer partials —
// all scaled by the peak of the fullest one; a sample is read from the two tables bracketing the
// fundamental, interpolated within each (linear, or 3- / 5-point Lagrange at low rates) and then
// between them. The pitch shifter's sawtooths reset abruptly; how Chrome band-limits that reset is
// part of how Tone's PitchShift sounds, so it is ported rather than idealised
// (`MasterChainChromeTests` compares with Chrome). Tables are built once per sample rate, off the
// audio thread, and shared.

/// The wavetables of one waveform at one sample rate (immutable once built).
final class PeriodicWave: @unchecked Sendable {
  /// `PeriodicWaveSize()`.
  let size: Int
  /// `NumberOfRanges()`.
  let ranges: Int
  /// `lowest_fundamental_frequency_` = nyquist / (size / 2).
  let lowestFundamental: Float
  /// `RateScale()` = size / sample rate.
  let rateScale: Float
  /// `ranges` tables of `size` samples, range 0 (all partials) first.
  let tables: UnsafeMutablePointer<Float>

  /// `real` / `imag` are the cosine / sine coefficients from index 0 (DC), as handed to
  /// `createPeriodicWave`; normalised as Chrome does (by the peak of range 0).
  init(sampleRate: Double, real: [Float], imag: [Float]) {
    let sr = Float(sampleRate)
    size = sampleRate <= 24000 ? 2048 : (sampleRate <= 88200 ? 4096 : 16384)
    ranges = Int(0.5 + 3 * log2f(Float(size)))
    let half = size / 2
    lowestFundamental = 0.5 * sr / Float(half)
    rateScale = Float(size) / sr
    tables = .allocate(capacity: ranges * size)
    let components = min(real.count, half)
    // inverse DFT: x[k] = Σ_n a_n cos(2πnk/N) + b_n sin(2πnk/N)
    let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE)!
    defer { vDSP_DFT_DestroySetup(setup) }
    var inRe = [Float](repeating: 0, count: size)
    var inIm = [Float](repeating: 0, count: size)
    var outRe = [Float](repeating: 0, count: size)
    var outIm = [Float](repeating: 0, count: size)
    var scale: Float = 1
    for r in 0..<ranges {
      // NumberOfPartialsForRange
      let centsToCull = Float(r) * (1200 / 3)
      let culling = Float(pow(2.0, Double(-centsToCull / 1200)))
      let partials = Int(culling * Float(half))
      for i in 0..<size {
        inRe[i] = 0
        inIm[i] = 0
      }
      // bins 1 ..< min(components, partials + 1); DC and Nyquist cleared
      for n in 1..<min(components, partials + 1) {
        // X[n] = (a − i b) / 2, X[N − n] = conj(X[n])
        inRe[n] = real[n] / 2
        inIm[n] = -imag[n] / 2
        inRe[size - n] = real[n] / 2
        inIm[size - n] = imag[n] / 2
      }
      vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
      let t = tables + r * size
      for k in 0..<size { t[k] = outRe[k] }
      if r == 0 {
        var peak: Float = 0
        for k in 0..<size { peak = max(peak, abs(t[k])) }
        if peak > 0 { scale = 1 / peak }
      }
      for k in 0..<size { t[k] *= scale }
    }
  }

  deinit { tables.deallocate() }

  /// `WaveDataForFundamentalFrequency`: the two tables (fewer partials, more partials) and the
  /// factor between them.
  func tablesFor(fundamental f: Float) -> (lower: Int, higher: Int, factor: Float) {
    let ff = abs(f)
    let ratio: Float = ff > 0 ? ff / lowestFundamental : 0.5
    let cents = log2f(ratio) * 1200
    var pitchRange = 1 + cents / (1200 / 3)
    pitchRange = max(0, min(pitchRange, Float(ranges - 1)))
    let r1 = Int(pitchRange)
    let r2 = r1 < ranges - 1 ? r1 + 1 : r1
    return (r2, r1, pitchRange - Float(r1))
  }

  // MARK: the three waveforms of Tone's PitchShift, per sample rate

  /// Chrome's built-in "sawtooth" (`GenerateBasicWaveform`, coefficients in float).
  static func sawtooth(sampleRate: Double) -> PeriodicWave { cached(sampleRate, 0) }
  /// Tone's sawtooth at phase 180 (Oscillator.js `_getRealImaginary`, a custom PeriodicWave).
  static func sawtooth180(sampleRate: Double) -> PeriodicWave { cached(sampleRate, 1) }
  /// Tone's triangle at phase 90.
  static func triangle90(sampleRate: Double) -> PeriodicWave { cached(sampleRate, 2) }

  private static let cache = Mutex<[String: PeriodicWave]>([:])

  private static func cached(_ sr: Double, _ which: Int) -> PeriodicWave {
    let key = "\(sr)/\(which)"
    return cache.withLock { c in
      if let w = c[key] { return w }
      let w = make(sr, which)
      c[key] = w
      return w
    }
  }

  private static func make(_ sr: Double, _ which: Int) -> PeriodicWave {
    if which == 0 {
      // GenerateBasicWaveform(SAWTOOTH): half-size coefficients, b = pi_factor · ±1 (float)
      let size = sr <= 24000 ? 2048 : (sr <= 88200 ? 4096 : 16384)
      let half = size / 2
      var imag = [Float](repeating: 0, count: half)
      for n in 1..<half {
        let piFactor = 2 / (Float(n) * Float.pi)
        imag[n] = piFactor * (n & 1 == 1 ? 1 : -1)
      }
      return PeriodicWave(sampleRate: sr, real: [Float](repeating: 0, count: half), imag: imag)
    }
    // Tone: fftSize 4096 → 2048 coefficients; real[n] = −b·sin(nφ), imag[n] = b·cos(nφ)
    let count = 2048
    let phase = which == 1 ? Double.pi : Double.pi / 2
    var real = [Float](repeating: 0, count: count)
    var imag = [Float](repeating: 0, count: count)
    for n in 1..<count {
      let piFactor = 2 / (Double(n) * Double.pi)
      let b: Double
      if which == 1 {
        b = piFactor * (n & 1 == 1 ? 1 : -1)
      } else {
        b = n & 1 == 1 ? 2 * (piFactor * piFactor) * (((n - 1) >> 1) & 1 == 1 ? -1 : 1) : 0
      }
      if b != 0 {
        real[n] = Float(-b * sin(phase * Double(n)))
        imag[n] = Float(b * cos(phase * Double(n)))
      }
    }
    return PeriodicWave(sampleRate: sr, real: real, imag: imag)
  }
}

/// One Chrome oscillator reading a `PeriodicWave` at a rate that changes only now and then.
struct WaveOscillator {
  /// `virtual_read_index` (0 ..< size).
  private(set) var index = 0.0
  private var incr: Float = 0
  private var lower = 0
  private var higher = 0
  private var factor: Float = 0

  /// The fundamental changed (`frequency * rate_scale`, the tables bracketing it).
  mutating func setFrequency(_ f: Double, _ wave: PeriodicWave) {
    let ff = Float(f)
    incr = ff * wave.rateScale
    (lower, higher, factor) = wave.tablesFor(fundamental: ff)
  }

  /// This sample's value, then advance (`DoInterpolation` and the read-index update).
  @inline(__always)
  mutating func next(_ wave: PeriodicWave) -> Double {
    let size = wave.size
    let mask = size - 1
    let lo = wave.tables + lower * size
    let hi = wave.tables + higher * size
    let i0 = Int(index)
    var sLo = 0.0
    var sHi = 0.0
    let step = abs(incr)
    if step >= 0.3 {
      let i1 = (i0 + 1) & mask
      let j0 = i0 & mask
      let f = Double(Float(index) - Float(i0))
      sHi = (1 - f) * Double(hi[j0]) + f * Double(hi[i1])
      sLo = (1 - f) * Double(lo[j0]) + f * Double(lo[i1])
    } else if step >= 0.16 {
      let t = index - Double(i0)
      let a0 = 0.5 * t * (t - 1)
      let a1 = 1 - t * t
      let a2 = 0.5 * t * (t + 1)
      let k0 = (i0 - 1) & mask
      let k1 = i0 & mask
      let k2 = (i0 + 1) & mask
      sLo = a0 * Double(lo[k0]) + a1 * Double(lo[k1]) + a2 * Double(lo[k2])
      sHi = a0 * Double(hi[k0]) + a1 * Double(hi[k1]) + a2 * Double(hi[k2])
    } else {
      let t = index - Double(i0)
      let t2 = t * t
      let a0 = t * (t2 - 1) * (t - 2) / 24
      let a1 = -t * (t - 1) * (t2 - 4) / 6
      let a2 = (t2 - 1) * (t2 - 4) / 4
      let a3 = -t * (t + 1) * (t2 - 4) / 6
      let a4 = t * (t2 - 1) * (t + 2) / 24
      let k0 = (i0 - 2) & mask
      let k1 = (i0 - 1) & mask
      let k2 = i0 & mask
      let k3 = (i0 + 1) & mask
      let k4 = (i0 + 2) & mask
      sLo =
        a0 * Double(lo[k0]) + a1 * Double(lo[k1]) + a2 * Double(lo[k2]) + a3 * Double(lo[k3])
        + a4 * Double(lo[k4])
      sHi =
        a0 * Double(hi[k0]) + a1 * Double(hi[k1]) + a2 * Double(hi[k2]) + a3 * Double(hi[k3])
        + a4 * Double(hi[k4])
    }
    let sample = Float((1 - Double(factor)) * sHi + Double(factor) * sLo)
    index += Double(incr)
    index -= (index * (1.0 / Double(size))).rounded(.down) * Double(size)
    return Double(sample)
  }
}
