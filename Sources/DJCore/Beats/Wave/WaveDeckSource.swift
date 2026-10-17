import Synchronization

/// Messages from the main thread to the audio thread.
public enum WaveCommand: BitwiseCopyable {
  /// An `Unmanaged<WaveProject>` retained by the sender.
  case load(UnsafeMutableRawPointer)
  case play
  case pause
  case stop
  case tempo(Double)
  /// Mute a net by `strHash(netId)`.
  case mute(hash: Int32, muted: Bool)
  /// Mute / unmute a role (riff group or plain net) by `strHash(role)`.
  case roleMute(hash: Int32, muted: Bool)
  /// `activate-slot` on the net with this `strHash(netId)`.
  case slot(hash: Int32)
  case macro(id: UInt8, ticks: Int32)
  case stinger(hash: Int32, ticks: Int32)
  case panic
  /// Live keys (already scale-locked by the sender).
  case noteOn(note: Int16, velocity: UInt8)
  case noteOff(note: Int16)
  case allNotesOff
  /// Shift the beat grid by this many ticks (see `WaveRunner.align`).
  case align(ticks: Double)
  /// Scratching the net clock.
  case freeze
  case scrub(ticks: Double)
  case release
  case chase(seconds: Double)
  /// A master-chain macro (`MasterMacro.rawValue`); `bars` < 0: its default duration, 0:
  /// permanent.
  case masterMacro(id: UInt8, bars: Int16)
  /// A hand on a master FX slider (`MasterFxKey.rawValue`, the slider's own units).
  case masterFx(key: UInt8, value: Int16)
  /// A channel's voice settings, from the sound panel (`WaveRunner.setVoice`).
  case voice(VoiceLaneParams)
}

/// A `WaveRunner` that a deck can play: the Petri-net executor and the wave synthesis
/// running on the audio thread, driven from the main thread through a lock-free queue.
///
/// Same contract as `Turntable`:
///  * `render` is the only code on the audio thread. It allocates nothing, takes no
///    locks and frees nothing (measured: `WaveRunnerRealTimeTests`, release builds).
///  * Everything else is for one non-audio thread. Projects are compiled off the audio
///    thread (`WaveRunner.prepare`) and handed over whole; whatever the audio thread
///    lets go of comes back through `retired` to be freed on the main thread.
///
/// What the scopes read, all in the deck's frame time base (`Deck.renderedFrames`):
///  * `fires` / `anchors` (and `readEvents`): audible hits and every tick of the net clock, in
///    overwrite rings the audio thread fills. Any number of readers, each with its own cursor.
///  * `readMarking`: a consistent copy of every net's tokens and mutes (the marking mirror),
///    with the layout of the project it came from.
///  * the atomics `tick`, `tickPhase`, `tempo`, `isPlaying`, `isMacroActive`, the mute words.
///    Each is stored once per render block and they are not stamped or stored together, so two
///    of them may be one block apart; the (frame, tick) pairs that are exact are the anchors'.
///
/// **Net mode only.** These mirrors, the rings and the marking mirror are written by `render`,
/// which the deck calls only while it plays a net (`Deck.mode == .net`). After the deck goes
/// back to a sample they stop where they were (`isPlaying` may still read true, `readMarking`
/// still returns the last song): gate every read on `Deck.mode`, which is main-thread state.
public final class WaveDeckSource: @unchecked Sendable {
  public let sampleRate: Double

  private let commands = SPSCRing<WaveCommand>(capacity: 512)
  private let retired = SPSCRing<UnsafeMutableRawPointer>(capacity: 32)
  private let runner: WaveRunner
  /// Audio -> readers: every audible net fire, and every tick of the net clock, in order, as
  /// absolute sequence numbers. The audio thread only writes; each reader keeps its own cursor.
  /// Read `fires` before `anchors` (see `readEvents`).
  public let fires: LatestRing<FireEvent>
  public let anchors: LatestRing<TickAnchor>
  /// Frames rendered through the 3-argument `render` (a standalone source's own time base).
  private var ownFrames = 0

