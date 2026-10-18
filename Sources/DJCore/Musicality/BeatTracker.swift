import Accelerate
import Foundation

/// Tempo, beats and downbeats of a render (ROADMAP 6.1: a reference's section lengths are
/// counted in its bars). Offline, on the main thread or any worker; never the audio thread.
///
/// 1. Onset envelope: log-magnitude spectral flux (`frameSize` Hann frames every `hopSeconds`,
///    vDSP), half-wave rectified, minus a local mean. A second envelope from the bins under
///    `lowBandHz` (the kick) is kept for the downbeats.
/// 2. Tempo: autocorrelation of the envelope over 70–180 BPM, each lag scored with its first
///    harmonic (ac(L) + ac(2L): a beat repeats every two beats too) and weighted by a
///    log-Gaussian prior centred on 120 BPM (`priorOctaves` wide). Half and double tempo sit
///    about equally under that prior, so the double wins whenever ac(L/2) is at least
///    `doubleRatio` of ac(L) (dnb at 174, not 87). The peak is interpolated.
/// 3. Beats: Ellis' dynamic programme (2007): each frame's onset plus the best earlier beat
///    one period back, penalised by `tightness · log²(gap / period)`; backtracked from the best
///    beat in the last period. Offbeat bass and hats can outweigh the beat in the full band, so
///    the sequence is moved half a period when the low band (`lowBandHz`, the kick) says the
///    offbeat is stronger. The tempo is then refined by a least-squares line through the beats.
/// 4. Downbeats: of the four phases of the beat sequence, the one whose beats carry the most
///    low-band onset (the kick lands on one in four/four).
///
/// `confidence` (0…1) is the normalised harmonic score at the chosen period, (ac(L) + ac(2L)) /
/// 2·ac(0): a click track is near 1, noise near 0. Ground truth so far is our own synth renders
/// (BeatTrackerTests); real references will read less well.
public struct BeatTracker: Sendable {
  public static let minBPM = 70.0
  public static let maxBPM = 180.0
  public static let priorBPM = 120.0
  public static let priorOctaves = 1.0
  public static let hopSeconds = 0.005
  public static let lowBandHz = 150.0
  public static let tightness = 100.0
  /// How late the flux peak's frame centre reads an onset, seconds (measured on a click track).
  public static let onsetLatency = 0.016
  /// The double tempo wins when its autocorrelation is at least this share of the pick's.
  public static let doubleRatio = 0.75

  /// Tempo, BPM (refined from the beats).
  public var bpm = 0.0
  /// Beat times, seconds from the render's first sample.
  public var beats: [Double] = []
  /// Downbeat times (every fourth beat, from the strongest low-band phase).
  public var downbeats: [Double] = []
  /// Index in `beats` of the first downbeat (0…3).
  public var downbeatPhase = 0
  /// How periodic the onsets are at `bpm`, 0…1.
  public var confidence = 0.0

  public init(left: [Float], right: [Float], sampleRate sr: Double) {
    let n = min(left.count, right.count)
    var mono = [Float](repeating: 0, count: n)
    var h: Float = 0.5
    vDSP_vasm(left, 1, right, 1, &h, &mono, 1, vDSP_Length(n))
    self.init(mono: mono, sampleRate: sr)
  }

