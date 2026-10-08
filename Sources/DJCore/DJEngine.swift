@preconcurrency import AVFoundation

public enum DJEngineError: Error, CustomStringConvertible {
  case unreadable(URL, String)
  public var description: String {
    switch self {
    case .unreadable(let url, let why): "\(url.lastPathComponent): \(why)"
    }
  }
}

/// One AVAudioEngine. Per deck: source node -> EQ (filter + 3 bands) ->
/// channel strip (mixer node, gain = trim x volume x crossfader) -> main mixer.
public final class DJEngine {
  public let engine = AVAudioEngine()
  public let sampleRate: Double
  public let format: AVAudioFormat
  public private(set) var decks: [String: Deck] = [:]
  /// Last writer of each continuous parameter ("A.volume", "crossfader", …):
  /// a control id, or "ui". Drives soft takeover between devices.
  public var owners: [String: String] = [:]

  /// 0 = all A, 1 = all B, constant-power curve. Only decks "A" and "B" are faded.
  public var crossfader = 0.5 { didSet { applyGains() } }
  /// The deck keys, the joystick and other deck-less performance controls act on:
  /// the one a controller touched last.
  public var focus = "A"
  /// 0...1
  public var master: Double {
    get { Double(engine.mainMixerNode.outputVolume) }
    set { engine.mainMixerNode.outputVolume = Float(min(1, max(0, newValue))) }
  }

  /// `offline: true` renders through `renderOffline` instead of the speakers
  /// (tests, and bouncing a mix to a file).
  public init(
    decks names: [String] = ["A", "B"], offline: Bool = false,
    sampleRate offlineRate: Double = 48_000
  ) throws {
    if offline {
      sampleRate = offlineRate
      format = AVAudioFormat(standardFormatWithSampleRate: offlineRate, channels: 2)!
      try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    } else {
      let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
      sampleRate = hw > 0 ? hw : offlineRate
      format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }
    for name in names {
      let deck = Deck(name: name, sampleRate: sampleRate, format: format)
      engine.attach(deck.node)
      engine.attach(deck.filterNode)
      engine.attach(deck.strip)
      engine.connect(deck.node, to: deck.filterNode, format: format)
      engine.connect(deck.filterNode, to: deck.strip, format: format)
      engine.connect(deck.strip, to: engine.mainMixerNode, format: format)
      deck.onGainChange = { [weak self] in self?.applyGains() }
      decks[name] = deck
    }
    applyGains()
  }

  /// Crossfader gain for a deck (1 for decks other than A/B).
  public func crossfadeGain(_ deck: String) -> Double {
    switch deck {
    case "A": cos(crossfader * .pi / 2)
    case "B": sin(crossfader * .pi / 2)
    default: 1
    }
  }

  private func applyGains() {
    for (name, d) in decks { d.strip.outputVolume = Float(d.trim * d.volume * crossfadeGain(name)) }
  }

  public func start() throws {
    engine.prepare()
    try engine.start()
  }

  public func stop() { engine.stop() }

  public subscript(name: String) -> Deck? { decks[name] }
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
  /// Band 0 low-pass, 1 high-pass (see `filter`); 2 low shelf, 3 mid peak,
  /// 4 high shelf (see `eqLow` / `eqMid` / `eqHigh`).
  public let filterNode = AVAudioUnitEQ(numberOfBands: 5)
  /// Channel strip: its output volume is volume x crossfader gain.
  public let strip = AVAudioMixerNode()
  public private(set) var loaded: SampleBuffer?
  public private(set) var mode: DeckMode = .sample
  /// The project a net deck is playing (nil in sample mode).
  public private(set) var netProject: Project?
  /// The net's tempo before the pitch fader: the project's own BPM.
  public private(set) var netBaseBPM = 120.0
  /// What `generate` / `advanceToNext` last loaded.
  public internal(set) var currentSpec: TrackSpec?
  /// When a song ends (its `stop-transport` fires), start the pre-composed next one.
  public var autoAdvance = false
  /// Called whenever no next track is composed or composing: keeps one coming.
  public var nextProvider: (() -> TrackSpec)?
  var generation = 0
  var netNudge = 0.0
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