  // Audio → main mirrors.
  private let tickAtomic = Atomic<Int>(0)
  private let phaseBits = Atomic<UInt64>(0)
  private let tempoBits = Atomic<UInt64>(0)
  private let playingAtomic = Atomic<Bool>(false)
  private let stoppedAtomic = Atomic<Bool>(false)
  private let hasProjectAtomic = Atomic<Bool>(false)
  private let scrubbingAtomic = Atomic<Bool>(false)
  private let macroAtomic = Atomic<Bool>(false)
  /// Which macros are in effect, which nets each holds muted, and for which project: one
  /// consistent record per block (see MacroMirror.swift).
  private let macroMirror = MacroMirror()
  /// The last whole record a reader got (main thread): what it keeps if a writer is in the way.
  private var macroLast = MacroMirror.Read()
  /// Whether the owning deck routes its output through this source.
  private let activeAtomic = Atomic<Bool>(false)
  /// Bit i of word i/64 = net i is muted (first 256 nets), refreshed every block.
  private let muteWord0 = Atomic<UInt64>(0)
  private let muteWord1 = Atomic<UInt64>(0)
  private let muteWord2 = Atomic<UInt64>(0)
  private let muteWord3 = Atomic<UInt64>(0)

  /// Main-thread only: the last project handed over, to resolve net ids.
  public private(set) var latest: WaveProject?
  /// Main-thread only: each channel's voice settings (the sound panel), set on every project
  /// handed over from now on (`load`) as well as the one playing. Session state: never in a
  /// share or a favorite. The deck clears it when another song loads (`Deck.loadNet`).
  public private(set) var voiceSettings: [Int: VoiceSetting] = [:]
  /// `WaveProject.generation` of the project the audio thread is running (0: none yet).
  private let activeGenerationAtomic = Atomic<Int32>(0)
  /// The project queued behind it, waiting for a bar (0: none).
  private let pendingGenerationAtomic = Atomic<Int32>(0)
  /// Main-thread only: the mirrors (with their layouts) of recently loaded projects, oldest
  /// first, so a snapshot or an event can be matched to the layout of the project that
  /// produced it even after newer projects have been loaded. Not the projects themselves
  /// (about 6 MB each for a big song): a mirror with its layout is about 0.35 MB (measured,
  /// 6000-place techno), 8 of them a few MB per deck.
  private var mirrors: [MarkingMirror] = []
  private static let mirrorsKept = 8

  /// This deck's sampled instruments (rendered by `runner`, inside this deck's callback).
  public let samplers: SamplerBank

  // The master chain (beats' Tone master inserts) after the net and its samplers, and the
  // macro automation that drives it, on the deck's transport clock (see MasterFx/).
  private let fx: FxAutomation
  private let chain: MasterChain
  /// Frames the transport has run (it stops while the deck is paused or stopped).
  private var transportFrames: Int64 = 0
  /// The block being rendered: its transport time and length (for the automation's events).
  private var blockTransport = 0.0
  private var blockFrames = 0
  /// This block's slider dispatches, in time order: sample index, chain time, key, value.
  private static let opCapacity = 256
  private let opIndex: UnsafeMutablePointer<Int>
  private let opTime: UnsafeMutablePointer<Double>
  private let opKey: UnsafeMutablePointer<UInt8>
  private let opValue: UnsafeMutablePointer<Int32>
  private var opCount = 0
  /// Audio → main: which master macros are in effect (`MasterMacro.bit`), the chain's HP / LP
  /// corners (Double bits) and whether it is bypassed.
  private let masterMaskAtomic = Atomic<UInt32>(0)
  private let hpCornerBits = Atomic<UInt64>(20.0.bitPattern)
  private let lpCornerBits = Atomic<UInt64>(20000.0.bitPattern)
  private let chainIdleAtomic = Atomic<Bool>(true)

