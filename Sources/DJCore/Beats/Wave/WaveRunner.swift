import Foundation
import Synchronization

// Port of beats' wave-engine/runner.js: the net executor and the synthesis, sample by
// sample. Per sample: advance the tick clock; at a tick boundary fire the net and add
// each audible fire's weight to its lane's gate; every active lane then outputs
// gate × carrier and the lanes are summed through the master curve.
//
// The gate is the IIR realisation of synth.js::envelope: one state per exponential,
// multiplied down each sample and bumped by α·w at each onset.
//
// This is the parity port: arithmetic and operation order follow the JS exactly so
// the audio matches within float32 rounding. It is not yet the real-time-safe form
// (ROADMAP 3.1 hardens `process` for the audio thread).

private let ppq = 4.0
private let silent = 1e-6

// lane state slots
private let slotEnv = 0
private let slotPrev = 1
private let slotLevel = 2
private let slotPhase = 3
private let slotSweep = 4
private let slotSweepMul = 5
private let slotF0 = 6
private let slotF1 = 7
private let slotToneInc = 8
private let slotToneMix = 9
private let slotZ1 = 10
private let slotZ2 = 11
private let slotAmDepth = 12
private let slotFmDepth = 13
private let slotInvSr = 14
private let slotAttMul = 15
private let stateSize = 16

enum Carrier { case dc, sweep, noise, noiseTone }

/// `opts.mods` entry: an outer ring's gate scales (am) or bends (fm) an inner one.
public struct WaveMod {
  public var target: String
  public var source: String
  public var kind: String  // "am" | "fm"
  public var depth: Double
  public var silentSource = false
  public init(
    target: String, source: String, kind: String, depth: Double, silentSource: Bool = false
  ) {
    self.target = target
    self.source = source
    self.kind = kind
    self.depth = depth
    self.silentSource = silentSource
  }
}

public struct WaveOptions {
  /// "soft" (beats' tanh, default), "linear" (tests), or "limit" (the app,
  /// `WaveOptions.extended`): the runner's sum stays linear and the deck ends in a lookahead
  /// peak limiter (`PeakLimiter`, in `WaveDeckSource`) after the master chain, so the loudness
  /// gain can bring a track up to `LevelMatch.referenceLUFS` without driving the tanh.
  public var master = "soft"
  public var masterGain = 0.8
  public var voices: [String: VoiceSpec] = [:]
  public var mods: [WaveMod] = []
  /// Per-instrument voices (`InstrumentTable`); nil = beats' families only (parity).
  public var instruments: InstrumentTable?
  /// Where sampled instruments play (a deck's bank). nil = synth voices only.
  public var samplers: SamplerBank?
  /// Seeds which sampled instrument each role gets (`VoiceCatalog`): the track's seed, so a
  /// track keeps its instruments across section jumps and replays.
  public var voicingSeed = 0.0
  /// dj's fixes to a composed track (`DJMusicality`), run by `PreparedTrack`; none = the
  /// project exactly as composed (parity).
  public var musicality: DJMusicality.Fixes = []
  /// The gain to prepare with instead of measuring one (`Loudness`): a section jump or a
  /// relocation of the song already playing reuses that project's.
  public var trackGain: Double?
  /// Likewise the energy curve (`EnergyCurve`, measured from the project): another start of the
  /// same song reuses the playing project's.
  public var trackEnergy: EnergyCurve?
  /// Kick-keyed ducking of the bass and pad (`DJMusicality.Fixes.duck`): how far they dip on
  /// each kick (0 = none), set from the track's genre (`DJMusicality.duckDepth`).
  public var duckDepth = 0.0
  /// The room (`DJMusicality.Fixes.space`), set from the track's genre (`SpaceSpec.forGenre`);
  /// nil with `.space` on plays `SpaceSpec.room`.
  public var space: SpaceSpec?
  /// The echo (`DJMusicality.Fixes.echo`), set from the track's genre (`EchoSpec.forGenre`);
  /// nil = none.
  public var echo: EchoSpec?
  /// Per-genre sound design under `.subtractive` / `.unison` / `.stereo` (`VoiceDesign.forGenre`,
  /// set by `forGenre`): which parts are plucked, how wide the pads are.
  public var voiceDesign = VoiceDesign()
  /// The parts' trims (`DJMusicality.Fixes.balance`, dB by `MixBalance` part) to prepare with
  /// instead of measuring them: another start of the same song reuses the playing project's.
  public var trackBalance: [String: Double]?
  /// The rest schedule (`RestSchedule.build`) to prepare with instead of building one: another
  /// start of the same song reuses the playing project's.
  public var trackRests: RestSchedule?
  /// A mix-out tail (`MixOutTail`): the melodic lanes rest from its `fromTick`, the song's
  /// `stop-transport` is ignored, and the deck stops on its `endTick`. nil = the song as it
  /// ends (parity, and every deck until `Deck.mixOut` sets one).
  public var tail: MixOutTail?
  /// The track's genre, set by `forGenre`; nil (raw nets, parity) = unknown, and the gestures
  /// a genre gates (`.bandStop`: the song family) stay off.
  public var genre: String?
  /// The family's groove template the drums play (`DJMusicality.Fixes.feel`), set from the
  /// track's genre (`GrooveTemplate.forGenre`); nil = none, even with `.feel` on.
  public var feel: GrooveTemplate?
  /// Brushes on the snare (`Brush`, `DJMusicality.Fixes.backbeat`'s jazz): its synth lanes play
  /// the brush voice, a sampled kit's play the bank's Brush kit (or the kit's own snare, softer).
  /// Set by `forGenre`; false = beats' snare (parity, and every other genre).
  public var brushes = false
  /// Roles whose notes are dropped at compile time (`djctl export --mute/--solo`): the nets
  /// still run, so everything else plays exactly as it would. nil = all play.
  public var roleFilter: RoleFilter?
  /// `vinyl-brake` as a turntable brake (`WaveDeckSource`, TurntableBrake.swift): the whole
  /// deck slows to a stop and drops back in time. false = beats' compound (an octave-down hold:
  /// its tape-stop step does nothing there), what the parity fixtures run. A deliberate dj
  /// divergence (GO-DIVERGENCE.md §5); on in `WaveOptions.extended`.
  public var turntableBrake = false
  /// The loudness probe's stand-in for sampled parts (`Loudness.measure`): net id → a level on
  /// its tonal lane, so its synth voice sounds about as loud as the sampler the deck plays there
  /// (`WaveProject.sampledGroups`, `Loudness.sampledPartDB`). Empty everywhere else.
  var probeLevels: [String: Double] = [:]
  public var onTick: ((WaveRunner) -> Void)?
  /// Offline only (`GrooveReport`, `djctl render`): called on the render thread with every
  /// onset the runner plays, at the sample it plays on (`HitRecord`; a held-back groove note
  /// when it is due). Read once when the runner is made. nil (everywhere but measurement) costs
  /// one nil check per hit, and the hook never changes what plays.
  public var onHit: ((HitRecord) -> Void)?
  public init() {}
}

/// Which roles a render keeps. A net is named by its id, its riff group (`bass` for
/// `bass-3`) and its mixer group (`drums`, `bass`, `melody`, `arp`, `harmony`, `stinger`);
/// drum fills (`fill-N`) count as `drums`.
public struct RoleFilter: Sendable, Equatable {
  public var mute: Set<String>
  /// When set, only these play.
  public var solo: Set<String>?

  public init(mute: Set<String> = [], solo: Set<String>? = nil) {
    self.mute = mute
    self.solo = solo
  }

  public var isEmpty: Bool { mute.isEmpty && solo == nil }

  func silences(_ id: String, _ nb: NetBundle) -> Bool {
    var names: Set<String> = [id]
    if !nb.riffGroup.isEmpty { names.insert(nb.riffGroup) }
    if let g = nb.track.group, !g.isEmpty { names.insert(g) }
    if id.hasPrefix("fill-") { names.insert("drums") }
    if !names.isDisjoint(with: mute) { return true }
    if let solo { return names.isDisjoint(with: solo) }
    return false
  }

  /// `project` with the silenced nets' note bindings removed.
  public func apply(_ project: Project) -> Project {
    guard !isEmpty else { return project }
    var p = project
    for id in p.nets.keys {
      guard let nb = p.nets[id], nb.role != "control", !nb.bindings.keys.isEmpty,
        silences(id, nb)
      else { continue }
      p.nets[id]!.bindings = OrderedMap()
    }
    return p
  }
}

final class Lane {
  let isTonal: Bool
  let voice: VoiceSpec
  var active = false
  var st: [Double]
  var numExp = 0
  var alpha: [Double] = []
  var mul: [Double] = []
  var s: [Double] = []
  var carrier: Carrier = .dc
  var rng: Int32 = 1
  var bq: [Double] = [0, 0, 0, 0, 0]
  var am: Lane?
  var fm: Lane?
  var netId = ""
  // tonal pool
  var table: [Float] = []
  var poly = 0
  var inc: [Double] = []
  var phase: [Double] = []
  var sd: [Double] = []
  var sa: [Double] = []
  var md: [Double] = []
  /// Live keys: a held voice does not decay until released.
  var hold: [Bool] = []
  var heldNote: [Int] = []
  // pluck engine: one delay line of `dmax` samples per voice, all in `dl` (allocated at
  // prepare; the audio thread only reads and writes it)
  var isPluck = false
  var dl: [Float] = []
  var dmax = 0
  var dw: [Int] = []
  var dlen: [Double] = []
  var lp: [Double] = []
  var fb: [Double] = []
  var excite: [Int] = []
  var pluckA = 0.0
  var vibPhase = 0.0
  var vibInc = 0.0
  // pitch envelope: each voice's current multiplier, its per-sample step, where it stops
  var pmOn = false
  var pm: [Double] = []
  var pmMul = 1.0
  // sampled instrument: a slot in the deck's SamplerBank (-1 = synth voice); notes sound
  // there and this lane only keeps their note-offs (sample time, fixed capacity)
  var samplerSlot = -1
  /// A drum lane on a sampled kit (`Track.kit`): the GM key it plays and how long each hit is
  /// held (`DrumKits.gmNote` / `holdMs`).
  var kitNote = 36
  var kitHoldMs = 400.0
  /// …and its hits' velocity scale: `.balance`'s kick trim as a velocity (`DrumKits.velocityScale`).
  var kitVelocity = 1.0
  var offNote = [Int](repeating: 0, count: 64)
  var offAt = [Double](repeating: 0, count: 64)
  var offCount = 0
  var nextOff = Double.infinity
  /// Bass / pad voice that dips on the kick (`WaveOptions.duckDepth`); the kick that keys it.
  var ducks = false
  var isKick = false
  /// What the prepare keyed it by (`kick`, `snare`, `clap`, `hat`, `openhat`, `crash`,
  /// `tonal`, `v` for a voice override): `HitRecord.kind`.
  var kind = ""
  /// `.stereo`: side gain of the whole lane, and per voice when its voices spread (empty: all
  /// at `pan`). 0 = centre. `voiceSpread` is each voice's offset at full width (±spread);
  /// `voicePan` what it plays at, narrowed for low notes when the voice is struck.
  var pan = 0.0
  var voiceSpread: [Double] = []
  var voicePan: [Double] = []
  /// What the lane is for the rest schedule (`WaveProject.rests`): it drops its hits while the
  /// step's mask holds its class. Empty (never rests): crashes, stingers, overrides, the live
  /// keys.
  var restClass: RestSchedule.Class = []
  /// `.sectionHarmony` / `.harmonicRhythm`: the lane's group in `WaveProject.harmony` (-1: not
  /// moved, e.g. drums and the live keys).
  var harmonyGroup = -1
  /// `.choke`: the open hat a hit on this (closed hat) lane chokes; on the open hat lane,
  /// whether it is being choked and how fast it dies then (per sample).
  var choke: Lane?
  var choking = false
  var chokeMul = 1.0
  /// `.space`: how much of the lane goes to the reverb send (`SpaceSpec.send`).
  var send = 0.0
  /// `.echo`: how much goes to the echo (`EchoSpec.send`).
  var echoSend = 0.0
  /// `.subtractive`: band-limited tables by octave (`MipTables`; empty = `table` for every
  /// note) and the table each voice reads (`mipBase`); a two-pole lowpass per voice (`fz1`,
  /// `fz2`) whose cutoff is `fBase` × the note's frequency plus `fAmount` × velocity²
  /// (`fVel`) × an envelope (`fEnv`) that falls by `fMul` a sample. `fAmount` 0: no filter.
  var mip: [Float] = []
  var mipTop: [Double] = []
  var mipBase: [Int] = []
  var fAmount = 0.0
  var fBase = 0.0
  var fMul = 0.0
  var fK = 1.0
  var fEnv: [Double] = []
  var fVel: [Double] = []
  var fz1: [Double] = []
  var fz2: [Double] = []
  /// `.unison`: each voice is two oscillators, `uniDown` and `uniUp` × its frequency (1 = off),
  /// the second with its own phase (`phase2`); with `.stereo` (`uniWide`) they sit either side,
  /// `uniWidth` apart for the voice's note (centred low, as `voicePan` is).
  var uniDown = 1.0
  var uniUp = 1.0
  var phase2: [Double] = []
  var uniWide = false
  var uniWidth: [Double] = []
  /// …and their difference is highpassed (`Unison.sideHz`), so the low mids stay mono.
  var uniHP: [Double] = []
  /// The pair's width at full spread (`Unison.width`, × `VoiceDesign.padWidth` on a pad).
  var uniMax = Unison.width
  var uz1 = 0.0
  var uz2 = 0.0
  // post chain on the voice sum: lowpass biquad (`post`, 5 coefficients on every tonal lane,
  // used while `postOn`), then distortion
  var post: [Double] = []
  var postOn = false
  var pz1 = 0.0
  var pz2 = 0.0
  /// `.subtractive` / a pitch sweep on a saw or square: voices read `mip` (else `table`).
  var mipOn = false
  /// `.stereo`: the voices spread (`voiceSpread`) and nothing on the voice sum is in the way.
  var spreadOn = false
  // What the sound panel can change live (`VoiceTweak`, `setVoice`): the voice's values the
  // audio thread reads, starting as the instrument's own (`voice`).
  var decayScale: Double
  var maxDecay: Double
  var vibDepth: Double
  var distortion: Double
  var pitchFrom: Double
  var pitchTo: Double
  /// The MIDI channel of the net this lane plays (the share's `tracks` key; -1 for live keys).
  var channel = -1
  var instrument = ""
  /// The sampler slot this lane was bound to at prepare (-1: none): what `samplerSlot` goes back
  /// to after "Use synth voice" is turned off, and what the project gives back on `deinit`.
  var sampledSlot = -1
  // The prepared values `setVoice` restores for a field the tweak leaves alone (`captureBase`).
  var baseLevel = 0.0
  var baseAttMul = 0.0
  var basePost: [Double] = []
  var basePostOn = false
  var baseVibInc = 0.0
  var basePmOn = false
  var basePmMul = 1.0
  var baseSpread = false

