import Accelerate
import Darwin

/// A faithful emulation of the Web Audio `AnalyserNode`'s frequency analysis, as Chrome
/// implements it, for the scopes that read beats' analysers (measured spectrogram and bands,
/// the corona's FFT, the feed flame).
///
/// What beats does, and so what this reproduces: `getFloatTimeDomainData` and
/// `getFloatFrequencyData` on a plain `createAnalyser()` node (scope.js, modes 3 and 5),
/// `getByteFrequencyData` on another (feed.html's flame, mode 28), and the corona's
/// `Tone.Analyser('fft', 128)` (mode 9), whose `getValue()` is that node's raw
/// `getFloatFrequencyData` dB. The numerics are the same in all three; **the input channel is
/// not**, see below.
///
/// **Which channel the analyser hears (decide this in the caller).** A plain `AnalyserNode`
/// down-mixes its stereo input to mono, (L+R)/2: that is what scope.js and feed.html analyse,
/// and what the engine's master tap delivers. Tone 15.1.22's `Analyser` (the version beats
/// loads) is a different graph: `Gain -> ChannelSplitter(1) -> AnalyserNode`, and a
/// one-output splitter keeps channel 0 only, so the corona analyses the LEFT channel, not the
/// down-mix. (Checked in headless Chrome with L != R: the splitter analyser's time domain
/// equals L exactly, a plain analyser's equals (L+R)/2.) beats' wave engine is dual-mono
/// (L == R), so nothing shows there; the DJ master also carries stereo sample decks, so a
/// corona fed the (L+R)/2 tap deviates from beats on stereo material (tens of dB in some
/// bins). Mode 9 should either be given a left-channel window or record (L+R)/2 as a
/// deliberate deviation. This class takes whatever window it is handed.
///
/// The algorithm (Web Audio spec, "AnalyserNode"), for the newest `fftSize` = N mono samples
/// `x[n]`:
///
/// 1. Blackman window with α = 0.16, periodic form:
///    `w[n] = 0.5(1-α) - 0.5 cos(2πn/N) + 0.5α cos(4πn/N)`, n = 0 ..< N.
/// 2. Forward FFT of `x[n]·w[n]`; the normalised magnitude is `|X_k|/N` for the
///    `frequencyBinCount` = N/2 bins k = 0 ..< N/2. (The Nyquist bin is not output; as in
///    Chrome, the packed Nyquist term is discarded.)
/// 3. Smoothing over time: `s_k = τ·s_k(previous analysis) + (1-τ)·|X_k|/N`, with
///    τ = `smoothingTimeConstant` and `s_k` starting at 0, so the first analysis of a
///    fresh analyser is attenuated by `(1-τ)`, exactly as in a browser.
/// 4. dB: `20·log10(s_k)`. Silence is `-Float.infinity` (Chrome returns -Infinity, not a
///    floor value). The byte form scales `[minDecibels, maxDecibels]` onto 0...255 and
///    truncates (spec: floor).
///
/// **Scaling.** `vDSP_fft_zrip` returns the true DFT times 2 (for every bin, DC included), so
/// the magnitude is `|zrip_k| · 0.5 / N`. This is proved in `AnalyserFFTTests` against an
/// O(N²) double-precision DFT of the spec formulas (scripts/analyser-reference.mjs), and
/// analytically: a sine of amplitude A exactly on bin k gives `|X_k|/N = A·0.42/2`, because the
/// periodic Blackman window has mean 0.42 (its coherent gain) and a DFT that is non-zero only
/// at bins 0, ±1, ±2 (0.42, -0.25, 0.04).
///
/// **Differences from a browser, on purpose.** There is no input buffer: the caller passes
/// the window. Input shorter than `fftSize` is zero-padded at the FRONT (an under-filled
/// analyser buffer), longer input contributes its newest `fftSize` samples. And a browser
/// analyses at most once per render quantum however often you read; here `analyse(_:)` is one
/// explicit smoothing step and the getters never advance anything. NaN or infinity in the
/// input (the audio graph never produces any) counts as a silent frame instead of poisoning
/// the smoothed state.
///
/// **The cadence of `analyse(_:)` sets the smoothing time constant.** τ acts once per call, not
/// per second. beats reads each analyser once per `requestAnimationFrame` (60 Hz on a normal
/// display), and Chrome advances the smoothing once per read, so the browser's flame (τ 0.78:
/// half-life ln 0.5 / ln 0.78 = 2.8 analyses = 46 ms at 60 Hz) and corona (τ 0.4: 0.76
/// analyses = 13 ms) are time constants of a 60 Hz loop. Call `analyse` exactly once per drawn
/// frame, at about 60 Hz: never from a slower model poll (AppModel's 30 Hz would double the
/// smoothing's wall-clock time) and never twice per draw. On a display that redraws faster
/// (a 120 Hz ProMotion screen halves the half-life) either throttle to 60 Hz or compensate with
/// `smoothingTimeConstant = pow(tau, dt * 60)` for the real frame interval `dt`. The measured
/// modes use τ = 0, which has no cadence dependence.
///
/// Usage per UI frame (allocation-free after `init`/`setFFTSize`):
/// ```
/// analyser.analyse(newestSamples)             // one analysis step per drawn frame
/// analyser.floatFrequencyData(into: dbBuffer) // getFloatFrequencyData
/// ```
///
/// Single-owner, deliberately not `Sendable`: one thread (the main thread, for the scopes)
/// owns an instance. It is not for the audio thread.
public final class AnalyserFFT {
  /// Chrome accepts powers of two from 32 to 32768 and throws `IndexSizeError` otherwise.
  public static let minFFTSize = 32
  public static let maxFFTSize = 32768
  /// `AnalyserNode` defaults.
  public static let defaultFFTSize = 2048
  public static let defaultSmoothingTimeConstant: Float = 0.8
  public static let defaultMinDecibels: Float = -100
  public static let defaultMaxDecibels: Float = -30
  /// The spec's fixed Blackman alpha.
  public static let blackmanAlpha = 0.16

