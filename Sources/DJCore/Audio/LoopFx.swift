import Darwin
import Foundation

// Per-loop after effects: an insert chain on each loop-bank voice, after its playback and before
// its level × fade, plus a safety limiter on the loop channel. Non-destructive: a clip's audio
// stays dry (its id, the library's WAV, sequences and crops are made from the dry audio), and
// the FX are a value on the clip (`LoopClip.fx`) that the voice plays it through.
//
//   playback → drive (0…+24 dB) → shaper (clean | soft | hard | tube | fold | crush, amount)
//            → tone (2-pole lowpass) → auto-level → dry/wet mix → trim → level × fade → Σ
//   Σ (the loop channel) → safety limiter (only while any voice has FX, or its gain is back up)
//
// The shapers reuse the repo's own curves: soft is the runner's `tanh` saturation, tube is
// Tone.Distortion's curve (`toneDistortion`) biased off centre (asymmetric: even harmonics),
// crush is the master chain's crusher quantiser (`crushQuantize`) with a sample-and-hold.
// Hard clip and fold are one line each.
//
// Oversampling: the four waveshaping modes run at 2× through a 47-tap Kaiser halfband (23 base
// samples of latency, matched by a delay on the dry side of the mix). Cost: ~50 multiply-adds
// and two shaper calls per sample per channel, only on voices with FX on: under 1 % of a core
// with all 16 loops driven. 2× takes the aliasing of a +24 dB push down by the halfband's
// ~70 dB stopband for everything that lands above 24 kHz on the way up; 4× would double the
// cost to move the remaining fold-back (12…24 kHz content's harmonics, which the tone control
// is there to roll off anyway) and was not worth it. Crush is not oversampled: aliasing is the
// sound. Clean (drive only) is linear and has no latency.
//
// Bypass is exact: a voice whose FX are off (`LoopFX.isActive` false) never enters the chain,
// so its samples are the turntable's bytes; the limiter runs only while some voice's FX are on
// (and until its gain has released back to 1), so a row with no FX renders exactly as before.
// Switching FX on or off, or a mode / sample-and-hold change, crossfades the chain in and out
// over 10 ms; every continuous parameter is smoothed (one pole, ~10 ms) toward its target.
//
// Threading: `LoopFxVoice.process` and `LoopFxLimiter.process` are the audio thread's (called
// from `LoopBank.render`); they allocate nothing (every buffer is made in `init`). Parameters
// cross as `LoopFxParams` (plain floats) in `LoopBankCommand.fx`, the way clip gain does.

/// What a voice's shaper does.
public enum LoopFXMode: String, CaseIterable, Sendable {
  /// No shaping: drive is plain amplification.
  case clean
  /// tanh saturation.
  case soft
  /// Clipped flat at full scale.
  case hard
  /// Tone.Distortion's curve, biased: one half of the wave bends sooner (even harmonics).
  case tube
  /// Wave folding: past full scale the wave folds back down.
  case fold
  /// Bit crusher: `bits` of resolution over full scale (driven past it, it clips first), each
  /// value held for `downsample` samples.
  case crush

  public var label: String {
    switch self {
    case .clean: "clean"
    case .soft: "soft"
    case .hard: "hard"
    case .tube: "tube"
    case .fold: "fold"
    case .crush: "crush"
    }
  }

  var code: UInt8 {
    switch self {
    case .clean: 0
    case .soft: 1
    case .hard: 2
    case .tube: 3
    case .fold: 4
    case .crush: 5
    }
  }

  /// Runs at 2× (the waveshapers).
  var oversampled: Bool { self != .clean && self != .crush }
}