  /// `fireCapacity` / `anchorCapacity` size the event rings (rounded up to a power of two). A
  /// ring that fills overwrites its oldest records; a reader that was a whole ring behind is
  /// told how many it missed. The defaults hold minutes of an ordinary song and many seconds
  /// of the densest one, against a reader that polls at 30...60 Hz.
  public init(
    sampleRate: Double, opts: WaveOptions = WaveOptions(), fireCapacity: Int = 8192,
    anchorCapacity: Int = 2048
  ) {
    self.sampleRate = sampleRate
    let bank = opts.samplers ?? SamplerBank(sampleRate: sampleRate)
    samplers = bank
    var o = opts
    o.samplers = bank
    fires = LatestRing<FireEvent>(capacity: fireCapacity)
    anchors = LatestRing<TickAnchor>(capacity: anchorCapacity)
    runner = WaveRunner(sampleRate: sampleRate, opts: o)
    runner.fireRing = fires
    runner.anchorRing = anchors
    fx = FxAutomation()
    chain = MasterChain(sampleRate: sampleRate)
    opIndex = .allocate(capacity: Self.opCapacity)
    opTime = .allocate(capacity: Self.opCapacity)
    opKey = .allocate(capacity: Self.opCapacity)
    opValue = .allocate(capacity: Self.opCapacity)
    let ring = retired
    runner.onRetire = { project in
      // Retain into the ring *before* the runner drops its own reference, so the last
      // release (and the free) happens on the main thread.
      _ = ring.push(Unmanaged.passRetained(project).toOpaque())
    }
  }

  deinit {
    while let c = commands.pop() {
      if case .load(let p) = c { Unmanaged<WaveProject>.fromOpaque(p).release() }
    }
    drainRetired()
    opIndex.deallocate()
    opTime.deallocate()
    opKey.deallocate()
    opValue.deallocate()
  }

  // MARK: main-thread side

  public var isActive: Bool {
    get { activeAtomic.load(ordering: .relaxed) }
    set { activeAtomic.store(newValue, ordering: .relaxed) }
  }

  public func send(_ command: WaveCommand) {
    drainRetired()
    commands.push(command)
  }

  /// Hand a compiled project to the audio thread: immediately when stopped, at the next
  /// bar when playing.
  public func load(_ prepared: WaveProject) {
    // the channels' voice settings go with it (it is not the audio thread's yet); a channel
    // whose instrument changed starts from that instrument's own voice
    for (ch, setting) in voiceSettings {
      guard let v = prepared.channelVoice(ch) else { continue }
      if v.instrument != setting.instrument {
        voiceSettings[ch] = nil
        continue
      }
      prepared.applyVoice(prepared.voiceParams(channel: ch, setting, sampleRate: sampleRate))
    }
    let p = Unmanaged.passRetained(prepared).toOpaque()
    drainRetired()
    if commands.push(.load(p)) {
      latest = prepared
      remember(prepared.marking)
      // A stopped deck installs the project at once: show its starting mutes before the
      // first render publishes the real ones.
      if !isPlaying { publishMutes(prepared.graph.muted) }
    } else {
      Unmanaged<WaveProject>.fromOpaque(p).release()
    }
  }

  /// Set channel `channel`'s voice: `tweak` on the instrument's own, and (a sampled channel)
  /// its synth voice instead of the sample. Takes effect at the next block on the project
  /// playing and any queued, and on every project loaded after (`load`). A default setting
  /// (empty tweak, sample) is the instrument exactly. False when the latest project has no net
  /// on that channel.
  @discardableResult
  public func setVoice(channel: Int, tweak: VoiceTweak, useSynth: Bool) -> Bool {
    guard let project = latest, let v = project.channelVoice(channel) else { return false }
    let setting = VoiceSetting(tweak: tweak, useSynth: useSynth, instrument: v.instrument)
    voiceSettings[channel] = setting.isDefault ? nil : setting
    send(.voice(project.voiceParams(channel: channel, setting, sampleRate: sampleRate)))
    return true
  }

  /// Forget every channel's voice settings for the projects loaded from now on (another song).
  /// The one playing keeps its sound until it is replaced.
  public func clearVoiceSettings() { voiceSettings = [:] }

