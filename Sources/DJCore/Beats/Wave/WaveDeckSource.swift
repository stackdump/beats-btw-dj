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
public final class WaveDeckSource: @unchecked Sendable {
  public let sampleRate: Double

  private let commands = SPSCRing<WaveCommand>(capacity: 512)
  private let retired = SPSCRing<UnsafeMutableRawPointer>(capacity: 32)
  private let runner: WaveRunner

  // Audio → main mirrors.
  private let tickAtomic = Atomic<Int>(0)
  private let phaseBits = Atomic<UInt64>(0)
  private let tempoBits = Atomic<UInt64>(0)
  private let playingAtomic = Atomic<Bool>(false)
  private let stoppedAtomic = Atomic<Bool>(false)
  private let hasProjectAtomic = Atomic<Bool>(false)
  private let scrubbingAtomic = Atomic<Bool>(false)
  /// Whether the owning deck routes its output through this source.
  private let activeAtomic = Atomic<Bool>(false)
  /// Bit i of word i/64 = net i is muted (first 256 nets), refreshed every block.
  private let muteWord0 = Atomic<UInt64>(0)
  private let muteWord1 = Atomic<UInt64>(0)
  private let muteWord2 = Atomic<UInt64>(0)
  private let muteWord3 = Atomic<UInt64>(0)

  /// Main-thread only: the last project handed over, to resolve net ids.
  public private(set) var latest: WaveProject?

  public init(sampleRate: Double, opts: WaveOptions = WaveOptions()) {
    self.sampleRate = sampleRate
    runner = WaveRunner(sampleRate: sampleRate, opts: opts)
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
    let p = Unmanaged.passRetained(prepared).toOpaque()
    drainRetired()
    if commands.push(.load(p)) {
      latest = prepared
      // A stopped deck installs the project at once: show its starting mutes before the
      // first render publishes the real ones.
      if !isPlaying { publishMutes(prepared.graph.muted) }
    } else {
      Unmanaged<WaveProject>.fromOpaque(p).release()
    }
  }

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

  // MARK: audio-thread side

  /// Fill `frames` samples of `left` (and `right` if given). Real-time safe.
  public func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    while let c = commands.pop() { apply(c) }
    runner.process(left, right, frames: frames)
    tickAtomic.store(runner.graph?.tick ?? 0, ordering: .relaxed)
    phaseBits.store(runner.tickPhase.bitPattern, ordering: .relaxed)
    tempoBits.store(runner.tempo.bitPattern, ordering: .relaxed)
    playingAtomic.store(runner.playing, ordering: .relaxed)
    stoppedAtomic.store(runner.stopped, ordering: .relaxed)
    hasProjectAtomic.store(runner.graph != nil, ordering: .relaxed)
    scrubbingAtomic.store(runner.isScrubbing, ordering: .relaxed)
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
    case .stop: runner.stop()
    case .tempo(let bpm): runner.setTempo(bpm)
    case .mute(let hash, let muted): runner.setMute(hash: hash, muted)
    case .roleMute(let hash, let muted): runner.setRoleMuted(hash: hash, muted)
    case .slot(let hash): runner.activateSlot(hash: hash)
    case .macro(let id, let ticks):
      if let m = NetMacro(rawValue: id) { runner.fireMacro(m, ticks: Int(ticks)) }
    case .stinger(let hash, let ticks): runner.fireStinger(hash: hash, ticks: Int(ticks))
    case .panic: runner.panic()
    case .noteOn(let note, let velocity): runner.noteOn(Int(note), velocity: Int(velocity))
    case .noteOff(let note): runner.noteOff(Int(note))
    case .allNotesOff: runner.allNotesOff()
    case .align(let ticks): runner.align(ticks: ticks)
    case .freeze: runner.freeze()
    case .scrub(let ticks): runner.scrub(ticks: ticks)
    case .release: runner.release()
    case .chase(let seconds): runner.setChase(seconds: seconds)
    }
  }
}
