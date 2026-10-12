import Foundation

// beats' master insert chain (audio/tone-engine.js `init`, Tone 15.1.22), per deck, after the
// wave engine and its sampled instruments:
//
//   HP (Tone.Filter 20 Hz, highpass, rolloff -48)  →  Phaser (1 Hz, 3 octaves, base 350 Hz,
//   10 stages, Q 10, wet 0)  →  LP (Tone.Filter 20 kHz, lowpass, -48)  →  BitCrusher (16 bits,
//   wet 0)  →  Distortion (0, wet 0)  →  PitchShift (0, window 0.03 s)
//
// What each Tone node is, as ported (the Tone sources and the Web Audio spec / Chrome's
// implementation are the reference; `MasterChainTests` hold the closed forms):
//   * Tone.Filter rolloff -48 = four identical cascaded BiquadFilterNodes; Q = 1 (dB for
//     lowpass/highpass). Their frequency is a Signal (an audio-rate input), so Chrome recomputes
//     the coefficients every sample while it ramps. Biquad: Chrome's direct form I with the RBJ
//     coefficients of the Web Audio spec (`BiquadCoefficients.pass`), float output.
//   * Phaser: a sine LFO per channel (right at 180°) scaled to base…base·2^octaves Hz drives ten
//     allpass biquads (Q 10) per channel, per sample; equal-power dry/wet (Tone.CrossFade =
//     StereoPannerNode on a constant: dry·cos(w·π/2) + wet·sin(w·π/2)).
//   * BitCrusher: Tone's worklet, `step = 0.5^(bits-1)`, `step·floor(x/step + 0.5)`; `bits` is a
//     k-rate parameter, read at the start of every 128-frame render quantum; equal-power wet.
//   * Distortion: a WaveShaper. Its curve has **1024** points: Distortion's setter calls
//     `setMap(fn)` with WaveShaper's default length, not the 4096 it was built with. Linear
//     interpolation as the spec / Chrome do it; oversample none; equal-power wet.
//   * PitchShift: two delay lines (linear interpolation, as Chrome's DelayNode) swept by
//     sawtooth LFOs (0° and 180°) between 0 and the window, crossfaded (equal power) by a
//     triangle LFO at 90°, all at `factor · 1.2 / window` Hz (`intervalToFrequencyRatio`, with
//     beats' `interval - 1` for downward shifts). The LFO waveforms are the ideal sawtooth and
//     triangle scaled by the normalisation Chrome applies to a PeriodicWave (peak of the
//     2047-partial table: 1.17849 for the sawtooth, 0.99980 for the triangle), so the delay
//     slopes — the pitch ratios — are Chrome's; the band-limited ripple near each sawtooth reset
//     (where its crossfade gain is ~0) is not modelled. Its feedback path (feedback 0) is
//     dropped.
//
// Deviations, by decision (ROADMAP 3.3):
//   * A neutral chain is bypassed and bit-transparent, as beats' default ("lean") wave path is,
//     not the `&fx=tone` chain at rest (whose HP at 20 Hz, LP at 20 kHz and pitch shifter at 0
//     — a fixed two-tap delay — colour the sound). HP, LP and the pitch shifter fade in over
//     5 ms when they leave their resting value and fade out over 5 ms when they settle back on
//     it; their state starts from zero (the pitch shifter's delay lines keep the input history
//     while bypassed, one block copy per channel). The phaser, crusher and distortion are
//     bypassed while their wet is 0; their own 50 ms wet ramps are the fade.
//   * No compressor (beats' master ends in Tone.Compressor(-12, 3)).
//   * The phaser's LFO starts at phase 0 when the chain is made (beats': whenever Tone was
//     started) at Tone's initial 1 Hz. beats' reset value for the rate slider (0) maps to 0.1 Hz,
//     so after a macro has restored `phaser-freq` the rate is 0.1 Hz, not 1 Hz — as in beats.
//
// Real-time: everything is allocated in `init`; `apply` and `process` allocate, lock and free
// nothing (`MasterChainRealTimeTests`, release builds).