  public func play() { send(.play) }
  public func pause() { send(.pause) }
  public func stop() { send(.stop) }
  public func setTempo(_ bpm: Double) { send(.tempo(bpm)) }

  public func setMute(_ netId: String, _ muted: Bool) {
    send(.mute(hash: strHash(netId), muted: muted))
  }

  public func setRoleMuted(_ role: String, _ muted: Bool) {
    send(.roleMute(hash: strHash(role), muted: muted))
  }

  public func activateSlot(_ netId: String) { send(.slot(hash: strHash(netId))) }
  public func fire(_ macro: NetMacro, ticks: Int? = nil) {
    send(.macro(id: macro.rawValue, ticks: Int32(ticks ?? macro.ticks())))
  }
  public func fireStinger(_ netId: String, ticks: Int = 16) {
    send(.stinger(hash: strHash(netId), ticks: Int32(ticks)))
  }
  public func panic() { send(.panic) }

  /// Fire a master-chain macro for `bars` bars (nil: its default; 0: permanent, no restore).
  public func fire(_ macro: MasterMacro, bars: Int? = nil) {
    send(.masterMacro(id: macro.rawValue, bars: Int16(clamping: bars ?? -1)))
  }

  /// Move one of the master FX sliders by hand (its own units: 0...100, pitch -12...12).
  public func setMasterFx(_ key: MasterFxKey, _ value: Int) {
    send(.masterFx(key: UInt8(key.rawValue), value: Int16(clamping: value)))
  }

  public func noteOn(_ note: Int, velocity: Int) {
    send(.noteOn(note: Int16(clamping: note), velocity: UInt8(clamping: velocity)))
  }
  public func noteOff(_ note: Int) { send(.noteOff(note: Int16(clamping: note))) }
  public func allNotesOff() { send(.allNotesOff) }
  public func align(ticks: Double) { send(.align(ticks: ticks)) }
  public func freeze() { send(.freeze) }
  public func scrub(ticks: Double) { send(.scrub(ticks: ticks)) }
  public func release() { send(.release) }

  /// Is net `index` of the latest project muted right now? (Mute mirror, main-thread safe.)
  public func isNetMuted(index i: Int) -> Bool {
    guard i >= 0, i < 256 else { return false }
    let w: UInt64
    switch i / 64 {
    case 0: w = muteWord0.load(ordering: .relaxed)
    case 1: w = muteWord1.load(ordering: .relaxed)
    case 2: w = muteWord2.load(ordering: .relaxed)
    default: w = muteWord3.load(ordering: .relaxed)
    }
    return w & (1 << UInt64(i % 64)) != 0
  }

  /// Is the role (a riff group or a plain net id) making sound right now? Reads the
  /// mute mirror and the latest project's role table, so it is main-thread safe.
  public func isRoleAudible(_ role: String) -> Bool {
    guard let g = latest?.graph, let t = g.roleTargets[strHash(role)] else { return false }
    let words = [
      muteWord0.load(ordering: .relaxed), muteWord1.load(ordering: .relaxed),
      muteWord2.load(ordering: .relaxed), muteWord3.load(ordering: .relaxed),
    ]
    func muted(_ i: Int) -> Bool { i < 256 && words[i / 64] & (1 << UInt64(i % 64)) != 0 }
    if t >= 0 { return g.groupNets[t].contains { !muted($0) } }
    return !muted(-t - 2)
  }

  // MARK: fires and tick anchors (any reader thread)

  /// A reader's place in a deck's two event streams: the next fire and the next anchor it has
  /// not seen. Every reader (a deck's feed, the master's feed, a timeline) has its own, so
  /// readers never disturb one another or the audio thread.
  public struct EventCursor: Equatable, Sendable {
    public var fires: Int
    public var anchors: Int
    public init(fires: Int = 0, anchors: Int = 0) {
      self.fires = fires
      self.anchors = anchors
    }
  }

