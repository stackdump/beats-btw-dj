@preconcurrency import AVFoundation
import Synchronization

public enum DJEngineError: Error, CustomStringConvertible {
  case unreadable(URL, String)
  public var description: String {
    switch self {
    case .unreadable(let url, let why): "\(url.lastPathComponent): \(why)"
    }
  }
}

/// Counts frames pulled through the engine: the session timebase. Audio thread writes,
/// any thread reads.
final class FrameClock: Sendable {
  let frames = Atomic<Int>(0)
}

/// One AVAudioEngine. Per deck: source node -> EQ (filter + 3 bands) ->
/// channel strip (mixer node, gain = trim x volume x crossfader) -> main mixer.
public final class DJEngine {
  public let engine = AVAudioEngine()
  public let sampleRate: Double
  public let format: AVAudioFormat
  public private(set) var decks: [String: Deck] = [:]
  /// The loop channel ("L"): plays the clips LOOP record makes, under the mixer. Not one of
  /// `decks` (no crossfader, no jog, not in a session's starting state), but `self["L"]` and
  /// `perform` reach it like a deck.
  public let loopChannel: Deck
  /// The row under the mixer: every take LOOP record has finished, oldest first.
  public internal(set) var clips: [LoopClip] = []
  var loopTakes: [String: LoopTake] = [:]
  /// The loop bank's voices, as the main thread sees them (`startLoop` / `stopLoop`).
  var loopVoices = [LoopVoice](repeating: LoopVoice(), count: LoopBank.voiceCount)
  var clipGains: [String: Double] = [:]
  /// How the loops sound (LoopSound.swift): muted and soloed clips, key lock (per clip, and the
  /// row's default), the start / stop fade, and the time-stretched copies key lock plays.
  var clipMutes: Set<String> = []
  var clipSolos: Set<String> = []
  var clipKeyLocks: [String: Bool] = [:]
  public internal(set) var loopKeyLock = false
  public internal(set) var loopFade = LoopFade.declick
  var stretchCache: [String: (bpm: Double, buffer: SampleBuffer)] = [:]
  var stretchToken = 0
  var loopCount = 0
  /// Clips taken off the row, newest first, each with the place it had (`removeClip`,
  /// `restoreClip`).
  public internal(set) var removedClips: [RemovedClip] = []
  /// How many bars a tap of LOOP records (let go within `DJEngine.loopTapFrames` of the
  /// press), when the press does not say: what a controller's LOOP button uses. The app sets it
  /// from its own setting through `perform(.tapBars)`, so a session records it (a controller's
  /// tap is recorded as MIDI, and a replay would otherwise take the default); nil turns
  /// fixed-length takes off (a tap records to the next downbeat, like a hold).
  public internal(set) var tapTakeBars: Int? = DJEngine.defaultTapTakeBars
  /// What loops start and stop on, in beats: 4 (the next bar) unless set (`setLoopQuantum`).
  public internal(set) var loopQuantum = DJEngine.defaultLoopQuantum
  /// Whose tempo the loops follow (`setLoopFollow`): the louder deck unless set.
  public internal(set) var loopFollow = LoopFollow.louder
  /// The deck the loops follow now under `.louder` (`updateDominantDeck`).
  public internal(set) var dominantDeck: String?
  /// Saved sets of loops (`LoopScene`), in the order they were made.
  public internal(set) var scenes: [LoopScene] = []
  /// Actions the user locked (right-click ▸ Disable): a controller binding with one of these
  /// keys does nothing (`SurfaceProfile.Binding.lockKey`; the UI greys its button the same way).
  public var lockedActions: Set<String> = []
  /// Last writer of each continuous parameter ("A.volume", "crossfader", …):
  /// a control id, or "ui". Drives soft takeover between devices.
  public var owners: [String: String] = [:]

  /// 0 = all A, 1 = all B, constant-power curve. Only decks "A" and "B" are faded.
  public var crossfader = 0.5 { didSet { applyGains() } }
  /// The deck keys, the joystick and other deck-less performance controls act on:
  /// the one a controller touched last.
  public var focus = "A"