  init(voice: VoiceSpec, sr: Double, tonal: Bool) {
    self.voice = voice
    isTonal = tonal
    st = [Double](repeating: 0, count: stateSize)
    st[slotLevel] = voice.level
    st[slotInvSr] = 1 / sr
    decayScale = voice.decayScale
    maxDecay = voice.maxDecay
    vibDepth = voice.vibratoDepth
    distortion = voice.distortion
    pitchFrom = voice.pitchFrom
    pitchTo = voice.pitchTo
  }

  /// Every value `setVoice` writes, in one array (tests compare lanes bit for bit).
  var voiceState: [Double] {
    [
      st[slotLevel], st[slotAttMul], decayScale, maxDecay, postOn ? 1 : 0, distortion, vibInc,
      vibDepth, pmOn ? 1 : 0, pitchFrom, pitchTo, pmMul, mipOn ? 1 : 0, spreadOn ? 1 : 0,
      Double(samplerSlot),
    ] + (postOn ? post : [])
  }

  /// Remember what prepare made of the voice (the end of `buildLanes`).
  func captureBase() {
    sampledSlot = samplerSlot
    spreadOn = !voiceSpread.isEmpty
    baseLevel = st[slotLevel]
    baseAttMul = st[slotAttMul]
    // its own storage: sharing `post`'s, the first live write would copy it on the audio thread
    basePost = post.map { $0 }
    basePostOn = postOn
    baseVibInc = vibInc
    basePmOn = pmOn
    basePmMul = pmMul
    baseSpread = spreadOn
  }

  /// Install a channel's voice settings (`VoiceLaneParams`): each field the params set, else
  /// the lane's own prepared value. Allocation-free (the audio thread calls it, through
  /// `WaveRunner.setVoice`; a project not yet handed over is set on the main thread). A
  /// sampled lane's pending note-offs must be sent before it switches to its synth voice
  /// (`WaveRunner.applyVoice`).
  func setVoice(_ p: VoiceLaneParams) {
    st[slotLevel] = p.has(VoiceLaneParams.level) ? baseLevel * p.levelMul : baseLevel
    guard isTonal else { return }
    st[slotAttMul] = p.has(VoiceLaneParams.attack) ? p.attMul : baseAttMul
    decayScale = p.has(VoiceLaneParams.decayScale) ? p.decayScale : voice.decayScale
    maxDecay = p.has(VoiceLaneParams.maxDecay) ? p.maxDecay : voice.maxDecay
    if p.has(VoiceLaneParams.lowpass) {
      postOn = p.postOn
      if postOn && post.count == 5 {
        post[0] = p.b0
        post[1] = p.b1
        post[2] = p.b2
        post[3] = p.b3
        post[4] = p.b4
      }
    } else {
      postOn = basePostOn
      for i in 0..<min(post.count, basePost.count) { post[i] = basePost[i] }
    }
    if !postOn {
      pz1 = 0
      pz2 = 0
    }
    distortion = p.has(VoiceLaneParams.drive) ? p.distortion : voice.distortion
    vibInc = p.has(VoiceLaneParams.vibRate) ? p.vibInc : baseVibInc
    vibDepth = p.has(VoiceLaneParams.vibDepth) ? p.vibDepth : voice.vibratoDepth
    // A pitch sweep needs its per-voice multipliers (every wavetable lane has them, from
    // prepare); a string has none.
    if !isPluck && pm.count == poly {
      if p.has(VoiceLaneParams.pitch) {
        pmOn = p.pmOn
        pitchFrom = p.pitchFrom
        pitchTo = p.pitchTo
        pmMul = p.pmMul
      } else {
        pmOn = basePmOn
        pitchFrom = voice.pitchFrom
        pitchTo = voice.pitchTo
        pmMul = basePmMul
      }
      let wantMip = fAmount > 0 || (pmOn && !mip.isEmpty)
      if wantMip && !mipOn {
        // voices already sounding read the plainest table until their next strike
        let top = (mipTop.count - 1) * (waveTableSize + 1)
        for k in 0..<mipBase.count { mipBase[k] = top }
      }
      mipOn = wantMip
      if !pmOn { for k in 0..<pm.count { pm[k] = 1 } }
    }
    // a post chain on the voice sum takes the voices' spread away (one pan for all)
    spreadOn = baseSpread && !postOn && distortion == 0
    guard sampledSlot >= 0 else { return }
    let synth = p.has(VoiceLaneParams.synth) && p.useSynth
    if synth {
      samplerSlot = -1
    } else if samplerSlot < 0 {
      // back to the sample: the synth voices stop
      for k in 0..<poly {
        sd[k] = 0
        sa[k] = 0
      }
      samplerSlot = sampledSlot
    }
  }
}

private func gateLane(_ voice: VoiceSpec, _ sr: Double, _ seed: Int) -> Lane {
  let lane = Lane(voice: voice, sr: sr, tonal: false)
  lane.numExp = voice.pulse.alpha.count
  lane.alpha = voice.pulse.alpha
  lane.mul = voice.pulse.tau.map { exp(-1 / ($0 * sr)) }
  lane.s = [Double](repeating: 0, count: lane.numExp)
  switch voice.carrier {
  case "dc": lane.carrier = .dc
  case "sweep": lane.carrier = .sweep
  case "noise+tone": lane.carrier = .noiseTone
  default: lane.carrier = .noise
  }
  lane.rng = noiseSeed(seed)
  lane.st[slotF0] = voice.f0
  lane.st[slotF1] = voice.f1
  lane.st[slotToneInc] = voice.tone / sr
  lane.st[slotToneMix] = voice.toneMix
  if lane.carrier == .sweep { lane.st[slotSweepMul] = exp(-1 / (voice.sweepTau * sr)) }
  if lane.carrier == .noise || lane.carrier == .noiseTone {
    lane.bq = biquad(type: voice.filter, fc: voice.fc, q: voice.q, sr: sr)
  }
  return lane
}

private func tonalLane(
  _ voice: VoiceSpec, _ sr: Double, _ poly: Int, tables: inout [String: [Float]], seed: Int = 0
)
  -> Lane
{
  let lane = Lane(voice: voice, sr: sr, tonal: true)
  lane.rng = noiseSeed(seed)
  if voice.engine == "pluck" {
    lane.isPluck = true
    lane.dmax = Int(sr / 16) + 2  // down to ~16 Hz
    lane.dl = [Float](repeating: 0, count: poly * lane.dmax)
    lane.dw = [Int](repeating: 0, count: poly)
    lane.dlen = [Double](repeating: 1, count: poly)
    lane.lp = [Double](repeating: 0, count: poly)
    lane.fb = [Double](repeating: 0, count: poly)
    lane.excite = [Int](repeating: 0, count: poly)
    lane.pluckA = 1 - exp(-2 * Double.pi * min(voice.dampening, sr * 0.45) / sr)
  }
  lane.vibInc = voice.vibratoRate / sr
  if !lane.isPluck {
    // every wavetable lane can sweep (the sound panel turns it on live): its multipliers, and
    // for a saw or square the band-limited tables a swept note crosses octaves on (shared, built
    // once per rate), re-chosen as it falls
    lane.pm = [Double](repeating: 1, count: poly)
    if voice.wave == "saw" || voice.wave == "square" {
      let t = MipTables.shared(voice.wave, sampleRate: sr)
      lane.mip = t.samples
      lane.mipTop = t.top
      lane.mipBase = [Int](repeating: 0, count: poly)
    }
  }
  if voice.pitchTime > 0 && voice.pitchFrom != voice.pitchTo && !lane.isPluck {
    lane.pmOn = true
    lane.pmMul = pow(voice.pitchTo / voice.pitchFrom, 1 / (voice.pitchTime * sr))
    lane.mipOn = !lane.mip.isEmpty
  }
  // the lowpass's coefficients are there on every tonal lane, so it can be turned on live
  lane.post = [Double](repeating: 0, count: 5)
  if voice.lowpass > 0 {
    lane.post = biquad(type: "lowpass", fc: voice.lowpass, q: 1, sr: sr)
    lane.postOn = true
  }
  lane.st[slotAttMul] = exp(-1 / (voice.attack * sr))
  if tables[voice.wave] == nil { tables[voice.wave] = buildTable(voice.wave) }
  lane.table = tables[voice.wave]!
  lane.poly = poly
  lane.inc = [Double](repeating: 0, count: poly)
  lane.phase = [Double](repeating: 0, count: poly)
  lane.sd = [Double](repeating: 0, count: poly)
  lane.sa = [Double](repeating: 0, count: poly)
  lane.md = [Double](repeating: 0, count: poly)
  lane.hold = [Bool](repeating: false, count: poly)
  lane.heldNote = [Int](repeating: -1, count: poly)
  return lane
}

/// `.subtractive`: give a saw / square lane its band-limited tables and filter envelope.
private func shapeVoice(_ lane: Lane, group: String, plucked: Set<String>, _ sr: Double) {
  guard !lane.isPluck,
    let f = FilterEnvelope.forVoice(lane.voice, group: group, plucked: plucked)
  else { return }
  let tables = MipTables.shared(lane.voice.wave, sampleRate: sr)
  lane.mip = tables.samples
  lane.mipTop = tables.top
  lane.mipBase = [Int](repeating: 0, count: lane.poly)
  lane.mipOn = true
  lane.fAmount = f.amount
  lane.fBase = f.base
  lane.fMul = exp(-1 / (f.seconds * sr))
  lane.fK = 1 / f.q
  lane.fEnv = [Double](repeating: 0, count: lane.poly)
  lane.fVel = [Double](repeating: 0, count: lane.poly)
  lane.fz1 = [Double](repeating: 0, count: lane.poly)
  lane.fz2 = [Double](repeating: 0, count: lane.poly)
}

/// `.unison`: play a pad / saw lead lane's voices as detuned pairs; spread wide under `.stereo`
/// when the pair is unfiltered (a filtered pair shares one filter: its difference would not be).
private func detune(
  _ lane: Lane, group: String, wide: Bool, design: VoiceDesign = VoiceDesign(), _ sr: Double
) {
  guard !lane.isPluck, let c = Unison.cents(lane.voice, group: group) else { return }
  lane.uniDown = pow(2, -c / 1200)
  lane.uniUp = pow(2, c / 1200)
  lane.phase2 = (0..<lane.poly).map { 0.25 + 0.13 * Double($0) }
  lane.uniWide = wide && lane.fAmount == 0
  lane.uniWidth = [Double](repeating: 0, count: lane.poly)
  let pad = group == "harmony" || group == "pad"
  lane.uniMax = Unison.width * (pad ? design.padWidth : 1)
  lane.uniHP = biquad(
    type: "highpass", fc: pad ? design.padSideHz : Unison.sideHz, q: 0.7071, sr: sr)
}

/// `.feel` as the runner reads it: a family's `GrooveTemplate` flattened into fixed arrays
/// (`voice × 16 + step`) when a project is prepared. The swing is not folded in (unlike
/// `GrooveTemplate.Prepared`): it is worked out per hit at the tempo playing, so a tempo
/// change or a tempo macro moves it. Reading it never allocates.
struct FeelTable: Sendable {
  let offsetMs: [Double]
  let velocity: [Double]
  let swing: GrooveTemplate.Swing

  init(_ t: GrooveTemplate) {
    var off = [Double](
      repeating: 0, count: GrooveTemplate.Voice.allCases.count * GrooveTemplate.steps)
    var vel = [Double](repeating: 1, count: off.count)
    for v in GrooveTemplate.Voice.allCases {
      for s in 0..<GrooveTemplate.steps {
        off[Self.cell(v, s)] = max(0, t.offsetMs(v, step: s))
        vel[Self.cell(v, s)] = t.velocity(v, step: s)
      }
    }
    offsetMs = off
    velocity = vel
    swing = t.swing
  }

  @inline(__always) static func cell(_ voice: GrooveTemplate.Voice, _ step: Int) -> Int {
    voice.rawValue * GrooveTemplate.steps + (step & (GrooveTemplate.steps - 1))
  }

  /// The swing delay (ms) of bar step `step` at `bpm`: (2r − 1) sixteenths on the off-beat
  /// sixteenth of each pair (twice that on the off-beat eighth of the jazz family's), 0 elsewhere.
  @inline(__always) func swingMs(step: Int, bpm: Double) -> Double {
    let pair = swing.pairSteps
    guard step % pair == pair / 2, bpm > 0 else { return 0 }
    return swing.delayMs(bpm: bpm)
  }
}

