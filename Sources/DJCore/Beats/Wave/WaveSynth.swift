import Foundation

// Port of beats' wave-engine/synth.js: pulse shapes, voice specs, wavetables, noise
// seeds and biquad coefficients. Pure functions; the runner realises them per sample.

public let waveTableSize = 2048

public struct Pulse: Equatable {
  public var alpha: [Double]
  public var tau: [Double]
}

/// `pulse(attack, decay)`: two exponentials (no onset click), or one if attack ≥ decay.
public func pulse(attack: Double, decay: Double) -> Pulse {
  if !(attack > 0) || attack >= decay { return Pulse(alpha: [1], tau: [decay]) }
  return Pulse(alpha: [1, -1], tau: [decay, attack])
}

/// A voice spec, the union of the drum and tonal shapes synth.js returns.
public struct VoiceSpec: Equatable {
  public var kind: String  // kick | snare | clap | hat | openhat | tonal
  public var carrier: String  // sweep | noise | noise+tone | table | dc
  public var f1 = 0.0
  public var f0 = 0.0
  public var sweepTau = 0.0
  public var filter = ""
  public var fc = 0.0
  public var q = 0.0
  public var tone = 0.0
  public var toneMix = 0.0
  public var pulse = Pulse(alpha: [1], tau: [0.1])
  public var level = 0.0
  // tonal
  public var wave = "saw"
  public var attack = 0.0
  public var decayScale = 0.0
  public var maxDecay = 0.0
  // Beyond beats' wave engine (InstrumentTable; defaults leave a voice exactly as beats has it).
  /// "table" (wavetable) | "pluck" (Karplus-Strong string, as Tone's PluckSynth).
  public var engine = "table"
  /// pluck: noise burst length in periods of the note.
  public var attackNoise = 1.0
  /// pluck: lowpass cutoff inside the string loop, Hz.
  public var dampening = 4000.0
  /// pluck: loop feedback, 0…1.
  public var resonance = 0.9
  /// Pitch vibrato: rate in Hz, depth as a fraction of the frequency.
  public var vibratoRate = 0.0
  public var vibratoDepth = 0.0
  /// Post lowpass on the voice sum, Hz (0 = off).
  public var lowpass = 0.0
  /// Tone.Distortion amount after the lowpass (0 = off).
  public var distortion = 0.0
  /// Per-note pitch envelope (laser zaps, Tone's frequency.exponentialRampToValueAtTime): the
  /// note starts at `pitchFrom` × its frequency and glides exponentially to `pitchTo` ×
  /// over `pitchTime` seconds, then holds. `pitchTime` 0 = off.
  public var pitchFrom = 1.0
  public var pitchTo = 1.0
  public var pitchTime = 0.0

  public init(kind: String, carrier: String) {
    self.kind = kind
    self.carrier = carrier
  }

  /// Decode the JSON shape synth.js emits (used by tests and voice overrides).
  public init(json v: JSONValue) {
    self.init(kind: v["kind"]?.string ?? "tonal", carrier: v["carrier"]?.string ?? "dc")
    f1 = v["f1"]?.double ?? 0
    f0 = v["f0"]?.double ?? 0
    sweepTau = v["sweepTau"]?.double ?? 0
    filter = v["filter"]?.string ?? ""
    fc = v["fc"]?.double ?? 0
    q = v["q"]?.double ?? 0
    tone = v["tone"]?.double ?? 0
    toneMix = v["toneMix"]?.double ?? 0
    applyExtended(v)
    if let p = v["pulse"] {
      pulse = Pulse(
        alpha: (p["alpha"]?.array ?? []).compactMap(\.double),
        tau: (p["tau"]?.array ?? []).compactMap(\.double))
    }
    level = v["level"]?.double ?? 0
    wave = v["wave"]?.string ?? "saw"
    attack = v["attack"]?.double ?? 0
    decayScale = v["decayScale"]?.double ?? 0
    maxDecay = v["maxDecay"]?.double ?? 0
  }
}

private struct Kit {
  var kickDecay: Double
  var kickOctaves: Double
  var snareDecay: Double
  var hihatDecay: Double
}