  /// A cursor for a reader that subscribes now: it sees the fires from now on, and the anchors
  /// from the newest one written so far (so the first anchor it reads places it on the net
  /// clock at once, and the fires of a tick that is half written still find their anchor).
  /// `EventCursor()` instead starts at the oldest records still held.
  public func eventCursorNow() -> EventCursor {
    let a = anchors.written  // anchors first: a tick's anchor is written before its fires
    let f = fires.written
    return EventCursor(fires: f, anchors: max(0, a - 1))
  }

  /// Append everything written since `cursor` to `fires` and `anchors` (oldest first) and move
  /// the cursor past it. Returns how many records of each stream were lost: overwritten before
  /// this reader got to them, because it was a whole ring behind.
  ///
  /// The fires are read first and the anchors second, and the audio thread writes a tick's
  /// anchor before its fires, so every fire returned has its anchor (same `generation` and
  /// `tick`) in this call's `anchors` or an earlier one's, unless that anchor was lost.
  /// Records are stamped in the deck's frame time base and carry their project `generation`
  /// (resolve it with `markingLayout(generation:)`: which net, which lane, which song).
  ///
  /// Allocates only if the arrays have to grow, on the caller's thread.
  @discardableResult
  public func readEvents(
    _ cursor: inout EventCursor, fires out: inout [FireEvent],
    anchors anchorsOut: inout [TickAnchor]
  ) -> (firesLost: Int, anchorsLost: Int) {
    let f = fires.drain(from: &cursor.fires, into: &out)
    let a = anchors.drain(from: &cursor.anchors, into: &anchorsOut)
    return (f, a)
  }

  public var fireCapacity: Int { fires.capacity }
  public var anchorCapacity: Int { anchors.capacity }

  // MARK: marking mirror (main thread)

  /// `WaveProject.generation` of the project the audio thread is running right now; 0 until
  /// the first render after a load. Changes at the bar where a queued project takes over.
  public var activeGeneration: Int32 { activeGenerationAtomic.load(ordering: .relaxed) }

  /// The layout of the most recently loaded project: net ids, place ids and what each net is.
  public var markingLayout: MarkingLayout? { latest?.marking.layout }

  /// The layout of a recent project by generation (the active one, the latest, and a few
  /// older), e.g. the generation stamped on a `FireEvent` or a `TickAnchor`. It says which net
  /// an event's `net` index is (`nets[i]`: riff group, instrument, note range, positions), and
  /// by `trackSerial` whether two generations are the same song (a section launch) or not.
  /// Main thread.
  public func markingLayout(generation: Int32) -> MarkingLayout? {
    mirror(generation: generation)?.layout
  }

  /// Copy the marking of the project that is sounding into `snap`: every net's place tokens,
  /// the mute flags, the tick, and which project (`snap.generation`, `snap.layout`) they are
  /// from. Consistent (never a mix of two states), lock-free, and allocation-free once `snap`
  /// is sized (it is resized when the project changes). On a deck that is not playing, a project
  /// loaded since the last render is the one reported (its initial marking, or the one rebuilt
  /// for a section launch) because it takes over at the next block; on a playing deck the old
  /// project is reported until it hands over at the bar. False if nothing is loaded.
  ///
  /// Never touches the audio thread's graph: `WaveGraph.marking()` allocates and must not be
  /// called from the main thread while the deck plays.
  @discardableResult
  public func readMarking(into snap: inout MarkingSnapshot) -> Bool {
    let active = activeGeneration
    var m = active != 0 ? mirror(generation: active) : nil
    // A project the audio thread has not seen yet, on a deck that is not playing, is installed
    // at once by the next block: it is the one to show. (One already queued for a bar is not.)
    if let newest = latest, !isPlaying, newest.generation != active,
      newest.generation != pendingGenerationAtomic.load(ordering: .relaxed)
    {
      m = newest.marking
    }
    guard let m = m ?? latest?.marking else { return false }
    return m.read(into: &snap)
  }

  /// `readMarking(into:)` for a particular project (a recent generation). False if unknown.
  @discardableResult
  public func readMarking(generation: Int32, into snap: inout MarkingSnapshot) -> Bool {
    guard let m = mirror(generation: generation) else { return false }
    return m.read(into: &snap)
  }

