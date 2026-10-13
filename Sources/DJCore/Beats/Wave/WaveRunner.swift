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
  /// "soft" (tanh, default) or "linear" (tests).
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
  public var onTick: ((WaveRunner) -> Void)?
  public init() {}
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
  // sampled instrument: a slot in the deck's SamplerBank (-1 = synth voice); notes sound
  // there and this lane only keeps their note-offs (sample time, fixed capacity)
  var samplerSlot = -1
  var offNote = [Int](repeating: 0, count: 64)
  var offAt = [Double](repeating: 0, count: 64)
  var offCount = 0
  var nextOff = Double.infinity
  /// Bass / pad voice that dips on the kick (`WaveOptions.duckDepth`); the kick that keys it.
  var ducks = false
  var isKick = false
  /// `.stereo`: side gain of the whole lane, and per voice when its voices spread (empty: all
  /// at `pan`). 0 = centre. `voiceSpread` is each voice's offset at full width (±spread);
  /// `voicePan` what it plays at, narrowed for low notes when the voice is struck.
  var pan = 0.0
  var voiceSpread: [Double] = []
  var voicePan: [Double] = []
  // post chain on the voice sum: lowpass biquad, then distortion
  var post: [Double] = []
  var pz1 = 0.0
  var pz2 = 0.0

  init(voice: VoiceSpec, sr: Double, tonal: Bool) {
    self.voice = voice
    isTonal = tonal
    st = [Double](repeating: 0, count: stateSize)
    st[slotLevel] = voice.level
    st[slotInvSr] = 1 / sr
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
  if voice.lowpass > 0 { lane.post = biquad(type: "lowpass", fc: voice.lowpass, q: 1, sr: sr) }
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
  /// beats has it).
  public let gain: Double
  /// The section energy arc the deck plays (`DJMusicality.Fixes.energy`); nil = none.
  public let energy: EnergyCurve?
  /// How far bass and pad dip on each kick (0: no ducking), and the sampler slots they play.
  public let duckDepth: Double
  let duckSlots: UInt64
  private static let generations = Atomic<Int>(0)
  private static let tracks = Atomic<Int>(0)

  init(
    graph: WaveGraph, lanes: [Lane], byNet: [String: [Int]], sources: [Lane], liveLane: Int,
    samplers: SamplerBank? = nil, trackSerial: Int32? = nil, startTick: Int = 0,
    geometry: Project? = nil, gain: Double = 1, energy: EnergyCurve? = nil, duckDepth: Double = 0
  ) {
    self.gain = gain
    self.energy = energy
    self.duckDepth = duckDepth
    var slots: UInt64 = 0
    for lane in lanes where lane.ducks && lane.samplerSlot >= 0 && lane.samplerSlot < 64 {
      slots |= 1 << UInt64(lane.samplerSlot)
    }
    duckSlots = slots
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
    for lane in lanes where lane.samplerSlot >= 0 { samplers.release(lane.samplerSlot) }
  }
}