/// A compiled project plus its voices: everything the audio thread needs, built off the
/// audio thread (`WaveRunner.prepare`) and handed over whole. Reference-counted so the
/// runner can pass it to a retire hook instead of freeing it on the audio thread.
public final class WaveProject: @unchecked Sendable {
  /// Process-wide, 1-based, increasing in the order projects are prepared. Stamped on every
  /// `FireEvent`, `TickAnchor` and marking snapshot so a consumer knows which project's net
  /// and place indices they refer to, across swaps at a bar boundary.
  public let generation: Int32
  /// Which song this project plays. A new track gets a new serial; relaunching the same song
  /// (a section launch, a jump to a tick: `Deck.jumpToSection`, `relocate`) prepares a new
  /// project, with a new `generation` because its tick numbering and marking start over, but
  /// keeps the song's serial. A scope keeps its history across generations of one serial.
  public let trackSerial: Int32
  /// The tick the graph was seeded at before it started (`prepare(startTick:)`); 0 from the top.
  public let startTick: Int
  public let graph: WaveGraph
  /// The published copy of this project's marking, with the layout that explains it. Created
  /// at prepare time on the preparing thread; the audio thread writes only into the mirror of
  /// the project it is running.
  public let marking: MarkingMirror
  let lanes: [Lane]
  let byNet: [String: [Int]]
  let sources: [Lane]
  /// Index in `lanes` of the pooled voice that MIDI keys play.
  let liveLane: Int
  /// The bank its sampled lanes play from; each holds a reference on its slot until this
  /// project is freed (off the audio thread), which is what keeps the slot from eviction.
  let samplers: SamplerBank?
  /// Gain on everything this project plays, before the master curve (`Loudness`; 1 = as
  /// beats has it). Set by `prepare`, before the hand-over.
  public internal(set) var gain: Double
  /// The nets whose tonal lane plays a sampled instrument, with the lane's group: what the
  /// loudness probe stands in for them (`WaveRunner.prepare`).
  var sampledGroups: [String: String] = [:]
  /// The section energy arc the deck plays (`DJMusicality.Fixes.energy`); nil = none.
  public let energy: EnergyCurve?
  /// How far bass and pad dip on each kick (0: no ducking), and the sampler slots they play.
  public let duckDepth: Double
  let duckSlots: UInt64
  /// When which lanes rest (`.dropGap` and 6.2's gestures, and the mix-out tail's); empty = none.
  public let rests: RestSchedule
  /// The song's own rests, without the tail's: what another start of the song reuses
  /// (`WaveOptions.trackRests`).
  public let songRests: RestSchedule
  /// The mix-out tail this project plays (`WaveOptions.tail`); nil = it ends with the song.
  public let tail: MixOutTail?
  /// Where the audio thread is in `rests`; reset when the project is installed or stopped.
  var restCursor = RestSchedule.Cursor()
  /// The section plan the tonal lanes play through (`.sectionHarmony`, `.harmonicRhythm`); nil =
  /// as bound.
  public let harmony: SectionHarmony?
  /// The room this project plays in (`.space`); nil = dry.
  public let space: SpaceSpec?
  /// The sampler slots of lanes that send to the room.
  let sendSlots: UInt64
  /// The echo this project plays (`.echo`); nil = none.
  public let echo: EchoSpec?
  /// The parts' trims it plays with (`.balance`), dB; nil = none.
  public let balance: [String: Double]?
  /// The groove template it plays (`.feel`); nil = none. `feelTable` is what the runner reads.
  public let feel: GrooveTemplate?
  let feelTable: FeelTable?
  /// `vinyl-brake` brakes the deck while this project plays (`WaveOptions.turntableBrake`).
  public internal(set) var turntableBrake = false
  /// The sound design it was prepared with (`WaveOptions.voiceDesign`): another start of the
  /// same song keeps it.
  public internal(set) var voiceDesign = VoiceDesign()
  private static let generations = Atomic<Int>(0)
  private static let tracks = Atomic<Int>(0)

  init(
    graph: WaveGraph, lanes: [Lane], byNet: [String: [Int]], sources: [Lane], liveLane: Int,
    samplers: SamplerBank? = nil, trackSerial: Int32? = nil, startTick: Int = 0,
    geometry: Project? = nil, gain: Double = 1, energy: EnergyCurve? = nil, duckDepth: Double = 0,
    rests: RestSchedule = .empty, songRests: RestSchedule? = nil, tail: MixOutTail? = nil,
    space: SpaceSpec? = nil, echo: EchoSpec? = nil, balance: [String: Double]? = nil,
    harmony: SectionHarmony? = nil, feel: GrooveTemplate? = nil
  ) {
    self.gain = gain
    self.feel = feel
    feelTable = feel.map(FeelTable.init)
    self.harmony = harmony
    self.echo = echo
    self.balance = balance
    self.energy = energy
    self.duckDepth = duckDepth
    self.rests = rests
    self.songRests = songRests ?? rests
    self.tail = tail
    self.space = space
    var slots: UInt64 = 0
    var sending: UInt64 = 0
    for lane in lanes where lane.samplerSlot >= 0 && lane.samplerSlot < 64 {
      if lane.ducks { slots |= 1 << UInt64(lane.samplerSlot) }
      if lane.send > 0 { sending |= 1 << UInt64(lane.samplerSlot) }
    }
    duckSlots = slots
    sendSlots = space == nil ? 0 : sending
    let gen = Int32(truncatingIfNeeded: Self.generations.add(1, ordering: .relaxed).newValue)
    let track =
      trackSerial ?? Int32(truncatingIfNeeded: Self.tracks.add(1, ordering: .relaxed).newValue)
    generation = gen
    self.trackSerial = track
    self.startTick = startTick
    marking = MarkingMirror(
      generation: gen, trackSerial: track, startTick: startTick, graph: graph,
      geometry: geometry ?? graph.project)
    self.liveLane = liveLane
    self.samplers = samplers
    self.graph = graph
    self.lanes = lanes
    self.byNet = byNet
    self.sources = sources
  }

  deinit {
    guard let samplers else { return }
    for lane in lanes where lane.sampledSlot >= 0 { samplers.release(lane.sampledSlot) }
  }

  // MARK: voice settings (the sound panel)

  /// What channel `channel` plays in this project: its instrument and that instrument's voice
  /// as prepared, before any tweak. nil when no net of the project is on that channel. Reads
  /// only what prepare wrote: safe on the main thread while the audio thread plays it.
  public func channelVoice(_ channel: Int) -> ChannelVoice? {
    let on = lanes.filter { $0.channel == channel }
    guard let first = on.first(where: \.isTonal) ?? on.first else { return nil }
    return ChannelVoice(
      channel: channel, instrument: first.instrument, voice: first.voice, tonal: first.isTonal,
      sampled: on.contains { $0.sampledSlot >= 0 }, pluck: first.isPluck)
  }

  /// `setting` made concrete for this project's lanes on `channel` (main thread).
  func voiceParams(channel: Int, _ setting: VoiceSetting, sampleRate: Double) -> VoiceLaneParams {
    VoiceLaneParams(
      channel: channel, tweak: setting.tweak, useSynth: setting.useSynth,
      voice: channelVoice(channel)?.voice, sampleRate: sampleRate)
  }

  /// Set the voice of every lane on `p.channel`. For a project the audio thread does not have
  /// yet (`WaveDeckSource.load`, before the hand-over); the one it plays is set through
  /// `WaveCommand.voice`.
  func applyVoice(_ p: VoiceLaneParams) {
    for lane in lanes where lane.channel == Int(p.channel) { lane.setVoice(p) }
  }
}

private func buildLanes(
  _ g: WaveGraph, _ sr: Double, _ opts: WaveOptions, trackSerial: Int32? = nil, startTick: Int = 0,
  geometry: Project? = nil, gain: Double = 1, energy: EnergyCurve? = nil,
  rests: RestSchedule = .empty, songRests: RestSchedule? = nil, tail: MixOutTail? = nil,
  harmony: SectionHarmony? = nil
) -> WaveProject {
  var lanes: [Lane] = []
  var byNet: [String: [Int]] = [:]
  var tables: [String: [Float]] = [:]
  var sampledGroups: [String: String] = [:]
  // `.fills` / `.buildup` / `.crash`: beats' drum-fill nets are control nets with notes; give
  // them a voice.
  let voiceFills = !opts.musicality.isDisjoint(with: [.fills, .buildup, .crash])
  let voiceCrash = opts.musicality.contains(.crash)
  let voiceOpenHats = opts.musicality.contains(.openHats)
  let stereo = opts.musicality.contains(.stereo)
  let space = opts.musicality.contains(.space)
  let subtractive = opts.musicality.contains(.subtractive)
  let unison = opts.musicality.contains(.unison)
  let echo = opts.musicality.contains(.echo) && opts.echo != nil
  let kickHz =
    opts.musicality.contains(.kickTune) ? KickTuning.hz(root: g.project.rootNote) : nil
  let trims = opts.musicality.contains(.balance) ? opts.trackBalance ?? [:] : [:]
  // A sampled drum kit the track picked (dj's, never the parity path: it needs the deck's bank
  // and the instrument table, `.extended`); nil = beats' synth kits.
  // (dj-only track fields — `picked`, `kit` — are not in the JSON the graph is compiled from:
  // they are read from the project itself, `geometry`)
  let kit =
    opts.samplers != nil && opts.instruments != nil ? drumKitSource(geometry ?? g.project) : nil
  for n in g.nets {
    if n.bundle.role == "control" && !(voiceFills && n.id.hasPrefix("fill-")) { continue }
    let tr = n.bundle.track
    let picked = geometry?.nets[n.id]?.track.picked ?? tr.picked
    let option = geometry?.nets[n.id]?.track.sound.option ?? tr.sound.option
    let override = opts.voices[n.id]
    var kindOrder: [String] = []
    var kindLane: [String: Int] = [:]
    for t in 0..<n.nTrans where n.midi[t] {
      let b = n.bundle.bindings[n.transIds[t]]!
      let ch = b.channel != 0 ? b.channel : tr.channel
      var key = override != nil ? "v" : (isDrumChannel(ch) ? drumKind(n.note[t]) : "tonal")
      // `.crash`: the section crashes on fill nets get a crash, not beats' short open hat
      if voiceCrash && key == "openhat" && n.id.hasPrefix("fill-")
        && n.note[t] == DJMusicality.crashNote
      {
        key = "crash"
      }
      // `.openHats`: beats voices notes 42–46 as one closed hat
      if voiceOpenHats && key == "hat" && n.note[t] == DJMusicality.openHatNote { key = "openhat" }
      if kindLane[key] == nil {
        let lane: Lane
        if let override {
          lane =
            override.kind == "tonal"
            ? tonalLane(override, sr, 4, tables: &tables) : gateLane(override, sr, lanes.count)
        } else if key == "tonal" {
          let voice =
            opts.instruments?.voice(instrument: tr.instrument, group: tr.group)
            ?? tonalVoice(instrument: tr.instrument, group: tr.group)
          lane = tonalLane(
            voice, sr, tr.group == "harmony" ? 6 : 4, tables: &tables, seed: lanes.count)
          bindSampler(
            lane, tr.instrument, tr.group ?? n.bundle.riffGroup, opts, picked: picked,
            option: option)
          if lane.samplerSlot >= 0 { sampledGroups[n.id] = tr.group ?? n.bundle.riffGroup }
          let part = tr.group ?? n.bundle.riffGroup
          if subtractive {
            shapeVoice(lane, group: part, plucked: opts.voiceDesign.pluckGroups, sr)
          }
          if unison { detune(lane, group: part, wide: stereo, design: opts.voiceDesign, sr) }
        } else {
          let brushed = opts.brushes && key == "snare"
          var voice = brushed ? Brush.voice : drumVoice(kind: key, instrument: tr.instrument)
          if key == "kick", let hz = kickHz {
            // `.kickTune`: the same sweep, landing on the key
            voice.f0 *= hz / voice.f1
            voice.f1 = hz
          }
          lane = gateLane(voice, sr, lanes.count)
          if let kit {
            if brushed, let brush = DrumKits.brushKit(for: kit),
              bindKit(lane, kind: key, brush, opts)
            {
              // the bank's Brush kit plays the snare
            } else if bindKit(lane, kind: key, kit, opts), brushed {
              // no Brush kit in the bank: the kit's own snare, played softer
              lane.kitVelocity = Brush.stockVelocity
            }
            // `.balance`: the kit was matched to the synth kit before its trims; the kick's
            // trim moves the whole kit (its own balance is the kit's)
            if !trims.isEmpty, let db = trims["kick"] {
              lane.kitVelocity *= DrumKits.velocityScale(db)
            }
          }
        }
        lane.netId = n.id
        lane.kind = key
        lane.channel = tr.channel
        lane.instrument = tr.instrument
        if stereo {
          let at = DJMusicality.stereoPlacement(
            kind: key, group: tr.group ?? n.bundle.riffGroup)
          lane.pan = at.pan
          let part = tr.group ?? n.bundle.riffGroup
          let spread = at.spread * (part == "harmony" ? opts.voiceDesign.padWidth : 1)
          // (a voice post chain — lowpass, distortion — runs on the voice sum: one pan for all)
          if spread > 0 && lane.isTonal && !lane.postOn && lane.voice.distortion == 0 {
            lane.voiceSpread = (0..<lane.poly).map { $0 % 2 == 0 ? spread : -spread }
            lane.voicePan = [Double](repeating: at.pan, count: lane.poly)
          }
        }
        if opts.duckDepth > 0 {
          lane.ducks = key == "tonal" && (tr.group == "bass" || tr.group == "harmony")
          lane.isKick = key == "kick" && (n.bundle.riffGroup == "kick" || n.id == "kick")
        }
        if space {
          lane.send = SpaceSpec.send(kind: key, group: tr.group ?? n.bundle.riffGroup)
        }
        // (a sampled lane's too: it is used if the lane plays its synth voice instead)
        if echo {
          lane.echoSend = EchoSpec.send(kind: key, group: tr.group ?? n.bundle.riffGroup)
        }
        // `.balance`: the part's trim (fills and crashes are no part's: as composed)
        if !trims.isEmpty, override == nil, !n.id.hasPrefix("fill-"),
          let part = MixBalance.part(kind: key, group: tr.group ?? n.bundle.riffGroup),
          let db = trims[part]
        {
          lane.st[slotLevel] *= pow(10, db / 20)
        }
        // the loudness probe: a sampled part about as loud as its sampler
        if key == "tonal", let level = opts.probeLevels[n.id] { lane.st[slotLevel] *= level }
        if !rests.isEmpty && override == nil && !g.isStingerNet[n.index] {
          lane.restClass = RestSchedule.Class.of(
            kind: key, group: tr.group ?? n.bundle.riffGroup, net: n.id)
        }
        if let harmony, lane.isTonal {
          lane.harmonyGroup = harmony.groupIndex(NoteLog.groupName(n.bundle, id: n.id)) ?? -1
        }
        kindLane[key] = lanes.count
        kindOrder.append(key)
        lanes.append(lane)
      }
      n.lane[t] = kindLane[key]!
    }
    if !kindOrder.isEmpty { byNet[n.id] = kindOrder.map { kindLane[$0]! } }
    // `.choke`: the net's closed hat cuts its open hat off (10 ms)
    if opts.musicality.contains(.choke), let h = kindLane["hat"], let o = kindLane["openhat"] {
      lanes[h].choke = lanes[o]
      lanes[o].chokeMul = exp(-1 / (0.01 * sr))
    }
  }
  var sources: [Lane] = []
  for m in opts.mods {
    guard let src = byNet[m.source], let dst = byNet[m.target] else { continue }
    for li in dst {
      if m.kind == "fm" {
        lanes[li].fm = lanes[src[0]]
        lanes[li].st[slotFmDepth] = m.depth
      } else {
        lanes[li].am = lanes[src[0]]
        lanes[li].st[slotAmDepth] = m.depth
      }
    }
    if m.silentSource { for li in src { lanes[li].st[slotLevel] = 0 } }
    if !sources.contains(where: { $0 === lanes[src[0]] }) { sources.append(lanes[src[0]]) }
  }
  // Live keys: one extra pooled voice, shaped like the melody net's instrument.
  let melody = g.nets.first { $0.bundle.riffGroup == "melody" || $0.id == "melody" }
  let liveInstrument = melody?.bundle.track.instrument ?? ""
  let liveVoice =
    opts.instruments?.voice(instrument: liveInstrument, group: "melody")
    ?? tonalVoice(instrument: liveInstrument, group: "melody")
  let live = tonalLane(liveVoice, sr, 8, tables: &tables, seed: lanes.count)
  let liveOption = melody.flatMap { geometry?.nets[$0.id]?.track.sound.option }
  bindSampler(live, liveInstrument, "melody", opts, option: liveOption)
  if subtractive { shapeVoice(live, group: "melody", plucked: [], sr) }
  if unison { detune(live, group: "melody", wide: stereo, sr) }
  live.netId = "<live>"
  if space { live.send = SpaceSpec.send(kind: "tonal", group: "melody") }
  if echo { live.echoSend = EchoSpec.send(kind: "tonal", group: "melody") }
  let liveIndex = lanes.count
  lanes.append(live)
  for lane in lanes { lane.captureBase() }
  let project = WaveProject(
    graph: g, lanes: lanes, byNet: byNet, sources: sources, liveLane: liveIndex,
    samplers: opts.samplers, trackSerial: trackSerial, startTick: startTick, geometry: geometry,
    gain: gain, energy: energy, duckDepth: opts.duckDepth, rests: rests,
    songRests: songRests, tail: tail, space: space ? opts.space ?? .room : nil,
    echo: echo ? opts.echo : nil, balance: trims.isEmpty ? nil : trims, harmony: harmony,
    feel: opts.musicality.contains(.feel) ? opts.feel : nil)
  project.sampledGroups = sampledGroups
  project.voiceDesign = opts.voiceDesign
  return project
}

