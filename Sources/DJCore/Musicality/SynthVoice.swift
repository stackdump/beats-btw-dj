import Foundation
import Synchronization

/// How a saw / square voice is shaped under `DJMusicality.Fixes.subtractive`: a lowpass per
/// voice whose cutoff opens on the note and closes as it plays, the way an analogue synth's
/// filter envelope does, and opens further the harder the note is struck. beats' voices are a
/// fixed 8-partial wavetable at one brightness for every note: a bass at 55 Hz stops at 440 Hz
/// (no definition on small speakers) and an accent sounds like any other note, only louder.
public struct FilterEnvelope: Sendable, Equatable {
  /// Where the cutoff rests, in multiples of the note's frequency (keyboard tracking).
  public var base: Double
  /// How far a full-velocity note opens it, Hz, on top of `base`.
  public var amount: Double
  /// Time constant of the close, seconds.
  public var seconds: Double
  /// Resonance (Q of the two-pole state-variable lowpass).
  public var q: Double

  public init(base: Double, amount: Double, seconds: Double, q: Double) {
    self.base = base
    self.amount = amount
    self.seconds = seconds
    self.q = q
  }

  /// A bass: dark at rest (the first few harmonics), a short bright bite on the attack.
  public static let bass = FilterEnvelope(base: 2.5, amount: 1400, seconds: 0.16, q: 1.0)
  /// A lead / arp: brighter at rest, a longer open.
  public static let lead = FilterEnvelope(base: 4, amount: 5000, seconds: 0.35, q: 0.8)
  /// A pluck / stab / keys voice: wide open on the strike, closed fast.
  public static let pluck = FilterEnvelope(base: 3, amount: 6000, seconds: 0.12, q: 0.8)

  /// The envelope for a tonal synth voice of part `group`, or nil for voices it leaves as they
  /// are: anything that is not a wavetable saw or square (pads are the soft table, bells and
  /// subs have no harmonics to shape, the Karplus-Strong strings and instruments with their own
  /// post lowpass are designed already). Parts in `plucked` (`VoiceDesign.pluckGroups`, by
  /// genre) take `.pluck` whatever their voice.
  public static func forVoice(
    _ v: VoiceSpec, group: String, plucked: Set<String> = []
  ) -> FilterEnvelope? {
    guard v.engine == "table", v.wave == "saw" || v.wave == "square", v.lowpass == 0 else {
      return nil
    }
    if group == "bass" { return .bass }
    if plucked.contains(group) { return .pluck }
    // tonalVoice's pluck / stab / piano / guitar family: decayScale 0.35
    if v.decayScale < 0.4 { return .pluck }
    return .lead
  }
}

/// `DJMusicality.Fixes.unison`: a voice played as two oscillators a few cents either side of
/// the note, the chorus every analogue pad and "supersaw" lead has (beats' voices are one
/// oscillator each: a held chord is static, a lead thin). Under `.stereo` a pad's two
/// oscillators go to either side, so a held chord is wide and moving; it folds to mono intact.
public enum Unison {
  /// Detune either side of the note, cents, for a tonal synth voice of part `group`; nil = one
  /// oscillator. Pads (the soft table) 7, saw leads 6. Basses stay single (beating low notes
  /// throb), as do plucks, squares, bells and strings.
  public static func cents(_ v: VoiceSpec, group: String) -> Double? {
    guard v.engine == "table", v.lowpass == 0, v.distortion == 0, group != "bass" else {
      return nil
    }
    if v.wave == "soft" && (group == "harmony" || group == "pad") { return 7 }
    if FilterEnvelope.forVoice(v, group: group) == .lead && group == "melody" { return 6 }
    return nil
  }

  /// How far apart a pad's two oscillators sit (side gain each way) at full width (C5 and up;
  /// none at A3 and below).
  public static let width = 0.35
  /// The pair's difference is highpassed here (second order): what is wide is above the low
  /// mids, so the mix's low end stays mono.
  public static let sideHz = 300.0
}

/// Per-genre settings for the runner's sound design (`WaveOptions.voiceDesign`, set by
/// `WaveOptions.forGenre` for the fixes it holds). The default is what every genre played
/// before p66: no part plucked, pads at full width with their side highpassed at
/// `Unison.sideHz`.
public struct VoiceDesign: Sendable, Equatable {
  /// Parts whose saw / square voices take the `.pluck` filter envelope under `.subtractive`
  /// (wide open on the strike, closed in 0.12 s) instead of `.lead`'s 0.35 s open.
  public var pluckGroups: Set<String> = []
  /// Scales the pad's (`harmony`) stereo spread under `.stereo` (`stereoPlacement`'s 0.5) and its
  /// unison pair's width (`Unison.width`); 1 = as placed.
  public var padWidth = 1.0
  /// Where the pad's unison pair's difference is highpassed (`Unison.sideHz` by default).
  public var padSideHz = Unison.sideHz

