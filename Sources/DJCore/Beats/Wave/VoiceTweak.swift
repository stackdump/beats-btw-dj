import Foundation

/// The performer's own shaping of one channel's synth voice (the sound panel: long press on an
/// instrument): each field set replaces that part of the instrument's voice (`InstrumentTable`),
/// each nil leaves the instrument's own. Empty = the instrument exactly.
///
/// A poke like any other (`DeckAction.voiceTweak`, recorded with its values inline), applied live
/// to the playing song (`WaveCommand.voice`, at the next block). Session-only: it lives on the deck
/// (`WaveDeckSource.voiceSettings`) for the song it was made on, through its recompiles (section
/// jumps, the next bar's swap, an instrument change on another channel), and is never written into
/// the share payload, a favorite or the canonical text. Saved variations are
/// `VoiceVariationStore`'s.
public struct VoiceTweak: Equatable, Sendable {
  /// Gain on the instrument's level, dB.
  public var gainDB: Double?
  /// Attack time constant, seconds.
  public var attack: Double?
  /// A note's decay time constant as a multiple of its length…
  public var decayScale: Double?
  /// …at most this long, seconds.
  public var maxDecay: Double?
  /// Brightness: the post lowpass on the voice sum, Hz (0 = off).
  public var lowpass: Double?
  /// Drive: Tone.Distortion amount, 0…1 (0 = off).
  public var distortion: Double?
  /// Vibrato rate, Hz, and depth, a fraction of the frequency.
  public var vibratoRate: Double?
  public var vibratoDepth: Double?
  /// Pitch sweep: each note starts at `pitchFrom` × its frequency and glides to `pitchTo` × over
  /// `pitchTime` seconds (0 = off). Applied as a group: a tweak that sets one sets all three.
  public var pitchFrom: Double?
  public var pitchTo: Double?
  public var pitchTime: Double?

  public init(
    gainDB: Double? = nil, attack: Double? = nil, decayScale: Double? = nil,
    maxDecay: Double? = nil, lowpass: Double? = nil, distortion: Double? = nil,
    vibratoRate: Double? = nil, vibratoDepth: Double? = nil, pitchFrom: Double? = nil,
    pitchTo: Double? = nil, pitchTime: Double? = nil
  ) {
    self.gainDB = gainDB
    self.attack = attack
    self.decayScale = decayScale
    self.maxDecay = maxDecay
    self.lowpass = lowpass
    self.distortion = distortion
    self.vibratoRate = vibratoRate
    self.vibratoDepth = vibratoDepth
    self.pitchFrom = pitchFrom
    self.pitchTo = pitchTo
    self.pitchTime = pitchTime
  }

  /// The JSON keys, in the panel's order.
  public static let keys = [
    "gainDB", "attack", "decayScale", "maxDecay", "lowpass", "distortion", "vibratoRate",
    "vibratoDepth", "pitchFrom", "pitchTo", "pitchTime",
  ]

  /// Where each value may go (anything else is clamped into it): wide enough for any sound worth
  /// playing, narrow enough that none blows up the mix.
  public static let ranges: [String: ClosedRange<Double>] = [
    "gainDB": -48...24, "attack": 0.0005...4, "decayScale": 0.05...20, "maxDecay": 0.03...10,
    "lowpass": 0...20_000, "distortion": 0...1, "vibratoRate": 0...20, "vibratoDepth": 0...0.1,
    "pitchFrom": 0.05...32, "pitchTo": 0.05...32, "pitchTime": 0...4,
  ]

  nonisolated(unsafe) private static let paths: [String: WritableKeyPath<VoiceTweak, Double?>] = [
    "gainDB": \.gainDB, "attack": \.attack, "decayScale": \.decayScale, "maxDecay": \.maxDecay,
    "lowpass": \.lowpass, "distortion": \.distortion, "vibratoRate": \.vibratoRate,
    "vibratoDepth": \.vibratoDepth, "pitchFrom": \.pitchFrom, "pitchTo": \.pitchTo,
    "pitchTime": \.pitchTime,
  ]

  public subscript(key: String) -> Double? {
    get { Self.paths[key].flatMap { self[keyPath: $0] } }
    set {
      guard let p = Self.paths[key] else { return }
      self[keyPath: p] = newValue.map { Self.clamp(key, $0) }
    }
  }

  static func clamp(_ key: String, _ v: Double) -> Double {
    guard v.isFinite, let r = ranges[key] else { return ranges[key]?.lowerBound ?? 0 }
    // a cutoff below 40 Hz is "off"
    if key == "lowpass" && v < 40 { return 0 }
    return min(r.upperBound, max(r.lowerBound, v))
  }

  public var isEmpty: Bool { Self.keys.allSatisfy { self[$0] == nil } }

  /// Does it set the pitch sweep?
  var setsPitch: Bool { pitchFrom != nil || pitchTo != nil || pitchTime != nil }

  /// `voice` with this tweak on it (what the panel shows, and what the lanes play).
  public func applied(to voice: VoiceSpec) -> VoiceSpec {
    var v = voice
    if let g = gainDB { v.level = voice.level * pow(10, g / 20) }
    if let x = attack { v.attack = x }
    if let x = decayScale { v.decayScale = x }
    if let x = maxDecay { v.maxDecay = x }
    if let x = lowpass { v.lowpass = x }
    if let x = distortion { v.distortion = x }
    if let x = vibratoRate { v.vibratoRate = x }
    if let x = vibratoDepth { v.vibratoDepth = x }
    if let x = pitchFrom { v.pitchFrom = x }
    if let x = pitchTo { v.pitchTo = x }
    if let x = pitchTime { v.pitchTime = x }
    return v
  }

