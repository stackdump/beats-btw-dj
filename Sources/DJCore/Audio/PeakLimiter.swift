import Foundation
import Synchronization

/// A stereo-linked lookahead peak limiter: the last stage of a net deck on the app's path
/// (`WaveOptions.master == "limit"`, set by `WaveOptions.extended`), after the runner, the brake
/// and the master chain, before the deck's EQ, filter and fader. The track's loudness gain
/// (`Loudness`) puts it at the app's reference level (`LevelMatch.referenceLUFS`); this only
/// catches the peaks that would cross `ceilingDB`, so the drums keep their attack instead of
/// going through beats' `tanh` curve (which bends everything above about −10 dBFS).
///
/// Per sample: the gain each incoming sample needs (`ceiling / |x|`, 1 under it), the minimum of
/// that over the lookahead window (a monotonic queue), then two envelopes — a fast one that
/// falls at once and recovers in `fastReleaseSeconds` (a hat or a snare's attack: a short dip,
/// no pumping on sixteenths), and a slow one that falls over `slowAttackSeconds` and recovers
/// in `slowReleaseSeconds` (a bass note or a dense drop held over: a steady gain, no ripple
/// within a low note's cycle) — the lower of the two, then a moving average over the
/// lookahead, applied to the sample `lookahead` behind. The average of values that are all at most the gain a peak
/// needs is at most that gain, and it reaches it exactly as the peak comes out, so the output
/// never crosses the ceiling (clamped as well, for rounding) and the gain moves smoothly into
/// it (no click). Under the ceiling the output is the input, `lookahead` samples late.
///
/// Real-time safe: every buffer is allocated at init; `process` allocates, locks and frees
/// nothing (`PeakLimiterRealTimeTests`). One instance per deck; `process` from one thread.
public final class PeakLimiter: @unchecked Sendable {
  /// Sample-peak ceiling: −1 dBFS leaves room for inter-sample peaks and the deck's EQ boost.
  public static let ceilingDB = -1.0
  public static let lookaheadSeconds = 0.0015
  public static let fastReleaseSeconds = 0.015
  public static let slowAttackSeconds = 0.03
  public static let slowReleaseSeconds = 0.25

  public let sampleRate: Double
  /// Samples of delay (the lookahead).
  public let lookahead: Int
  private let ceiling: Double
  private let fastRelease: Double
  private let slowAttack: Double
  private let slowRelease: Double
  private let delayL: UnsafeMutablePointer<Float>
  private let delayR: UnsafeMutablePointer<Float>
  private var delayPos = 0
  // sliding minimum over the last `lookahead + 1` needed gains
  private let queueCap: Int
  private let qValue: UnsafeMutablePointer<Double>
  private let qIndex: UnsafeMutablePointer<Int>
  private var qHead = 0
  private var qCount = 0
  // moving average of the envelope over `lookahead` samples
  private let box: UnsafeMutablePointer<Double>
  private var boxPos = 0
  private var boxSum: Double
  private var fast = 1.0
  private var slow = 1.0
  private var n = 0
  // gain-reduction statistics (offline measurement, `djctl render`): samples per 0.1 dB of GR
  public static let histogramBins = 301
  private let histogram: UnsafeMutablePointer<Int>
  /// The deepest gain reduction (dB, ≥ 0) of the last block: what a meter shows.
  private let blockGRBits = Atomic<UInt64>(0.0.bitPattern)

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    lookahead = max(1, Int((Self.lookaheadSeconds * sampleRate).rounded()))
    ceiling = pow(10, Self.ceilingDB / 20)
    fastRelease = exp(-1 / (Self.fastReleaseSeconds * sampleRate))
    slowAttack = 1 - exp(-1 / (Self.slowAttackSeconds * sampleRate))
    slowRelease = 1 - exp(-1 / (Self.slowReleaseSeconds * sampleRate))
    delayL = .allocate(capacity: lookahead)
    delayR = .allocate(capacity: lookahead)
    delayL.initialize(repeating: 0, count: lookahead)
    delayR.initialize(repeating: 0, count: lookahead)
    queueCap = lookahead + 2
    qValue = .allocate(capacity: queueCap)
    qIndex = .allocate(capacity: queueCap)
    qValue.initialize(repeating: 1, count: queueCap)
    qIndex.initialize(repeating: 0, count: queueCap)
    box = .allocate(capacity: lookahead)
    box.initialize(repeating: 1, count: lookahead)
    boxSum = Double(lookahead)
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
  }

  /// Limit `frames` samples of `left` (and `right`) in place. Audio thread.
  public func process(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int
  ) {
    var deepest = 1.0
    let c = Float(ceiling)
    for i in 0..<frames {
      let xl = left[i]
      let xr = right?[i] ?? xl
      let x = Double(max(abs(xl), abs(xr)))
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
      while qIndex[qHead] < n - lookahead {
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
      if boxPos == lookahead {
        boxPos = 0
        // re-add exactly once per window, so the running sum never drifts
        var s = 0.0
        for k in 0..<lookahead { s += box[k] }
        boxSum = s
      }
      let g = min(1, boxSum / Double(lookahead))
      if g < deepest { deepest = g }
      let gf = Float(g)
      let ol = delayL[delayPos]
      let or = delayR[delayPos]
      delayL[delayPos] = xl
      delayR[delayPos] = xr
      delayPos = delayPos + 1 == lookahead ? 0 : delayPos + 1
      left[i] = min(c, max(-c, ol * gf))
      right?[i] = min(c, max(-c, or * gf))
      let bin = g >= 1 ? 0 : min(Self.histogramBins - 1, Int(-200 * log10(g)))
      histogram[bin] += 1
      n += 1
    }
    blockGRBits.store((deepest >= 1 ? 0 : -20 * log10(deepest)).bitPattern, ordering: .relaxed)
  }

  /// Deepest gain reduction of the last block, dB (0 = not limiting). Any thread.
  public var gainReductionDB: Double {
    Double(bitPattern: blockGRBits.load(ordering: .relaxed))
  }

  /// Gain reduction over everything processed since the last `resetStatistics`: the dB at
  /// `percentiles` (0…1) of the samples, the maximum, and the share of samples limited by more
  /// than 0.1 dB. Not for the audio thread (read it when nothing is rendering).
  public func statistics(percentiles: [Double] = [0.5, 0.95, 0.99]) -> GainReductionStats {
    var total = 0
    for b in 0..<Self.histogramBins { total += histogram[b] }
    guard total > 0 else { return GainReductionStats() }
    var out = GainReductionStats()
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
  }
}

/// `PeakLimiter.statistics`.
public struct GainReductionStats: Sendable, Equatable {
  /// The dB at each percentile asked for, in order (0 = not limiting there).
  public var percentilesDB: [Double] = []
  public var maxDB = 0.0
  /// Share of samples limited by more than 0.1 dB.
  public var limitedShare = 0.0
}