/// One of the master chain's automated parameters, as the parity fixture names it.
enum MasterParamID: String, CaseIterable {
  case hpFrequency = "hp.frequency"
  case lpFrequency = "lp.frequency"
  case phaserFrequency = "phaser.frequency"
  case phaserWet = "phaser.wet"
  case phaserOctaves = "phaser.octaves"
  case crusherWet = "crusher.wet"
  case crusherBits = "crusher.bits"
  case distortionWet = "distortion.wet"
  case distortionAmount = "distortion.amount"
  case pitch = "pitch.pitch"
}

/// A Tone-level call one of tone-engine.js's setters made (for the parity test).
struct MasterParamOp: Equatable {
  enum Kind: String { case cancel, ramp, set }
  var time: Double
  var param: MasterParamID
  var kind: Kind
  var a: Double
  var b: Double = 0
}

/// The chain's parameters and tone-engine.js's master setters (`setHighpassFreq`,
/// `setLowpassFreq`, `setPhaserFreq`, `setPhaserDepth`, `setPhaserWet`, `setCrush`,
/// `setDistortion`, `setMasterPitch`), behind build.js's `applyFx`.
struct MasterParams {
  var hp: ToneParam
  var lp: ToneParam
  var phaserRate: ToneParam
  var phaserWet: ToneParam
  var crusherWet: ToneParam
  var crusherBits: ToneParam
  var distortionWet: ToneParam
  /// Plain properties (set at once).
  var octaves = 3.0
  var distortionAmount = 0.0
  var pitch = 0.0

  init(sampleRate sr: Double) {
    hp = ToneParam(value: 20, exponentialRamps: true, sampleRate: sr)
    lp = ToneParam(value: 20000, exponentialRamps: true, sampleRate: sr)
    phaserRate = ToneParam(value: 1, exponentialRamps: true, sampleRate: sr)
    phaserWet = ToneParam(value: 0, exponentialRamps: false, sampleRate: sr)
    crusherWet = ToneParam(value: 0, exponentialRamps: false, sampleRate: sr)
    crusherBits = ToneParam(value: 16, exponentialRamps: false, sampleRate: sr)
    distortionWet = ToneParam(value: 0, exponentialRamps: false, sampleRate: sr)
  }

  /// mixer-sliders.js `hpFreq`.
  static func hpFreq(_ v: Double) -> Double { 20 * pow(250, v / 100) }
  /// mixer-sliders.js `lpFreq`.
  static func lpFreq(_ v: Double) -> Double { 100 * pow(200, v / 100) }

  /// `applyFx(key, value)` at context time `now`. `log` (tests) sees every Tone-level call.
  mutating func apply(
    _ key: MasterFxKey, _ value: Int, at now: Double, log: ((MasterParamOp) -> Void)? = nil
  ) {
    let v = Double(value)
    switch key {
    case .hpFreq:
      let f = max(20, min(5000, Self.hpFreq(v)))
      hp.cancelScheduledValues(now)
      hp.rampTo(f, duration: 0.1, at: now)
      log?(MasterParamOp(time: now, param: .hpFrequency, kind: .cancel, a: now))
      log?(MasterParamOp(time: now, param: .hpFrequency, kind: .ramp, a: f, b: 0.1))
    case .lpFreq:
      let f = max(100, min(20000, Self.lpFreq(v)))
      lp.cancelScheduledValues(now)
      lp.rampTo(f, duration: 0.1, at: now)
      log?(MasterParamOp(time: now, param: .lpFrequency, kind: .cancel, a: now))
      log?(MasterParamOp(time: now, param: .lpFrequency, kind: .ramp, a: f, b: 0.1))
    case .phaserFreq:
      let rate = value == 0 ? 0 : 0.1 + (v / 100) * 9.9
      let r = max(0.1, min(10, rate))
      phaserRate.rampTo(r, duration: 0.1, at: now)
      log?(MasterParamOp(time: now, param: .phaserFrequency, kind: .ramp, a: r, b: 0.1))
    case .phaserDepth:
      octaves = max(0.5, (v / 100) * 6)
      log?(MasterParamOp(time: now, param: .phaserOctaves, kind: .set, a: octaves))
    case .phaserWet:
      let w = max(0, min(1, v / 100))
      phaserWet.rampTo(w, duration: 0.05, at: now)
      log?(MasterParamOp(time: now, param: .phaserWet, kind: .ramp, a: w, b: 0.05))
    case .crushBits:
      let amount = v / 100
      let wet: Double = amount <= 0 ? 0 : 1
      crusherWet.rampTo(wet, duration: 0.05, at: now)
      log?(MasterParamOp(time: now, param: .crusherWet, kind: .ramp, a: wet, b: 0.05))
      if amount > 0 {
        let bits = max(1, jsRound(16 - amount * 15))
        crusherBits.setImmediate(bits, at: now)
        log?(MasterParamOp(time: now, param: .crusherBits, kind: .set, a: bits))
      }
    case .distortion:
      let a = max(0, min(1, v / 100))
      let wet: Double = a > 0 ? 1 : 0
      distortionAmount = a
      log?(MasterParamOp(time: now, param: .distortionAmount, kind: .set, a: a))
      distortionWet.rampTo(wet, duration: 0.05, at: now)
      log?(MasterParamOp(time: now, param: .distortionWet, kind: .ramp, a: wet, b: 0.05))
    case .masterPitch:
      pitch = max(-24, min(24, v))
      log?(MasterParamOp(time: now, param: .pitch, kind: .set, a: pitch))
    }
  }