  /// Records the performance when set (see `SessionRecorder`).
  public var recorder: SessionRecorder?
  /// Resolves a sample's content id to audio (replays, and `perform(.load)`).
  public var sampleResolver: ((String) -> SampleBuffer?)?
  /// Audio loaded through `perform`, by content id: lets a session be exported.
  public var sampleLibrary: [String: SampleBuffer] = [:]
  /// Replay mode: anything that normally finishes on a background thread (section
  /// launches, composing, queueing) completes inline, so the same inputs give the same
  /// audio every time.
  public var deterministic = false {
    didSet { for d in decks.values { d.deterministic = deterministic } }
  }
  let frameClock = FrameClock()
  /// Mono history of the master mix (after the master volume), for the scopes; off until a
  /// scope calls `masterTap.acquire()`. Fed once per render cycle, with no latency: after every
  /// cycle `masterTap.endFrame == frame`. See MasterTap.swift.
  public let masterTap = ScopeTap()
  /// The LEFT channel of the master mix (the master pair's left when cue routing is on), for the
  /// stage's corona: Tone's analyser hears the left channel only, `masterTap` the (L+R)/2
  /// down-mix. Off unless someone subscribed (`ScopeFeed.setLeftChannelWanted`); fed from the same
  /// render notification as `masterTap`, so the two always cover the same frames.
  public let masterLeftTap = ScopeTap(capacity: ScopeTap.leftCapacity)
  let masterProbe: MasterTapProbe
  // Headphone cue: pre-fader sends → cueSum ─┐
  //                master mix → headMaster ──┴→ headBus (→ the cue pair, once routed)
  let cueSum = AVAudioMixerNode()
  let headMaster = AVAudioMixerNode()
  let headBus = AVAudioMixerNode()
  var channelRouter: AVAudioUnit?
  var _headphoneMix = 0.0
  var _headphoneLevel = 0.7
  /// Samples rendered since the engine was built.
  public var frame: Int { frameClock.frames.load(ordering: .relaxed) }
  /// 0...1
  public var master: Double {
    get { Double(engine.mainMixerNode.outputVolume) }
    set { engine.mainMixerNode.outputVolume = Float(min(1, max(0, newValue))) }
  }

  /// `offline: true` renders through `renderOffline` instead of the speakers
  /// (tests, and bouncing a mix to a file).
  public init(
    decks names: [String] = ["A", "B"], offline: Bool = false,
    sampleRate offlineRate: Double = 48_000, outputChannels: Int = 2
  ) throws {
    masterProbe = MasterTapProbe(tap: masterTap, leftTap: masterLeftTap, clock: frameClock)
    if offline {
      sampleRate = offlineRate
      format = AVAudioFormat(standardFormatWithSampleRate: offlineRate, channels: 2)!
      // More than two output channels is for the headphone/cue path (see `enableCueRouting`).
      let renderFormat =
        outputChannels <= 2
        ? format
        : AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: offlineRate, interleaved: false,
          channelLayout: AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(outputChannels))!)
      try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
    } else {
      let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
      sampleRate = hw > 0 ? hw : offlineRate
      format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }
    loopChannel = Deck(name: "L", sampleRate: sampleRate, format: format, loopBank: true)
    engine.attach(cueSum)
    engine.attach(headMaster)
    engine.attach(headBus)
    engine.connect(cueSum, to: headBus, format: format)
    engine.connect(headMaster, to: headBus, format: format)
    applyHeadphoneMix()
    // A silent source whose only job is to count the frames the engine renders.
    let clock = frameClock
    let clockNode = AVAudioSourceNode(format: format) { _, _, frames, abl in
      for b in UnsafeMutableAudioBufferListPointer(abl) {
        if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
      }
      clock.frames.store(clock.frames.load(ordering: .relaxed) + Int(frames), ordering: .relaxed)
      return noErr
    }
    engine.attach(clockNode)
    engine.connect(clockNode, to: engine.mainMixerNode, format: format)
    for name in names {
      let deck = Deck(name: name, sampleRate: sampleRate, format: format)
      wire(deck)
      deck.onGrid = { [weak self] g in
        self?.recorder?.record(.grid(deck: name, bpm: g.bpm, offset: g.offset))
      }
      decks[name] = deck
    }
    wire(loopChannel)
    applyGains()
    masterProbe.attach(to: engine)
  }

  deinit { masterProbe.detach() }

  /// Source -> EQ -> reverb -> strip -> main mixer, plus the pre-fader cue send; and the
  /// capture tap on the EQ (LOOP record listens after the EQ, before the reverb and the fader).
  private func wire(_ deck: Deck) {
    engine.attach(deck.node)
    engine.attach(deck.filterNode)
    engine.attach(deck.reverb.node)
    engine.attach(deck.strip)
    engine.attach(deck.cueSend)
    engine.connect(deck.node, to: deck.filterNode, format: format)
    engine.connect(deck.filterNode, to: deck.reverb.node, format: format)
    // Post-EQ and reverb, pre-fader: the strip feeds the master, the cue send the headphones.
    engine.connect(
      deck.reverb.node,
      to: [
        AVAudioConnectionPoint(node: deck.strip, bus: 0),
        AVAudioConnectionPoint(node: deck.cueSend, bus: 0),
      ], fromBus: 0, format: format)
    engine.connect(deck.strip, to: engine.mainMixerNode, format: format)
    engine.connect(deck.cueSend, to: cueSum, format: format)
    deck.cueSend.outputVolume = 0  // after attach: attaching resets a mixer to unity
    deck.onGainChange = { [weak self] in self?.applyGains() }
    deck.capture.attach(to: deck.filterNode.audioUnit)
  }

  /// Every deck the engine renders: A, B, … and the loop channel.
  public var allDecks: [Deck] { decks.values.sorted { $0.name < $1.name } + [loopChannel] }

  /// Crossfader gain for a deck (1 for decks other than A/B).
  public func crossfadeGain(_ deck: String) -> Double {
    switch deck {
    case "A": cos(crossfader * .pi / 2)
    case "B": sin(crossfader * .pi / 2)
    default: 1
    }
  }

  private func applyGains() {
    for d in allDecks {
      d.strip.outputVolume = Float(d.mute ? 0 : d.trim * d.volume * crossfadeGain(d.name))
    }
  }

  public func start() throws {
    engine.prepare()
    masterProbe.attach(to: engine)  // a no-op unless the engine replaced its output unit
    for d in allDecks { d.capture.attach(to: d.filterNode.audioUnit) }
    try engine.start()
  }

  public func stop() {
    engine.stop()
  }

  public subscript(name: String) -> Deck? {
    decks[name] ?? (name == loopChannel.name ? loopChannel : nil)
  }
}