  /// N, the analysis window length in samples.
  public var fftSize: Int { plan.size }
  /// N/2, the number of output bins (`frequencyBinCount`).
  public var frequencyBinCount: Int { plan.size / 2 }

  private var tau: Float
  /// τ in 0...1. Chrome throws on values outside the range; here they are clamped (and NaN is
  /// ignored). Changing it never resets the smoothed state.
  public var smoothingTimeConstant: Float {
    get { tau }
    set {
      guard !newValue.isNaN else { return }
      tau = min(1, max(0, newValue))
    }
  }

  private var minDb = AnalyserFFT.defaultMinDecibels
  private var maxDb = AnalyserFFT.defaultMaxDecibels

  /// The byte conversion's dB range (`getByteFrequencyData`): `minDecibels` maps to 0 and
  /// `maxDecibels` to 255. Both must be finite with min < max, always. Chrome throws on a
  /// violation; here the assignment is ignored and the pair stays as it was (like an invalid
  /// size), so the byte scale is always finite and positive. As in a browser, the order of two
  /// assignments matters: to move the range up, set `maxDecibels` first.
  public var minDecibels: Float {
    get { minDb }
    set { if newValue.isFinite && newValue < maxDb { minDb = newValue } }
  }
  /// See `minDecibels`.
  public var maxDecibels: Float {
    get { maxDb }
    set { if newValue.isFinite && newValue > minDb { maxDb = newValue } }
  }

  private var plan: Plan

  /// `fftSize` must be a power of two in 32...32768 (precondition; use `isValidFFTSize` for
  /// untrusted values).
  public init(
    fftSize: Int = AnalyserFFT.defaultFFTSize,
    smoothingTimeConstant: Float = AnalyserFFT.defaultSmoothingTimeConstant
  ) {
    precondition(Self.isValidFFTSize(fftSize), "fftSize must be a power of two in 32...32768")
    plan = Plan(size: fftSize)
    tau = 0
    self.smoothingTimeConstant = smoothingTimeConstant
  }

  deinit { plan.free() }

  public static func isValidFFTSize(_ n: Int) -> Bool {
    n >= minFFTSize && n <= maxFFTSize && n & (n - 1) == 0
  }

  /// Change N. Returns false and changes nothing for an invalid size (Chrome throws). A
  /// different valid size resets the smoothed state, as in Chrome; the same size is a no-op.
  /// Allocates (a new plan).
  @discardableResult
  public func setFFTSize(_ n: Int) -> Bool {
    guard Self.isValidFFTSize(n) else { return false }
    if n != plan.size {
      let next = Plan(size: n)
      plan.free()
      plan = next
    }
    return true
  }

  /// Forget the smoothed magnitudes (every bin back to 0, i.e. -∞ dB).
  public func reset() {
    plan.smoothed.update(repeating: 0, count: plan.size / 2)
  }

  // MARK: - Analysis