  public init(mono x: [Float], sampleRate sr: Double) {
    guard sr > 0 else { return }
    let hop = max(1, Int((sr * Self.hopSeconds).rounded()))
    let fps = sr / Double(hop)
    let env = Self.onsets(x, sampleRate: sr, hop: hop)
    guard env.full.count > Int(fps * 4) else { return }
    let full = Self.normalise(env.full, fps: fps)

    // tempo: autocorrelation with its first harmonic (a beat repeats at two beats too),
    // prior-weighted
    let minLag = Int((60 / Self.maxBPM * fps).rounded(.down))
    let maxLag = Int((60 / Self.minBPM * fps).rounded(.up))
    guard full.count > maxLag * 4 else { return }
    let ac = Self.autocorrelation(full, maxLag: 2 * maxLag + 2)
    guard ac[0] > 0 else { return }
    var best = minLag
    var bestScore = -Double.infinity
    for lag in minLag...maxLag {
      let bpm = 60 * fps / Double(lag)
      let o = log2(bpm / Self.priorBPM) / Self.priorOctaves
      let score = (ac[lag] + ac[2 * lag]) * exp(-0.5 * o * o)
      if score > bestScore {
        bestScore = score
        best = lag
      }
    }
    // half and double tempo sit equally under the prior: take the faster pulse when it is
    // nearly as periodic
    while true {
      let h = Int((Double(best) / 2).rounded())
      guard h - 1 >= minLag else { break }
      let lag = (h - 1...h + 1).max { ac[$0] < ac[$1] }!
      guard ac[lag] >= Self.doubleRatio * ac[best] else { break }
      best = lag
    }
    var period = Double(best)
    if best > 1 {
      let a = ac[best - 1]
      let b = ac[best]
      let c = ac[best + 1]
      let d = a - 2 * b + c
      if d < 0 { period += max(-0.5, min(0.5, 0.5 * (a - c) / d)) }
    }
    confidence = max(0, min(1, (ac[best] + ac[2 * best]) / (2 * ac[0])))

    // beats: Ellis' DP on the whole band, then the phase the kick agrees with: offbeat bass
    // and hats can outweigh the beat in the full-band flux, never in the low band
    let low = Self.normalise(env.low, fps: fps)
    var frames = Self.track(full, period: period)
    let shift = Int((period / 2).rounded())
    let reach = min(shift - 1, Int(0.1 * fps))
    let onBeat = Self.windowSum(low, at: frames, reach: reach)
    let offBeat = Self.windowSum(low, at: frames.map { $0 + shift }, reach: reach)
    if offBeat > onBeat {
      frames = frames.map { $0 + shift }.filter { $0 < full.count }
    }
    // frame f covers samples [f·hop, f·hop + frameSize): its centre, plus the flux's latency
    let offset = Double(Self.frameSize(sr)) / 2 / sr + Self.onsetLatency
    beats = frames.map { Double($0) / fps + offset }

    // tempo refined: a line through the beats
    if beats.count >= 8 {
      let m = Double(beats.count)
      let mi = (m - 1) / 2
      let mt = beats.reduce(0, +) / m
      var sxy = 0.0
      var sxx = 0.0
      for (i, t) in beats.enumerated() {
        sxy += (Double(i) - mi) * (t - mt)
        sxx += (Double(i) - mi) * (Double(i) - mi)
      }
      let slope = sxy / sxx
      bpm = slope > 0 ? 60 / slope : 60 * fps / period
    } else {
      bpm = 60 * fps / period
    }

    // downbeats: the phase whose beats hold the most kick
    var phaseSum = [Double](repeating: 0, count: 4)
    for (i, f) in frames.enumerated() {
      phaseSum[i % 4] += Self.windowSum(low, at: [f], reach: reach)
    }
    downbeatPhase = phaseSum.indices.max { phaseSum[$0] < phaseSum[$1] } ?? 0
    downbeats = stride(from: downbeatPhase, to: beats.count, by: 4).map { beats[$0] }
  }

  /// The analysis frame: the power of two nearest 46 ms (1024 at 22.05 kHz, 2048 at 44.1k).
  static func frameSize(_ sr: Double) -> Int {
    1 << max(8, Int((log2(sr * 0.046)).rounded()))
  }

  /// Spectral flux of log magnitudes, whole spectrum and under `lowBandHz`, one per hop.
  static func onsets(_ x: [Float], sampleRate sr: Double, hop: Int) -> (
    full: [Double], low: [Double]
  ) {
    let size = frameSize(sr)
    let half = size / 2
    guard x.count >= size else { return ([], []) }
    let log2n = vDSP_Length(log2(Double(size)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
    defer { vDSP_destroy_fftsetup(setup) }
    let count = (x.count - size) / hop + 1
    let lowBins = max(2, Int(lowBandHz * Double(size) / sr))
    var window = [Float](repeating: 0, count: size)
    vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    var buf = [Float](repeating: 0, count: size)
    var re = [Float](repeating: 0, count: half)
    var im = re
    var mag = re
    var prev = [Float](repeating: 0, count: half)
    var diff = re
    var full = [Double](repeating: 0, count: count)
    var low = full
    var gamma: Float = 100
    var zero: Float = 0
    x.withUnsafeBufferPointer { xp in
      for f in 0..<count {
        vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &buf, 1, vDSP_Length(size))
        re.withUnsafeMutableBufferPointer { rp in
          im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            buf.withUnsafeBufferPointer { bp in
              bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
              }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            ip[0] = 0  // Nyquist, packed
            vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
          }
        }
        // log(1 + γ|X|)
        vDSP_vsmul(mag, 1, &gamma, &mag, 1, vDSP_Length(half))
        var c = Int32(half)
        vvlog1pf(&mag, mag, &c)
        vDSP_vsub(prev, 1, mag, 1, &diff, 1, vDSP_Length(half))
        vDSP_vthr(diff, 1, &zero, &diff, 1, vDSP_Length(half))
        var s: Float = 0
        vDSP_sve(diff, 1, &s, vDSP_Length(half))
        var sl: Float = 0
        vDSP_sve(diff, 1, &sl, vDSP_Length(lowBins))
        if f > 0 {
          full[f] = Double(s)
          low[f] = Double(sl)
        }
        swap(&prev, &mag)
      }
    }
    return (full, low)
  }