private func buildLanes(
  _ g: WaveGraph, _ sr: Double, _ opts: WaveOptions, trackSerial: Int32? = nil, startTick: Int = 0,
  geometry: Project? = nil, gain: Double = 1, energy: EnergyCurve? = nil
) -> WaveProject {
  var lanes: [Lane] = []
  var byNet: [String: [Int]] = [:]
  var tables: [String: [Float]] = [:]
  // `.fills` / `.buildup` / `.crash`: beats' drum-fill nets are control nets with notes; give
  // them a voice.
  let voiceFills = !opts.musicality.isDisjoint(with: [.fills, .buildup, .crash])
  let voiceCrash = opts.musicality.contains(.crash)
  let voiceOpenHats = opts.musicality.contains(.openHats)
  let stereo = opts.musicality.contains(.stereo)
  for n in g.nets {
    if n.bundle.role == "control" && !(voiceFills && n.id.hasPrefix("fill-")) { continue }
    let tr = n.bundle.track
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
          bindSampler(lane, tr.instrument, tr.group ?? n.bundle.riffGroup, opts)
        } else {
          lane = gateLane(drumVoice(kind: key, instrument: tr.instrument), sr, lanes.count)
        }
        lane.netId = n.id
        if stereo {
          let at = DJMusicality.stereoPlacement(
            kind: key, group: tr.group ?? n.bundle.riffGroup)
          lane.pan = at.pan
          // (a voice post chain — lowpass, distortion — runs on the voice sum: one pan for all)
          if at.spread > 0 && lane.isTonal && lane.post.isEmpty && lane.voice.distortion == 0 {
            lane.voiceSpread = (0..<lane.poly).map { $0 % 2 == 0 ? at.spread : -at.spread }
            lane.voicePan = [Double](repeating: at.pan, count: lane.poly)
          }
        }
        if opts.duckDepth > 0 {
          lane.ducks = key == "tonal" && (tr.group == "bass" || tr.group == "harmony")
          lane.isKick = key == "kick" && (n.bundle.riffGroup == "kick" || n.id == "kick")
        }
        kindLane[key] = lanes.count
        kindOrder.append(key)
        lanes.append(lane)
      }
      n.lane[t] = kindLane[key]!
    }
    if !kindOrder.isEmpty { byNet[n.id] = kindOrder.map { kindLane[$0]! } }
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
  bindSampler(live, liveInstrument, "melody", opts)
  live.netId = "<live>"
  let liveIndex = lanes.count
  lanes.append(live)
  return WaveProject(
    graph: g, lanes: lanes, byNet: byNet, sources: sources, liveLane: liveIndex,
    samplers: opts.samplers, trackSerial: trackSerial, startTick: startTick, geometry: geometry,
    gain: gain, energy: energy, duckDepth: opts.duckDepth)
}