  /// A timeline parameter's value at `t` (what Tone's `getValueAtTime` reads).
  func value(_ id: MasterParamID, at t: Double) -> Double {
    switch id {
    case .hpFrequency: hp.value(at: t)
    case .lpFrequency: lp.value(at: t)
    case .phaserFrequency: phaserRate.value(at: t)
    case .phaserWet: phaserWet.value(at: t)
    case .crusherWet: crusherWet.value(at: t)
    case .crusherBits: crusherBits.value(at: t)
    case .distortionWet: distortionWet.value(at: t)
    case .phaserOctaves: octaves
    case .distortionAmount: distortionAmount
    case .pitch: pitch
    }
  }

  mutating func prune(before t: Double) {
    hp.prune(before: t)
    lp.prune(before: t)
    phaserRate.prune(before: t)
    phaserWet.prune(before: t)
    crusherWet.prune(before: t)
    crusherBits.prune(before: t)
    distortionWet.prune(before: t)
  }
}

/// The DSP of the chain, in place on a deck's block.
final class MasterChain {
  let sampleRate: Double
  private(set) var params: MasterParams
  /// Context frames processed so far: sample `k` of the block being processed is at
  /// `(frame + k) / sr` s.
  private(set) var frame: Int64 = 0

  static let filterStages = 4
  static let filterQDb = 1.0
  static let phaserStages = 10
  static let phaserQ = 10.0
  static let phaserBase = 350.0
  static let quantum: Int64 = 128
  static let curveLength = 1024
  static let window = 0.03
  /// Peak of Chrome's 2047-partial sawtooth / triangle table (the PeriodicWave normalisation).
  static let sawPeak = 1.1784914234857347
  static let trianglePeak = 0.9998021070789256
  /// Fade in / out of bypass.
  static let fadeSeconds = 0.005

  private let fadeStep: Double

  private struct Biquad {
    var b0 = 1.0
    var b1 = 0.0
    var b2 = 0.0
    var a1 = 0.0
    var a2 = 0.0
  }

  // HP / LP: [channel][stage][x1, x2, y1, y2]
  private let hpState: UnsafeMutablePointer<Double>
  private let lpState: UnsafeMutablePointer<Double>
  private static let passStateCount = 2 * filterStages * 4
  private var hpMix = 0.0
  private var lpMix = 0.0
  private var hpCoef = Biquad()
  private var lpCoef = Biquad()
  private var hpCoefF = -1.0
  private var lpCoefF = -1.0

  // phaser: [channel][stage][x1, x2, y1, y2]
  private let apState: UnsafeMutablePointer<Double>
  private static let apStateCount = 2 * phaserStages * 4
  private var phaserPhase = 0.0
  private var phaserRunning = false

  // crusher
  private var bitsK = 16.0
  private var crusherRunning = false

  // distortion
  private let curve: UnsafeMutablePointer<Float>
  private var curveAmount = Double.nan