/// Play `instrument` on the deck's sampler when its category picks a sampled sound for this
/// role and one loads (off the audio thread: this may load an EXS from disk, or evict an
/// unused one). The reference taken on the slot is the project's, given back in
/// `WaveProject.deinit`.
///
/// `option` (`TrackSound.option`, what the palette or the user chose for the role): a synth
/// voice plays no sample; a sampled option's sounds come first, unless the user picked the
/// instrument; the instrument's own chain follows as the fallback.
private func bindSampler(
  _ lane: Lane, _ instrument: String, _ role: String, _ opts: WaveOptions, picked: Bool = false,
  option: String? = nil
) {
  guard let bank = opts.samplers, opts.instruments != nil else { return }
  if !picked, let o = option, o == "synth" || SoundPalette.synthName(o) != nil { return }
  let role = role.isEmpty ? "melody" : role
  let own = VoiceCatalog.shared.sources(
    instrument: instrument, role: role, seed: opts.voicingSeed, picked: picked)
  let fromPalette =
    picked
    ? nil : option.flatMap { SoundPalette.sources(option: $0, role: role, seed: opts.voicingSeed) }
  guard let sources = fromPalette.map({ $0 + (own ?? []) }) ?? own,
    let slot = bank.slot(for: sources)
  else { return }
  lane.samplerSlot = slot
}

/// The kit a project's drums play: the first drum-channel net's `Track.kit` (a share `tracks`
/// override on the drum channels), resolved to an installed bank; nil = the synth kit.
func drumKitSource(_ project: Project) -> SamplerSource? {
  for id in project.nets.keys {
    guard let nb = project.nets[id], nb.role != "control", isDrumChannel(nb.track.channel)
    else { continue }
    if let k = nb.track.kit ?? nb.track.sound.kit {
      return DrumKits.source(for: k)
    }
  }
  return nil
}

/// Play a drum lane's hits on the kit (its kind's GM key), when the kit loads in the deck's
/// bank; else the lane keeps beats' synth voice. Its reference is the project's (`deinit`).
/// Whether it bound.
@discardableResult
private func bindKit(_ lane: Lane, kind: String, _ kit: SamplerSource, _ opts: WaveOptions)
  -> Bool
{
  guard let bank = opts.samplers, let slot = bank.slot(for: [kit]) else { return false }
  lane.samplerSlot = slot
  lane.kitNote = DrumKits.gmNote(kind: kind)
  lane.kitHoldMs = DrumKits.holdMs(kind: kind)
  return true
}

// clock slots
private let clkTickPos = 0
private let clkSpt = 1
private let clkTempo = 2
private let clkSamples = 3

public final class WaveRunner {
  public let sampleRate: Double
  public var opts: WaveOptions
  public var masterGain: Double
  private let linear: Bool
  /// `master == "limit"`: linear like "linear", but with the master and track gain (the deck's
  /// `PeakLimiter` follows); "linear" leaves the plain sum unscaled (the probes scale it).
  private let scaled: Bool
  private var current: WaveProject?
  private var pending: WaveProject?
  /// The previous project's voices, ringing out after a swap.
  private var fading: WaveProject?
  /// Called instead of dropping a project on the calling thread, so a real-time
  /// caller can hand it to another thread to free. Default: just drop.
  public var onRetire: ((WaveProject) -> Void)?
  /// Where audible net fires are reported, or nil (the default: offline renders and sessions
  /// play exactly as before). Set once, before the first `process`, by the owner; the runner
  /// is the only producer. Never written by silent replays or scrubs, only by the tick clock.
  public var fireRing: LatestRing<FireEvent>?
  /// Where every tick of the net clock is reported, or nil. Same rules as `fireRing`.
  public var anchorRing: LatestRing<TickAnchor>?
  // What the last anchor said, to flag the next one that does not follow on from it.
  private var lastAnchorTick: Int32 = -1
  private var lastAnchorGeneration: Int32 = 0
  /// The tick clock was started, stopped, realigned or scratched since the last anchor.
  private var clockBroken = true
  /// Deck frame of the sample being rendered when a tick lands (set by `process` right
  /// before `doTick`): start-of-block frame + offset inside the block.
  private var tickFrame: Int64 = 0
  /// `startFrame` of the block being processed: + `blockOffset` = the frame of the sample.
  private var blockStart: Int64 = 0
  private let onHit: ((HitRecord) -> Void)?
  public var graph: WaveGraph? { current?.graph }
  /// `WaveProject.generation` of the project the clock is running (0: none).
  public var generation: Int32 { current?.generation ?? 0 }
  /// Generation of the project queued behind it, waiting for the next bar (0: none).
  public var pendingGeneration: Int32 { pending?.generation ?? 0 }

  /// Publish the running project's marking to its mirror (no-op when unchanged), as the state
  /// at the end of the block that ends at deck frame `endFrame`. Allocation-free.
  func publishMarking(endFrame: Int) {
    if let proj = current { proj.marking.publish(proj.graph, endFrame: endFrame) }
  }
  public private(set) var playing = false
  private var clock = [Double](repeating: 0, count: 4)
  public private(set) var ticksInBlock = 0
  /// Set when a stop-transport control fires.
  public private(set) var stopped = false
  private var acc = 0.0
  private var scrubbing = false
  private var scrubPos = 0.0
  private var scrubTarget = 0.0
  private var scrubRate = 0.0
  private lazy var scrubChase = 0.035 * sampleRate
  private lazy var scrubSmooth = 1 - exp(-1 / (0.004 * sampleRate))

  /// Sampled instruments: MIDI queued during a block, sent just before the bank renders it.
  private let samplers: SamplerBank?
  private var evSlot = [Int](repeating: 0, count: 1024)
  private var evWord = [UInt32](repeating: 0, count: 1024)
  private var evOffset = [Int](repeating: 0, count: 1024)
  private var evCount = 0
  /// With `.loudness`: the samplers render here and join the voices before the master curve.
  private let samplersInCurve: Bool
  private var preL = [Float](repeating: 0, count: 4096)
  private var smpL = [Float](repeating: 0, count: 4096)
  private var smpR = [Float](repeating: 0, count: 4096)
  // Groove (`DJMusicality.Fixes.groove`): notes held back by swing / humanize, due at a
  // sample time. Fixed capacity; refer to the current project by net / transition / lane.
  private let grooveOn: Bool
  private static let grooveCapacity = 1024
  private var grooveDue = [Double](repeating: 0, count: WaveRunner.grooveCapacity)
  private var grooveNet = [Int32](repeating: 0, count: WaveRunner.grooveCapacity)
  private var grooveTrans = [Int32](repeating: 0, count: WaveRunner.grooveCapacity)
  private var grooveLane = [Int32](repeating: 0, count: WaveRunner.grooveCapacity)
  private var grooveVel = [Int32](repeating: 0, count: WaveRunner.grooveCapacity)
  // for `onHit` only: the tick each held-back note belongs to, and that tick's frame
  private var grooveTick = [Int32](repeating: 0, count: WaveRunner.grooveCapacity)
  private var grooveGrid = [Int64](repeating: 0, count: WaveRunner.grooveCapacity)
  /// The note as mapped at the fire's step (`.sectionHarmony`), not at the step it falls due.
  private var grooveNote = [Int32](repeating: 0, count: WaveRunner.grooveCapacity)
  private var grooveCount = 0
  private var grooveNext = Double.infinity
  /// Sample index within the block being rendered (0 between blocks).
  private var blockOffset = 0
  // Section energy (`DJMusicality.Fixes.energy`): tonal voices sum apart (`accTone`) so their
  // lowpass leaves the drums alone; level and cutoff follow the project's `EnergyCurve`,
  // smoothed once a block.
  private let energyOn: Bool
  private var splitTone = false
  private var accTone = 0.0
  private var toneL = [Float](repeating: 0, count: 4096)
  private var energyPrimed = false
  private var energyGain = 1.0
  private var energyCut = EnergyCurve.openHz
  private var toneLP = (SweepFilter(), SweepFilter())
  // Kick ducking (`DJMusicality.Fixes.duck`): a kick sets `duckHold` to 1, which falls back
  // exponentially; `duckEnv` follows it with a 2 ms attack (no click); bass and pad voices are
  // scaled by `duckGain` = 1 − depth × duckEnv. `duckBuf` keeps each sample's gain for the
  // sampler slots, which render once a block.
  private var duckHold = 0.0
  private var duckEnv = 0.0
  private var duckGain = 1.0
  private var duckBuf = [Float](repeating: 1, count: 4096)
  private var duckL = [Float](repeating: 0, count: 4096)
  private var duckR = [Float](repeating: 0, count: 4096)
  private var duckingSlots: UInt64 = 0
  // Stereo (`DJMusicality.Fixes.stereo`): each sample's side signal beside the mid one (`acc`,
  // `accTone`): left = mid + side, right = mid − side. Off, side stays 0 and is never read.
  private let stereoOn: Bool
  private var accS = 0.0
  private var accToneS = 0.0
  private var preS = [Float](repeating: 0, count: 4096)
  private var toneS = [Float](repeating: 0, count: 4096)
  /// …and the sampled instruments (stereo samples) mono below 150 Hz.
  private var samplerSide: SideHighpass
  // Room (`DJMusicality.Fixes.space`): each sample's send (`accSend`, the lanes' `send` share)
  // into the reverb, whose stereo return joins the mix as mid and side. Sampled instruments
  // render a block at a time, after the samples: their send waits in `sendFifo` and goes in
  // during the next block (a block's delay, inside the room's pre-delay).
  private let reverb: FDNReverb?
  private var accSend = 0.0
  private var sendFifo = [Float](repeating: 0, count: 8192)
  private var fifoRead = 0
  private var fifoCount = 0
  private var sendBuf = [Float](repeating: 0, count: 4096)
  private var sendingSlots: UInt64 = 0
  // Echo (`DJMusicality.Fixes.echo`): each sample's echo send (`accEcho`); the repeats join the
  // mix as mid and side, and go on into the room.
  private let echoFx: PingPong?
  private var accEcho = 0.0

  public init(sampleRate: Double, opts: WaveOptions = WaveOptions()) {
    self.sampleRate = sampleRate
    self.opts = opts
    reverb = opts.musicality.contains(.space) ? FDNReverb(sampleRate: sampleRate) : nil
    echoFx = opts.musicality.contains(.echo) ? PingPong(sampleRate: sampleRate) : nil
    samplers = opts.samplers
    samplersInCurve = opts.samplers != nil && opts.musicality.contains(.loudness)
    grooveOn = opts.musicality.contains(.groove)
    onHit = opts.onHit
    energyOn = opts.musicality.contains(.energy)
    stereoOn = opts.musicality.contains(.stereo)
    samplerSide = SideHighpass(hz: 150, sampleRate: sampleRate)
    masterGain = opts.masterGain
    linear = opts.master == "linear" || opts.master == "limit"
    scaled = opts.master == "limit"
    clock[clkTempo] = 120
    clock[clkSpt] = spt(120)
  }

  public var tempo: Double { clock[clkTempo] }
  public var samples: Double { clock[clkSamples] }

  private func spt(_ bpm: Double) -> Double { sampleRate * 60 / (bpm * ppq) }

  /// Compile everything off the audio thread. Hand the result to `load(prepared:)`.
  /// `startTick` replays the net silently to that tick first (a section launch). `trackSerial`
  /// says this is another start of a song that was prepared before (pass that project's
  /// `trackSerial`); omitted, the project is a new track.
  public static func prepare(
    _ project: Project, sampleRate: Double, opts: WaveOptions = WaveOptions(), startTick: Int = 0,
    trackSerial: Int32? = nil
  ) -> WaveProject {
    let g = WaveGraph(project: opts.roleFilter?.apply(project) ?? project)
    if startTick > 0 { g.fastForward(to: startTick) }
    var opts = opts
    if opts.musicality.contains(.balance) && opts.trackBalance == nil {
      opts.trackBalance = MixBalance.trims(for: project, fixes: opts.musicality)
    }
    // (the compiled graph is built from the project's JSON, which has no coordinates: the
    // layout takes the net positions from the project itself)
    // `.loudness`: measured after the lanes are built, so the probe knows which parts the deck
    // plays on samplers (each sits at its sampler's level, not its synth voice's)
    let measureGain = opts.trackGain == nil && opts.musicality.contains(.loudness)
    let gain = opts.trackGain ?? 1
    let energy =
      opts.musicality.contains(.energy) ? (opts.trackEnergy ?? EnergyCurve(project: project)) : nil
    let songRests =
      opts.trackRests ?? RestSchedule.build(project, fixes: opts.musicality, genre: opts.genre)
    let rests = opts.tail.map { songRests.with(tail: $0) } ?? songRests
    // `.sectionHarmony` / `.harmonicRhythm`: the band moves with the section and its chords
    // (a pure function of the played project, cheap: rebuilt on section jumps rather than
    // carried)
    let harmony = SectionHarmony.playing(project, fixes: opts.musicality)
    let prepared = buildLanes(
      g, sampleRate, opts, trackSerial: trackSerial, startTick: max(0, startTick),
      geometry: project, gain: gain, energy: energy, rests: rests, songRests: songRests,
      tail: opts.tail, harmony: harmony)
    prepared.turntableBrake = opts.turntableBrake
    if measureGain {
      prepared.gain = Loudness.gain(
        for: project, fixes: opts.musicality,
        balance: opts.musicality.contains(.balance) ? opts.trackBalance : nil,
        sampled: prepared.sampledGroups.mapValues { Loudness.sampledPartLevel(group: $0) })
    }
    return prepared
  }