/// A loop's after effects (`LoopClip.fx`): drive, a shaper, tone, auto-level, mix and trim.
/// The default (`LoopFX()`) is off: the clip plays bit-identically to no FX.
public struct LoopFX: Equatable, Sendable {
  /// Off without forgetting the settings.
  public var bypass = false
  /// Extra amplification before the shaper, dB (0…24): "the amp".
  public var drive = 0.0
  public var mode = LoopFXMode.clean
  /// How hard the shaper bends (0 = clean, 1 = all the way: +30 dB into its curve).
  public var amount = 0.5
  /// Crush: bits of resolution (1…16).
  public var bits = 8.0
  /// Crush: each value held for this many samples (1 = no sample-rate reduction, …32).
  public var downsample = 1
  /// Tone: the lowpass after the shaper, 0 (400 Hz) … 1 (open, off).
  public var tone = 1.0
  /// Dry/wet, 0…1.
  public var mix = 1.0
  /// Output trim, dB (−24…+12).
  public var trim = 0.0
  /// Keep the level where it was while drive and shaping change it (default on).
  public var autoLevel = true

  public init(
    bypass: Bool = false, drive: Double = 0, mode: LoopFXMode = .clean, amount: Double = 0.5,
    bits: Double = 8, downsample: Int = 1, tone: Double = 1, mix: Double = 1, trim: Double = 0,
    autoLevel: Bool = true
  ) {
    self.bypass = bypass
    self.drive = drive
    self.mode = mode
    self.amount = amount
    self.bits = bits
    self.downsample = downsample
    self.tone = tone
    self.mix = mix
    self.trim = trim
    self.autoLevel = autoLevel
  }

  public static let off = LoopFX()

  public static let driveRange: ClosedRange<Double> = 0...24
  public static let bitsRange: ClosedRange<Double> = 1...16
  public static let downsampleRange: ClosedRange<Int> = 1...32
  public static let trimRange: ClosedRange<Double> = -24...12

  /// Every value inside its range (what the poke, the library and the journal store).
  public var clamped: LoopFX {
    func c(_ v: Double, _ r: ClosedRange<Double>) -> Double {
      v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }
    var f = self
    f.drive = c(drive, Self.driveRange)
    f.amount = c(amount, 0...1)
    f.bits = c(bits, Self.bitsRange)
    let hold = Self.downsampleRange
    f.downsample = min(max(downsample, hold.lowerBound), hold.upperBound)
    f.tone = c(tone, 0...1)
    f.mix = c(mix, 0...1)
    f.trim = c(trim, Self.trimRange)
    return f
  }

  /// Does the chain change the sound at all? Off, bypassed, or set to nothing: the voice plays
  /// its clip untouched.
  public var isActive: Bool {
    guard !bypass else { return false }
    if trim != 0 { return true }
    guard mix > 0 else { return false }
    return drive > 0 || (mode != .clean && amount > 0) || tone < 1
  }

  /// "drive +12 · soft 60 %" for a badge's help, "off".
  public var summary: String {
    guard isActive else { return bypass ? "bypassed" : "off" }
    var parts: [String] = []
    if drive > 0 { parts.append(String(format: "drive +%.0f dB", drive)) }
    if mode != .clean && amount > 0 {
      parts.append(
        mode == .crush
          ? String(format: "crush %.0f bit", bits) + (downsample > 1 ? " ÷\(downsample)" : "")
          : String(format: "%@ %.0f%%", mode.label, amount * 100))
    }
    if tone < 1 { parts.append(String(format: "tone %.0f%%", tone * 100)) }
    if mix < 1 { parts.append(String(format: "mix %.0f%%", mix * 100)) }
    if trim != 0 { parts.append(String(format: "trim %+.1f dB", trim)) }
    if !autoLevel { parts.append("auto-level off") }
    return parts.joined(separator: " · ")
  }

  // MARK: presets