  // pitch shift: two rings (left, right) of `ringSize`
  private let ring: UnsafeMutablePointer<Float>
  private let ringSize: Int
  private var ringWrite = 0
  private var pitchPhase = 0.0
  private var pitchMix = 0.0
  private var pitchRate = 0.0
  private var pitchMin = 0.03
  private var pitchMax = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    params = MasterParams(sampleRate: sampleRate)
    fadeStep = 1 / (Self.fadeSeconds * sampleRate)
    hpState = .allocate(capacity: Self.passStateCount)
    hpState.initialize(repeating: 0, count: Self.passStateCount)
    lpState = .allocate(capacity: Self.passStateCount)
    lpState.initialize(repeating: 0, count: Self.passStateCount)
    apState = .allocate(capacity: Self.apStateCount)
    apState.initialize(repeating: 0, count: Self.apStateCount)
    curve = .allocate(capacity: Self.curveLength)
    curve.initialize(repeating: 0, count: Self.curveLength)
    var n = 1
    while n < Int(Self.window * sampleRate) + 8 { n <<= 1 }
    ringSize = n
    ring = .allocate(capacity: 2 * n)
    ring.initialize(repeating: 0, count: 2 * n)
    rebuildCurve(0)
    setPitch(0)
  }

  deinit {
    hpState.deallocate()
    lpState.deallocate()
    apState.deallocate()
    curve.deallocate()
    ring.deallocate()
  }

  /// The chain's time at sample `k` of the block being processed.
  @inline(__always)
  func time(at k: Int) -> Double { Double(frame + Int64(k)) / sampleRate }

  /// Is every stage bypassed and settled at sample `k` (the chain leaves the audio alone)?
  func isIdle(at k: Int = 0) -> Bool {
    let t = time(at: k)
    return hpMix == 0 && lpMix == 0 && pitchMix == 0 && params.pitch == 0
      && isAt(params.hp, 20, t) && isAt(params.lp, 20000, t) && isAt(params.phaserWet, 0, t)
      && isAt(params.crusherWet, 0, t) && isAt(params.distortionWet, 0, t)
  }

  /// The HP / LP corners at sample `k` of the block (for the scope model).
  func filterCorners(at k: Int = 0) -> (hp: Double, lp: Double) {
    let t = time(at: k)
    return (params.hp.value(at: t), params.lp.value(at: t))
  }

  private func isAt(_ p: ToneParam, _ v: Double, _ t: Double) -> Bool {
    p.isSettled(at: t) && p.value(at: t) == v
  }

  /// `applyFx(key, value)` at context time `now` (taking effect from the next sample processed).
  func apply(_ key: MasterFxKey, _ value: Int, at now: Double) {
    params.apply(key, value, at: now)
    switch key {
    case .distortion:
      if params.distortionAmount != curveAmount { rebuildCurve(params.distortionAmount) }
    case .masterPitch: setPitch(params.pitch)
    default: break
    }
  }

  /// Process samples `start..<end` of the current block in place. Ops applied between two calls
  /// land at that sample. Call `finish(frames:)` after the block's last segment.
  func process(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, from start: Int,
    to end: Int
  ) {
    guard end > start else { return }
    if isIdle(at: start) {
      advancePhaser(start, end)
      writeHistory(left, right, start, end)
      return
    }
    passStage(lowpass: false, left, right, start, end)
    phaser(left, right, start, end)
    passStage(lowpass: true, left, right, start, end)
    crusher(left, right, start, end)
    distortion(left, right, start, end)
    pitchShift(left, right, start, end)
  }

  /// End of a block of `frames`: advance the clock, forget events in the past.
  func finish(frames: Int) {
    frame += Int64(frames)
    params.prune(before: time(at: 0))
  }

  // MARK: HP / LP

  /// Chrome `Biquad::SetLowpassParams` / `SetHighpassParams` (Q in dB), normalised by a0.
  private func passCoefficients(_ lowpass: Bool, _ f: Double) -> Biquad {
    let cutoff = max(0, min(1, f / (sampleRate / 2)))
    if cutoff == 1 { return lowpass ? Biquad() : Biquad(b0: 0) }
    if cutoff <= 0 { return lowpass ? Biquad(b0: 0) : Biquad() }
    let resonance = pow(10, Self.filterQDb / 20)
    let theta = Double.pi * cutoff
    let alpha = sin(theta) / (2 * resonance)
    let cosw = cos(theta)
    let beta = lowpass ? (1 - cosw) / 2 : (1 + cosw) / 2
    let b1 = lowpass ? 2 * beta : -2 * beta
    let a0 = 1 + alpha
    return Biquad(
      b0: beta / a0, b1: b1 / a0, b2: beta / a0, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
  }

  /// Chrome's `Biquad::Process` (direct form I, float output) on one sample.
  @inline(__always)
  private static func biquad(_ c: Biquad, _ x: Double, _ st: UnsafeMutablePointer<Double>) -> Double
  {
    let y = Float(c.b0 * x + c.b1 * st[0] + c.b2 * st[1] - c.a1 * st[2] - c.a2 * st[3])
    st[1] = st[0]
    st[0] = x
    st[3] = st[2]
    st[2] = Double(y)
    return Double(y)
  }

  private static func flushDenormals(_ st: UnsafeMutablePointer<Double>, _ n: Int) {
    for i in 0..<n where abs(st[i]) < 1e-30 { st[i] = 0 }
  }

  private func passStage(
    lowpass: Bool, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ s: Int,
    _ e: Int
  ) {
    let t0 = time(at: s)
    let rest = lowpass ? 20000.0 : 20.0
    let settled = lowpass ? params.lp.isSettled(at: t0) : params.hp.isSettled(at: t0)
    let constant = lowpass ? params.lp.value(at: t0) : params.hp.value(at: t0)
    let target: Double = settled && constant == rest ? 0 : 1
    var mix = lowpass ? lpMix : hpMix
    if mix == 0 && target == 0 { return }
    let st = lowpass ? lpState : hpState
    if mix == 0 { st.update(repeating: 0, count: Self.passStateCount) }  // engaging: fresh state
    var coef = lowpass ? lpCoef : hpCoef
    var coefF = lowpass ? lpCoefF : hpCoefF
    let channels = r == nil ? 1 : 2
    for k in s..<e {
      let f =
        settled
        ? constant : (lowpass ? params.lp.value(at: time(at: k)) : params.hp.value(at: time(at: k)))
      if f != coefF {
        coef = passCoefficients(lowpass, f)
        coefF = f
      }
      if mix < target {
        mix = min(target, mix + fadeStep)
      } else if mix > target {
        mix = max(target, mix - fadeStep)
      }
      for ch in 0..<channels {
        let buf = ch == 0 ? l : r!
        let x0 = Double(buf[k])
        var x = x0
        for stage in 0..<Self.filterStages {
          x = Self.biquad(coef, x, st + (ch * Self.filterStages + stage) * 4)
        }
        buf[k] = mix >= 1 ? Float(x) : Float(x0 + (x - x0) * mix)
      }
    }
    Self.flushDenormals(st, Self.passStateCount)
    if lowpass {
      lpMix = mix
      lpCoef = coef
      lpCoefF = coefF
    } else {
      hpMix = mix
      hpCoef = coef
      hpCoefF = coefF
    }
  }

  // MARK: phaser

  /// Chrome `Biquad::SetAllpassParams` (Q linear), normalised.
  @inline(__always)
  private func allpassCoefficients(_ f: Double) -> Biquad {
    let frequency = max(0, min(1, f / (sampleRate / 2)))
    guard frequency > 0, frequency < 1 else { return Biquad() }
    let w0 = Double.pi * frequency
    let alpha = sin(w0) / (2 * Self.phaserQ)
    let k = cos(w0)
    let a0 = 1 + alpha
    return Biquad(
      b0: (1 - alpha) / a0, b1: -2 * k / a0, b2: (1 + alpha) / a0, a1: -2 * k / a0,
      a2: (1 - alpha) / a0)
  }

  /// The LFO runs whether or not anything hears it.
  private func advancePhaser(_ s: Int, _ e: Int) {
    let t0 = time(at: s)
    if params.phaserRate.isSettled(at: t0) {
      phaserPhase += params.phaserRate.value(at: t0) * Double(e - s) / sampleRate
    } else {
      for k in s..<e { phaserPhase += params.phaserRate.value(at: time(at: k)) / sampleRate }
    }
    phaserPhase -= phaserPhase.rounded(.down)
  }

  private func phaser(
    _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ s: Int, _ e: Int
  ) {
    let t0 = time(at: s)
    let wetSettled = params.phaserWet.isSettled(at: t0)
    let wet0 = params.phaserWet.value(at: t0)
    if wetSettled && wet0 == 0 {
      if phaserRunning {
        phaserRunning = false
        apState.update(repeating: 0, count: Self.apStateCount)
      }
      advancePhaser(s, e)
      return
    }
    phaserRunning = true
    let rateSettled = params.phaserRate.isSettled(at: t0)
    let rate0 = params.phaserRate.value(at: t0)
    let minF = Self.phaserBase
    let maxF = Self.phaserBase * pow(2, params.octaves)
    let channels = r == nil ? 1 : 2
    var phase = phaserPhase
    for k in s..<e {
      let t = time(at: k)
      let w = wetSettled ? wet0 : params.phaserWet.value(at: t)
      let osc = sin(2 * Double.pi * phase)
      let gd = cos(w * Double.pi / 2)
      let gw = sin(w * Double.pi / 2)
      for ch in 0..<channels {
        // Tone.LFO: oscillator → AudioToGain ((x + 1) / 2) → Scale (× (max − min) + min)
        let f = ((ch == 0 ? osc : -osc) + 1) / 2 * (maxF - minF) + minF
        let c = allpassCoefficients(f)
        let buf = ch == 0 ? l : r!
        let x0 = Double(buf[k])
        var x = x0
        for stage in 0..<Self.phaserStages {
          x = Self.biquad(c, x, apState + (ch * Self.phaserStages + stage) * 4)
        }
        buf[k] = Float(x0 * gd + x * gw)
      }
      phase += (rateSettled ? rate0 : params.phaserRate.value(at: t)) / sampleRate
      phase -= phase.rounded(.down)
    }
    Self.flushDenormals(apState, Self.apStateCount)
    phaserPhase = phase
  }

  // MARK: bit crusher

  private func crusher(
    _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ s: Int, _ e: Int
  ) {
    let t0 = time(at: s)
    let wetSettled = params.crusherWet.isSettled(at: t0)
    let wet0 = params.crusherWet.value(at: t0)
    if wetSettled && wet0 == 0 {
      crusherRunning = false
      return
    }
    if !crusherRunning {
      // the k-rate value of the render quantum this sample is in
      let q = (frame + Int64(s)) / Self.quantum * Self.quantum
      bitsK = params.crusherBits.value(at: Double(q) / sampleRate)
      crusherRunning = true
    }
    let channels = r == nil ? 1 : 2
    for k in s..<e {
      if (frame + Int64(k)) % Self.quantum == 0 {
        bitsK = params.crusherBits.value(at: time(at: k))
      }
      let w = wetSettled ? wet0 : params.crusherWet.value(at: time(at: k))
      let gd = cos(w * Double.pi / 2)
      let gw = sin(w * Double.pi / 2)
      let step = pow(0.5, bitsK - 1)
      for ch in 0..<channels {
        let buf = ch == 0 ? l : r!
        let x = Double(buf[k])
        // the worklet's output is a Float32Array
        let crushed = Double(Float(step * (x / step + 0.5).rounded(.down)))
        buf[k] = Float(x * gd + crushed * gw)
      }
    }
  }

  // MARK: distortion

  /// Distortion's setter: `setMap` over WaveShaper's default 1024 points.
  private func rebuildCurve(_ amount: Double) {
    curveAmount = amount
    let k = amount * 100
    let deg = Double.pi / 180
    let n = Self.curveLength
    for i in 0..<n {
      let x = (Double(i) / Double(n - 1)) * 2 - 1
      curve[i] = abs(x) < 0.001 ? 0 : Float(((3 + k) * x * 20 * deg) / (Double.pi + k * abs(x)))
    }
  }

  /// The curve lookup (the spec's WaveShaper, as Chrome's `WaveShaperDSPKernel` does it).
  @inline(__always)
  func shape(_ input: Float) -> Double {
    let n = Self.curveLength
    let v = 0.5 * (Double(input) + 1) * Double(n - 1)
    if v < 0 { return Double(curve[0]) }
    if v >= Double(n - 1) { return Double(curve[n - 1]) }
    let i = Int(v)
    let f = v - Double(i)
    return (1 - f) * Double(curve[i]) + f * Double(curve[i + 1])
  }

  private func distortion(
    _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ s: Int, _ e: Int
  ) {
    let t0 = time(at: s)
    let wetSettled = params.distortionWet.isSettled(at: t0)
    let wet0 = params.distortionWet.value(at: t0)
    if wetSettled && wet0 == 0 { return }
    let channels = r == nil ? 1 : 2
    for k in s..<e {
      let w = wetSettled ? wet0 : params.distortionWet.value(at: time(at: k))
      let gd = cos(w * Double.pi / 2)
      let gw = sin(w * Double.pi / 2)
      for ch in 0..<channels {
        let buf = ch == 0 ? l : r!
        let x = buf[k]
        let y = Double(Float(shape(x)))
        buf[k] = Float(Double(x) * gd + y * gw)
      }
    }
  }

  // MARK: pitch shift

  /// PitchShift's `pitch` setter: which way the sawtooths sweep, and the LFOs' rate.
  private func setPitch(_ p: Double) {
    let factor: Double
    if p < 0 {
      pitchMin = 0
      pitchMax = Self.window
      factor = pow(2, (p - 1) / 12) + 1
    } else {
      pitchMin = Self.window
      pitchMax = 0
      factor = pow(2, p / 12) - 1
    }
    pitchRate = factor * (1.2 / Self.window)
  }

  /// Keep the history the delay lines read while the stage is bypassed.
  private func writeHistory(
    _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ s: Int, _ e: Int
  ) {
    let mask = ringSize - 1
    var w = ringWrite
    let right = r ?? l
    for k in s..<e {
      ring[w] = l[k]
      ring[ringSize + w] = right[k]
      w = (w + 1) & mask
    }
    ringWrite = w
  }

  /// The ideal sawtooth (0 at phase 0, rising) at the level Chrome's normalised table plays it.
  @inline(__always)
  static func saw(_ phase: Double) -> Double {
    var p = phase + 0.5
    p -= p.rounded(.down)
    return (2 * p - 1) / sawPeak
  }

  /// The ideal triangle (0 at phase 0, peak at a quarter), normalised likewise.
  @inline(__always)
  static func triangle(_ phase: Double) -> Double {
    var p = phase + 0.25
    p -= p.rounded(.down)
    return (1 - 4 * abs(p - 0.5)) / trianglePeak
  }

  /// Chrome's DelayNode read (the input is in the ring already): linear interpolation.
  @inline(__always)
  private func readDelay(_ base: UnsafeMutablePointer<Float>, _ w: Int, _ delay: Double) -> Double {
    let size = Double(ringSize)
    var pos = Double(w) + size - max(0, min(1, delay)) * sampleRate
    if pos >= size { pos -= size }
    let i1 = Int(pos)
    let i2 = (i1 + 1) & (ringSize - 1)
    let f = pos - Double(i1)
    return (1 - f) * Double(base[i1]) + f * Double(base[i2])
  }

  private func pitchShift(
    _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ s: Int, _ e: Int
  ) {
    let target: Double = params.pitch != 0 ? 1 : 0
    if pitchMix == 0 && target == 0 {
      writeHistory(l, r, s, e)
      return
    }
    let mask = ringSize - 1
    let channels = r == nil ? 1 : 2
    let right = r ?? l
    var mix = pitchMix
    var phase = pitchPhase
    var w = ringWrite
    let minD = pitchMin
    let maxD = pitchMax
    let inc = pitchRate / sampleRate
    for k in s..<e {
      ring[w] = l[k]
      ring[ringSize + w] = right[k]
      // Tone.LFO: (osc + 1) / 2 → × (max − min) + min
      let dA = (Self.saw(phase) + 1) / 2 * (maxD - minD) + minD
      let dB = (Self.saw(phase - 0.5) + 1) / 2 * (maxD - minD) + minD
      let fade = (Self.triangle(phase - 0.25) + 1) / 2
      let ga = cos(fade * Double.pi / 2)
      let gb = sin(fade * Double.pi / 2)
      if mix < target {
        mix = min(target, mix + fadeStep)
      } else if mix > target {
        mix = max(target, mix - fadeStep)
      }
      for ch in 0..<channels {
        let base = ring + ch * ringSize
        let y = ga * readDelay(base, w, dA) + gb * readDelay(base, w, dB)
        let buf = ch == 0 ? l : r!
        let x = Double(buf[k])
        buf[k] = Float(x + (y - x) * mix)
      }
      w = (w + 1) & mask
      phase += inc
      phase -= phase.rounded(.down)
    }
    ringWrite = w
    pitchPhase = phase
    pitchMix = mix
  }
}
