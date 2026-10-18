import Foundation

/// ITU-R BS.1770-4 Annex 2 true peak: each channel oversampled 4× through the annex's 48-tap
/// polyphase FIR (four phases of 12), the largest magnitude of what comes out, in dBTP. Catches
/// the peaks between samples that a sample-peak meter misses (an fs/4 sine at 45° reads 3 dB
/// over its samples). `TruePeak.Detector` is the streaming form, one per channel: a fixed
/// 12-sample history, nothing allocated per sample, so a limiter can run it on the audio thread
/// (its output lags the input by `delay` samples, the FIR's centre). `PeakLimiter` runs the
/// same FIR (`interpolatedPeak`) on its own buffers, to hold a true-peak ceiling.
public enum TruePeak {
  /// Taps per phase.
  public static let taps = 12
  /// Samples the oversampled output lags the input: the FIR's centre.
  public static let delay = 6
  /// `phases`, phase-major (4 × `taps`).
  public static let flatCoefficients: [Double] = phases.flatMap { $0 }

  /// The largest magnitude of the four oversampled outputs for one input: `coefficients` is
  /// `flatCoefficients`, `history[k]` the input `k` samples ago (`taps` of them, newest first).
  /// Allocates nothing.
  @inline(__always)
  public static func interpolatedPeak(
    _ coefficients: UnsafePointer<Double>, _ history: UnsafePointer<Double>
  ) -> Double {
    let n = taps
    var m = 0.0
    for p in 0..<4 {
      var y = 0.0
      for k in 0..<n { y += coefficients[p * n + k] * history[k] }
      m = max(m, abs(y))
    }
    return m
  }

  /// The annex's coefficients, phase by phase.
  static let phases: [[Double]] = [
    [
      0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875,
      0.1373291015625, 0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250,
      0.0148925781250, -0.0083007812500,
    ],
    [
      -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500,
      0.4650878906250, 0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625,
      0.0330810546875, -0.0189208984375,
    ],
    [
      -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125,
      0.7797851562500, 0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000,
      0.0292968750000, -0.0291748046875,
    ],
    [
      -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750,
      0.9721679687500, 0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125,
      0.0109863281250, 0.0017089843750,
    ],
  ]

  /// One channel's 4× oversampled peak, fed a sample at a time. Make it off the audio thread;
  /// `process` and `reset` then never allocate.
  public struct Detector {
    static let taps = TruePeak.taps
    private var coefficients: [Double]  // 4 × 12, phase-major
    // the last 12 inputs, twice over, so a read never wraps: newest at `head` and `head + 12`
    private var history: [Double]
    private var head = 0
    /// The largest magnitude seen since the last `reset`, linear.
    public private(set) var peak: Double = 0

    public init() {
      coefficients = TruePeak.flatCoefficients
      history = [Double](repeating: 0, count: 2 * Self.taps)
    }

    /// Takes one input sample; returns the largest magnitude of the four oversampled outputs
    /// it produces.
    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
      let n = Self.taps
      head = head == 0 ? n - 1 : head - 1
      history[head] = x
      history[head + n] = x
      let at = head
      let m = coefficients.withUnsafeBufferPointer { c in
        // h[head + k] is the input k samples ago
        history.withUnsafeBufferPointer { h in
          TruePeak.interpolatedPeak(c.baseAddress!, h.baseAddress! + at)
        }
      }
      peak = max(peak, m)
      return m
    }

    /// Back to silence: history cleared, `peak` 0.
    public mutating func reset() {
      for i in history.indices { history[i] = 0 }
      head = 0
      peak = 0
    }
  }

  /// True peak over both channels, linear (`right` nil = mono). The FIR's tail is flushed, so a
  /// peak in the last samples counts.
  public static func peak(left: [Float], right: [Float]?) -> Double {
    func channel(_ x: [Float]) -> Double {
      var d = Detector()
      for v in x { _ = d.process(Double(v)) }
      for _ in 0..<Detector.taps { _ = d.process(0) }
      return d.peak
    }
    return max(channel(left), right.map(channel) ?? 0)
  }

  /// True peak in dBTP; −200 for silence.
  public static func dbtp(left: [Float], right: [Float]?) -> Double {
    let p = peak(left: left, right: right)
    return p > 0 ? 20 * log10(p) : -200
  }
}