  /// The right-click menu's quick settings, in order.
  public static let presets: [(name: String, fx: LoopFX)] = [
    ("Off", LoopFX()),
    ("Warm drive", LoopFX(drive: 6, mode: .tube, amount: 0.35, tone: 0.8)),
    ("Crunch", LoopFX(drive: 9, mode: .hard, amount: 0.55, tone: 0.75)),
    ("Fuzz", LoopFX(drive: 18, mode: .soft, amount: 0.9, tone: 0.6)),
    ("Crush", LoopFX(mode: .crush, amount: 1, bits: 6, downsample: 4, tone: 0.85, mix: 0.8)),
    ("Loud", LoopFX(drive: 9, mode: .soft, amount: 0.15, autoLevel: false)),
  ]

  /// The preset these settings are, if any.
  public var presetName: String? { Self.presets.first { $0.fx == self }?.name }

  // MARK: JSON

  /// Every field, so a recorded poke means the same whatever the defaults become.
  public var json: JSONValue {
    .object(
      JSONObject([
        ("bypass", .bool(bypass)), ("drive", .number(drive)), ("mode", .string(mode.rawValue)),
        ("amount", .number(amount)), ("bits", .number(bits)), ("downsample", .int(downsample)),
        ("tone", .number(tone)), ("mix", .number(mix)), ("trim", .number(trim)),
        ("autoLevel", .bool(autoLevel)),
      ]))
  }

  /// Missing fields take their defaults; values are clamped into their ranges.
  public init(json v: JSONValue?) {
    let d = LoopFX()
    self.init(
      bypass: v?["bypass"]?.bool ?? d.bypass, drive: v?["drive"]?.double ?? d.drive,
      mode: v?["mode"]?.string.flatMap(LoopFXMode.init(rawValue:)) ?? d.mode,
      amount: v?["amount"]?.double ?? d.amount, bits: v?["bits"]?.double ?? d.bits,
      downsample: v?["downsample"]?.int ?? d.downsample, tone: v?["tone"]?.double ?? d.tone,
      mix: v?["mix"]?.double ?? d.mix, trim: v?["trim"]?.double ?? d.trim,
      autoLevel: v?["autoLevel"]?.bool ?? d.autoLevel)
    self = clamped
  }
}

// MARK: - shared DSP

/// The master chain's crusher quantiser (`MasterChain.crusher`): `bits` of resolution, rounding
/// down to a step of 2^(1 − bits), through Float as the worklet's output is.
@inline(__always)
func crushQuantize(_ x: Double, step: Double) -> Double {
  Double(Float(step * (x / step + 0.5).rounded(.down)))
}

/// The crusher's step for `bits`.
@inline(__always)
func crushStep(bits: Double) -> Double { pow(0.5, bits - 1) }

/// The tube shaper's bias and the stiffness of its Tone.Distortion curve.
private let tubeBias = 0.08
private let tubeCurve = 0.2

@inline(__always)
private func tube(_ v: Double) -> Double {
  toneDistortion(v + tubeBias, amount: tubeCurve) - toneDistortion(tubeBias, amount: tubeCurve)
}

/// A triangle fold into −1…1.
@inline(__always)
private func fold(_ v: Float) -> Float {
  var t = (v + 1).truncatingRemainder(dividingBy: 4)
  if t < 0 { t += 4 }
  return t < 2 ? t - 1 : 3 - t
}

/// The targets a voice's chain heads for, as the audio thread uses them (gains linear,
/// coefficients ready): made on the main thread from a `LoopFX`.
struct LoopFxParams {
  var active = false
  var mode: UInt8 = 0
  /// Sample-and-hold length (crush).
  var hold: Int32 = 1
  var drive: Float = 1
  var amount: Float = 0
  /// Gain into the curve, and the curve's normalisation (full scale in, full scale out).
  var pre: Float = 1
  var norm: Float = 1
  /// Crusher step (2^(1 − bits)).
  var step: Float = 1.0 / 128
  /// The lowpass's g = tan(π fc / fs), and how much of it is heard (0 at tone 1).
  var toneG: Float = 1
  var toneWet: Float = 0
  var mix: Float = 1
  var trim: Float = 1
  /// Static auto-level (1 / drive) and whether auto-level is on (0 / 1).
  var comp: Float = 1
  var auto: Float = 1