  private func mirror(generation g: Int32) -> MarkingMirror? {
    mirrors.last { $0.layout.generation == g }
  }

  private func remember(_ m: MarkingMirror) {
    mirrors.append(m)
    // Drop the oldest, but never the one the audio thread is running or the newest.
    let active = activeGeneration
    var i = 0
    while mirrors.count > Self.mirrorsKept, i < mirrors.count - 1 {
      if mirrors[i].layout.generation == active { i += 1 } else { mirrors.remove(at: i) }
    }
  }

  /// Free projects the audio thread has let go of. Called by `send`/`load`; call it
  /// from a timer too.
  public func drainRetired() {
    while let p = retired.pop() { Unmanaged<WaveProject>.fromOpaque(p).release() }
  }

  public var tick: Int { tickAtomic.load(ordering: .relaxed) }
  /// Fraction of the current tick elapsed.
  public var tickPhase: Double { Double(bitPattern: phaseBits.load(ordering: .relaxed)) }
  public var tempo: Double { Double(bitPattern: tempoBits.load(ordering: .relaxed)) }
  public var isPlaying: Bool { playingAtomic.load(ordering: .relaxed) }
  /// A `stop-transport` control fired (the song ended). Cleared by the next `play`.
  public var hasEnded: Bool { stoppedAtomic.load(ordering: .relaxed) }
  public var hasProject: Bool { hasProjectAtomic.load(ordering: .relaxed) }
  public var isScrubbing: Bool { scrubbingAtomic.load(ordering: .relaxed) }
  /// A macro is in effect: a pending mute restore (drop, breakdown, cut...), a beat repeat, or
  /// a tempo effect (half time, tape stop, tempo anchor). It does not say which, or for how long.
  public var isMacroActive: Bool { macroAtomic.load(ordering: .relaxed) }

  /// The last whole macro record (main thread).
  private func macroRead() -> MacroMirror.Read {
    if let r = macroMirror.read() { macroLast = r }
    return macroLast
  }

  /// The macros in effect right now, as of the last render block: a mute macro while the nets
  /// it muted wait for their restore, the beat repeat while it runs, a tempo macro while its
  /// tempo effect lasts. (A mute macro that found everything it targets already muted muted
  /// nothing and is not in effect.) Main thread; allocates the array it returns.
  public var activeMacros: [NetMacro] {
    let m = macroRead().snapshot.mask
    return NetMacro.allCases.filter { m & $0.bit != 0 }
  }

  public func isActive(_ macro: NetMacro) -> Bool {
    macroRead().snapshot.mask & macro.bit != 0
  }

  /// The master-chain macros with an animation, a restore or a sub-fire pending, as of the last
  /// render block. Main thread; allocates the array it returns.
  public var activeMasterMacros: [MasterMacro] {
    let m = masterMaskAtomic.load(ordering: .relaxed)
    return MasterMacro.allCases.filter { m & $0.bit != 0 }
  }

  public func isActive(_ macro: MasterMacro) -> Bool {
    masterMaskAtomic.load(ordering: .relaxed) & macro.bit != 0
  }

  /// The master chain's HP and LP corners (Hz) at the last block, and whether the chain was
  /// bypassed then (both at rest: 20 Hz and 20 kHz).
  public var masterFilterCorners: (hp: Double, lp: Double, bypassed: Bool) {
    (
      Double(bitPattern: hpCornerBits.load(ordering: .relaxed)),
      Double(bitPattern: lpCornerBits.load(ordering: .relaxed)),
      chainIdleAtomic.load(ordering: .relaxed)
    )
  }

  /// Is net `index` of the project the audio thread runs held muted by a running macro (its
  /// restore is pending)? As `isNetMuted`, from a per-block mirror. Main thread.
  public func isNetHeldByMacro(index i: Int) -> Bool { macroRead().snapshot.isHeld(net: i) }