  public static func prepare(json: JSONValue, sampleRate: Double, opts: WaveOptions = WaveOptions())
    -> WaveProject
  {
    buildLanes(WaveGraph(json: json), sampleRate, opts)
  }

  /// Compile a project. Applied now when stopped, at the next bar when playing.
  public func load(_ project: Project) {
    load(prepared: Self.prepare(project, sampleRate: sampleRate, opts: opts))
  }
  public func load(json: JSONValue) {
    load(prepared: Self.prepare(json: json, sampleRate: sampleRate, opts: opts))
  }

  /// Install a prepared project: immediately when stopped, at the next bar when
  /// playing. Allocation-free; anything displaced goes to `onRetire`.
  public func load(prepared next: WaveProject) {
    if playing && current != nil {
      if let old = pending { retire(old) }
      pending = next
      return
    }
    install(next)
  }

  private func retire(_ p: WaveProject) {
    if let onRetire { onRetire(p) }
  }

  private func install(_ next: WaveProject) {
    flushGroove()
    energyPrimed = false
    if let old = current {
      if let f = fading { retire(f) }
      fading = old
    }
    current = next
    next.restCursor.reset()
    reverb?.tune(next.space)
    echoFx?.tune(next.echo, bpm: next.graph.tempo)
    setTempo(next.graph.tempo)
  }

  public func play() {
    guard current != nil, !playing else { return }
    playing = true
    stopped = false
    clockBroken = true
    clock[clkTickPos] = clock[clkSpt] - 1  // first tick lands on the next sample
  }

  public func pause() { playing = false }

  public func stop() {
    grooveCount = 0
    playing = false
    clockBroken = true
    macroHoldTicks = 0
    graph?.reset()
    current?.restCursor.reset()
    samplersAllOff()
    energyPrimed = false
    toneLP.0.reset()
    toneLP.1.reset()
    duckHold = 0
    duckEnv = 0
    samplerSide.reset()
  }

  /// `.stereo`: the samplers' block (in `smpL` / `smpR`) mono below 150 Hz.
  private func monoSamplerLows(frames: Int) {
    for i in 0..<frames { samplerSide.process(&smpL[i], &smpR[i]) }
  }

  public func setTempo(_ bpm: Double) {
    guard bpm > 0 else { return }
    let frac = clock[clkTickPos] / clock[clkSpt]
    clock[clkTempo] = bpm
    graph?.tempo = bpm
    echoFx?.setTempo(bpm)
    clock[clkSpt] = spt(bpm)
    clock[clkTickPos] = frac * clock[clkSpt]
  }

  /// Mute by `strHash(netId)` (allocation-free; what the audio-thread facade uses).
  public func setMute(hash: Int32, _ muted: Bool) {
    if let g = graph, let i = g.byHash[hash] { g.muted[i] = muted ? 1 : 0 }
  }

  /// Fraction (0..<1) of the current tick that has elapsed.
  public var tickPhase: Double { clock[clkSpt] > 0 ? clock[clkTickPos] / clock[clkSpt] : 0 }

  public func setRoleMuted(hash: Int32, _ muted: Bool) { graph?.setRoleMuted(hash: hash, muted) }

  /// A channel's voice settings (the sound panel), on the project playing and the one queued
  /// for the next bar, from the next sample on. Allocation-free.
  public func setVoice(_ p: VoiceLaneParams) {
    if let c = current { applyVoice(p, c) }
    if let n = pending { applyVoice(p, n) }
  }

  private func applyVoice(_ p: VoiceLaneParams, _ proj: WaveProject) {
    for lane in proj.lanes where lane.channel == Int(p.channel) {
      if lane.samplerSlot >= 0 && p.has(VoiceLaneParams.synth) && p.useSynth {
        // to the synth voice: the sampler's notes end now
        for k in 0..<lane.offCount { queue(lane.samplerSlot, 0x80, lane.offNote[k], 0) }
        lane.offCount = 0
        lane.nextOff = .infinity
      }
      lane.setVoice(p)
    }
  }
  public func activateSlot(hash: Int32) { graph?.activateSlot(hash: hash) }
  public func fireStinger(hash: Int32, ticks: Int) {
    graph?.fireStinger(hash: hash, ticks: ticks)
    markMacroRunning(ticks: ticks)
  }

  public func setMute(_ netId: String, _ muted: Bool) {
    if let g = graph, let i = g.byId[netId] { g.muted[i] = muted ? 1 : 0 }
  }

  // MARK: scratching the net clock

  /// Hand on the platter: the tick clock stops following the tempo and follows the hand.
  public func freeze() {
    flushGroove()
    guard graph != nil, !scrubbing else { return }
    scrubbing = true
    clockBroken = true
    scrubPos = Double(graph!.tick) + tickPhase
    scrubTarget = scrubPos
    scrubRate = 0
  }

  /// Move the hand by this many ticks (negative = backwards, undoing ticks).
  public func scrub(ticks: Double) { if scrubbing { scrubTarget += ticks } }

  /// Hand off: back to the tempo clock from wherever the platter is.
  public func release() {
    guard scrubbing else { return }
    scrubbing = false
    clockBroken = true
    scrubRate = 0
    clock[clkTickPos] = (scrubPos - scrubPos.rounded(.down)) * clock[clkSpt]
  }

  /// Seconds the net clock takes to catch up with the hand.
  public func setChase(seconds: Double) { scrubChase = max(0.002, seconds) * sampleRate }

  public var isScrubbing: Bool { scrubbing }

  private func scrubSample() {
    guard let g = graph else { return }
    let spt = clock[clkSpt]
    let maxRate = 12 / spt  // ticks per sample: 12× normal speed
    let want = min(maxRate, max(-maxRate, (scrubTarget - scrubPos) / scrubChase))
    scrubRate += (want - scrubRate) * scrubSmooth
    var newPos = scrubPos + scrubRate
    if abs(scrubTarget - newPos) < 1e-3 {  // settled: land on the target, not just short of it
      newPos = scrubTarget
      scrubRate = 0
    }
    let goal = Int(newPos.rounded(.down))
    while g.tick < goal {
      stepForwardScrub(g)
    }
    while g.tick > goal {
      let proj = current
      let step = g.tick - 1  // the step being played backwards
      let ok = g.unadvance { n, t in
        let li = n.lane[t]
        if li >= 0, let proj {
          let lane = proj.lanes[li]
          self.hit(lane, n, t, note: self.playedNote(proj, lane, n, t, step: step))
        }
      }
      if !ok {  // the start of the log: the platter stops here
        newPos = Double(g.tick)
        scrubRate = 0
        scrubTarget = max(scrubTarget, newPos)
        break
      }
    }
    scrubPos = newPos
    clock[clkTickPos] = (newPos - newPos.rounded(.down)) * spt
  }

  private func stepForwardScrub(_ g: WaveGraph) {
    let proj = current
    let step = g.tick
    g.advance { n, t in
      let li = n.lane[t]
      if li >= 0, let proj {
        let lane = proj.lanes[li]
        self.hit(lane, n, t, note: self.playedNote(proj, lane, n, t, step: step))
      }
    }
    ticksInBlock += 1
    g.stopRequested = false  // a scratched-over end of song doesn't stop the deck
  }

  // MARK: beat alignment

  /// Move this deck's beat grid by `ticks` ticks (a tick is a sixteenth). Positive moves
  /// forward in the song: whole ticks are replayed silently, the remainder shifts the
  /// tick boundary. Negative holds the clock back (the next tick comes later).
  public func align(ticks: Double) {
    guard let g = graph else { return }
    clockBroken = true
    if ticks < 0 {
      clock[clkTickPos] += ticks * clock[clkSpt]
      return
    }
    let whole = ticks.rounded(.down)
    var n = 0
    while Double(n) < whole && !g.stopRequested {
      g.advance { _, _ in }
      if let proj = current { _ = songEnds(proj) }  // a mix-out tail aligns on past the end
      n += 1
    }
    clock[clkTickPos] += (ticks - whole) * clock[clkSpt]
  }

  /// Put the tick clock `ticks` ticks further on, silently, as if it had kept running at the
  /// tempo all along (a turntable brake's release: `WaveDeckSource`). Unlike `align`, the
  /// remainder lands exactly: a boundary it crosses is ticked now, not on the next sample. Each
  /// tick does what `doTick` would without sounding: a queued project takes over on its bar,
  /// the macro hold counts down, the end of the song stops the deck. Allocation-free.
  func catchUp(ticks: Double) {
    guard ticks > 0, current != nil, clock[clkSpt] > 0 else { return }
    flushGroove()
    clockBroken = true
    var pos = clock[clkTickPos] / clock[clkSpt] + ticks
    while pos >= 1, let proj = current {
      pos -= 1
      let g = proj.graph
      if let next = pending, (g.tick + 1) % 16 == 0 {
        pending = nil
        install(next)
        continue
      }
      if endsTail(proj) { return }
      g.advance { _, _ in }
      if macroHoldTicks > 0 { macroHoldTicks -= 1 }
      if songEnds(proj) {
        stopped = true
        stop()
        return
      }
    }
    clock[clkTickPos] = max(0, pos) * clock[clkSpt]
  }

  /// The song's `stop-transport` fired, and no mix-out tail plays on past it. A tail takes the
  /// request back: it stops the deck itself, on its own bar line (`endsTail`), even when the
  /// song's last step is the one before it. Allocation-free.
  @inline(__always)
  private func songEnds(_ proj: WaveProject) -> Bool {
    let g = proj.graph
    guard g.stopRequested else { return false }
    if proj.tail != nil {
      g.stopRequested = false
      return false
    }
    return true
  }

  /// The mix-out tail's bar line: at the tick boundary of its `endTick` the deck stops instead
  /// of playing that step (true: stopped). Allocation-free.
  @inline(__always)
  private func endsTail(_ proj: WaveProject) -> Bool {
    guard let tail = proj.tail, proj.graph.tick >= tail.endTick else { return false }
    stopped = true
    stop()
    return true
  }

  /// The tick the playing project's mix-out tail stops on, or -1 (none).
  var tailEndTick: Int { current?.tail?.endTick ?? -1 }

  /// Does the project playing want `vinyl-brake` as a turntable brake?
  var turntableBrake: Bool { current?.turntableBrake ?? false }

  // MARK: live performance

  /// A key goes down on the pooled live voice (already scale-locked by the caller).
  /// The voice holds until `noteOff`, then rings out.
  public func noteOn(_ note: Int, velocity: Int) {
    guard let proj = current else { return }
    let lane = proj.lanes[proj.liveLane]
    if lane.samplerSlot >= 0 {
      queue(lane.samplerSlot, 0x90, note, max(1, min(127, velocity)))
      return
    }
    lane.active = true
    let w = Double(max(1, min(127, velocity))) / 127
    var v = 0
    var best = Double.infinity
    for k in 0..<lane.poly {
      // prefer a free (not held) voice, then the quietest
      let a = abs(lane.sd[k] + lane.sa[k]) + (lane.hold[k] ? 1000 : 0)
      if a < best {
        best = a
        v = k
      }
    }
    let cur = lane.sd[v] + lane.sa[v]
    strike(lane, v, note: note)
    if lane.fAmount > 0 { lane.fVel[v] = w * w }
    lane.md[v] = exp(-lane.st[slotInvSr] / 0.3)  // release time constant, used after noteOff
    lane.hold[v] = true
    lane.heldNote[v] = note
    lane.sd[v] = w
    lane.sa[v] = cur - w
  }

  public func noteOff(_ note: Int) {
    guard let proj = current else { return }
    let lane = proj.lanes[proj.liveLane]
    if lane.samplerSlot >= 0 {
      queue(lane.samplerSlot, 0x80, note, 0)
      return
    }
    for k in 0..<lane.poly where lane.hold[k] && lane.heldNote[k] == note {
      lane.hold[k] = false
      lane.heldNote[k] = -1
    }
  }

  public func allNotesOff() {
    guard let proj = current else { return }
    let lane = proj.lanes[proj.liveLane]
    if lane.samplerSlot >= 0 { queue(lane.samplerSlot, 0xB0, 123, 0) }
    for k in 0..<lane.poly {
      lane.hold[k] = false
      lane.heldNote[k] = -1
    }
  }

  private enum TempoFx { case none, hold, sweep }
  private var tempoFx = TempoFx.none
  private var fxStartSample = 0.0
  private var fxDurSamples = 0.0
  private var fxStartBpm = 120.0
  private var fxTarget = 120.0

  /// Bits (`NetMacro.bit`) of the tempo macros whose effect is running; meaningful while
  /// `tempoFx != .none`, and started afresh by the first fire after it ended.
  private var tempoFxMask: UInt32 = 0

  private func beginTempoFx(_ kind: TempoFx, target: Double, ticks: Int, macro: NetMacro) {
    if tempoFx == .none { tempoFxMask = 0 }
    tempoFxMask |= macro.bit
    // A stacked fire restores to the tempo the first one started from, not its own peak.
    let start = tempoFx == .none ? clock[clkTempo] : fxStartBpm
    tempoFx = kind
    fxStartBpm = start
    fxTarget = target
    fxStartSample = clock[clkSamples]
    fxDurSamples = Double(max(1, ticks)) * clock[clkSpt]
    if kind == .hold { setTempo(target) }
  }

  private func serviceTempoFx() {
    guard tempoFx != .none else { return }
    let elapsed = clock[clkSamples] - fxStartSample
    if elapsed >= fxDurSamples {
      tempoFx = .none
      setTempo(fxStartBpm)
    } else if tempoFx == .sweep {
      let t = min(1, elapsed / fxDurSamples)
      let eased = 1 - (1 - t) * (1 - t)
      setTempo(fxStartBpm + (fxTarget - fxStartBpm) * eased)
    }
  }

  /// Net ticks left of the latest macro fired (`markMacroRunning`).
  private var macroHoldTicks = 0