  init() {}

  init(_ fx: LoopFX, sampleRate sr: Double) {
    let f = fx.clamped
    active = f.isActive
    mode = f.mode.code
    hold = Int32(f.downsample)
    let drive = pow(10, f.drive / 20)
    self.drive = Float(drive)
    amount = f.mode == .clean ? 0 : Float(f.amount)
    let pre = pow(10, f.amount * 30 / 20)
    self.pre = Float(pre)
    switch f.mode {
    case .soft: norm = Float(1 / tanh(pre))
    case .tube: norm = Float(1 / max(abs(tube(pre)), abs(tube(-pre))))
    default: norm = 1
    }
    step = Float(crushStep(bits: f.bits))
    let fc = min(400 * pow(50, f.tone), 0.45 * sr)
    toneG = Float(tan(Double.pi * fc / sr))
    toneWet = f.tone < 1 ? 1 : 0
    mix = Float(f.mix)
    trim = Float(pow(10, f.trim / 20))
    comp = Float(1 / drive)
    auto = f.autoLevel ? 1 : 0
  }
}

/// The 2× halfband (47 taps, Kaiser β 7): its 24 non-zero side taps (the centre is 0.5).
/// Scaled so the side taps sum to exactly 0.5 (unity at DC both ways).
private func halfbandTaps() -> [Float] {
  let n = 47
  let mid = n / 2
  func i0(_ x: Double) -> Double {
    var sum = 1.0
    var term = 1.0
    for k in 1..<32 {
      term *= (x / 2) / Double(k)
      sum += term * term
    }
    return sum
  }
  let beta = 7.0
  var taps: [Double] = []
  for k in stride(from: 0, to: n, by: 2) {
    let j = Double(k - mid)  // odd: −23, −21, … 23
    let sinc = sin(Double.pi * j / 2) / (Double.pi * j / 2)
    let r = j / Double(mid)
    let w = i0(beta * (1 - r * r).squareRoot()) / i0(beta)
    taps.append(0.5 * sinc * w)
  }
  let s = taps.reduce(0, +)
  return taps.map { Float($0 * 0.5 / s) }
}

/// A short history, newest first, readable as one contiguous run (`at(k)` = k samples ago).
private struct History {
  let buf: UnsafeMutablePointer<Float>
  let length: Int
  var pos = 0

  init(_ length: Int) {
    self.length = length
    buf = .allocate(capacity: 2 * length)
    buf.initialize(repeating: 0, count: 2 * length)
  }

  func free() { buf.deallocate() }

  mutating func push(_ x: Float) {
    pos = pos == 0 ? length - 1 : pos - 1
    buf[pos] = x
    buf[pos + length] = x
  }

  @inline(__always) func at(_ k: Int) -> Float { buf[pos + k] }
  /// The run from now back: `run[k]` = k samples ago.
  @inline(__always) var run: UnsafePointer<Float> { UnsafePointer(buf + pos) }

  mutating func clear() {
    buf.update(repeating: 0, count: 2 * length)
    pos = 0
  }
}

/// One channel's chain state.
private struct FxChannel {
  /// Input (base rate) for the upsampler and the dry side's delay.
  var input = History(24)
  /// The shaped signal at 2×: its even samples (for the decimating filter) and its odd ones
  /// (12 samples back is the centre tap).
  var even = History(24)
  var odd = History(13)
  /// The tone lowpass (TPT state variable filter).
  var ic1: Float = 0
  var ic2: Float = 0
  /// DC blocker (tube).
  var dcX: Float = 0
  var dcY: Float = 0
  /// Crush's held value.
  var held: Float = 0

  func free() {
    input.free()
    even.free()
    odd.free()
  }

  mutating func clear() {
    input.clear()
    even.clear()
    odd.clear()
    ic1 = 0
    ic2 = 0
    dcX = 0
    dcY = 0
    held = 0
  }
}