  /// One analysis step on the newest `fftSize` samples of `window` (see the type comment for
  /// short and long input): window, FFT, smoothing. Allocation-free.
  public func analyse(_ window: UnsafeBufferPointer<Float>) {
    let n = plan.size
    let half = n / 2
    let frame = plan.frame
    // The newest n samples, zero-padded at the front when fewer were given.
    let have = min(window.count, n)
    let pad = n - have
    if pad > 0 { frame.update(repeating: 0, count: pad) }
    if have > 0, let base = window.baseAddress {
      (frame + pad).update(from: base + (window.count - have), count: have)
    }
    // Window and deinterleave in one go: even samples to the real parts, odd to the
    // imaginary parts (the packed-real input of `vDSP_fft_zrip`).
    vDSP_vmul(frame, 2, plan.window, 2, plan.real, 1, vDSP_Length(half))
    vDSP_vmul(frame + 1, 2, plan.window + 1, 2, plan.imag, 1, vDSP_Length(half))
    var split = DSPSplitComplex(realp: plan.real, imagp: plan.imag)
    vDSP_fft_zrip(plan.setup, &split, 1, vDSP_Length(plan.log2n), FFTDirection(FFT_FORWARD))
    // Packed output: real[0] = DC, imag[0] = Nyquist. Only N/2 bins are reported, so the
    // Nyquist term is blown away (as Chrome does), leaving bin 0's magnitude = |DC|.
    plan.imag[0] = 0
    // |zrip_k| = 2|X_k|; normalise to |X_k|/N.
    vDSP_zvabs(&split, 1, frame, 1, vDSP_Length(half))
    let scale = 0.5 / Float(n)
    let keep = tau
    let take = 1 - tau
    let smoothed = plan.smoothed
    for k in 0..<half {
      // NaN or infinity in the input spreads to every bin; count such a frame as silence so
      // one bad block cannot poison the smoothed state for good.
      let m = frame[k] * scale
      smoothed[k] = keep * smoothed[k] + take * (m.isFinite ? m : 0)
    }
  }

  public func analyse(_ window: [Float]) {
    window.withUnsafeBufferPointer { analyse($0) }
  }

  public func analyse(_ window: ArraySlice<Float>) {
    window.withUnsafeBufferPointer { analyse($0) }
  }

  // MARK: - Reading the last analysis

  /// The smoothed linear magnitudes `s_k` of the last analysis (0 before the first). Copies
  /// `min(out.count, frequencyBinCount)` values.
  public func magnitudes(into out: UnsafeMutableBufferPointer<Float>) {
    let count = min(out.count, plan.size / 2)
    guard count > 0, let base = out.baseAddress else { return }
    base.update(from: plan.smoothed, count: count)
  }

  /// `getFloatFrequencyData`: `20·log10(s_k)` per bin, `-Float.infinity` where `s_k` is 0.
  /// Copies `min(out.count, frequencyBinCount)` values. Allocation-free.
  public func floatFrequencyData(into out: UnsafeMutableBufferPointer<Float>) {
    let count = min(out.count, plan.size / 2)
    let smoothed = plan.smoothed
    for k in 0..<count { out[k] = 20 * log10f(smoothed[k]) }
  }

  /// `getByteFrequencyData`: the dB value scaled from `minDecibels...maxDecibels` onto
  /// 0...255, clamped, truncated. Silence (-∞ dB) is 0. Copies
  /// `min(out.count, frequencyBinCount)` values. Allocation-free.
  public func byteFrequencyData(into out: UnsafeMutableBufferPointer<UInt8>) {
    let count = min(out.count, plan.size / 2)
    let lo = Double(minDb)
    let hi = Double(maxDb)
    let rangeScale = 1 / (hi - lo)  // min < max is an invariant of the setters
    let smoothed = plan.smoothed
    for k in 0..<count {
      let db = Double(20 * log10f(smoothed[k]))
      let scaled = 255 * (db - lo) * rangeScale
      if !(scaled > 0) {
        out[k] = 0  // below range, -∞ or NaN
      } else if scaled >= 255 {
        out[k] = 255
      } else {
        out[k] = UInt8(scaled)  // truncates toward zero, as the spec's floor
      }
    }
  }

  /// `getFloatTimeDomainData`: the newest `fftSize` samples of `window` (front zero-padded
  /// when fewer were given). Like the browser with a short destination, a short `out` receives
  /// the OLDEST `out.count` samples of that span. Allocation-free.
  public func floatTimeDomainData(
    window: UnsafeBufferPointer<Float>, into out: UnsafeMutableBufferPointer<Float>
  ) {
    let n = plan.size
    let count = min(out.count, n)
    let have = min(window.count, n)
    let pad = n - have
    let first = window.count - have  // index in `window` of the oldest sample that is used
    for i in 0..<count {
      out[i] = i < pad ? 0 : window[first + i - pad]
    }
  }