  /// beats `markMacroRunning` (macros/runtime.js): a macro of ANY kind is running for `ticks` net
  /// ticks from its fire, whether or not it changed anything we can see (a mute that found every
  /// net it targets already muted sets no restore timer; the master-chain macros — FX, pitch,
  /// feel, `MasterMacro` — set none either: `WaveDeckSource` calls this when it fires one). It
  /// feeds `macroActive`, so the `FireFlags.macro` stamped on each hit, the per-deck
  /// clock flag and everything keyed on them (the Stage's bolts, seeds and halo) follow the macro
  /// that was fired, not the mutes it left behind. Every macro entry point calls it; a kind added
  /// later calls it too. Allocation-free.
  public func markMacroRunning(ticks: Int) {
    macroHoldTicks = max(macroHoldTicks, max(1, ticks))
  }

  /// Fire a net macro (`catalog.js`): mutes restore after `ticks` net ticks; tempo
  /// macros last `ticks` ticks of wall time at the tempo they were fired at.
  public func fireMacro(_ macro: NetMacro, ticks: Int) {
    guard let g = graph else { return }
    markMacroRunning(ticks: ticks)
    switch macro {
    case .drop: g.fireMute(.nonDrums, ticks: ticks, macro: macro.tag)
    case .breakdown: g.fireMute(.drumsOnly, ticks: ticks, macro: macro.tag)
    case .soloDrums: g.fireMute(.nonDrums, ticks: ticks, macro: macro.tag)
    case .cut: g.fireMute(.everything, ticks: ticks, macro: macro.tag)
    case .doubleDrop:
      g.fireMute(.everything, ticks: 2, macro: macro.tag)
      // the second half lands 260 ms later (a timer on the net clock, in ticks)
      let delay = max(1, Int((0.26 / (60 / (clock[clkTempo] * ppq))).rounded()))
      g.scheduleMute(.nonDrums, after: delay, ticks: ticks, macro: macro.tag)
    case .beatRepeat: g.fireBeatRepeat(ticks: ticks)
    case .halfTime:
      beginTempoFx(
        .hold, target: max(20, jsRound(clock[clkTempo] * 0.5)), ticks: ticks, macro: macro)
    case .tapeStop: beginTempoFx(.sweep, target: 22, ticks: ticks, macro: macro)
    case .tempoAnchor:
      beginTempoFx(.hold, target: max(20, g.project.tempo), ticks: ticks, macro: macro)
    }
  }

  /// Is a macro in effect right now: one fired and not yet run out (`markMacroRunning`), a
  /// pending mute restore, a running beat repeat or a tempo effect (half time, tape stop, tempo
  /// anchor)? Allocation-free.
  public var macroActive: Bool {
    macroHoldTicks > 0 || (graph?.hasActiveMacros ?? false) || tempoFx != .none
  }

  /// Which macros are in effect and which nets they hold muted (see `WaveGraph.macroSnapshot`),
  /// tempo macros included. Allocation-free.
  func macroSnapshot() -> MacroSnapshot {
    guard let g = graph else { return MacroSnapshot() }
    var s = g.hasActiveMacros ? g.macroSnapshot() : MacroSnapshot()
    if tempoFx != .none { s.mask |= tempoFxMask }
    return s
  }

  /// Restore every pending macro effect now.
  public func panic() {
    graph?.cancelMacros()
    samplersAllOff()
    macroHoldTicks = 0
    if tempoFx != .none {
      tempoFx = .none
      setTempo(fxStartBpm)
    }
  }

  // MARK: onsets

  /// The note transition `t` of `n` sounds on `lane` at song step `step`: as bound, or moved
  /// by the section plan (`.sectionHarmony`). Allocation-free.
  @inline(__always)
  private func playedNote(
    _ proj: WaveProject, _ lane: Lane, _ n: CompiledNet, _ t: Int, step: Int
  ) -> Int {
    let note = n.note[t]
    guard lane.harmonyGroup >= 0, let h = proj.harmony, !isDrumChannel(Int(n.channel[t])) else {
      return note
    }
    return h.note(note, group: lane.harmonyGroup, step: step)
  }

  /// `note`: what a tonal lane plays (`playedNote`); a drum lane ignores it.
  /// `tick` / `gridFrame`: where a held-back groove note was due on the grid (`onHit`); -1 =
  /// now (the graph's tick, this sample).
  private func hit(
    _ lane: Lane, _ n: CompiledNet, _ t: Int, note: Int, velocity: Int? = nil, tick: Int = -1,
    gridFrame: Int64 = -1
  ) {
    lane.active = true
    let vel = velocity ?? n.vel[t]
    if let onHit { logHit(onHit, lane, n, note, vel, tick: tick, gridFrame: gridFrame) }
    let w = Double(vel) / 127
    if lane.isKick { duckHold = 1 }
    if !lane.isTonal {
      if lane.samplerSlot >= 0 {
        // a sampled kit: the hit is its GM key; a closed hat ends the open hat's ring
        if let open = lane.choke, open.samplerSlot >= 0 { endSamplerNotes(open) }
        samplerNote(
          lane, note: lane.kitNote, w: min(1, w * lane.kitVelocity), durMs: lane.kitHoldMs)
        return
      }
      if let open = lane.choke, open.active { open.choking = true }
      lane.choking = false
      for e in 0..<lane.numExp { lane.s[e] += lane.alpha[e] * w }
      if lane.carrier == .sweep { lane.st[slotSweep] = 1 }
      return
    }
    let steps = n.durSteps[t]
    let durMs = steps > 0 ? steps * 60000 / (clock[clkTempo] * ppq) : n.durMs[t]
    trigger(lane, note: note, w: w, durMs: durMs)
  }

  /// `onHit`'s record of a hit (offline only: it builds strings). `note`: as played.
  private func logHit(
    _ onHit: (HitRecord) -> Void, _ lane: Lane, _ n: CompiledNet, _ note: Int, _ vel: Int,
    tick: Int, gridFrame: Int64
  ) {
    let frame = blockStart &+ Int64(blockOffset)
    onHit(
      HitRecord(
        frame: frame, gridFrame: gridFrame >= 0 ? gridFrame : frame,
        tick: tick >= 0 ? tick : current?.graph.tick ?? 0, net: n.id, note: note,
        channel: lane.channel, kind: lane.kind, velocity: vel))
  }

  /// Start a note on a tonal lane: steal the quietest voice (deterministic), continuing from
  /// its current level, and decay over the note's length.
  fileprivate func trigger(_ lane: Lane, note: Int, w: Double, durMs: Double) {
    lane.active = true
    if lane.samplerSlot >= 0 {
      samplerNote(lane, note: note, w: w, durMs: durMs)
      return
    }
    var v = 0
    var best = Double.infinity
    for k in 0..<lane.poly {
      let a = abs(lane.sd[k] + lane.sa[k])
      if a < best {
        best = a
        v = k
      }
    }
    let cur = lane.sd[v] + lane.sa[v]
    strike(lane, v, note: note)
    if lane.fAmount > 0 { lane.fVel[v] = w * w }
    var tau = (durMs > 0 ? durMs : 100) / 1000 * lane.decayScale
    tau = tau < 0.03 ? 0.03 : (tau > lane.maxDecay ? lane.maxDecay : tau)
    lane.md[v] = exp(-lane.st[slotInvSr] / tau)
    lane.sd[v] = w
    lane.sa[v] = cur - w
  }

  // MARK: groove

  /// beats' browser timing (backend/index.js `swingDelay`, `humanizeNote`), which its wave
  /// engine leaves out: the off-beat sixteenths (steps 1 and 3 of a beat) late by
  /// swing% × half a tick; humanize% jitters every note's time (±30 ms × h on the off-beats,
  /// 0…15 ms × h late on the beat) and velocity (±15 × h). Never early, so a note never
  /// leaves its tick. The jitter is a hash of (tick, net, transition), not a random draw: a
  /// replay plays the same groove.
  ///
  /// With `.feel` (the project has a `feelTable`) the family's template plays instead of the
  /// project's swing and humanize: a drum is late by its template offset at (voice, bar step)
  /// plus the swing delay, (2r − 1) × the swing grid's half pair on its off-beat member, r the
  /// family's ratio at the tempo playing; its velocity is scaled by the template. Tonal lanes
  /// (and drums the template has no voice for) get the swing only.
  private func grooveHit(
    _ proj: WaveProject, _ lane: Lane, _ n: CompiledNet, _ t: Int, lane li: Int, note: Int
  ) {
    let step = proj.graph.tick - 1
    var delayMs = 0.0
    var vel = n.vel[t]
    if let feel = proj.feelTable {
      let bar = step & (GrooveTemplate.steps - 1)
      delayMs = feel.swingMs(step: bar, bpm: clock[clkTempo])
      if !lane.isTonal, let v = GrooveTemplate.Voice(note: note) {
        let c = FeelTable.cell(v, bar)
        delayMs += feel.offsetMs[c]
        vel = max(1, min(127, Int((Double(vel) * feel.velocity[c]).rounded())))
      }
    } else {
      let p = proj.graph.project
      let tickMs = 60000 / (clock[clkTempo] * ppq)
      let h = p.humanize / 100
      var r = grooveHash(step, n.index, t)
      let r1 = Double(r & 0xFFFF) / 65535 * 2 - 1
      r >>= 16
      let r2 = Double(r & 0xFFFF) / 65535 * 2 - 1
      if step % 2 == 1 {
        delayMs = max(0, p.swing / 100 * tickMs * 0.5 + r1 * h * 30)
      } else if h > 0 {
        delayMs = max(0, r1 * h * 15)
      }
      if h > 0 { vel = max(1, min(127, Int((Double(vel) + r2 * h * 15).rounded()))) }
    }
    let delay = delayMs / 1000 * sampleRate
    guard delay >= 1, grooveCount < Self.grooveCapacity else {
      hit(lane, n, t, note: note, velocity: vel)
      return
    }
    let due = clock[clkSamples] + delay
    grooveDue[grooveCount] = due
    grooveNet[grooveCount] = Int32(n.index)
    grooveTrans[grooveCount] = Int32(t)
    grooveLane[grooveCount] = Int32(li)
    grooveVel[grooveCount] = Int32(vel)
    grooveTick[grooveCount] = Int32(truncatingIfNeeded: proj.graph.tick)
    grooveGrid[grooveCount] = blockStart &+ Int64(blockOffset)
    grooveNote[grooveCount] = Int32(truncatingIfNeeded: note)
    grooveCount += 1
    if due < grooveNext { grooveNext = due }
  }