/// One loop-bank voice's FX chain. Main-thread side: nothing (commands go through the bank).
/// Audio thread: `set` (from the bank's command), `process`.
final class LoopFxVoice {
  /// Base samples the oversampled modes are late by (the dry side waits as long).
  static let latency = 23
  private let taps: UnsafeMutablePointer<Float>
  private var ch: (FxChannel, FxChannel)
  /// Where the chain is heading, and the settings waiting for a crossfade through dry (a mode
  /// or hold change, or FX switched on while the old ones fade out).
  private var target = LoopFxParams()
  private var pending: LoopFxParams?
  /// The values in use (smoothed toward `target`).
  private var cur = LoopFxParams()
  private var mode: UInt8 = 0
  private var hold = 1
  private var holdCount = 0
  /// Chain in (1) or out (0) of the voice, and its ramp.
  private var engage: Float = 0
  private var engageStep: Float = 0
  private var engageLeft = 0
  private let engageFrames: Int
  /// One-pole smoothing per sample, and the auto-level followers' coefficient.
  private let smooth: Float
  private let follow: Float
  private var powerIn: Float = 0
  private var powerWet: Float = 0
  private let dcR: Float
  /// Whether the chain is in the signal path (FX on, or fading out).
  private(set) var running = false

  init(sampleRate sr: Double) {
    let t = halfbandTaps()
    taps = .allocate(capacity: t.count)
    taps.initialize(from: t, count: t.count)
    ch = (FxChannel(), FxChannel())
    engageFrames = max(1, Int(sr * 0.01))
    smooth = Float(1 - exp(-1 / (0.01 * sr)))
    follow = Float(1 - exp(-1 / (0.3 * sr)))
    dcR = Float(1 - 2 * Double.pi * 10 / sr)
  }

  deinit {
    taps.deallocate()
    ch.0.free()
    ch.1.free()
  }

  /// New targets. `sounding`: the voice is playing (changes are smoothed and crossfaded);
  /// otherwise they take effect at once, from a clean state.
  func set(_ p: LoopFxParams, sounding: Bool) {
    guard sounding else {
      target = p
      pending = nil
      cur = p
      mode = p.mode
      hold = Int(max(1, p.hold))
      reset()
      engage = p.active ? 1 : 0
      engageLeft = 0
      engageStep = 0
      running = p.active
      return
    }
    if !running {
      guard p.active else {
        target = p
        cur = p
        return
      }
      // in from dry: the chain starts clean at the new settings and fades in
      target = p
      cur = p
      mode = p.mode
      hold = Int(max(1, p.hold))
      reset()
      running = true
      ramp(to: 1)
      return
    }
    let swaps = p.mode != mode || Int(max(1, p.hold)) != hold
    if !p.active || swaps {
      // out through dry first; `pending` comes in after (if it is on)
      pending = p.active ? p : nil
      if !p.active { target.active = false }
      ramp(to: 0)
      return
    }
    pending = nil
    target = p
    if engage < 1 || engageStep < 0 { ramp(to: 1) }
  }

  private func ramp(to t: Float) {
    engageLeft = max(1, Int(Float(engageFrames) * abs(t - engage)))
    engageStep = (t - engage) / Float(engageLeft)
    if engageStep == 0 { engageLeft = 0 }
  }

  private func reset() {
    ch.0.clear()
    ch.1.clear()
    holdCount = 0
    powerIn = 0
    powerWet = 0
  }