// Mirrors tone-engine.js::_synthDrumKit's per-kit constants.
private let kits: [String: Kit] = [
  "drums": Kit(kickDecay: 0.30, kickOctaves: 6, snareDecay: 0.15, hihatDecay: 0.05),
  "drums-breakbeat": Kit(kickDecay: 0.20, kickOctaves: 4, snareDecay: 0.20, hihatDecay: 0.08),
  "drums-cr78": Kit(kickDecay: 0.25, kickOctaves: 3, snareDecay: 0.12, hihatDecay: 0.04),
  "drums-v8": Kit(kickDecay: 0.35, kickOctaves: 8, snareDecay: 0.18, hihatDecay: 0.06),
  "drums-808": Kit(kickDecay: 0.60, kickOctaves: 8, snareDecay: 0.20, hihatDecay: 0.04),
  "drums-lofi": Kit(kickDecay: 0.25, kickOctaves: 4, snareDecay: 0.15, hihatDecay: 0.05),
]

public func isDrumChannel(_ ch: Int) -> Bool { ch >= 10 && ch <= 15 }

/// Same note → drum-role dispatch as `_synthDrumKit`.
public func drumKind(_ note: Int) -> String {
  if note == 36 || note == 35 { return "kick" }
  if note == 38 || note == 40 || note == 37 { return "snare" }
  if note == 39 { return "clap" }
  if note >= 42 && note <= 46 { return "hat" }
  if note == 49 || note == 57 { return "openhat" }
  return "kick"
}

public func drumVoice(kind: String, instrument: String) -> VoiceSpec {
  let k = kits[instrument] ?? kits["drums"]!
  switch kind {
  case "kick":
    var v = VoiceSpec(kind: "kick", carrier: "sweep")
    v.f1 = 48
    v.f0 = 48 * k.kickOctaves
    v.sweepTau = 0.03
    v.pulse = pulse(attack: 0.001, decay: k.kickDecay / 2.5)
    v.level = 0.9
    return v
  case "snare":
    var v = VoiceSpec(kind: "snare", carrier: "noise+tone")
    v.filter = "bandpass"
    v.fc = 3000
    v.q = 0.9
    v.tone = 180
    v.toneMix = 0.35
    v.pulse = pulse(attack: 0.001, decay: k.snareDecay / 2.5)
    v.level = 0.6
    return v
  case "clap":
    var v = VoiceSpec(kind: "clap", carrier: "noise")
    v.filter = "bandpass"
    v.fc = 1400
    v.q = 1.2
    v.pulse = pulse(attack: 0.002, decay: 0.06)
    v.level = 0.6
    return v
  case "crash":
    // Not in beats (its drum map plays note 49 as the open hat): dj's section crash
    // (`DJMusicality.Fixes.crash`). Bright noise with a cymbal's long tail.
    var v = VoiceSpec(kind: "crash", carrier: "noise")
    v.filter = "highpass"
    v.fc = 4200
    v.q = 0.5
    v.pulse = pulse(attack: 0.002, decay: 0.7)
    v.level = 0.2
    return v
  case "openhat":
    var v = VoiceSpec(kind: "openhat", carrier: "noise")
    v.filter = "highpass"
    v.fc = 7000
    v.q = 0.7
    v.pulse = pulse(attack: 0.001, decay: k.hihatDecay * 2.5)
    v.level = 0.28
    return v
  default:
    var v = VoiceSpec(kind: "hat", carrier: "noise")
    v.filter = "highpass"
    v.fc = 7000
    v.q = 0.7
    v.pulse = pulse(attack: 0.001, decay: k.hihatDecay / 2)
    v.level = 0.32
    return v
  }
}

private func matches(_ name: String, _ parts: [String]) -> Bool {
  parts.contains { name.contains($0) }
}