  /// The set fields only, in key order (an empty object for an empty tweak).
  public var json: JSONValue {
    .object(JSONObject(Self.keys.compactMap { k in self[k].map { (k, .number($0)) } }))
  }

  /// Reads the fields it knows (clamped); ignores the rest.
  public init(json v: JSONValue?) {
    self.init()
    for k in Self.keys { if let x = v?[k]?.double { self[k] = x } }
  }
}

/// A channel's voice settings on a deck: the tweak, whether a sampled channel plays its synth
/// voice instead ("Use synth voice"), and the instrument they were made for (an instrument change
/// on that channel starts from the new instrument's own voice).
public struct VoiceSetting: Equatable, Sendable {
  public var tweak: VoiceTweak
  public var useSynth: Bool
  public var instrument: String
  public init(tweak: VoiceTweak = VoiceTweak(), useSynth: Bool = false, instrument: String) {
    self.tweak = tweak
    self.useSynth = useSynth
    self.instrument = instrument
  }
  public var isDefault: Bool { tweak.isEmpty && !useSynth }
}

/// What a deck's channel plays, for the sound panel: its instrument, the instrument's own voice,
/// and what can be shaped.
public struct ChannelVoice: Equatable {
  public var channel: Int
  public var instrument: String
  /// The instrument's own synth voice (`InstrumentTable`, before any tweak).
  public var voice: VoiceSpec
  /// A synth voice with notes (false: a drum kit, whose level alone can be set).
  public var tonal: Bool
  /// Plays a sampled sound (EXS / SoundFont) unless switched to its synth voice.
  public var sampled: Bool
  /// A Karplus-Strong string: no pitch sweep.
  public var pluck: Bool
}

/// A tweak made concrete for the lanes of one channel (main thread, `WaveProject.voiceParams`):
/// the coefficients the audio thread installs as they are. Plain values only, so it crosses the
/// command ring (`WaveCommand.voice`). A field whose bit is clear in `mask` puts the lane's own
/// (prepared) value back: every lane restores exactly what its instrument had.
public struct VoiceLaneParams: BitwiseCopyable, Equatable, Sendable {
  public var channel: Int16
  var mask: UInt16 = 0
  var useSynth = false
  var levelMul = 1.0
  var attMul = 0.0
  var decayScale = 0.0
  var maxDecay = 0.0
  var postOn = false
  var b0 = 0.0
  var b1 = 0.0
  var b2 = 0.0
  var b3 = 0.0
  var b4 = 0.0
  var distortion = 0.0
  var vibInc = 0.0
  var vibDepth = 0.0
  var pmOn = false
  var pitchFrom = 1.0
  var pitchTo = 1.0
  var pmMul = 1.0

  static let level: UInt16 = 1 << 0
  static let attack: UInt16 = 1 << 1
  static let decayScale: UInt16 = 1 << 2
  static let maxDecay: UInt16 = 1 << 3
  static let lowpass: UInt16 = 1 << 4
  static let drive: UInt16 = 1 << 5
  static let vibRate: UInt16 = 1 << 6
  static let vibDepth: UInt16 = 1 << 7
  static let pitch: UInt16 = 1 << 8
  static let synth: UInt16 = 1 << 9

  @inline(__always) func has(_ bit: UInt16) -> Bool { mask & bit != 0 }

  /// `tweak` (and the synth switch) for channel `channel` at `sampleRate`; `voice` is the
  /// instrument's own, which fills a pitch sweep the tweak only partly sets. The arithmetic is
  /// prepare's (`tonalLane`), so a value equal to the instrument's gives the same bits.
  public init(
    channel: Int, tweak t: VoiceTweak, useSynth: Bool, voice: VoiceSpec?, sampleRate sr: Double
  ) {
    self.channel = Int16(clamping: channel)
    if let g = t.gainDB {
      mask |= Self.level
      levelMul = pow(10, g / 20)
    }
    if let a = t.attack {
      mask |= Self.attack
      attMul = exp(-1 / (a * sr))
    }
    if let x = t.decayScale {
      mask |= Self.decayScale
      decayScale = x
    }
    if let x = t.maxDecay {
      mask |= Self.maxDecay
      maxDecay = x
    }
    if let fc = t.lowpass {
      mask |= Self.lowpass
      postOn = fc > 0
      if postOn {
        let b = biquad(type: "lowpass", fc: fc, q: 1, sr: sr)
        (b0, b1, b2, b3, b4) = (b[0], b[1], b[2], b[3], b[4])
      }
    }
    if let x = t.distortion {
      mask |= Self.drive
      distortion = x
    }
    if let x = t.vibratoRate {
      mask |= Self.vibRate
      vibInc = x / sr
    }
    if let x = t.vibratoDepth {
      mask |= Self.vibDepth
      vibDepth = x
    }
    if t.setsPitch {
      mask |= Self.pitch
      pitchFrom = t.pitchFrom ?? voice?.pitchFrom ?? 1
      pitchTo = t.pitchTo ?? voice?.pitchTo ?? 1
      let time = t.pitchTime ?? voice?.pitchTime ?? 0
      pmOn = time > 0 && pitchFrom != pitchTo
      if pmOn { pmMul = pow(pitchTo / pitchFrom, 1 / (time * sr)) }
    }
    if useSynth {
      mask |= Self.synth
      self.useSynth = true
    }
  }
}