  init(name: String, sampleRate: Double, format: AVAudioFormat) {
    self.name = name
    let tt = Turntable(sampleRate: sampleRate)
    let wv = WaveDeckSource(sampleRate: sampleRate)
    turntable = tt
    wave = wv
    node = AVAudioSourceNode(format: format) { _, _, frames, abl in
      let list = UnsafeMutableAudioBufferListPointer(abl)
      guard let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      let r = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
      if wv.isActive {
        wv.render(frames: Int(frames), left: l, right: r)
      } else {
        tt.render(frames: Int(frames), left: l, right: r)
      }
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

  public func load(_ buffer: SampleBuffer, title: String) {
    leaveNetMode()
    loaded = buffer
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
        let t = Int(netCueTick)
        Task { @MainActor in await self.jumpToTick(t) }
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
      cuePoint = turntable.position
    }
  }

  /// LOOP IN: mark the loop start at the playhead (and leave any active loop).
  public func loopIn() {
    guard loaded != nil else { return }
    if looping { exitLoop() }
    loopStart = turntable.position
    loopEnd = nil
  }

  /// LOOP OUT: close the loop at the playhead and start looping; while
  /// looping, exit the loop.
  public func loopOut() {
    if looping { return exitLoop() }
    guard let start = loopStart, turntable.position > start + 1 else { return }
    setLoop(start, turntable.position)
  }

  public func loopHalve() {
    guard looping, let s = loopStart, let e = loopEnd, e - s > 64 else { return }
    setLoop(s, s + (e - s) / 2)
  }

  public func loopDouble() {
    guard looping, let s = loopStart, let e = loopEnd else { return }
    setLoop(s, s + (e - s) * 2)
  }

  private func setLoop(_ start: Double, _ end: Double) {
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
        let t = Int(at)
        Task { @MainActor in await self.jumpToTick(t) }
      } else if wave.hasProject {
        hotCues[slot] = Double(wave.tick)
      }
      return
    }
    if let at = hotCues[slot] {
      turntable.send(.seek(sample: at))
    } else if loaded != nil {  // not turntable.length: that lags until the next render
      hotCues[slot] = turntable.position
    }
  }

  public func clearCue(_ slot: Int) { hotCues[slot] = nil }

  /// Decode (and resample if needed) a file, then load it.
  public func load(contentsOf url: URL) throws {
    load(
      try Self.decode(url, sampleRate: turntable.sampleRate),
      title: url.deletingPathExtension().lastPathComponent)
  }

  public func loadDemo() {
    load(DemoLoop.make(sampleRate: turntable.sampleRate), title: "demo loop")
  }

  public func setPlaying(_ on: Bool) {
    playing = on
    if mode == .net {
      if on { wave.play() } else { wave.pause() }
    } else {
      turntable.send(.transport(playing: on))
    }
  }

  // MARK: net mode

  /// Put an already-composed project on the deck. Compiles on the calling thread
  /// (use `generate` to keep that off the main thread). A playing deck swaps at the
  /// next bar; a stopped one switches at once.
  public func loadNet(_ project: Project, title: String? = nil) {
    loadNet(
      WaveRunner.prepare(project, sampleRate: wave.sampleRate), project: project, title: title)
  }

  /// Hand over a project compiled elsewhere (`WaveRunner.prepare`).
  public func loadNet(_ prepared: WaveProject, project: Project, title: String? = nil) {
    if mode != .net {
      turntable.send(.transport(playing: false))
      mode = .net
      wave.isActive = true
    }
    netProject = project
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

  public func freeze() { turntable.send(.freeze) }
  public func scrubBy(seconds: Double) {
    turntable.send(.scrub(samples: seconds * turntable.sampleRate))
  }
  public func release() { turntable.send(.release) }
  public func nudge(_ ratio: Double) {
    turntable.send(.nudge(ratio: ratio))
    netNudge = ratio
    applyNetTempo()
  }

  // MARK: decoding

  static func decode(_ url: URL, sampleRate: Double) throws -> SampleBuffer {
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