  /// Run `n` samples of the voice's playback (in place) through the chain.
  func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
    guard running else { return }
    let settled = cur.isSettled(at: target)
    for i in 0..<n {
      if !settled { cur.approach(target, smooth) }
      let xl = l[i]
      let xr = r[i]
      var yl: Float = 0
      var yr: Float = 0
      chain(xl, xr, &yl, &yr)
      // the chain in or out, through the dry signal as it is now
      if engageLeft > 0 {
        engageLeft -= 1
        engage = engageLeft == 0 ? (engageStep > 0 ? 1 : 0) : engage + engageStep
        if engageLeft == 0 { engageStep = 0 }
      }
      let e = engage
      l[i] = (1 - e) * xl + e * yl
      r[i] = (1 - e) * xr + e * yr
      if engage == 0 && engageLeft == 0 {
        // out: the next settings come in clean, or the chain leaves the path
        if let p = pending {
          pending = nil
          target = p
          cur = p
          mode = p.mode
          hold = Int(max(1, p.hold))
          reset()
          ramp(to: 1)
        } else {
          reset()
          running = false
          return  // the rest of the block is the voice's own samples
        }
      }
    }
  }

  /// One stereo sample through the chain at the current settings.
  @inline(__always)
  private func chain(_ xl: Float, _ xr: Float, _ yl: inout Float, _ yr: inout Float) {
    let c = cur
    var wl: Float
    var wr: Float
    var dl = xl
    var dr = xr
    switch mode {
    case 0:
      wl = xl * c.drive
      wr = xr * c.drive
    case 5:
      if holdCount == 0 {
        // a converter's range: driven past full scale it clips, then the bits go
        let step = Double(c.step)
        ch.0.held = Float(crushQuantize(Double(min(max(xl * c.drive, -1), 1)), step: step))
        ch.1.held = Float(crushQuantize(Double(min(max(xr * c.drive, -1), 1)), step: step))
        holdCount = hold
      }
      holdCount -= 1
      let ul = xl * c.drive
      let ur = xr * c.drive
      wl = (1 - c.amount) * ul + c.amount * ch.0.held
      wr = (1 - c.amount) * ur + c.amount * ch.1.held
    default:
      wl = Self.oversample(&ch.0, xl, c, mode, taps)
      wr = Self.oversample(&ch.1, xr, c, mode, taps)
      dl = ch.0.input.at(Self.latency)
      dr = ch.1.input.at(Self.latency)
      if mode == 3 {
        wl = Self.dcBlock(&ch.0, wl, dcR)
        wr = Self.dcBlock(&ch.1, wr, dcR)
      }
    }
    // tone
    if c.toneWet > 0 {
      wl += c.toneWet * (Self.lowpass(&ch.0, wl, c.toneG) - wl)
      wr += c.toneWet * (Self.lowpass(&ch.1, wr, c.toneG) - wr)
    } else {
      _ = Self.lowpass(&ch.0, wl, c.toneG)
      _ = Self.lowpass(&ch.1, wr, c.toneG)
    }
    // auto-level: 1 / drive, then the followers' ratio for what the shaping did to the level
    let sl = wl * c.comp
    let sr = wr * c.comp
    powerIn += follow * (0.5 * (dl * dl + dr * dr) - powerIn)
    powerWet += follow * (0.5 * (sl * sl + sr * sr) - powerWet)
    let agc = min(max(((powerIn + 1e-9) / (powerWet + 1e-9)).squareRoot(), 0.25), 4)
    let g = 1 + c.auto * (c.comp * agc - 1)
    yl = c.trim * ((1 - c.mix) * dl + c.mix * wl * g)
    yr = c.trim * ((1 - c.mix) * dr + c.mix * wr * g)
  }

  /// One base-rate sample of a waveshaping mode, at 2×: up (polyphase halfband), shaped twice,
  /// down (halfband, decimated). Late by `latency` samples.
  @inline(__always)
  private static func oversample(
    _ s: inout FxChannel, _ x: Float, _ c: LoopFxParams, _ mode: UInt8,
    _ taps: UnsafeMutablePointer<Float>
  ) -> Float {
    s.input.push(x)
    let run = s.input.run
    var even: Float = 0
    for k in 0..<24 { even += taps[k] * run[k] }
    even *= 2
    let odd = run[11]
    s.even.push(shape(even * c.drive, c, mode))
    s.odd.push(shape(odd * c.drive, c, mode))
    let e = s.even.run
    var y: Float = 0
    for k in 0..<24 { y += taps[k] * e[k] }
    return y + 0.5 * s.odd.at(12)
  }

  @inline(__always)
  private static func shape(_ u: Float, _ c: LoopFxParams, _ mode: UInt8) -> Float {
    let v = u * c.pre
    let s: Float
    switch mode {
    case 1: s = tanhf(v) * c.norm
    case 2: s = min(max(v, -1), 1)
    case 3: s = Float(tube(Double(v))) * c.norm
    default: s = fold(v)
    }
    return (1 - c.amount) * u + c.amount * s
  }

  @inline(__always)
  private static func lowpass(_ s: inout FxChannel, _ x: Float, _ g: Float) -> Float {
    // TPT SVF, Q = 1/√2
    let k: Float = 1.41421356
    let a1 = 1 / (1 + g * (g + k))
    let a2 = g * a1
    let a3 = g * a2
    let v3 = x - s.ic2
    let v1 = a1 * s.ic1 + a2 * v3
    let v2 = s.ic2 + a2 * s.ic1 + a3 * v3
    s.ic1 = 2 * v1 - s.ic1
    s.ic2 = 2 * v2 - s.ic2
    return v2
  }

  @inline(__always)
  private static func dcBlock(_ s: inout FxChannel, _ x: Float, _ r: Float) -> Float {
    let y = x - s.dcX + r * s.dcY
    s.dcX = x
    s.dcY = y
    return y
  }
}