  public init(
    pluckGroups: Set<String> = [], padWidth: Double = 1, padSideHz: Double = Unison.sideHz
  ) {
    self.pluckGroups = pluckGroups
    self.padWidth = padWidth
    self.padSideHz = padSideHz
  }

  /// The arp in trance, edm and synthwave is a pluck: those styles' arps are short, bright
  /// filter stabs, not a held lead. Ambient's pads are narrower and their side starts higher:
  /// its pads sit low and long, so at full width their side reached under 150 Hz (the p66
  /// target: `AudioMetrics.lowSideDB` from −26 dB to −35 dB or lower, with `sideDB` still −20 dB
  /// or wider, `StereoTests.ambientPadsKeepTheirLowsMono`; numbers to be measured there).
  public static func forGenre(_ name: String) -> VoiceDesign {
    switch name {
    case "trance", "edm", "synthwave": return VoiceDesign(pluckGroups: ["arp"])
    case "ambient": return VoiceDesign(padWidth: 0.6, padSideHz: 600)
    default: return VoiceDesign()
    }
  }
}

/// `DJMusicality.Fixes.kickTune`: the kick's body in the track's key. beats' kick sweeps down to
/// 48 Hz in every track — two thirds of a semitone flat of G1, in no key in particular — so under
/// a bass on A1 its tail beats against the bass a few hertz apart. Producers tune the kick to the
/// key: here its resting pitch is the key's root or fifth, whichever is nearest 50 Hz (between
/// about 37 and 73 Hz), and the sweep keeps its shape (it starts the same number of octaves up).
public enum KickTuning {
  /// Where a kick's tail sits best: low enough to be felt, high enough for small speakers.
  static let centreHz = 50.0

  /// The kick's resting frequency for a track whose key's root is `root` (a MIDI note); nil
  /// without one.
  public static func hz(root: Int?) -> Double? {
    guard let root else { return nil }
    var best: Double?
    for pc in [root % 12, (root + 7) % 12] {
      // the octave of this pitch class nearest `centreHz`
      var f = 440 * pow(2, (Double(pc) - 69) / 12)
      while f > centreHz * 2.squareRoot() { f /= 2 }
      while f < centreHz / 2.squareRoot() { f *= 2 }
      if best == nil || abs(log2(f / centreHz)) < abs(log2(best! / centreHz)) { best = f }
    }
    return best
  }
}

/// `DJMusicality.Fixes.subOctave`: a sine an octave under each bass note, as dnb's reese, a
/// dubstep wobble and a trap 808 carry their weight. beats' bass is one oscillator whose
/// fundamental is the lowest thing in the mix; in those styles the sub-bass an octave down is.
/// Synth bass lanes only (`WaveOptions.subOctave`, set by `forGenre`): a sampled bass plays as
/// sampled (a lane switched to its synth voice live gets the sub too). Notes whose sub would be
/// under `minHz` play without it (inaudible, and all limiter). Each voice's phase is allocated
/// at prepare and runs free, unfiltered and centred.
public enum SubOctave {
  /// The genres that play it.
  public static let genres: Set<String> = ["dnb", "dubstep", "trap"]
  /// Its level against the voice's oscillator (−6 dB).
  public static let gain = 0.5
  /// The lowest sub it plays, Hz (a bass note of 60 Hz and up).
  public static let minHz = 30.0

  /// Whether a track of `genre` plays a sub-octave.
  public static func forGenre(_ genre: String) -> Bool { genres.contains(genre) }
}

/// Brushes on the snare, for jazz under `DJMusicality.Fixes.backbeat` (`WaveOptions.brushes`):
/// `.backbeat` brings jazz's snare in on a soft 2 and 4, and beats' snare is a stick's crack (a
/// 1 ms attack, a 180 Hz tone under the noise) where a jazz drummer plays brushes. The brush is
/// band-passed noise and nothing else — no tonal body — rising over about 25 ms (two
/// exponentials, 20 ms up and 70 ms down: the peak at 35 ms, 10–90 % in about 20 ms) and
/// swishing out over about 200 ms (−20 dB at 220 ms). A dj voice: beats' kits
/// (`drumVoice`, WaveSynth.swift) never play it, and `WaveOptions()` never sets it.
public enum Brush {
  /// Whether a track of `genre` plays brushes.
  public static func forGenre(_ genre: String) -> Bool { genre == "jazz" }

  /// The synth brush.
  public static var voice: VoiceSpec {
    var v = VoiceSpec(kind: "snare", carrier: "noise")
    v.filter = "bandpass"
    v.fc = 2500
    v.q = 0.6
    v.pulse = pulse(attack: attack, decay: decay)
    v.level = 0.7
    return v
  }
  /// The envelope's rise and fall time constants, seconds.
  static let attack = 0.02
  static let decay = 0.07

  /// A sampled kit whose bank has no Brush kit plays its own snare this much softer (−8 dB as
  /// a velocity, `DrumKits.velocityScale`).
  public static let stockVelocity = DrumKits.velocityScale(-8)
}

