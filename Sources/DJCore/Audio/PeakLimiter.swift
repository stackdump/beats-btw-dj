import Foundation
import Synchronization

/// A stereo-linked lookahead true-peak limiter: the last stage of a net deck on the app's path
/// (`WaveOptions.master == "limit"`, set by `WaveOptions.extended`), after the runner, the brake
/// and the master chain, before the deck's EQ, filter and fader. The track's loudness gain
/// (`Loudness`) puts it at the app's reference level (`LevelMatch.referenceLUFS`); this only
/// catches the peaks that would cross `ceilingDB` (dBTP), so the drums keep their attack instead
/// of going through beats' `tanh` curve (which bends everything above about −10 dBFS).
///
/// Per sample: the level each incoming sample needs held — the larger of BS.1770's 4×
/// oversampled true peak (`TruePeak.interpolatedPeak`, both channels, `TruePeak.delay` samples
/// behind) and the sample itself at the FIR's centre — and the gain that needs (`ceiling / tp`,
/// 1 under it); the minimum of that over the window (a monotonic queue), then two envelopes — a
/// fast one that falls at once and recovers in `fastReleaseSeconds` (a hat or a snare's attack:
/// a short dip, no pumping on sixteenths), and a slow one that falls over `slowAttackSeconds`
/// and recovers in `slowReleaseSeconds` (a bass note or a dense drop held over: a steady gain,
/// no ripple within a low note's cycle) — the lower of the two, then a moving average over
/// `lookaheadSeconds`, applied to the sample `lookahead` behind. The average of values that are
/// all at most the gain a peak needs is at most that gain, and the window is widened by the
/// FIR's reach on both sides (`lookahead` = the moving average + 2 × `TruePeak.delay`), so every
/// sample the interpolation between two samples reads is held at least as far down as the peak
/// needs: the output's true peak stays under the ceiling (less `ceilingMarginDB`, for the gain's
/// slope across the FIR) and the gain moves smoothly into it (no click). Samples are clamped to
/// the ceiling as well, for rounding. Under the ceiling the output is the input, `lookahead`
/// samples late (1.75 ms at 48 kHz, not compensated: sample decks play 0, under any flam).
///
/// Real-time safe: every buffer is allocated at init; `process` allocates, locks and frees
/// nothing (`PeakLimiterRealTimeTests`). One instance per deck; `process` from one thread.
public final class PeakLimiter: @unchecked Sendable {
  /// True-peak ceiling (dBTP): −1 leaves room for the deck's EQ boost and a lossy encode.
  public static let ceilingDB = -1.0
  /// Held under the ceiling by this much: the gain moves across the FIR's 12 taps.
  public static let ceilingMarginDB = 0.05
  public static let lookaheadSeconds = 0.0015
  public static let fastReleaseSeconds = 0.015
  public static let slowAttackSeconds = 0.03
  public static let slowReleaseSeconds = 0.25