/// What a deck is playing.
public enum DeckMode: Sendable {
  /// Decoded audio on the turntable (WAV, MP3, …).
  case sample
  /// A Petri net rendered live by the wave engine (`WaveDeckSource`).
  case net
}

/// A turntable plus a wave-engine source behind one AVAudioSourceNode. Conforms to
/// `JogClock` so a `JogAdapter` can drive it directly.
public final class Deck: JogClock {
  public let name: String
  public let turntable: Turntable
  /// The live-net source. Only one of `turntable` / `wave` is rendered at a time.
  public let wave: WaveDeckSource
  public let node: AVAudioSourceNode
  let renderer: DeckRenderer
  /// Mono history of this deck's output (the source node's mixdown, before the EQ and the
  /// fader), for the scopes. Off until a scope calls `tap.acquire()`.
  public var tap: ScopeTap { renderer.tap }
  /// Stereo history after the EQ, always on: what LOOP record takes its bars from.
  let capture: CaptureTap
  /// The clip this deck is playing (`DJEngine.playClip`), nil once anything else loads.
  public internal(set) var clipID: String?
  /// The audio file the sample on the deck was loaded from (set by the app after a file or
  /// stock-loop load; nil for nets, clips and the demo loop): what a favorite of it reloads.
  public var sourceFile: URL?
  /// Roles the user disabled: left out of every net this deck compiles, kept muted in the one
  /// playing (`setRoleDisabled`).
  public internal(set) var disabledRoles: Set<String> = []
  /// STEMS groups this deck has muted, each with the roles that were playing when it was (what
  /// pressing it again brings back). Cleared when a track loads.
  var stemsMuted: [String: [String]] = [:]
  /// The same point of the chain as `tap`, but the LEFT channel alone instead of the mono
  /// mixdown (the stage's corona). Off until `leftTap.acquire()`; the same frame time base.
  public var leftTap: ScopeTap { renderer.leftTap }
  /// Frames this deck's source node has rendered, in both source modes (sample and net): the
  /// common time base of `tap`, the deck's fire events and its tick anchors. Monotonic;
  /// readable from any thread. Everything stamped below the value you read is already
  /// readable from its ring.
  public var renderedFrames: Int { renderer.renderedFrames }

