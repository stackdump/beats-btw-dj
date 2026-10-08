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
  /// Whether the owning deck routes its output through this source.
  private let activeAtomic = Atomic<Bool>(false)

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
    }
  }
}