  public let sampleRate: Double
  /// Samples of delay: the moving average's length plus the FIR's reach on both sides.
  public let lookahead: Int
  /// `lookahead` in seconds: how late a net deck's audio is against its transport.
  public var latencySeconds: Double { Double(lookahead) / sampleRate }
  /// The moving average's length (samples).
  private let window: Int
  /// The needed gains' minimum spans this many samples back (`window` + 2 × FIR delay).
  private let span: Int
  private let ceiling: Double
  private let fastRelease: Double
  private let slowAttack: Double
  private let slowRelease: Double
  private let delayL: UnsafeMutablePointer<Float>
  private let delayR: UnsafeMutablePointer<Float>
  private var delayPos = 0
  // the true-peak FIR: coefficients, and the last `taps` inputs twice over (a read never
  // wraps) per channel, for the input (`inL/inR`) and the output (`outL/outR`, the meter)
  private let coefficients: UnsafeMutablePointer<Double>
  private let inL: UnsafeMutablePointer<Double>
  private let inR: UnsafeMutablePointer<Double>
  private let outL: UnsafeMutablePointer<Double>
  private let outR: UnsafeMutablePointer<Double>
  private var head = 0
  // sliding minimum over the last `span + 1` needed gains
  private let queueCap: Int
  private let qValue: UnsafeMutablePointer<Double>
  private let qIndex: UnsafeMutablePointer<Int>
  private var qHead = 0
  private var qCount = 0
  // moving average of the envelope over `window` samples
  private let box: UnsafeMutablePointer<Double>
  private var boxPos = 0
  private var boxSum: Double
  private var fast = 1.0
  private var slow = 1.0
  private var n = 0
  // gain-reduction statistics (offline measurement, `djctl render`): samples per 0.1 dB of GR
  public static let histogramBins = 301
  private let histogram: UnsafeMutablePointer<Int>
  /// The output's true peak since `resetStatistics`, linear.
  private var outputPeak = 0.0
  /// The deepest gain reduction (dB, ≥ 0) of the last block: what a meter shows.
  private let blockGRBits = Atomic<UInt64>(0.0.bitPattern)

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    window = max(1, Int((Self.lookaheadSeconds * sampleRate).rounded()))
    lookahead = window + 2 * TruePeak.delay
    span = window + 2 * TruePeak.delay
    ceiling = pow(10, (Self.ceilingDB - Self.ceilingMarginDB) / 20)
    fastRelease = exp(-1 / (Self.fastReleaseSeconds * sampleRate))
    slowAttack = 1 - exp(-1 / (Self.slowAttackSeconds * sampleRate))
    slowRelease = 1 - exp(-1 / (Self.slowReleaseSeconds * sampleRate))
    delayL = .allocate(capacity: lookahead)
    delayR = .allocate(capacity: lookahead)
    delayL.initialize(repeating: 0, count: lookahead)
    delayR.initialize(repeating: 0, count: lookahead)
    let taps = TruePeak.taps
    coefficients = .allocate(capacity: 4 * taps)
    coefficients.initialize(from: TruePeak.flatCoefficients, count: 4 * taps)
    inL = .allocate(capacity: 2 * taps)
    inR = .allocate(capacity: 2 * taps)
    outL = .allocate(capacity: 2 * taps)
    outR = .allocate(capacity: 2 * taps)
    for h in [inL, inR, outL, outR] { h.initialize(repeating: 0, count: 2 * taps) }
    queueCap = span + 2
    qValue = .allocate(capacity: queueCap)
    qIndex = .allocate(capacity: queueCap)
    qValue.initialize(repeating: 1, count: queueCap)
    qIndex.initialize(repeating: 0, count: queueCap)
    box = .allocate(capacity: window)
    box.initialize(repeating: 1, count: window)
    boxSum = Double(window)
    histogram = .allocate(capacity: Self.histogramBins)
    histogram.initialize(repeating: 0, count: Self.histogramBins)
  }

  deinit {
    delayL.deallocate()
    delayR.deallocate()
    qValue.deallocate()
    qIndex.deallocate()
    box.deallocate()
    histogram.deallocate()
    coefficients.deallocate()
    for h in [inL, inR, outL, outR] { h.deallocate() }
  }

  /// Limit `frames` samples of `left` (and `right`) in place. Audio thread.
  public func process(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int
  ) {
    var deepest = 1.0
    let c = Float(ceiling)
    let taps = TruePeak.taps
    let centre = TruePeak.delay
    let stereo = right != nil
    var outPeak = outputPeak
    for i in 0..<frames {
      let xl = left[i]
      let xr = right?[i] ?? xl
      head = head == 0 ? taps - 1 : head - 1
      inL[head] = Double(xl)
      inL[head + taps] = Double(xl)
      inR[head] = Double(xr)
      inR[head + taps] = Double(xr)
      // the true peak around the sample `centre` behind, and that sample itself
      var x = max(TruePeak.interpolatedPeak(coefficients, inL + head), abs(inL[head + centre]))
      if stereo {
        x = max(x, TruePeak.interpolatedPeak(coefficients, inR + head), abs(inR[head + centre]))
      }
      let need = x > ceiling ? ceiling / x : 1
      // the window's minimum: drop larger values from the back, stale ones from the front
      while qCount > 0 {
        let back = (qHead + qCount - 1) % queueCap
        if qValue[back] >= need { qCount -= 1 } else { break }
      }
      let slot = (qHead + qCount) % queueCap
      qValue[slot] = need
      qIndex[slot] = n
      qCount += 1
      while qIndex[qHead] < n - span {
        qHead = qHead + 1 == queueCap ? 0 : qHead + 1
        qCount -= 1
      }
      let m = qValue[qHead]
      fast = m < fast ? m : m + (fast - m) * fastRelease
      slow += (m - slow) * (m < slow ? slowAttack : slowRelease)
      let env = min(fast, slow)
      boxSum += env - box[boxPos]
      box[boxPos] = env
      boxPos += 1
      if boxPos == window {
        boxPos = 0
        // re-add exactly once per window, so the running sum never drifts
        var s = 0.0
        for k in 0..<window { s += box[k] }
        boxSum = s
      }
      let g = min(1, boxSum / Double(window))
      if g < deepest { deepest = g }
      let gf = Float(g)
      let ol = delayL[delayPos]
      let or = delayR[delayPos]
      delayL[delayPos] = xl
      delayR[delayPos] = xr
      delayPos = delayPos + 1 == lookahead ? 0 : delayPos + 1
      let yl = min(c, max(-c, ol * gf))
      let yr = min(c, max(-c, or * gf))
      left[i] = yl
      right?[i] = yr
      // the output's true peak (what `statistics` reports)
      outL[head] = Double(yl)
      outL[head + taps] = Double(yl)
      outR[head] = Double(yr)
      outR[head + taps] = Double(yr)
      outPeak = max(outPeak, TruePeak.interpolatedPeak(coefficients, outL + head))
      if stereo { outPeak = max(outPeak, TruePeak.interpolatedPeak(coefficients, outR + head)) }
      let bin = g >= 1 ? 0 : min(Self.histogramBins - 1, Int(-200 * log10(g)))
      histogram[bin] += 1
      n += 1
    }
    outputPeak = outPeak
    blockGRBits.store((deepest >= 1 ? 0 : -20 * log10(deepest)).bitPattern, ordering: .relaxed)
  }

  /// Deepest gain reduction of the last block, dB (0 = not limiting). Any thread.
  public var gainReductionDB: Double {
    Double(bitPattern: blockGRBits.load(ordering: .relaxed))
  }

  /// Gain reduction over everything processed since the last `resetStatistics`: the dB at
  /// `percentiles` (0…1) of the samples, the maximum, the share of samples limited by more
  /// than 0.1 dB, and the output's true peak. Not for the audio thread (read it when nothing is rendering).
  public func statistics(percentiles: [Double] = [0.5, 0.95, 0.99]) -> GainReductionStats {
    var total = 0
    for b in 0..<Self.histogramBins { total += histogram[b] }
    guard total > 0 else { return GainReductionStats() }
    var out = GainReductionStats()
    out.truePeakDBTP = outputPeak > 0 ? 20 * log10(outputPeak) : -200
    var maxBin = 0
    for b in 0..<Self.histogramBins where histogram[b] > 0 { maxBin = b }
    out.maxDB = Double(maxBin + 1) / 10
    out.limitedShare = Double(total - histogram[0]) / Double(total)
    for p in percentiles {
      let want = Int((p * Double(total)).rounded(.up))
      var seen = 0
      var at = 0
      for b in 0..<Self.histogramBins {
        seen += histogram[b]
        if seen >= want {
          at = b
          break
        }
      }
      out.percentilesDB.append(at == 0 ? 0 : Double(at) / 10)
    }
    return out
  }

  public func resetStatistics() {
    histogram.update(repeating: 0, count: Self.histogramBins)
    outputPeak = 0
  }
}

/// `PeakLimiter.statistics`.
public struct GainReductionStats: Sendable, Equatable {
  /// The dB at each percentile asked for, in order (0 = not limiting there).
  public var percentilesDB: [Double] = []
  public var maxDB = 0.0
  /// Share of samples limited by more than 0.1 dB.
  public var limitedShare = 0.0
  /// The limiter's output true peak (BS.1770 4×, dBTP; −200 = silence): ≤ `ceilingDB`.
  public var truePeakDBTP = -200.0

  /// `djctl render`'s `limiter` report (the default percentiles: P50 / P95 / P99, and
  /// `truePeakDBTP`).
  public var dictionary: [String: Any] {
    var d: [String: Any] = [
      "grMaxDB": maxDB, "limitedShare": round3(limitedShare), "truePeakDBTP": round3(truePeakDBTP),
    ]
    for (name, db) in zip(["grP50DB", "grP95DB", "grP99DB"], percentilesDB) { d[name] = db }
    return d
  }
}