  /// Minus a 0.5 s moving mean, half-wave rectified, scaled to unit standard deviation.
  static func normalise(_ e: [Double], fps: Double) -> [Double] {
    let n = e.count
    guard n > 0 else { return e }
    let w = max(1, Int(fps * 0.25))
    var prefix = [Double](repeating: 0, count: n + 1)
    for i in 0..<n { prefix[i + 1] = prefix[i] + e[i] }
    var out = [Double](repeating: 0, count: n)
    for i in 0..<n {
      let a = max(0, i - w)
      let b = min(n, i + w + 1)
      out[i] = max(0, e[i] - (prefix[b] - prefix[a]) / Double(b - a))
    }
    let mean = out.reduce(0, +) / Double(n)
    let sd = (out.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)).squareRoot()
    if sd > 0 { for i in 0..<n { out[i] /= sd } }
    return out
  }

  /// Mean-removed autocorrelation, lags 0..<maxLag, each normalised by its overlap.
  static func autocorrelation(_ e: [Double], maxLag: Int) -> [Double] {
    let n = e.count
    let mean = e.reduce(0, +) / Double(n)
    let x = e.map { $0 - mean }
    var ac = [Double](repeating: 0, count: maxLag)
    x.withUnsafeBufferPointer { xp in
      for lag in 0..<min(maxLag, n) {
        var s = 0.0
        vDSP_dotprD(xp.baseAddress!, 1, xp.baseAddress! + lag, 1, &s, vDSP_Length(n - lag))
        ac[lag] = s / Double(n - lag)
      }
    }
    return ac
  }

  /// Σ over `frames` of the envelope from each frame to `reach` frames after it: the low band's
  /// flux builds later than the whole band's (its bins are few and a kick's body is slow).
  static func windowSum(_ e: [Double], at frames: [Int], reach: Int) -> Double {
    var sum = 0.0
    for f in frames where f >= 0 && f < e.count {
      for k in f...min(e.count - 1, f + reach) { sum += e[k] }
    }
    return sum
  }

  /// Ellis' beat DP over the onset envelope at `period` frames: the beat frames, in order.
  static func track(_ onset: [Double], period: Double) -> [Int] {
    let n = onset.count
    guard n > 0, period >= 2 else { return [] }
    var score = onset
    var back = [Int](repeating: -1, count: n)
    let lo = Int((period / 2).rounded(.down))
    let hi = Int((period * 2).rounded(.up))
    for t in 0..<n {
      var best = -Double.infinity
      var arg = -1
      let first = max(0, t - hi)
      let last = t - lo
      if last >= first {
        for tau in first...last {
          let r = log(Double(t - tau) / period)
          let s = score[tau] - tightness * r * r
          if s > best {
            best = s
            arg = tau
          }
        }
      }
      if arg >= 0 {
        score[t] = onset[t] + best
        back[t] = arg
      }
    }
    // the end: the best-scoring frame in the last period
    let tailStart = max(0, n - Int(period.rounded(.up)))
    var end = tailStart
    for t in tailStart..<n where score[t] > score[end] { end = t }
    var out: [Int] = []
    var t = end
    while t >= 0 {
      out.append(t)
      t = back[t]
    }
    return out.reversed()
  }
}