  /// What the source node's block runs on the audio thread: render the active source,
  /// count the frames, feed the tap if a scope subscribed. Internal so tests can drive a
  /// deck block by block without an engine running.
  func renderBlock(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    renderer.renderBlock(frames: frames, left: left, right: right)
  }
  /// After the EQ, before the fader: the channel's reverb (`DeckReverb`).
  public let reverb = DeckReverb()
  /// Band 0 low-pass, 1 high-pass (see `filter`); 2 low shelf, 3 mid peak,
  /// 4 high shelf (see `eqLow` / `eqMid` / `eqHigh`).
  public let filterNode = AVAudioUnitEQ(numberOfBands: 5)
  /// Channel strip: its output volume is volume x crossfader gain.
  public let strip = AVAudioMixerNode()
  /// Pre-fader send to the headphone bus: volume 1 while `pfl` is on.
  let cueSend = AVAudioMixerNode()
  /// Headphone cue (pre-fade listen): this deck's pre-fader signal goes to the cue bus.
  public var pfl = false { didSet { cueSend.outputVolume = pfl ? 1 : 0 } }
  public private(set) var loaded: SampleBuffer?
  public private(set) var mode: DeckMode = .sample
  /// The project a net deck is playing (nil in sample mode).
  public private(set) var netProject: Project?
  /// The net's tempo before the pitch fader: the project's own BPM.
  public private(set) var netBaseBPM = 120.0
  /// What `generate` / `advanceToNext` last loaded.
  public internal(set) var currentSpec: TrackSpec?
  /// The raw-`nets` share payload the deck is playing, when it is playing one (then
  /// `currentSpec` is nil).
  public internal(set) var currentRawNets: JSONValue?
  /// The seed this deck's sampled instruments are picked with (`WaveOptions.voicingSeed`):
  /// the spec's, or a raw-`nets` share's; recompiles (section jumps) must keep it.
  var voicingSeed: Double {
    currentSpec?.seed ?? currentRawNets.map { DeckSourceDescriptor.voicingSeed(rawNets: $0) } ?? 0
  }
  /// How many times the deck has handed over to its pre-composed next track (`advanceToNext`:
  /// the song ended with `autoAdvance` on, or the Next button). A display that reacts to a
  /// hand-over (the ring's Auto-DJ swing) watches this move.
  public internal(set) var advances = 0
  /// When a song ends (its `stop-transport` fires), start the next one: the one queued, or
  /// (`service`) the next version of this song, composed in the background while this plays.
  public var autoAdvance = false
  /// The song ended with auto-next on before its next version was composed: play that the
  /// moment it is ready.
  var awaitingNext = false
  /// The next version was just started: wait for the audio thread to start it before looking
  /// for the end of a song again.
  var startingNext = false
  /// Called whenever no next track is composed or composing: keeps one coming.
  public var nextProvider: (() -> TrackSpec)?
  var generation = 0
  /// The loop `stepSeed` last asked for, while it composes (nil once any track loads), so a
  /// fast turn of the wheel counts every click from the seed it is heading to.
  var seedTarget: TrackSpec?
  /// See `DJEngine.deterministic`.
  var deterministic = false
  var isDemo = false
  /// Told when a sample deck's beat grid changes (analysis finished, tapped, moved).
  var onGrid: ((BeatGrid) -> Void)?
  var netNudge = 0.0
  var ringShapes: [String: RingShape] = [:]
  /// Tempo and first-beat position of a sample deck (analysed, tapped or known).
  public internal(set) var beatGrid: BeatGrid?
  /// Whole-track peaks of the loaded audio, ready shortly after a load (nil until then).
  public internal(set) var waveform: WaveformOverview?
  var waveformToken = 0
  /// Snap cues and loops to this grid on a sample deck.
  public var quantize: Quantize = .off
  /// A deck whose tempo this one tracks (`follow(_:)`).
  weak var leader: Deck?
  var analysisToken = 0
  var netCueTick = 0.0
  var heldKeys: [Int: Int] = [:]
  let next = NextTrackSlot()
  public private(set) var title = "—"
  public internal(set) var playing = false
  /// Cue points in samples, by slot.
  public private(set) var hotCues: [Int: Double] = [:]
  /// The CUE button's point, in samples.
  public private(set) var cuePoint = 0.0
  /// Loop region in samples (unwrapped playhead), and whether it is active.
  public private(set) var loopStart: Double?
  public private(set) var loopEnd: Double?
  public private(set) var looping = false

  var onGainChange: (() -> Void)?