  private func grooveHash(_ a: Int, _ b: Int, _ c: Int) -> UInt32 {
    var x = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791)
    x ^= x >> 16
    x = x &* 0x7feb_352d
    x ^= x >> 15
    x = x &* 0x846c_a68b
    x ^= x >> 16
    return x
  }

  /// Play the held-back notes that are due.
  private func serviceGroove() {
    guard let proj = current else {
      grooveCount = 0
      return
    }
    let now = clock[clkSamples]
    var next = Double.infinity
    var k = 0
    while k < grooveCount {
      if grooveDue[k] <= now {
        let n = proj.graph.nets[Int(grooveNet[k])]
        hit(
          proj.lanes[Int(grooveLane[k])], n, Int(grooveTrans[k]), note: Int(grooveNote[k]),
          velocity: Int(grooveVel[k]), tick: Int(grooveTick[k]), gridFrame: grooveGrid[k])
        grooveCount -= 1
        grooveDue[k] = grooveDue[grooveCount]
        grooveNet[k] = grooveNet[grooveCount]
        grooveTrans[k] = grooveTrans[grooveCount]
        grooveLane[k] = grooveLane[grooveCount]
        grooveVel[k] = grooveVel[grooveCount]
        grooveTick[k] = grooveTick[grooveCount]
        grooveGrid[k] = grooveGrid[grooveCount]
        grooveNote[k] = grooveNote[grooveCount]
      } else {
        next = min(next, grooveDue[k])
        k += 1
      }
    }
    grooveNext = next
  }

  /// Play everything held back now (before a swap or a scratch changes what they refer to).
  private func flushGroove() {
    guard grooveCount > 0 else { return }
    for k in 0..<grooveCount { grooveDue[k] = 0 }
    serviceGroove()
    grooveNext = .infinity
  }

  // MARK: sampled instruments

  @inline(__always)
  private func queue(_ slot: Int, _ status: UInt8, _ d1: Int, _ d2: Int) {
    guard evCount < evSlot.count else { return }
    evSlot[evCount] = slot
    evWord[evCount] =
      UInt32(status) | UInt32(UInt8(clamping: d1)) << 8 | UInt32(UInt8(clamping: d2)) << 16
    evOffset[evCount] = blockOffset
    evCount += 1
  }

  /// A net note on a sampled lane: note-on now, note-off after its length (at least 120 ms,
  /// so one-step notes still speak). A note struck again while held is ended first.
  private func samplerNote(_ lane: Lane, note: Int, w: Double, durMs: Double) {
    let n = min(127, max(0, note))
    for k in 0..<lane.offCount where lane.offNote[k] == n {
      queue(lane.samplerSlot, 0x80, n, 0)
      lane.offCount -= 1
      lane.offNote[k] = lane.offNote[lane.offCount]
      lane.offAt[k] = lane.offAt[lane.offCount]
      break
    }
    queue(lane.samplerSlot, 0x90, n, max(1, Int((w * 127).rounded())))
    guard lane.offCount < lane.offNote.count else { return }
    let at = clock[clkSamples] + max(120, durMs > 0 ? durMs : 120) / 1000 * sampleRate
    lane.offNote[lane.offCount] = n
    lane.offAt[lane.offCount] = at
    lane.offCount += 1
    if at < lane.nextOff { lane.nextOff = at }
  }

  /// End every note a sampled lane holds, now (a choke).
  private func endSamplerNotes(_ lane: Lane) {
    for k in 0..<lane.offCount { queue(lane.samplerSlot, 0x80, lane.offNote[k], 0) }
    lane.offCount = 0
    lane.nextOff = .infinity
  }

  /// Send the note-offs that are due; the lane goes quiet once none are left.
  @inline(__always)
  private func serviceOffs(_ lane: Lane) {
    let now = clock[clkSamples]
    if now >= lane.nextOff {
      var next = Double.infinity
      var k = 0
      while k < lane.offCount {
        if lane.offAt[k] <= now {
          queue(lane.samplerSlot, 0x80, lane.offNote[k], 0)
          lane.offCount -= 1
          lane.offNote[k] = lane.offNote[lane.offCount]
          lane.offAt[k] = lane.offAt[lane.offCount]
        } else {
          next = min(next, lane.offAt[k])
          k += 1
        }
      }
      lane.nextOff = next
    }
    if lane.offCount == 0 { lane.active = false }
  }

  private func samplersAllOff() {
    guard let bank = samplers else { return }
    for slot in 0..<bank.count { queue(slot, 0xB0, 123, 0) }
    clearOffs(current)
    clearOffs(fading)
    clearOffs(pending)
  }

  private func clearOffs(_ p: WaveProject?) {
    guard let p else { return }
    for lane in p.lanes where lane.samplerSlot >= 0 {
      lane.offCount = 0
      lane.nextOff = .infinity
    }
  }

  /// End of a block: hand the queued MIDI to the samplers, then render them into it.
  private func flushSamplers(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int
  ) {
    guard let bank = samplers else { return }
    // A slot being evicted is off in `live`: its MIDI is dropped and it is not rendered.
    let live = bank.beginBlock()
    for e in 0..<evCount where live & (1 << UInt64(evSlot[e])) != 0 {
      let w = evWord[e]
      bank.send(
        evSlot[e], UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF),
        at: min(evOffset[e], frames - 1))
    }
    evCount = 0
    let fits = frames <= duckL.count
    let ducked = fits ? live & duckingSlots : 0
    let sent = fits ? live & sendingSlots : 0
    bank.renderAll(live & ~ducked & ~sent, frames: frames, left, right)
    // the slots that duck, send, or both, a group at a time through the scratch pair
    if sent != 0 { for i in 0..<frames { sendBuf[i] = 0 } }
    for group in 0..<3 {
      let mask = group == 0 ? ducked & ~sent : group == 1 ? sent & ~ducked : ducked & sent
      guard mask != 0 else { continue }
      for i in 0..<frames {
        duckL[i] = 0
        duckR[i] = 0
      }
      duckL.withUnsafeMutableBufferPointer { l in
        duckR.withUnsafeMutableBufferPointer { r in
          bank.renderAll(mask, frames: frames, l.baseAddress!, right == nil ? nil : r.baseAddress!)
        }
      }
      let ducks = group != 1
      for i in 0..<frames {
        let g: Float = ducks ? duckBuf[i] : 1
        let l = duckL[i] * g
        let r = duckR[i] * g
        left[i] += l
        right?[i] += r
        if group != 0 { sendBuf[i] += right == nil ? l : 0.5 * (l + r) }
      }
    }
    bank.endBlock()
    if sent != 0 { queueSamplerSend(frames: frames) }
  }

  /// The sampled instruments' send of the block just rendered, into `sendFifo` for the room to
  /// take during the next block. They join the voices at the track gain alone (the voices go
  /// through the master gain as well), so the send is lifted by that to match.
  private func queueSamplerSend(frames: Int) {
    let level = Float(SpaceSpec.samplerSend / max(0.05, masterGain))
    for i in 0..<frames where fifoCount < sendFifo.count {
      var w = fifoRead + fifoCount
      if w >= sendFifo.count { w -= sendFifo.count }
      sendFifo[w] = sendBuf[i] * level
      fifoCount += 1
    }
  }

  /// Tune voice `v` to `note`; a string is damped and plucked again.
  private func strike(_ lane: Lane, _ v: Int, note: Int) {
    lane.inc[v] = 440 * pow(2, (Double(note) - 69) / 12) * lane.st[slotInvSr]
    if !lane.voiceSpread.isEmpty {
      // centred at E3 and below (the low end stays mono), full width from G4 up
      let width = min(1, max(0, Double(note - 52) / 15))
      lane.voicePan[v] = lane.pan + lane.voiceSpread[v] * width
    }
    if lane.pmOn { lane.pm[v] = lane.pitchFrom }
    if lane.mipOn {
      let hz = lane.inc[v] * sampleRate * (lane.pmOn ? lane.pitchFrom : 1)
      var k = 0
      while k < lane.mipTop.count - 1 && lane.mipTop[k] < hz * 1.06 { k += 1 }
      lane.mipBase[v] = k * (waveTableSize + 1)
    }
    if lane.fAmount > 0 { lane.fEnv[v] = 1 }
    if lane.uniWide {
      // centred at A3 and below (the pair's beating would widen the low mids), full from C5
      lane.uniWidth[v] = lane.uniMax * min(1, max(0, Double(note - 57) / 15))
    }
    guard lane.isPluck else { return }
    let period = 1 / lane.inc[v]
    // The loop lowpass delays the note by its phase delay at f0: take that off the line
    // so the string plays in tune.
    let w = 2 * Double.pi * lane.inc[v]
    let b = 1 - lane.pluckA
    let lpDelay = atan2(b * sin(w), 1 - b * cos(w)) / w
    let len = min(Double(lane.dmax - 2), max(2, period - lpDelay))
    lane.dlen[v] = len
    // `resonance` is the feedback per period of a 220 Hz string; scaled so every pitch
    // rings for the same time (per period alone, high notes die in milliseconds).
    lane.fb[v] = pow(lane.voice.resonance, 220 * lane.st[slotInvSr] * period)
    let base = v * lane.dmax
    for i in base..<(base + lane.dmax) { lane.dl[i] = 0 }
    lane.lp[v] = 0
    lane.excite[v] = max(1, Int(lane.voice.attackNoise * len))
  }

  // MARK: section energy

  /// The end of a block under `.energy`: drums (`preL`) plus the lowpassed tonal voices
  /// (`toneL`, and the samplers when they join the curve), times the section's gain, through
  /// the master curve. Gain glides across the block; the cutoff moves once a block.
  private func finishEnergy(
    _ curve: EnergyCurve, _ left: UnsafeMutablePointer<Float>,
    _ right: UnsafeMutablePointer<Float>?,
    frames: Int, samplersIn: Bool, wide: Bool
  ) {
    let step = max(0, (current?.graph.tick ?? 1) - 1)
    let target = curve.at(step: step)
    if !energyPrimed {
      energyGain = target.gain
      energyCut = target.cutoff
      energyPrimed = true
    }
    let a = 1 - exp(-Double(frames) / (0.02 * sampleRate))
    let g0 = energyGain
    energyGain += (target.gain - energyGain) * a
    energyCut *= pow(target.cutoff / energyCut, a)
    toneLP.0.tune(energyCut, sampleRate: sampleRate)
    toneLP.1.tune(energyCut, sampleRate: sampleRate)
    let trackGain = Float(current?.gain ?? 1)
    if samplersIn {
      for i in 0..<frames {
        smpL[i] = 0
        smpR[i] = 0
      }
      smpL.withUnsafeMutableBufferPointer { l in
        smpR.withUnsafeMutableBufferPointer { r in
          flushSamplers(l.baseAddress!, r.baseAddress!, frames: frames)
        }
      }
      if wide { monoSamplerLows(frames: frames) }
    }
    let step1 = (energyGain - g0) / Double(frames)
    for i in 0..<frames {
      let g = g0 + step1 * Double(i + 1)
      let tone = Double(toneL[i])
      let dry = Double(preL[i])
      if let right {
        let sl = samplersIn ? Double(trackGain * smpL[i]) : 0
        let sr = samplersIn ? Double(trackGain * smpR[i]) : 0
        let l: Double
        let r: Double
        if wide {
          let ds = Double(preS[i])
          let ts = Double(toneS[i])
          l = (dry + ds + toneLP.0.process(tone + ts + sl)) * g
          r = (dry - ds + toneLP.1.process(tone - ts + sr)) * g
        } else {
          l = (dry + toneLP.0.process(tone + sl)) * g
          r = (dry + toneLP.1.process(tone + sr)) * g
        }
        left[i] = Float(linear ? l : tanh(l))
        right[i] = Float(linear ? r : tanh(r))
      } else {
        let s = samplersIn ? Double(trackGain * 0.5 * (smpL[i] + smpR[i])) : 0
        let l = (dry + toneLP.0.process(tone + s)) * g
        left[i] = Float(linear ? l : tanh(l))
      }
    }
    if !samplersIn { flushSamplers(left, right, frames: frames) }
  }

  // MARK: per-sample

  /// One sample of `lane`, added into `acc`.
  private func laneSample(_ lane: Lane) {
    if lane.samplerSlot >= 0 {
      serviceOffs(lane)
      return
    }
    if !lane.isTonal {
      var env = 0.0
      let choke = lane.choking ? lane.chokeMul : 1
      for e in 0..<lane.numExp {
        env += lane.s[e]
        lane.s[e] *= lane.mul[e] * choke
      }
      lane.st[slotEnv] = env
      var c = 1.0
      if lane.carrier == .sweep {
        var f = lane.st[slotF1] + (lane.st[slotF0] - lane.st[slotF1]) * lane.st[slotSweep]
        lane.st[slotSweep] *= lane.st[slotSweepMul]
        if let fm = lane.fm { f *= 1 + lane.st[slotFmDepth] * fm.st[slotPrev] }
        var ph = lane.st[slotPhase] + f * lane.st[slotInvSr]
        ph -= ph.rounded(.down)
        lane.st[slotPhase] = ph
        c = sin(2 * Double.pi * ph)
      } else if lane.carrier != .dc {
        var x = lane.rng
        x ^= x &<< 13
        x ^= Int32(bitPattern: UInt32(bitPattern: x) >> 17)
        x ^= x &<< 5
        lane.rng = x
        let nz = Double(x) / 2_147_483_648
        let b = lane.bq
        let y = b[0] * nz + lane.st[slotZ1]
        lane.st[slotZ1] = b[1] * nz - b[3] * y + lane.st[slotZ2]
        lane.st[slotZ2] = b[2] * nz - b[4] * y
        c = y
        if lane.carrier == .noiseTone {
          var ph = lane.st[slotPhase] + lane.st[slotToneInc]
          ph -= ph.rounded(.down)
          lane.st[slotPhase] = ph
          c = (1 - lane.st[slotToneMix]) * y + lane.st[slotToneMix] * sin(2 * Double.pi * ph)
        }
      }
      var out = env * c * lane.st[slotLevel]
      if let am = lane.am {
        out *= 1 - lane.st[slotAmDepth] + lane.st[slotAmDepth] * am.st[slotPrev]
      }
      acc += out
      accS += out * lane.pan
      accSend += out * lane.send
      if abs(lane.s[0]) < silent && (lane.numExp < 2 || abs(lane.s[1]) < silent) {
        lane.active = false
        lane.st[slotEnv] = 0
      }
      return
    }
    // Tonal pool
    var out = 0.0
    var side = 0.0  // per-voice pan (`voicePan`), summed alongside `out`
    var uside = 0.0  // `.unison`: the detuned pairs' difference, either side
    let spread = lane.spreadOn
    var envSum = 0.0
    var live = false
    let fmk = lane.fm != nil ? 1 + lane.st[slotFmDepth] * lane.fm!.st[slotPrev] : 1
    let am = lane.st[slotAttMul]
    var vib = 1.0
    if lane.vibInc > 0 {
      var vp = lane.vibPhase + lane.vibInc
      vp -= vp.rounded(.down)
      lane.vibPhase = vp
      vib = 1 + lane.vibDepth * sin(2 * Double.pi * vp)
    }
    for k in 0..<lane.poly {
      let sd = lane.sd[k]
      let sa = lane.sa[k]
      if abs(sd) < silent && abs(sa) < silent { continue }
      live = true
      let env = sd + sa
      envSum += env
      lane.sd[k] = sd * (lane.hold[k] ? 1.0 : lane.md[k])
      lane.sa[k] = sa * am
      if lane.isPluck {
        let y = env * pluckSample(lane, k, rate: fmk * vib)
        out += y
        if spread { side += y * lane.voicePan[k] }
        continue
      }
      var rate = lane.inc[k] * fmk * vib
      if lane.pmOn {
        let p = lane.pm[k]
        rate *= p
        let next = p * lane.pmMul
        let to = lane.pitchTo
        lane.pm[k] = lane.pmMul < 1 ? (next < to ? to : next) : (next > to ? to : next)
        if lane.mipOn {
          // falling: step down to the richest table that still fits under Nyquist
          let hz = rate * sampleRate
          var b = lane.mipBase[k] / (waveTableSize + 1)
          while b > 0 && lane.mipTop[b - 1] >= hz * 1.06 { b -= 1 }
          lane.mipBase[k] = b * (waveTableSize + 1)
        }
      }
      var osc: Double
      if lane.phase2.isEmpty {
        var ph = lane.phase[k] + rate
        ph -= ph.rounded(.down)
        lane.phase[k] = ph
        osc = tableRead(lane, k, ph)
      } else {
        var ph = lane.phase[k] + rate * lane.uniDown
        ph -= ph.rounded(.down)
        lane.phase[k] = ph
        var ph2 = lane.phase2[k] + rate * lane.uniUp
        ph2 -= ph2.rounded(.down)
        lane.phase2[k] = ph2
        let o1 = tableRead(lane, k, ph)
        let o2 = tableRead(lane, k, ph2)
        // equal power: two uncorrelated oscillators as loud as one
        osc = (o1 + o2) * 0.7071
        if lane.uniWide { uside += env * (o1 - o2) * 0.7071 * lane.uniWidth[k] }
      }
      if lane.fAmount > 0 { osc = filterSample(lane, k, osc, hz: rate * sampleRate) }
      let y = env * osc
      out += y
      if spread { side += y * lane.voicePan[k] }
    }
    lane.st[slotEnv] = envSum
    if !live { lane.active = false }
    if lane.postOn {
      let b = lane.post
      let y = b[0] * out + lane.pz1
      lane.pz1 = b[1] * out - b[3] * y + lane.pz2
      lane.pz2 = b[2] * out - b[4] * y
      out = y
    }
    if lane.distortion > 0 { out = toneDistortion(out, amount: lane.distortion) }
    out *= lane.st[slotLevel]
    if spread { side *= lane.st[slotLevel] }
    if lane.uniWide {
      let b = lane.uniHP
      let y = b[0] * uside + lane.uz1
      lane.uz1 = b[1] * uside - b[3] * y + lane.uz2
      lane.uz2 = b[2] * uside - b[4] * y
      uside = y * lane.st[slotLevel]
    }
    if let amod = lane.am {
      let m = 1 - lane.st[slotAmDepth] + lane.st[slotAmDepth] * amod.st[slotPrev]
      out *= m
      side *= m
      uside *= m
    }
    if lane.ducks {
      out *= duckGain
      side *= duckGain
      uside *= duckGain
    }
    accSend += out * lane.send
    accEcho += out * lane.echoSend
    // a spread lane has no post chain (`buildLanes`), so its voices' side sum is still in step;
    // nor has a wide unison one
    let s = (spread ? side : out * lane.pan) + uside
    if splitTone {
      accTone += out
      accToneS += s
    } else {
      acc += out
      accS += s
    }
  }

  /// One sample of string `k` (Karplus-Strong: a delay of one period, a lowpass and
  /// feedback in the loop, excited by a noise burst). `rate` bends the pitch (fm, vibrato).
  @inline(__always)
  private func pluckSample(_ lane: Lane, _ k: Int, rate: Double) -> Double {
    let base = k * lane.dmax
    let d = min(Double(lane.dmax - 2), lane.dlen[k] / rate)
    var rp = Double(lane.dw[k]) - d
    if rp < 0 { rp += Double(lane.dmax) }
    if rp >= Double(lane.dmax) { rp -= Double(lane.dmax) }  // -ε + dmax rounds to dmax
    let i0 = Int(rp)
    let fr = rp - Double(i0)
    let i1 = i0 + 1 == lane.dmax ? 0 : i0 + 1
    let a = Double(lane.dl[base + i0])
    let y = a + (Double(lane.dl[base + i1]) - a) * fr
    lane.lp[k] += lane.pluckA * (y - lane.lp[k])
    var input = 0.0
    if lane.excite[k] > 0 {
      var x = lane.rng
      x ^= x &<< 13
      x ^= Int32(bitPattern: UInt32(bitPattern: x) >> 17)
      x ^= x &<< 5
      lane.rng = x
      input = Double(x) / 2_147_483_648
      lane.excite[k] -= 1
    }
    lane.dl[base + lane.dw[k]] = Float(input + lane.lp[k] * lane.fb[k])
    lane.dw[k] = lane.dw[k] + 1 == lane.dmax ? 0 : lane.dw[k] + 1
    return y
  }

  /// Voice `k`'s wavetable at phase `ph` (0..<1), interpolated: its octave's band-limited table
  /// under `.subtractive`, else the lane's one table.
  @inline(__always)
  private func tableRead(_ lane: Lane, _ k: Int, _ ph: Double) -> Double {
    let x = ph * Double(waveTableSize)
    let i = Int(x)
    let fr = x - Double(i)
    if !lane.mipOn {
      let a = Double(lane.table[i])
      let b = Double(lane.table[i + 1])
      return a + (b - a) * fr
    }
    let a = Double(lane.mip[lane.mipBase[k] + i])
    let b = Double(lane.mip[lane.mipBase[k] + i + 1])
    return a + (b - a) * fr
  }

  /// One sample of voice `k`'s filter (`.subtractive`): a two-pole state-variable lowpass
  /// (trapezoidal, so it stays stable as the cutoff sweeps every sample) at the note's
  /// frequency × `fBase` plus the velocity-scaled envelope, which falls a step.
  @inline(__always)
  private func filterSample(_ lane: Lane, _ k: Int, _ x: Double, hz: Double) -> Double {
    let e = lane.fEnv[k]
    lane.fEnv[k] = e * lane.fMul
    let fc = min(hz * lane.fBase + lane.fAmount * lane.fVel[k] * e, 0.3 * sampleRate)
    // tan(π fc / sr), to a few percent below 0.3 sr (its Taylor series to x⁵)
    let w = Double.pi * fc * lane.st[slotInvSr]
    let w2 = w * w
    let g = w * (1 + w2 * (1.0 / 3 + w2 * (2.0 / 15)))
    let a1 = 1 / (1 + g * (g + lane.fK))
    let a2 = g * a1
    let a3 = g * a2
    let ic1 = lane.fz1[k]
    let ic2 = lane.fz2[k]
    let v3 = x - ic2
    let v1 = a1 * ic1 + a2 * v3
    let v2 = ic2 + a2 * ic1 + a3 * v3
    lane.fz1[k] = 2 * v1 - ic1
    lane.fz2[k] = 2 * v2 - ic2
    return v2
  }

  private func doTick() {
    guard let proj = current else { return }
    let g = proj.graph
    if let next = pending, (g.tick + 1) % 16 == 0 {
      pending = nil
      install(next)
      ticksInBlock += 1
      anchor(next, tick: next.graph.tick, swap: true)
      return
    }
    if endsTail(proj) { return }
    let lanes = proj.lanes
    let ring = fireRing
    let macro = ring != nil && macroActive
    // The tick's anchor goes out before its fires (`advance` is exactly one tick): a reader
    // that looks at the fires first and the anchors second finds the anchor of every fire.
    anchor(proj, tick: g.tick + 1, swap: false)
    let groove =
      proj.feelTable != nil
      || grooveOn && (proj.graph.project.swing > 0 || proj.graph.project.humanize > 0)
    // the rest schedule (`.dropGap`, …) at the step about to play (`advance` moves the tick past it)
    let resting = proj.rests.isEmpty ? [] : proj.restCursor.mask(at: g.tick, in: proj.rests)
    let step = g.tick
    g.advance { n, t in
      let li = n.lane[t]
      if li >= 0 {
        if !resting.isEmpty && !resting.isDisjoint(with: lanes[li].restClass) { return }
        let note = self.playedNote(proj, lanes[li], n, t, step: step)
        if groove {
          self.grooveHit(proj, lanes[li], n, t, lane: li, note: note)
        } else {
          self.hit(lanes[li], n, t, note: note)
        }
        if let ring { self.report(ring, proj, lanes[li], n, t, note: note, macro: macro) }
      }
    }
    assert(Int(lastAnchorTick) == g.tick, "advance moved the tick by exactly one")
    if macroHoldTicks > 0 { macroHoldTicks -= 1 }
    ticksInBlock += 1
    opts.onTick?(self)
    if songEnds(proj) {
      stopped = true
      stop()
    }
  }

  /// Play `notes` on one voice, offline (instrument auditions, tests): mono, through the
  /// master curve. Not for the audio thread.
  public static func audition(
    _ voice: VoiceSpec, notes: [(note: Int, at: Double, seconds: Double)], sampleRate: Double,
    seconds: Double, velocity: Int = 100, sampler: (bank: SamplerBank, slot: Int)? = nil
  ) -> [Float] {
    var o = WaveOptions()
    o.samplers = sampler?.bank
    let r = WaveRunner(sampleRate: sampleRate, opts: o)
    var tables: [String: [Float]] = [:]
    let lane = tonalLane(voice, sampleRate, 6, tables: &tables, seed: 1)
    lane.samplerSlot = sampler?.slot ?? -1
    let starts = notes.map { Int(($0.at * sampleRate).rounded()) }
    let w = Double(max(1, min(127, velocity))) / 127
    var out = [Float](repeating: 0, count: Int(seconds * sampleRate))
    let block = 512
    out.withUnsafeMutableBufferPointer { buf in
      var b0 = 0
      while b0 < buf.count {
        let n = min(block, buf.count - b0)
        for i in 0..<n {
          r.blockOffset = i
          let t = b0 + i
          for (j, note) in notes.enumerated() where starts[j] == t {
            r.trigger(lane, note: note.note, w: w, durMs: note.seconds * 1000)
          }
          r.acc = 0
          if lane.active { r.laneSample(lane) }
          buf[t] = Float(tanh(r.acc * r.masterGain))
          r.clock[clkSamples] += 1
        }
        r.flushSamplers(buf.baseAddress! + b0, nil, frames: n)
        b0 += n
      }
    }
    // a sampler with only one bank slot in play must not keep this lane's notes ringing
    if let sampler { sampler.bank.send(sampler.slot, 0xB0, 123, 0, at: 0) }
    return out
  }

  /// One audible hit, into the fire ring. Allocation-free; a full ring overwrites its oldest.
  private func report(
    _ ring: LatestRing<FireEvent>, _ proj: WaveProject, _ lane: Lane, _ n: CompiledNet, _ t: Int,
    note: Int, macro: Bool
  ) {
    let steps = n.durSteps[t]
    let durMs = steps > 0 ? steps * 60000 / (clock[clkTempo] * ppq) : n.durMs[t]
    var flags: FireFlags = lane.isTonal ? [] : .drum
    if proj.graph.isStingerNet[n.index] { flags.insert(.stinger) }
    if macro { flags.insert(.macro) }
    ring.write(
      FireEvent(
        frame: tickFrame, tick: Int32(truncatingIfNeeded: proj.graph.tick),
        generation: proj.generation, net: Int32(truncatingIfNeeded: n.index),
        transition: Int32(truncatingIfNeeded: t), note: Int16(truncatingIfNeeded: note),
        velocity: UInt8(clamping: n.vel[t]), channel: n.channel[t], durSteps: Float(steps),
        durMs: Float(durMs), flags: flags))
  }

  /// This tick of the net clock, into the anchor ring. `tick` is the graph's counter after the
  /// tick; the flags say how it relates to the anchor before it.
  private func anchor(_ proj: WaveProject, tick: Int, swap: Bool) {
    let t = Int32(truncatingIfNeeded: tick)
    var flags: TickAnchorFlags = swap ? .swap : []
    if clockBroken
      || (!swap && (proj.generation != lastAnchorGeneration || t != lastAnchorTick &+ 1))
    {
      flags.insert(.discontinuity)
    }
    clockBroken = false
    lastAnchorGeneration = proj.generation
    lastAnchorTick = t
    anchorRing?.write(
      TickAnchor(
        frame: tickFrame, tick: t, generation: proj.generation, tempo: Float(clock[clkTempo]),
        flags: flags))
  }

  /// Render `frames` samples into `left` (and `right`, if given). `startFrame` is the deck
  /// frame of the first sample, the base of every `FireEvent` / `TickAnchor` stamp.
  public func process(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int,
    startFrame: Int = 0
  ) {
    ticksInBlock = 0
    blockStart = Int64(startFrame)
    serviceTempoFx()
    let gain = masterGain * (current?.gain ?? 1)
    // Samplers join the voices before the curve when asked (and the block fits the scratch).
    let inCurve = samplersInCurve && frames <= preL.count
    let energy = energyOn && frames <= preL.count ? current?.energy : nil
    splitTone = energy != nil
    // stereo out: side is kept (and the scratch side buffers written) only with a right channel
    let wide = stereoOn && right != nil && frames <= preS.count
    let depth = frames <= duckBuf.count ? current?.duckDepth ?? 0 : 0
    duckingSlots = depth > 0 ? current?.duckSlots ?? 0 : 0
    sendingSlots = reverb != nil && frames <= sendBuf.count ? current?.sendSlots ?? 0 : 0
    // the dip recovers over about an eighth note (3 time constants), attack 2 ms
    let duckRelease = exp(-6 * clock[clkTempo] / (60 * sampleRate))
    let duckAttack = 1 - exp(-1 / (0.002 * sampleRate))
    if depth == 0 { duckGain = 1 }
    for i in 0..<frames {
      blockOffset = i
      if scrubbing {
        scrubSample()
      } else if playing {
        clock[clkTickPos] += 1
        if clock[clkTickPos] >= clock[clkSpt] {
          clock[clkTickPos] -= clock[clkSpt]
          tickFrame = Int64(startFrame) &+ Int64(i)
          doTick()
        }
      }
      if grooveCount > 0 && clock[clkSamples] >= grooveNext { serviceGroove() }
      if depth > 0 {
        duckEnv += (duckHold - duckEnv) * duckAttack
        duckHold *= duckRelease
        duckGain = 1 - depth * duckEnv
        duckBuf[i] = Float(duckGain)
      }
      acc = 0
      accTone = 0
      accS = 0
      accToneS = 0
      accSend = 0
      accEcho = 0
      if let proj = current {
        for lane in proj.lanes {
          if lane.active {
            laneSample(lane)
          } else {
            lane.st[slotEnv] = 0
          }
        }
      }
      if let f = fading { for lane in f.lanes where lane.active { laneSample(lane) } }
      if let proj = current { for lane in proj.sources { lane.st[slotPrev] = lane.st[slotEnv] } }
      if let echoFx, echoFx.isOn {
        let (el, er) = echoFx.process(accEcho)
        let mid = 0.5 * (el + er)
        let side = 0.5 * (el - er)
        accSend += mid * EchoSpec.roomSend
        if splitTone {
          accTone += mid
          accToneS += side
        } else {
          acc += mid
          accS += side
        }
      }
      if let reverb {
        var x = accSend
        if fifoCount > 0 {
          x += Double(sendFifo[fifoRead])
          fifoRead = fifoRead + 1 == sendFifo.count ? 0 : fifoRead + 1
          fifoCount -= 1
        }
        let (wl, wr) = reverb.process(x)
        let mid = 0.5 * (wl + wr)
        let side = 0.5 * (wl - wr)
        if splitTone {
          accTone += mid
          accToneS += side
        } else {
          acc += mid
          accS += side
        }
      }
      if energy != nil {
        preL[i] = Float(acc * gain)
        toneL[i] = Float(accTone * gain)
        if wide {
          preS[i] = Float(accS * gain)
          toneS[i] = Float(accToneS * gain)
        }
      } else if inCurve {
        preL[i] = Float(acc * gain)
        if wide { preS[i] = Float(accS * gain) }
      } else if wide, let right {
        let l = acc + accS
        let r = acc - accS
        left[i] = Float(scaled ? l * gain : linear ? l : tanh(l * gain))
        right[i] = Float(scaled ? r * gain : linear ? r : tanh(r * gain))
      } else {
        let y = scaled ? acc * gain : linear ? acc : tanh(acc * gain)
        left[i] = Float(y)
        right?[i] = Float(y)
      }
      clock[clkSamples] += 1
    }
    if let energy {
      finishEnergy(energy, left, right, frames: frames, samplersIn: inCurve, wide: wide)
    } else if inCurve {
      // The bank renders adding into a cleared scratch pair; each sampler's level is the one
      // it had after the curve at unity, so it joins scaled by the track gain only.
      let trackGain = Float(current?.gain ?? 1)
      for i in 0..<frames {
        smpL[i] = 0
        smpR[i] = 0
      }
      smpL.withUnsafeMutableBufferPointer { l in
        smpR.withUnsafeMutableBufferPointer { r in
          flushSamplers(l.baseAddress!, r.baseAddress!, frames: frames)
        }
      }
      if wide { monoSamplerLows(frames: frames) }
      if let right {
        for i in 0..<frames {
          let s: Float = wide ? preS[i] : 0
          let a = (preL[i] + s) + trackGain * smpL[i]
          let b = (preL[i] - s) + trackGain * smpR[i]
          left[i] = linear ? a : Float(tanh(Double(a)))
          right[i] = linear ? b : Float(tanh(Double(b)))
        }
      } else {
        // mono, as the bank renders it without a right channel: the mean of its two
        for i in 0..<frames {
          let a = preL[i] + trackGain * 0.5 * (smpL[i] + smpR[i])
          left[i] = linear ? a : Float(tanh(Double(a)))
        }
      }
    } else {
      flushSamplers(left, right, frames: frames)
    }
    blockOffset = 0
    if let f = fading, !f.lanes.contains(where: { $0.active }) {
      fading = nil
      retire(f)
    }
  }
}