  /// Of `roles` (riff-group or plain-net role names), those with a net that `macro` holds muted
  /// (its own mutes: a net another macro muted first is not its) and that is still muted (a
  /// role the performer switched back on during the macro is no longer held), in the order
  /// given. Reads the
  /// latest project's role table like `isRoleAudible`; allocates its result. Empty while the
  /// record comes from another project than the latest one (a hand-over waiting for its bar):
  /// the nets it names are the running graph's, the tables are the new one's. Main thread.
  public func rolesHeld(by macro: NetMacro, among roles: [String]) -> [String] {
    heldRoles(roles) { $0.isHeld(net: $1, by: macro) }
  }

  /// `rolesHeld(by:among:)` for any macro.
  public func rolesHeldByMacros(_ roles: [String]) -> [String] {
    heldRoles(roles) { $0.isHeld(net: $1) }
  }

  private func heldRoles(_ roles: [String], _ held: (MacroSnapshot, Int) -> Bool) -> [String] {
    let read = macroRead()
    guard let project = latest, project.generation == read.generation else { return [] }
    let g = project.graph
    return roles.filter { role in
      guard let t = g.roleTargets[strHash(role)] else { return false }
      let nets = t >= 0 ? g.groupNets[t] : [-t - 2]
      return nets.contains { held(read.snapshot, $0) && isNetMuted(index: $0) }
    }
  }

  // MARK: audio-thread side