  /// 0...1 channel fader.
  public var volume = 0.8 { didSet { onGainChange?() } }

  /// Silences the channel without stopping it (the loop channel's mute).
  public var mute = false { didSet { onGainChange?() } }

  /// Trim knob, 0...1: 0.5 = unity, 1 = +6 dB, 0 = -6 dB.
  public var gain = 0.5 { didSet { onGainChange?() } }
  var trim: Double { pow(2, (gain - 0.5) * 2) }

  /// EQ knobs, 0...1: 0.5 = flat, 1 = +6 dB, 0 = -24 dB (near kill).
  public var eqLow = 0.5 { didSet { setEQ(2, eqLow) } }
  public var eqMid = 0.5 { didSet { setEQ(3, eqMid) } }
  public var eqHigh = 0.5 { didSet { setEQ(4, eqHigh) } }

  static func eqDecibels(_ v: Double) -> Float {
    Float(v < 0.5 ? -24 * (0.5 - v) / 0.5 : 6 * (v - 0.5) / 0.5)
  }

  private func setEQ(_ band: Int, _ v: Double) {
    let b = filterNode.bands[band]
    b.gain = Self.eqDecibels(v)
    b.bypass = abs(v - 0.5) < 0.01
  }

  /// One-knob DJ filter, 0...1. Centre (0.45...0.55) is flat; below sweeps a
  /// low-pass from 20 kHz down to 200 Hz, above sweeps a high-pass from 20 Hz up to 5 kHz.
  public var filter = 0.5 {
    didSet {
      let lp = filterNode.bands[0]
      let hp = filterNode.bands[1]
      if filter < 0.45 {
        let t = (0.45 - filter) / 0.45
        lp.frequency = Float(20_000 * pow(200.0 / 20_000, t))
        lp.bypass = false
        hp.bypass = true
      } else if filter > 0.55 {
        let t = (filter - 0.55) / 0.45
        hp.frequency = Float(20 * pow(5_000.0 / 20, t))
        hp.bypass = false
        lp.bypass = true
      } else {
        lp.bypass = true
        hp.bypass = true
      }
    }
  }

  /// Tempo fader, -1...1 maps to ±`pitchRange`.
  public var pitch = 0.0 {
    didSet {
      turntable.send(.pitch(ratio: pitch * Self.pitchRange))
      applyNetTempo()
    }
  }
  public static let pitchRange = 0.08

  /// How this deck compiles nets: the instrument table, with its own sampler bank.
  public var waveOptions: WaveOptions {
    .extended(samplers: wave.samplers, seed: voicingSeed, roleFilter: roleFilter)
  }

  /// Roles this deck leaves out of every net it compiles (offline stems; nil = none).
  public var roleFilter: RoleFilter?

  /// The loop channel's clips, each on its own voice (nil on every other deck).
  let bank: LoopBank?

  init(name: String, sampleRate: Double, format: AVAudioFormat, loopBank: Bool = false) {
    self.name = name
    let tt = Turntable(sampleRate: sampleRate)
    let wv = WaveDeckSource(sampleRate: sampleRate)
    cueSend.outputVolume = 0
    turntable = tt
    wave = wv
    let b = loopBank ? LoopBank(sampleRate: sampleRate) : nil
    bank = b
    let core = DeckRenderer(turntable: tt, wave: wv, bank: b)
    renderer = core
    capture = CaptureTap { core.renderedFrames }
    node = AVAudioSourceNode(format: format) { _, _, frames, abl in
      core.render(abl, frames: Int(frames))
      return noErr
    }
    let types: [AVAudioUnitEQFilterType] = [
      .lowPass, .highPass, .lowShelf, .parametric, .highShelf,
    ]
    let freqs: [Float] = [20_000, 20, 250, 1_000, 4_000]
    for (i, band) in filterNode.bands.enumerated() {
      band.filterType = types[i]
      band.frequency = freqs[i]
      band.bandwidth = 1.5
      band.gain = 0
      band.bypass = true
    }
  }

  deinit { capture.detach() }

  public func load(_ buffer: SampleBuffer, title: String) {
    leaveNetMode()
    clipID = nil
    sourceFile = nil
    waveform = nil
    loaded = buffer
    beatGrid = nil
    isDemo = false
    computeWaveform(buffer)
    self.title = title
    hotCues = [:]
    cuePoint = 0
    loopStart = nil
    loopEnd = nil
    looping = false
    turntable.load(buffer)
  }