  /// Convenience copy of the above with a full-size result (allocates).
  public func timeDomain(window: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: plan.size)
    window.withUnsafeBufferPointer { w in
      out.withUnsafeMutableBufferPointer { floatTimeDomainData(window: w, into: $0) }
    }
    return out
  }

  public func timeDomain(window: ArraySlice<Float>) -> [Float] {
    var out = [Float](repeating: 0, count: plan.size)
    window.withUnsafeBufferPointer { w in
      out.withUnsafeMutableBufferPointer { floatTimeDomainData(window: w, into: $0) }
    }
    return out
  }

  /// Convenience copies (allocate) of the last analysis, for tests and one-off reads.
  public func decibels() -> [Float] {
    var out = [Float](repeating: 0, count: plan.size / 2)
    out.withUnsafeMutableBufferPointer { floatFrequencyData(into: $0) }
    return out
  }

  public func linearMagnitudes() -> [Float] {
    var out = [Float](repeating: 0, count: plan.size / 2)
    out.withUnsafeMutableBufferPointer { magnitudes(into: $0) }
    return out
  }

  public func bytes() -> [UInt8] {
    var out = [UInt8](repeating: 0, count: plan.size / 2)
    out.withUnsafeMutableBufferPointer { byteFrequencyData(into: $0) }
    return out
  }

  // MARK: - The window

  /// The spec's Blackman window, `count` points, periodic (the denominator is N, not N-1).
  public static func blackmanWindow(count n: Int, alpha: Double = blackmanAlpha) -> [Float] {
    let a0 = 0.5 * (1 - alpha)
    let a2 = 0.5 * alpha
    return (0..<n).map { i in
      let x = Double(i) / Double(n)
      return Float(a0 - 0.5 * cos(2 * Double.pi * x) + a2 * cos(4 * Double.pi * x))
    }
  }

  // MARK: - Conventions of the callers

  /// scope.js's measured spectrogram and bands ignore bins at or below this (-∞ included):
  /// `if (db > -200) sum += Math.pow(10, db / 10)`.
  public static let measuredFloorDecibels: Float = -200

  /// One bin's term in scope.js's power sum: `10^(db/10)`, or 0 when `db` is not above
  /// `measuredFloorDecibels` (silence, -∞).
  public static func measuredPower(decibels db: Float) -> Double {
    db > measuredFloorDecibels ? pow(10, Double(db) / 10) : 0
  }

  /// Tone's FFT `getValue()` hands out the node's raw dB (of the left channel only, see the
  /// type comment); the corona clamps it to `-100...0` (`Math.max(-100, Math.min(0, db))`),
  /// which also turns -∞ into the floor.
  public static func clamped(decibels db: Float, to range: ClosedRange<Float>) -> Float {
    max(range.lowerBound, min(range.upperBound, db))
  }

  // MARK: - Size-dependent state

  /// Everything that depends on N, allocated up front so analysis never allocates.
  private struct Plan {
    let size: Int
    let log2n: Int
    let setup: FFTSetup
    let window: UnsafeMutablePointer<Float>  // N
    let frame: UnsafeMutablePointer<Float>  // N: newest samples, then |zrip| scratch
    let real: UnsafeMutablePointer<Float>  // N/2
    let imag: UnsafeMutablePointer<Float>  // N/2
    let smoothed: UnsafeMutablePointer<Float>  // N/2: s_k, persistent

    init(size n: Int) {
      size = n
      log2n = n.trailingZeroBitCount
      guard let s = vDSP_create_fftsetup(vDSP_Length(n.trailingZeroBitCount), FFTRadix(kFFTRadix2))
      else { fatalError("vDSP_create_fftsetup failed for \(n)") }
      setup = s
      window = .allocate(capacity: n)
      window.initialize(from: AnalyserFFT.blackmanWindow(count: n), count: n)
      frame = .allocate(capacity: n)
      frame.initialize(repeating: 0, count: n)
      real = .allocate(capacity: n / 2)
      real.initialize(repeating: 0, count: n / 2)
      imag = .allocate(capacity: n / 2)
      imag.initialize(repeating: 0, count: n / 2)
      smoothed = .allocate(capacity: n / 2)
      smoothed.initialize(repeating: 0, count: n / 2)
    }

    func free() {
      vDSP_destroy_fftsetup(setup)
      window.deallocate()
      frame.deallocate()
      real.deallocate()
      imag.deallocate()
      smoothed.deallocate()
    }
  }
}
