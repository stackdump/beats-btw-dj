// The master-chain macros of beats' catalog (lib/macros/catalog.js): the FX, pitch and feel
// kinds, which drive beats' master FX sliders (and, for feel, the tempo) rather than the net.
// Kept apart from `NetMacro`: those are tick-locked net effects with their own mirror
// (`MacroMirror` sizes its record by `NetMacro.allCases`), these are timed in seconds on the
// transport clock and act on the deck's `MasterChain`.
//
// Ported: what reaches wave audio when beats routes the wave engine through Tone (`&fx=tone`,
// lib/backend/wave.js `connectOutput`): the master inserts HP, LP, phaser, bit crusher,
// distortion and pitch shift, and the tempo. NOT ported, because nothing of theirs reaches wave
// audio in beats (the reverb and delay are sends fed only by Tone's channel strips; pan and decay
// act on Tone channel strips): `delay-throw`, `cathedral`, `dub-delay`, the Pan macros
// (`ping-pong`, `hard-left`, `hard-right`, `auto-pan`, `mono`) and the Shape macros (`tighten`,
// `loosen`, `pulse`). Two macros are ported in part, for the same reason: `reverb-wash` keeps its
// HP move (its reverb wet / size / damp moves are dropped) and `riser` its HP and phaser moves
// (its reverb wet move is dropped). See ROADMAP 3.3.
//
// The catalog data here is checked against beats' own (macro-fx.json `meta.catalog`) by
// `MasterFxParityTests`.

/// One of beats' master FX sliders (lib/ui/build.js, `.pn-fx-slider[data-fx=…]`): an integer
/// position on the slider's own range, mapped to the engine by `applyFx`.
public enum MasterFxKey: Int, CaseIterable, Sendable {
  case hpFreq, lpFreq, phaserFreq, phaserDepth, phaserWet, crushBits, distortion, masterPitch

  public var id: String {
    switch self {
    case .hpFreq: "hp-freq"
    case .lpFreq: "lp-freq"
    case .phaserFreq: "phaser-freq"
    case .phaserDepth: "phaser-depth"
    case .phaserWet: "phaser-wet"
    case .crushBits: "crush-bits"
    case .distortion: "distortion"
    case .masterPitch: "master-pitch"
    }
  }

  public init?(id: String) {
    guard let k = Self.allCases.first(where: { $0.id == id }) else { return nil }
    self = k
  }

  /// The `<input type="range">`'s `min` (build.js).
  public var min: Int { self == .masterPitch ? -12 : 0 }
  /// The `<input type="range">`'s `max` (build.js).
  public var max: Int { self == .masterPitch ? 12 : 100 }
  /// `data-default` (build.js), also the FX Reset / Feel Reset target (`FX_HARD_DEFAULTS`).
  public var defaultValue: Int {
    switch self {
    case .lpFreq: 100
    case .phaserDepth: 50
    default: 0
    }
  }

  /// What the browser does to `slider.value = Math.round(v)`: clamp to the range (the step is
  /// 1 and the value already whole).
  func sanitize(_ v: Double) -> Int {
    let r = jsRound(v)
    guard r.isFinite else { return Swift.max(self.min, Swift.min(self.max, defaultValue)) }
    return Int(Swift.max(Double(self.min), Swift.min(Double(self.max), r)))
  }
}

/// A master-chain macro (`lib/macros/catalog.js`).
public enum MasterMacro: UInt8, CaseIterable, Sendable {
  case sweepLp, sweepHp, reverbWash, riser, buildCrush, phaserDrone, filterRes
  case octaveUp, octaveDown, pitchBend, vinylBrake
  case feelChill, feelDrive, feelAmbient, feelEuphoric, feelBuild, feelWindDown, feelReset

  /// One slider move of an FX macro: `{ fxKey, toValue }`.
  public struct Op: Equatable, Sendable {
    public var key: MasterFxKey
    public var to: Double
  }

  public enum Kind: Equatable, Sendable {
    /// `fx-sweep`: ramp to the value over 80 % of the duration, back over the rest.
    case sweep([Op])
    /// `fx-hold`: jump to the value, hold, ramp back over the last `tailFrac` of it.
    case hold([Op], tailFrac: Double)
    /// `compound` (only `vinyl-brake`): sub-macros at offsets.
    case compound
    /// `feel-snap`: the Feel puck to a corner for the duration.
    case feelSnap(x: Double, y: Double)
    /// `feel-sweep`: ease the puck to a point, then snap back.
    case feelSweep(x: Double, y: Double)
    /// `genre-reset`: ease every FX slider to its default and the tempo to the genre's.
    case genreReset
  }