  /// CUE button: while playing, back to the cue point and pause; while
  /// paused, set the cue point at the playhead.
  public func cue() {
    if mode == .net {
      // Net cue: playing → back to the cue tick and pause; paused → set it here.
      if playing {
        setPlaying(false)
        relocate(toTick: Int(netCueTick))
      } else {
        netCueTick = Double(wave.tick)
      }
      return
    }
    guard loaded != nil else { return }
    if playing {
      setPlaying(false)
      turntable.send(.seek(sample: cuePoint))
    } else {
      cuePoint = snapped(turntable.position)
    }
  }

  /// LOOP IN: mark the loop start at the playhead (and leave any active loop).
  public func loopIn() {
    guard loaded != nil else { return }
    if looping { exitLoop() }
    loopStart = snapped(turntable.position)
    loopEnd = nil
  }

  /// LOOP OUT: close the loop at the playhead and start looping; while
  /// looping, exit the loop.
  public func loopOut() {
    if looping { return exitLoop() }
    guard let start = loopStart else { return }
    let end = snapped(turntable.position)
    guard end > start + 1 else { return }
    setLoop(start, end)
  }

  public func loopHalve() {
    guard looping, let s = loopStart, let e = loopEnd, e - s > 64 else { return }
    setLoop(s, s + (e - s) / 2)
  }

  public func loopDouble() {
    guard looping, let s = loopStart, let e = loopEnd else { return }
    setLoop(s, s + (e - s) * 2)
  }

  func setLoop(_ start: Double, _ end: Double) {
    loopStart = start
    loopEnd = end
    looping = true
    turntable.send(.loop(start: start, end: end))
  }

  private func exitLoop() {
    looping = false
    turntable.send(.loopOff)
  }

  /// Jump to the cue in `slot`, or set it at the playhead if empty.
  public func hotCue(_ slot: Int) {
    if mode == .net {
      // A net hot cue is a tick on the net clock; jumping replays the control nets to it.
      if let at = hotCues[slot] {
        relocate(toTick: Int(at))
      } else if wave.hasProject {
        hotCues[slot] = Double(wave.tick)
      }
      return
    }
    if let at = hotCues[slot] {
      // Quantized, a jump keeps the beat phase: land as far past the cue as we were past
      // the grid line when the button went down.
      let held = quantize != .off && playing ? turntable.position - snapped(turntable.position) : 0
      turntable.send(.seek(sample: at + held))
    } else if loaded != nil {  // not turntable.length: that lags until the next render
      hotCues[slot] = snapped(turntable.position)
    }
  }

  public func clearCue(_ slot: Int) { hotCues[slot] = nil }

  /// Decode (and resample if needed) a file, then load it. The tempo is measured in the
  /// background and lands in `beatGrid` when ready.
  public func load(contentsOf url: URL) throws {
    let buffer = try Self.decode(url, sampleRate: turntable.sampleRate)
    load(buffer, title: url.deletingPathExtension().lastPathComponent)
    analyze(buffer)
  }

  public func loadDemo() {
    load(DemoLoop.make(sampleRate: turntable.sampleRate), title: "demo loop")
    beatGrid = BeatGrid(bpm: DemoLoop.bpm, offset: 0, confidence: 1)  // known, not measured
    isDemo = true
  }

  public func setPlaying(_ on: Bool) {
    playing = on
    if mode == .net {
      if on { wave.play() } else { wave.pause() }
    } else {
      turntable.send(.transport(playing: on))
    }
  }

  /// Start a sample at full speed this block (no motor spin-up), so it lands where it was put.
  func launch() {
    guard mode == .sample else { return setPlaying(true) }
    playing = true
    turntable.send(.start)
  }

  // MARK: net mode

  /// Put an already-composed project on the deck. Compiles on the calling thread
  /// (use `generate` to keep that off the main thread). A playing deck swaps at the
  /// next bar; a stopped one switches at once.
  public func loadNet(_ project: Project, title: String? = nil) {
    loadNet(
      WaveRunner.prepare(project, sampleRate: wave.sampleRate, opts: waveOptions), project: project,
      title: title)
  }