  /// Fill `frames` samples of `left` (and `right` if given). Real-time safe. Stamps fires
  /// on a time base of its own that starts at 0 and counts only these calls; a deck uses the
  /// variant below so everything shares the deck's `renderedFrames`.
  public func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    render(frames: frames, left: left, right: right, startFrame: ownFrames)
    ownFrames += frames
  }

  /// `render`, with `startFrame` the deck frame of the first sample of this block.
  public func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?,
    startFrame: Int
  ) {
    blockTransport = Double(transportFrames) / sampleRate
    blockFrames = frames
    opCount = 0
    fx.setNow(blockTransport)
    while let c = commands.pop() { apply(c) }
    syncFx()
    if runner.playing {
      fx.advance(until: blockTransport + Double(frames) / sampleRate) { handle($0) }
      transportFrames += Int64(frames)
    } else {
      fx.flush { handle($0) }
    }
    runner.process(left, right, frames: frames, startFrame: startFrame)
    var s = 0
    for i in 0..<opCount {
      let k = opIndex[i]
      if k > s {
        chain.process(left, right, from: s, to: k)
        s = k
      }
      chain.apply(MasterFxKey(rawValue: Int(opKey[i]))!, Int(opValue[i]), at: opTime[i])
    }
    chain.process(left, right, from: s, to: frames)
    chain.finish(frames: frames)
    masterMaskAtomic.store(fx.activeMask, ordering: .relaxed)
    let corners = chain.filterCorners()
    hpCornerBits.store(corners.hp.bitPattern, ordering: .relaxed)
    lpCornerBits.store(corners.lp.bitPattern, ordering: .relaxed)
    chainIdleAtomic.store(chain.isIdle(), ordering: .relaxed)
    runner.publishMarking(endFrame: startFrame + frames)
    activeGenerationAtomic.store(runner.generation, ordering: .relaxed)
    pendingGenerationAtomic.store(runner.pendingGeneration, ordering: .relaxed)
    tickAtomic.store(runner.graph?.tick ?? 0, ordering: .relaxed)
    phaseBits.store(runner.tickPhase.bitPattern, ordering: .relaxed)
    tempoBits.store(runner.tempo.bitPattern, ordering: .relaxed)
    playingAtomic.store(runner.playing, ordering: .relaxed)
    stoppedAtomic.store(runner.stopped, ordering: .relaxed)
    hasProjectAtomic.store(runner.graph != nil, ordering: .relaxed)
    scrubbingAtomic.store(runner.isScrubbing, ordering: .relaxed)
    macroAtomic.store(runner.macroActive, ordering: .relaxed)
    macroMirror.publish(runner.macroSnapshot(), generation: runner.generation)
    if let g = runner.graph { publishMutes(g.muted) }
  }

  /// Write the mute table into the four mirror words. No allocation.
  private func publishMutes(_ muted: [UInt8]) {
    var w0: UInt64 = 0
    var w1: UInt64 = 0
    var w2: UInt64 = 0
    var w3: UInt64 = 0
    for i in 0..<min(256, muted.count) where muted[i] != 0 {
      let bit: UInt64 = 1 << UInt64(i % 64)
      switch i / 64 {
      case 0: w0 |= bit
      case 1: w1 |= bit
      case 2: w2 |= bit
      default: w3 |= bit
      }
    }
    muteWord0.store(w0, ordering: .relaxed)
    muteWord1.store(w1, ordering: .relaxed)
    muteWord2.store(w2, ordering: .relaxed)
    muteWord3.store(w3, ordering: .relaxed)
  }

  private func apply(_ c: WaveCommand) {
    switch c {
    case .load(let p):
      runner.load(prepared: Unmanaged<WaveProject>.fromOpaque(p).takeRetainedValue())
    case .play: runner.play()
    case .pause: runner.pause()
    case .stop:
      runner.stop()
      fx.panic { handle($0) }  // beats: transport stop cancels and restores every animation
    case .tempo(let bpm): runner.setTempo(bpm)
    case .mute(let hash, let muted): runner.setMute(hash: hash, muted)
    case .roleMute(let hash, let muted): runner.setRoleMuted(hash: hash, muted)
    case .slot(let hash): runner.activateSlot(hash: hash)
    case .macro(let id, let ticks):
      if let m = NetMacro(rawValue: id) { runner.fireMacro(m, ticks: Int(ticks)) }
    case .stinger(let hash, let ticks): runner.fireStinger(hash: hash, ticks: Int(ticks))
    case .panic:
      runner.panic()
      syncFx()
      fx.panic { handle($0) }
    case .noteOn(let note, let velocity): runner.noteOn(Int(note), velocity: Int(velocity))
    case .noteOff(let note): runner.noteOff(Int(note))
    case .allNotesOff: runner.allNotesOff()
    case .align(let ticks): runner.align(ticks: ticks)
    case .freeze: runner.freeze()
    case .scrub(let ticks): runner.scrub(ticks: ticks)
    case .release: runner.release()
    case .chase(let seconds): runner.setChase(seconds: seconds)
    case .masterMacro(let id, let bars):
      guard let m = MasterMacro(rawValue: id) else { return }
      syncFx()
      let ticks = fx.fire(m, duration: bars < 0 ? nil : Int(bars)) { handle($0) }
      runner.markMacroRunning(ticks: ticks)
    case .masterFx(let key, let value):
      if let k = MasterFxKey(rawValue: Int(key)) { fx.setSlider(k, Double(value)) }
    case .voice(let p): runner.setVoice(p)
    }
  }

  /// `el._tempo` is the deck's tempo; the genre's BPM is the project's (as `tempo-anchor` reads
  /// it: the composer sets a song's tempo to its genre's).
  private func syncFx() {
    fx.tempo = runner.tempo
    fx.genreBpm = runner.graph?.project.tempo ?? runner.tempo
  }

  /// What the automation says, during a block: slider dispatches are queued for the chain at the
  /// sample they fall on; tempo writes go to the runner at once (block resolution, as the tempo
  /// macros).
  private func handle(_ e: FxAutomationEvent) {
    switch e {
    case .fx(let t, let key, let value):
      guard opCount < Self.opCapacity else { return }
      let offset = max(0, t - blockTransport)
      opIndex[opCount] = min(blockFrames, max(0, Int((offset * sampleRate).rounded(.up))))
      opTime[opCount] = chain.time(at: 0) + offset
      opKey[opCount] = UInt8(key.rawValue)
      opValue[opCount] = Int32(value)
      opCount += 1
    case .tempo(_, let bpm):
      runner.setTempo(bpm)
    }
  }
}