/// `tonalVoice(instrument, group)`: instrument families are matched by name, as the JS regexes do.
public func tonalVoice(instrument: String?, group: String?) -> VoiceSpec {
  let name = instrument ?? ""
  var wave = "saw"
  var attack = 0.003
  var decayScale = 0.5
  var level = 0.22
  var maxDecay = 1.5
  if matches(name, ["pad", "strings", "choir", "organ"]) || group == "harmony" || group == "pad" {
    wave = "soft"
    attack = 0.06
    decayScale = 0.8
    level = 0.12
    maxDecay = 3
  } else if matches(name, ["sub", "808"]) {
    wave = "sine"
    level = 0.42
  } else if matches(name, ["bass", "reese", "acid"]) || group == "bass" {
    wave = "saw"
    level = 0.26
  } else if matches(name, ["bell", "vibes", "marimba", "kalimba", "music-box", "steel", "glass"]) {
    wave = "bell"
    attack = 0.001
    decayScale = 1.2
    level = 0.2
  } else if matches(name, ["square", "chiptune", "pwm", "clav"]) {
    wave = "square"
    level = 0.16
  } else if matches(name, ["pluck", "stab", "piano", "guitar", "harpsi"]) {
    wave = "saw"
    attack = 0.002
    decayScale = 0.35
    level = 0.2
  }
  var v = VoiceSpec(kind: "tonal", carrier: "table")
  v.wave = wave
  v.attack = attack
  v.decayScale = decayScale
  v.maxDecay = maxDecay
  v.level = level
  return v
}

private let partials: [String: [Double]] = [
  "sine": [1],
  "saw": [1, 1.0 / 2, 1.0 / 3, 1.0 / 4, 1.0 / 5, 1.0 / 6, 1.0 / 7, 1.0 / 8],
  "square": [1, 0, 1.0 / 3, 0, 1.0 / 5, 0, 1.0 / 7],
  "soft": [1, 0.5, 0.25, 0.12],
  "bell": [1, 0, 0.45, 0, 0, 0.25, 0, 0, 0.12],
]

/// Normalised additive wavetable (`waveTableSize` + 1 guard sample), stored as float32.
public func buildTable(_ wave: String) -> [Float] {
  let amps = partials[wave] ?? partials["sine"]!
  var t = [Double](repeating: 0, count: waveTableSize)
  var peak = 0.0
  for i in 0..<waveTableSize {
    var s = 0.0
    for k in 0..<amps.count where amps[k] != 0 {
      s += amps[k] * sin(2 * Double.pi * Double(k + 1) * Double(i) / Double(waveTableSize))
    }
    // The JS stores into a Float32Array then normalises the stored (rounded) values.
    t[i] = Double(Float(s))
    if abs(s) > peak { peak = abs(s) }
  }
  var out = [Float](repeating: 0, count: waveTableSize + 1)
  for i in 0..<waveTableSize { out[i] = Float(t[i] / peak) }
  out[waveTableSize] = out[0]
  return out
}

/// Seeded xorshift32 seed for lane `i`.
public func noiseSeed(_ i: Int) -> Int32 {
  let s =
    Int32(bitPattern: 0x9E37_79B9)
    ^ (Int32(truncatingIfNeeded: i + 1) &* Int32(bitPattern: 0x85EB_CA6B))
  return s == 0 ? 1 : s
}

/// RBJ biquad coefficients `[b0, b1, b2, a1, a2]` (normalised by a0).
public func biquad(type: String, fc: Double, q: Double, sr: Double) -> [Double] {
  let w = 2 * Double.pi * min(fc, sr * 0.45) / sr
  let cw = cos(w)
  let sw = sin(w)
  let alpha = sw / (2 * q)
  let b0: Double
  let b1: Double
  let b2: Double
  if type == "highpass" {
    b0 = (1 + cw) / 2
    b1 = -(1 + cw)
    b2 = (1 + cw) / 2
  } else if type == "lowpass" {
    b0 = (1 - cw) / 2
    b1 = 1 - cw
    b2 = (1 - cw) / 2
  } else {
    b0 = alpha
    b1 = 0
    b2 = -alpha
  }
  let a0 = 1 + alpha
  return [b0 / a0, b1 / a0, b2 / a0, (-2 * cw) / a0, (1 - alpha) / a0]
}