/// Band-limited wavetables, one per octave of fundamental (a mip map), for
/// `DJMusicality.Fixes.subtractive`: as many partials as fit under Nyquist for the highest note
/// each table plays (up to 128), where beats' tables have 8 for every note. Flattened: table `k`
/// starts at `k × (waveTableSize + 1)` and serves fundamentals up to `top[k]`.
public struct MipTables: Sendable {
  public let samples: [Float]
  public let top: [Double]
  /// The fundamentals the tables start from, doubling per table, up to 20 kHz.
  static let lowest = 20.0
  static let count = 11
  static let maxPartials = 128

  private static let cache = Mutex<[String: MipTables]>([:])

  /// The tables for `wave` ("saw" or "square") at `sampleRate`, built once per process
  /// (off the audio thread: prepare calls this).
  public static func shared(_ wave: String, sampleRate: Double) -> MipTables {
    let key = "\(wave)@\(Int(sampleRate))"
    if let t = cache.withLock({ $0[key] }) { return t }
    let t = MipTables(wave: wave, sampleRate: sampleRate)
    cache.withLock { $0[key] = t }
    return t
  }

  init(wave: String, sampleRate sr: Double) {
    let size = waveTableSize
    // Every table's fundamental as strong as in beats' table for this wave (normalised by its
    // own peak): the richer tables add harmonics, the note's weight stays.
    let beats = buildTable(wave)
    var re = 0.0
    var im = 0.0
    for i in 0..<size {
      re += Double(beats[i]) * cos(2 * Double.pi * Double(i) / Double(size))
      im += Double(beats[i]) * sin(2 * Double.pi * Double(i) / Double(size))
    }
    let fundamental = 2 * (re * re + im * im).squareRoot() / Double(size)
    var out = [Float](repeating: 0, count: Self.count * (size + 1))
    var tops: [Double] = []
    var sines = [Double](repeating: 0, count: size)
    for k in 0..<Self.count {
      let top = Self.lowest * pow(2, Double(k + 1))
      tops.append(top)
      let partials = max(1, min(Self.maxPartials, Int(0.45 * sr / top)))
      var t = [Double](repeating: 0, count: size)
      for n in 1...partials {
        let a: Double
        if wave == "square" {
          a = n % 2 == 1 ? 1 / Double(n) : 0
        } else {
          a = 1 / Double(n)
        }
        guard a != 0 else { continue }
        for i in 0..<size {
          sines[i] = sin(2 * Double.pi * Double(n) * Double(i) / Double(size))
        }
        for i in 0..<size { t[i] += a * sines[i] }
      }
      // the fundamental's amplitude is 1 (a = 1 for n = 1) before scaling
      let base = k * (size + 1)
      for i in 0..<size { out[base + i] = Float(t[i] * fundamental) }
      out[base + size] = out[base]
    }
    samples = out
    top = tops
  }
}

/// `DJMusicality.Fixes.hfTilt` (ROADMAP 6.6): the mix's top end tilted down at the voices that
/// carry it, not on the master. beats' hat, open hat and dj's crash are highpassed white noise
/// (`drumVoice`, WaveSynth.swift): flat from 7 kHz (4.2 kHz for the crash) up to Nyquist, so a
/// drum genre's long-term spectrum rises again past 10 kHz (research M7: a +6–12 dB bump at
/// 16 kHz over the 63 Hz … 8 kHz fit, where a mastered record keeps falling). Under the fix those
/// lanes run a second-order lowpass after their own filter, at a cutoff per family
/// (`MixTargets.hfTiltHz`, targets.json `hfTilt`): their 7–10 kHz sizzle stays, the air above
/// falls 12 dB an octave. A dj voice: beats' kit table (`kits`, the synth.js port the parity
/// fixtures run) is untouched, and `WaveOptions()` never sets it.
public struct HFTilt: Sendable, Equatable {
  /// The lowpass's cutoff on hat / open hat lanes, Hz.
  public var hatHz: Double
  /// …and on the crash (`.crash`): the same, it is the same noise an octave lower.
  public var crashHz: Double
  /// Butterworth: no peak at the cutoff.
  public var q = 0.5.squareRoot()

  public init(hatHz: Double, crashHz: Double? = nil) {
    self.hatHz = hatHz
    self.crashHz = crashHz ?? hatHz
  }

  /// The cutoff for a drum lane of `kind` (`drumKind`'s, or "crash"); nil for what the tilt
  /// leaves alone (kick, snare, clap: their noise is band-passed under 4 kHz already).
  public func lowpassHz(kind: String) -> Double? {
    switch kind {
    case "hat", "openhat": return hatHz
    case "crash": return crashHz
    default: return nil
    }
  }

  /// The tilt a track of `genre` plays with: its family's cutoff from targets.json.
  public static func forGenre(_ genre: String) -> HFTilt? {
    let names = GrooveTemplate.familyNames
    let family = names[min(max(BeatsTables.shared.family(of: genre), 0), names.count - 1)]
    return MixTargets.shared.hfTiltHz(family: family).map { HFTilt(hatHz: $0) }
  }
}