/// Play `instrument` on the deck's sampler when its category picks a sampled sound for this
/// role and one loads (off the audio thread: this may load an EXS from disk, or evict an
/// unused one). The reference taken on the slot is the project's, given back in
/// `WaveProject.deinit`.
private func bindSampler(_ lane: Lane, _ instrument: String, _ role: String, _ opts: WaveOptions) {
  guard let bank = opts.samplers, opts.instruments != nil,
    let sources = VoiceCatalog.shared.sources(
      instrument: instrument, role: role.isEmpty ? "melody" : role, seed: opts.voicingSeed),
    let slot = bank.slot(for: sources)
  else { return }
  lane.samplerSlot = slot
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

  public init(sampleRate: Double, opts: WaveOptions = WaveOptions()) {
    self.sampleRate = sampleRate
    self.opts = opts
    samplers = opts.samplers
    samplersInCurve = opts.samplers != nil && opts.musicality.contains(.loudness)
    grooveOn = opts.musicality.contains(.groove)
    energyOn = opts.musicality.contains(.energy)
    stereoOn = opts.musicality.contains(.stereo)
    samplerSide = SideHighpass(hz: 150, sampleRate: sampleRate)
    masterGain = opts.masterGain
    linear = opts.master == "linear"
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
    let g = WaveGraph(project: project)
    if startTick > 0 { g.fastForward(to: startTick) }
    // (the compiled graph is built from the project's JSON, which has no coordinates: the
    // layout takes the net positions from the project itself)
    let gain =
      opts.trackGain ?? (opts.musicality.contains(.loudness) ? Loudness.gain(for: project) : 1)
    let energy =
      opts.musicality.contains(.energy) ? (opts.trackEnergy ?? EnergyCurve(project: project)) : nil
    return buildLanes(
      g, sampleRate, opts, trackSerial: trackSerial, startTick: max(0, startTick),
      geometry: project, gain: gain, energy: energy)
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
      let ok = g.unadvance { n, t in
        let li = n.lane[t]
        if li >= 0, let lanes = proj?.lanes { self.hit(lanes[li], n, t) }
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
    let lanes = current?.lanes ?? []
    g.advance { n, t in
      let li = n.lane[t]
      if li >= 0 { self.hit(lanes[li], n, t) }
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
      n += 1
    }
    clock[clkTickPos] += (ticks - whole) * clock[clkSpt]
  }

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

  private func hit(_ lane: Lane, _ n: CompiledNet, _ t: Int, velocity: Int? = nil) {
    lane.active = true
    let w = Double(velocity ?? n.vel[t]) / 127
    if lane.isKick { duckHold = 1 }
    if !lane.isTonal {
      for e in 0..<lane.numExp { lane.s[e] += lane.alpha[e] * w }
      if lane.carrier == .sweep { lane.st[slotSweep] = 1 }
      return
    }
    let steps = n.durSteps[t]
    let durMs = steps > 0 ? steps * 60000 / (clock[clkTempo] * ppq) : n.durMs[t]
    trigger(lane, note: n.note[t], w: w, durMs: durMs)
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
    var tau = (durMs > 0 ? durMs : 100) / 1000 * lane.voice.decayScale
    tau = tau < 0.03 ? 0.03 : (tau > lane.voice.maxDecay ? lane.voice.maxDecay : tau)
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
  private func grooveHit(
    _ proj: WaveProject, _ lane: Lane, _ n: CompiledNet, _ t: Int, lane li: Int
  ) {
    let p = proj.graph.project
    let step = proj.graph.tick - 1
    let tickMs = 60000 / (clock[clkTempo] * ppq)
    let h = p.humanize / 100
    var r = grooveHash(step, n.index, t)
    let r1 = Double(r & 0xFFFF) / 65535 * 2 - 1
    r >>= 16
    let r2 = Double(r & 0xFFFF) / 65535 * 2 - 1
    var delayMs = 0.0
    if step % 2 == 1 {
      delayMs = max(0, p.swing / 100 * tickMs * 0.5 + r1 * h * 30)
    } else if h > 0 {
      delayMs = max(0, r1 * h * 15)
    }
    let vel = h > 0 ? max(1, min(127, Int((Double(n.vel[t]) + r2 * h * 15).rounded()))) : n.vel[t]
    let delay = delayMs / 1000 * sampleRate
    guard delay >= 1, grooveCount < Self.grooveCapacity else {
      hit(lane, n, t, velocity: vel)
      return
    }
    let due = clock[clkSamples] + delay
    grooveDue[grooveCount] = due
    grooveNet[grooveCount] = Int32(n.index)
    grooveTrans[grooveCount] = Int32(t)
    grooveLane[grooveCount] = Int32(li)
    grooveVel[grooveCount] = Int32(vel)
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
        hit(proj.lanes[Int(grooveLane[k])], n, Int(grooveTrans[k]), velocity: Int(grooveVel[k]))
        grooveCount -= 1
        grooveDue[k] = grooveDue[grooveCount]
        grooveNet[k] = grooveNet[grooveCount]
        grooveTrans[k] = grooveTrans[grooveCount]
        grooveLane[k] = grooveLane[grooveCount]
        grooveVel[k] = grooveVel[grooveCount]
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
    let ducked = frames <= duckL.count ? live & duckingSlots : 0
    bank.renderAll(live & ~ducked, frames: frames, left, right)
    if ducked != 0 {
      for i in 0..<frames {
        duckL[i] = 0
        duckR[i] = 0
      }
      duckL.withUnsafeMutableBufferPointer { l in
        duckR.withUnsafeMutableBufferPointer { r in
          bank.renderAll(
            ducked, frames: frames, l.baseAddress!, right == nil ? nil : r.baseAddress!)
        }
      }
      for i in 0..<frames {
        left[i] += duckL[i] * duckBuf[i]
        right?[i] += duckR[i] * duckBuf[i]
      }
    }
    bank.endBlock()
  }

  /// Tune voice `v` to `note`; a string is damped and plucked again.
  private func strike(_ lane: Lane, _ v: Int, note: Int) {
    lane.inc[v] = 440 * pow(2, (Double(note) - 69) / 12) * lane.st[slotInvSr]
    if !lane.voiceSpread.isEmpty {
      // centred at E3 and below (the low end stays mono), full width from G4 up
      let width = min(1, max(0, Double(note - 52) / 15))
      lane.voicePan[v] = lane.pan + lane.voiceSpread[v] * width
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
      for e in 0..<lane.numExp {
        env += lane.s[e]
        lane.s[e] *= lane.mul[e]
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
      if abs(lane.s[0]) < silent && (lane.numExp < 2 || abs(lane.s[1]) < silent) {
        lane.active = false
        lane.st[slotEnv] = 0
      }
      return
    }
    // Tonal pool
    var out = 0.0
    var side = 0.0  // per-voice pan (`voicePan`), summed alongside `out`
    let spread = !lane.voicePan.isEmpty
    var envSum = 0.0
    var live = false
    let fmk = lane.fm != nil ? 1 + lane.st[slotFmDepth] * lane.fm!.st[slotPrev] : 1
    let am = lane.st[slotAttMul]
    var vib = 1.0
    if lane.vibInc > 0 {
      var vp = lane.vibPhase + lane.vibInc
      vp -= vp.rounded(.down)
      lane.vibPhase = vp
      vib = 1 + lane.voice.vibratoDepth * sin(2 * Double.pi * vp)
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
      var ph = lane.phase[k] + lane.inc[k] * fmk * vib
      ph -= ph.rounded(.down)
      lane.phase[k] = ph
      let x = ph * Double(waveTableSize)
      let i = Int(x)
      let fr = x - Double(i)
      let a = Double(lane.table[i])
      let b = Double(lane.table[i + 1])
      let y = env * (a + (b - a) * fr)
      out += y
      if spread { side += y * lane.voicePan[k] }
    }
    lane.st[slotEnv] = envSum
    if !live { lane.active = false }
    if !lane.post.isEmpty {
      let b = lane.post
      let y = b[0] * out + lane.pz1
      lane.pz1 = b[1] * out - b[3] * y + lane.pz2
      lane.pz2 = b[2] * out - b[4] * y
      out = y
    }
    if lane.voice.distortion > 0 { out = toneDistortion(out, amount: lane.voice.distortion) }
    out *= lane.st[slotLevel]
    if spread { side *= lane.st[slotLevel] }
    if let amod = lane.am {
      let m = 1 - lane.st[slotAmDepth] + lane.st[slotAmDepth] * amod.st[slotPrev]
      out *= m
      side *= m
    }
    if lane.ducks {
      out *= duckGain
      side *= duckGain
    }
    // a spread lane has no post chain (`buildLanes`), so its voices' side sum is still in step
    let s = spread ? side : out * lane.pan
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
    let lanes = proj.lanes
    let ring = fireRing
    let macro = ring != nil && macroActive
    // The tick's anchor goes out before its fires (`advance` is exactly one tick): a reader
    // that looks at the fires first and the anchors second finds the anchor of every fire.
    anchor(proj, tick: g.tick + 1, swap: false)
    let groove = grooveOn && (proj.graph.project.swing > 0 || proj.graph.project.humanize > 0)
    g.advance { n, t in
      let li = n.lane[t]
      if li >= 0 {
        if groove {
          self.grooveHit(proj, lanes[li], n, t, lane: li)
        } else {
          self.hit(lanes[li], n, t)
        }
        if let ring { self.report(ring, proj, lanes[li], n, t, macro: macro) }
      }
    }
    assert(Int(lastAnchorTick) == g.tick, "advance moved the tick by exactly one")
    if macroHoldTicks > 0 { macroHoldTicks -= 1 }
    ticksInBlock += 1
    opts.onTick?(self)
    if g.stopRequested {
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
    macro: Bool
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
        transition: Int32(truncatingIfNeeded: t), note: Int16(truncatingIfNeeded: n.note[t]),
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
        left[i] = Float(linear ? l : tanh(l * gain))
        right[i] = Float(linear ? r : tanh(r * gain))
      } else {
        let y = linear ? acc : tanh(acc * gain)
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