  public var id: String {
    switch self {
    case .sweepLp: "sweep-lp"
    case .sweepHp: "sweep-hp"
    case .reverbWash: "reverb-wash"
    case .riser: "riser"
    case .buildCrush: "build-crush"
    case .phaserDrone: "phaser-drone"
    case .filterRes: "filter-res"
    case .octaveUp: "octave-up"
    case .octaveDown: "octave-down"
    case .pitchBend: "pitch-bend"
    case .vinylBrake: "vinyl-brake"
    case .feelChill: "feel-chill"
    case .feelDrive: "feel-drive"
    case .feelAmbient: "feel-ambient"
    case .feelEuphoric: "feel-euphoric"
    case .feelBuild: "feel-build"
    case .feelWindDown: "feel-wind-down"
    case .feelReset: "feel-reset"
    }
  }

  public var label: String {
    switch self {
    case .sweepLp: "Sweep LP"
    case .sweepHp: "Sweep HP"
    case .reverbWash: "Reverb Wash"
    case .riser: "Riser"
    case .buildCrush: "Bit Crush"
    case .phaserDrone: "Phaser Drone"
    case .filterRes: "Res Ping"
    case .octaveUp: "Octave Up"
    case .octaveDown: "Octave Down"
    case .pitchBend: "Pitch Bend"
    case .vinylBrake: "Vinyl Brake"
    case .feelChill: "Chill"
    case .feelDrive: "Drive"
    case .feelAmbient: "Ambient"
    case .feelEuphoric: "Euphoric"
    case .feelBuild: "Build Up"
    case .feelWindDown: "Wind Down"
    case .feelReset: "Reset"
    }
  }

  public var group: String {
    switch self {
    case .sweepLp, .sweepHp, .reverbWash, .riser, .buildCrush, .phaserDrone, .filterRes: "FX"
    case .octaveUp, .octaveDown, .pitchBend, .vinylBrake: "Pitch"
    default: "Feel"
    }
  }

  /// Bars (every one of these is in bars).
  public var defaultDuration: Int {
    switch self {
    case .sweepLp, .riser, .feelBuild, .feelWindDown, .feelReset: 4
    case .octaveUp, .octaveDown, .vinylBrake: 1
    default: 2
    }
  }

  public var durationOptions: [Int] {
    switch self {
    case .riser, .feelBuild, .feelWindDown: [2, 4, 8]
    case .filterRes, .vinylBrake: [1, 2]
    case .octaveUp, .octaveDown, .pitchBend: [1, 2, 4]
    case .feelReset: [2, 4, 8, 16]
    default: [1, 2, 4, 8]
    }
  }

  public var kind: Kind {
    switch self {
    case .sweepLp: .sweep([Op(key: .lpFreq, to: 5)])
    case .sweepHp: .sweep([Op(key: .hpFreq, to: 80)])
    // beats: reverb-wet 95, reverb-size 90, reverb-damp 15 (dropped: no reverb on wave audio)
    case .reverbWash: .hold([Op(key: .hpFreq, to: 30)], tailFrac: 0.55)
    // beats: reverb-wet 80 between the two (dropped)
    case .riser: .sweep([Op(key: .hpFreq, to: 70), Op(key: .phaserWet, to: 60)])
    case .buildCrush: .sweep([Op(key: .crushBits, to: 80), Op(key: .distortion, to: 20)])
    // no tailFrac in the catalog: fxHold's default, 0.6
    case .phaserDrone:
      .hold(
        [
          Op(key: .phaserWet, to: 90), Op(key: .phaserDepth, to: 100), Op(key: .phaserFreq, to: 40),
        ],
        tailFrac: 0.6)
    case .filterRes: .sweep([Op(key: .lpFreq, to: 40), Op(key: .distortion, to: 30)])
    case .octaveUp: .hold([Op(key: .masterPitch, to: 12)], tailFrac: 0.3)
    case .octaveDown: .hold([Op(key: .masterPitch, to: -12)], tailFrac: 0.3)
    case .pitchBend: .sweep([Op(key: .masterPitch, to: 7)])
    case .vinylBrake: .compound
    case .feelChill: .feelSnap(x: 0, y: 0)
    case .feelDrive: .feelSnap(x: 1, y: 0)
    case .feelAmbient: .feelSnap(x: 0, y: 1)
    case .feelEuphoric: .feelSnap(x: 1, y: 1)
    case .feelBuild: .feelSweep(x: 0.85, y: 0.85)
    case .feelWindDown: .feelSweep(x: 0.25, y: 0.30)
    case .feelReset: .genreReset
    }
  }

  public init?(id: String) {
    guard let m = Self.allCases.first(where: { $0.id == id }) else { return nil }
    self = m
  }

  /// Its bit in `WaveDeckSource.activeMasterMacros`' mask.
  var bit: UInt32 { 1 << UInt32(rawValue) }
}