extension LoopFxParams {
  /// Every continuous value at its target.
  fileprivate func isSettled(at t: LoopFxParams) -> Bool {
    drive == t.drive && amount == t.amount && pre == t.pre && norm == t.norm && step == t.step
      && toneG == t.toneG && toneWet == t.toneWet && mix == t.mix && trim == t.trim
      && comp == t.comp && auto == t.auto
  }

  /// One step of one-pole smoothing toward `t`, landing exactly once within a hair of it.
  fileprivate mutating func approach(_ t: LoopFxParams, _ k: Float) {
    @inline(__always) func move(_ v: inout Float, _ to: Float) {
      let d = to - v
      v = abs(d) <= 1e-6 * max(1, abs(to)) ? to : v + k * d
    }
    move(&drive, t.drive)
    move(&amount, t.amount)
    move(&pre, t.pre)
    move(&norm, t.norm)
    move(&step, t.step)
    move(&toneG, t.toneG)
    move(&toneWet, t.toneWet)
    move(&mix, t.mix)
    move(&trim, t.trim)
    move(&comp, t.comp)
    move(&auto, t.auto)
  }
}

/// The loop channel's safety limiter: transparent at or under −0.5 dBFS, instant attack (no
/// look-ahead: the channel keeps its timing), 120 ms release. The bank runs it only while some
/// voice's FX are on or its gain is still coming back up, so a row without FX is untouched.
final class LoopFxLimiter {
  static let ceiling: Float = 0.944  // −0.5 dBFS
  /// The gain (Double: a Float stalls short of 1 on a slow release).
  private(set) var gain = 1.0
  private let release: Double

  init(sampleRate sr: Double) {
    release = 1 - exp(-1 / (0.12 * sr))
  }

  var idle: Bool { gain >= 1 }

  func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>?, _ n: Int) {
    var g = gain
    let t = Double(Self.ceiling)
    for i in 0..<n {
      let p = Double(max(abs(l[i]), r.map { abs($0[i]) } ?? 0))
      if g < 1 {
        g += release * (1 - g)
        if g > 0.999_999 { g = 1 }
      }
      if p * g > t { g = t / p }
      if g < 1 {
        let f = Float(g)
        l[i] *= f
        r?[i] *= f
      }
    }
    gain = g
  }
}
