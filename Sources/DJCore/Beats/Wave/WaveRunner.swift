import Foundation

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
  _ voice: VoiceSpec, _ sr: Double, _ poly: Int, tables: inout [String: [Float]]
)
  -> Lane
{
  let lane = Lane(voice: voice, sr: sr, tonal: true)
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
  public let graph: WaveGraph
  let lanes: [Lane]
  let byNet: [String: [Int]]
  let sources: [Lane]
  /// Index in `lanes` of the pooled voice that MIDI keys play.
  let liveLane: Int
  init(graph: WaveGraph, lanes: [Lane], byNet: [String: [Int]], sources: [Lane], liveLane: Int) {
    self.liveLane = liveLane
    self.graph = graph
    self.lanes = lanes
    self.byNet = byNet
    self.sources = sources
  }
}

private func buildLanes(_ g: WaveGraph, _ sr: Double, _ opts: WaveOptions) -> WaveProject {
  var lanes: [Lane] = []
  var byNet: [String: [Int]] = [:]
  var tables: [String: [Float]] = [:]
  for n in g.nets {
    if n.bundle.role == "control" { continue }
    let tr = n.bundle.track
    let override = opts.voices[n.id]
    var kindOrder: [String] = []
    var kindLane: [String: Int] = [:]
    for t in 0..<n.nTrans where n.midi[t] {
      let b = n.bundle.bindings[n.transIds[t]]!
      let ch = b.channel != 0 ? b.channel : tr.channel
      let key = override != nil ? "v" : (isDrumChannel(ch) ? drumKind(n.note[t]) : "tonal")
      if kindLane[key] == nil {
        let lane: Lane
        if let override {
          lane =
            override.kind == "tonal"
            ? tonalLane(override, sr, 4, tables: &tables) : gateLane(override, sr, lanes.count)
        } else if key == "tonal" {
          lane = tonalLane(
            tonalVoice(instrument: tr.instrument, group: tr.group), sr,
            tr.group == "harmony" ? 6 : 4, tables: &tables)
        } else {
          lane = gateLane(drumVoice(kind: key, instrument: tr.instrument), sr, lanes.count)
        }
        lane.netId = n.id
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
  let liveVoice = tonalVoice(
    instrument: melody?.bundle.track.instrument ?? "", group: "melody")
  let live = tonalLane(liveVoice, sr, 8, tables: &tables)
  live.netId = "<live>"
  let liveIndex = lanes.count
  lanes.append(live)
  return WaveProject(
    graph: g, lanes: lanes, byNet: byNet, sources: sources, liveLane: liveIndex)
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
  public var graph: WaveGraph? { current?.graph }
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

  public init(sampleRate: Double, opts: WaveOptions = WaveOptions()) {
    self.sampleRate = sampleRate
    self.opts = opts
    masterGain = opts.masterGain
    linear = opts.master == "linear"
    clock[clkTempo] = 120
    clock[clkSpt] = spt(120)
  }

  public var tempo: Double { clock[clkTempo] }
  public var samples: Double { clock[clkSamples] }

  private func spt(_ bpm: Double) -> Double { sampleRate * 60 / (bpm * ppq) }

  /// Compile everything off the audio thread. Hand the result to `load(prepared:)`.
  /// `startTick` replays the net silently to that tick first (a section launch).
  public static func prepare(
    _ project: Project, sampleRate: Double, opts: WaveOptions = WaveOptions(), startTick: Int = 0
  ) -> WaveProject {
    let g = WaveGraph(project: project)
    if startTick > 0 { g.fastForward(to: startTick) }
    return buildLanes(g, sampleRate, opts)
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
    clock[clkTickPos] = clock[clkSpt] - 1  // first tick lands on the next sample
  }

  public func pause() { playing = false }

  public func stop() {
    playing = false
    graph?.reset()
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
  public func fireStinger(hash: Int32, ticks: Int) { graph?.fireStinger(hash: hash, ticks: ticks) }

  public func setMute(_ netId: String, _ muted: Bool) {
    if let g = graph, let i = g.byId[netId] { g.muted[i] = muted ? 1 : 0 }
  }

  // MARK: scratching the net clock

  /// Hand on the platter: the tick clock stops following the tempo and follows the hand.
  public func freeze() {
    guard graph != nil, !scrubbing else { return }
    scrubbing = true
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
    lane.inc[v] = 440 * pow(2, (Double(note) - 69) / 12) * lane.st[slotInvSr]
    lane.md[v] = exp(-lane.st[slotInvSr] / 0.3)  // release time constant, used after noteOff
    lane.hold[v] = true
    lane.heldNote[v] = note
    lane.sd[v] = w
    lane.sa[v] = cur - w
  }

  public func noteOff(_ note: Int) {
    guard let proj = current else { return }
    let lane = proj.lanes[proj.liveLane]
    for k in 0..<lane.poly where lane.hold[k] && lane.heldNote[k] == note {
      lane.hold[k] = false
      lane.heldNote[k] = -1
    }
  }

  public func allNotesOff() {
    guard let proj = current else { return }
    let lane = proj.lanes[proj.liveLane]
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

  private func beginTempoFx(_ kind: TempoFx, target: Double, ticks: Int) {
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

  /// Fire a net macro (`catalog.js`): mutes restore after `ticks` net ticks; tempo
  /// macros last `ticks` ticks of wall time at the tempo they were fired at.
  public func fireMacro(_ macro: NetMacro, ticks: Int) {
    guard let g = graph else { return }
    switch macro {
    case .drop: g.fireMute(.nonDrums, ticks: ticks)
    case .breakdown: g.fireMute(.drumsOnly, ticks: ticks)
    case .soloDrums: g.fireMute(.nonDrums, ticks: ticks)
    case .cut: g.fireMute(.everything, ticks: ticks)
    case .doubleDrop:
      g.fireMute(.everything, ticks: 2)
      // the second half lands 260 ms later (a timer on the net clock, in ticks)
      let delay = max(1, Int((0.26 / (60 / (clock[clkTempo] * ppq))).rounded()))
      g.scheduleMute(.nonDrums, after: delay, ticks: ticks)
    case .beatRepeat: g.fireBeatRepeat(ticks: ticks)
    case .halfTime:
      beginTempoFx(.hold, target: max(20, jsRound(clock[clkTempo] * 0.5)), ticks: ticks)
    case .tapeStop: beginTempoFx(.sweep, target: 22, ticks: ticks)
    case .tempoAnchor: beginTempoFx(.hold, target: max(20, g.project.tempo), ticks: ticks)
    }
  }

  /// Restore every pending macro effect now.
  public func panic() {
    graph?.cancelMacros()
    if tempoFx != .none {
      tempoFx = .none
      setTempo(fxStartBpm)
    }
  }

  // MARK: onsets

  private func hit(_ lane: Lane, _ n: CompiledNet, _ t: Int) {
    lane.active = true
    let w = Double(n.vel[t]) / 127
    if !lane.isTonal {
      for e in 0..<lane.numExp { lane.s[e] += lane.alpha[e] * w }
      if lane.carrier == .sweep { lane.st[slotSweep] = 1 }
      return
    }
    let steps = n.durSteps[t]
    let durMs = steps > 0 ? steps * 60000 / (clock[clkTempo] * ppq) : n.durMs[t]
    // Steal the quietest voice (deterministic), continuing from its current level.
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
    lane.inc[v] = 440 * pow(2, (Double(n.note[t]) - 69) / 12) * lane.st[slotInvSr]
    var tau = (durMs > 0 ? durMs : 100) / 1000 * lane.voice.decayScale
    tau = tau < 0.03 ? 0.03 : (tau > lane.voice.maxDecay ? lane.voice.maxDecay : tau)
    lane.md[v] = exp(-lane.st[slotInvSr] / tau)
    lane.sd[v] = w
    lane.sa[v] = cur - w
  }

  // MARK: per-sample

  /// One sample of `lane`, added into `acc`.
  private func laneSample(_ lane: Lane) {
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
      if abs(lane.s[0]) < silent && (lane.numExp < 2 || abs(lane.s[1]) < silent) {
        lane.active = false
        lane.st[slotEnv] = 0
      }
      return
    }
    // Tonal pool
    var out = 0.0
    var envSum = 0.0
    var live = false
    let fmk = lane.fm != nil ? 1 + lane.st[slotFmDepth] * lane.fm!.st[slotPrev] : 1
    let am = lane.st[slotAttMul]
    for k in 0..<lane.poly {
      let sd = lane.sd[k]
      let sa = lane.sa[k]
      if abs(sd) < silent && abs(sa) < silent { continue }
      live = true
      let env = sd + sa
      envSum += env
      lane.sd[k] = sd * (lane.hold[k] ? 1.0 : lane.md[k])
      lane.sa[k] = sa * am
      var ph = lane.phase[k] + lane.inc[k] * fmk
      ph -= ph.rounded(.down)
      lane.phase[k] = ph
      let x = ph * Double(waveTableSize)
      let i = Int(x)
      let fr = x - Double(i)
      let a = Double(lane.table[i])
      let b = Double(lane.table[i + 1])
      out += env * (a + (b - a) * fr)
    }
    lane.st[slotEnv] = envSum
    if !live { lane.active = false }
    out *= lane.st[slotLevel]
    if let amod = lane.am {
      out *= 1 - lane.st[slotAmDepth] + lane.st[slotAmDepth] * amod.st[slotPrev]
    }
    acc += out
  }

  private func doTick() {
    guard let proj = current else { return }
    let g = proj.graph
    if let next = pending, (g.tick + 1) % 16 == 0 {
      pending = nil
      install(next)
      ticksInBlock += 1
      return
    }
    let lanes = proj.lanes
    g.advance { n, t in
      let li = n.lane[t]
      if li >= 0 { self.hit(lanes[li], n, t) }
    }
    ticksInBlock += 1
    opts.onTick?(self)
    if g.stopRequested {
      stopped = true
      stop()
    }
  }

  /// Render `frames` samples into `left` (and `right`, if given).
  public func process(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int
  ) {
    ticksInBlock = 0
    serviceTempoFx()
    let gain = masterGain
    for i in 0..<frames {
      if scrubbing {
        scrubSample()
      } else if playing {
        clock[clkTickPos] += 1
        if clock[clkTickPos] >= clock[clkSpt] {
          clock[clkTickPos] -= clock[clkSpt]
          doTick()
        }
      }
      acc = 0
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
      let y = linear ? acc : tanh(acc * gain)
      left[i] = Float(y)
      right?[i] = Float(y)
      clock[clkSamples] += 1
    }
    if let f = fading, !f.lanes.contains(where: { $0.active }) {
      fading = nil
      retire(f)
    }
  }
}