  /// Hand over a project compiled elsewhere (`WaveRunner.prepare`). The channels' voice
  /// settings (the sound panel) are the song's: another song starts without them unless
  /// `keepVoices` (`keepsVoiceSettings`).
  public func loadNet(
    _ prepared: WaveProject, project: Project, title: String? = nil, keepVoices: Bool = false
  ) {
    if !keepVoices { wave.clearVoiceSettings() }
    // A hand-built net has no spec; `loadNet(_:)` for a track sets its source after.
    currentSpec = nil
    currentRawNets = nil
    seedTarget = nil
    clipID = nil
    sourceFile = nil
    stemsMuted = [:]
    if mode != .net {
      turntable.send(.transport(playing: false))
      mode = .net
      wave.isActive = true
    }
    netProject = project
    ringShapes = [:]
    netBaseBPM = project.tempo > 0 ? project.tempo : 120
    self.title = title ?? project.name
    hotCues = [:]
    loopStart = nil
    loopEnd = nil
    looping = false
    wave.load(prepared)
    applyNetTempo()
    if playing { wave.play() }
  }

  /// Net clock = project BPM × tempo fader × momentary nudge (jog ring / joystick).
  func applyNetTempo() {
    guard mode == .net else { return }
    wave.setTempo(netBaseBPM * (1 + pitch * Self.pitchRange) * (1 + netNudge))
  }

  private func leaveNetMode() {
    guard mode == .net else { return }
    wave.pause()
    wave.isActive = false
    mode = .sample
    netProject = nil
    playing = false
  }

  /// Playhead in seconds within the loaded audio (wrapped).
  public var positionSeconds: Double {
    let len = Double(turntable.length)
    guard len > 0 else { return 0 }
    var p = turntable.position.truncatingRemainder(dividingBy: len)
    if p < 0 { p += len }
    return p / turntable.sampleRate
  }

  /// Unwrapped playhead in seconds — what a platter angle follows.
  public var platterSeconds: Double { turntable.position / turntable.sampleRate }

  // MARK: JogClock

  public func freeze() {
    if mode == .net { wave.freeze() } else { turntable.send(.freeze) }
  }
  public func scrubBy(seconds: Double) {
    if mode == .net {
      // platter seconds → ticks at the deck's tempo (a tick is a sixteenth: 4 per beat)
      wave.scrub(ticks: seconds * (effectiveBPM ?? 120) * 4 / 60)
    } else {
      turntable.send(.scrub(samples: seconds * turntable.sampleRate))
    }
  }
  public func release() {
    if mode == .net { wave.release() } else { turntable.send(.release) }
  }
  public func nudge(_ ratio: Double) {
    turntable.send(.nudge(ratio: ratio))
    netNudge = ratio
    applyNetTempo()
  }

  // MARK: decoding

  public static func decode(_ url: URL, sampleRate: Double) throws -> SampleBuffer {
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) } catch {
      throw DJEngineError.unreadable(url, error.localizedDescription)
    }
    let inFormat = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)
    else {
      throw DJEngineError.unreadable(url, "no audio frames")
    }
    try file.read(into: input)

    var pcm = input
    let channels = min(2, inFormat.channelCount)
    if inFormat.sampleRate != sampleRate || inFormat.channelCount != channels
      || inFormat.commonFormat != .pcmFormatFloat32 || inFormat.isInterleaved
    {
      let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
      guard let converter = AVAudioConverter(from: inFormat, to: outFormat),
        let output = AVAudioPCMBuffer(
          pcmFormat: outFormat,
          frameCapacity: AVAudioFrameCount(Double(frames) * sampleRate / inFormat.sampleRate) + 4096
        )
      else { throw DJEngineError.unreadable(url, "cannot convert \(inFormat) to \(outFormat)") }
      nonisolated(unsafe) var fed = false  // the input block runs synchronously inside convert()
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if fed {
          inputStatus.pointee = .endOfStream
          return nil
        }
        fed = true
        inputStatus.pointee = .haveData
        return input
      }
      if status == .error {
        throw DJEngineError.unreadable(url, error?.localizedDescription ?? "conversion failed")
      }
      pcm = output
    }

    guard let data = pcm.floatChannelData, pcm.frameLength > 0 else {
      throw DJEngineError.unreadable(url, "decoded to nothing")
    }
    let n = Int(pcm.frameLength)
    let left = Array(UnsafeBufferPointer(start: data[0], count: n))
    let right =
      pcm.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : nil
    return SampleBuffer(left: left, right: right, sampleRate: sampleRate)
  }
}

// A deck is shared between the main thread, the audio thread (through lock-free queues)
// and background compose tasks; its mutable state is main-thread by convention.
extension Deck: @unchecked Sendable {}
