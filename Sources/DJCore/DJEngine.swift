@preconcurrency import AVFoundation

public enum DJEngineError: Error, CustomStringConvertible {
  case unreadable(URL, String)
  public var description: String {
    switch self {
    case .unreadable(let url, let why): "\(url.lastPathComponent): \(why)"
    }
  }
}

/// One AVAudioEngine. Per deck: source node -> filter (EQ) -> channel strip
/// (mixer node, gain = deck volume x crossfader) -> main mixer.
public final class DJEngine {
  public let engine = AVAudioEngine()
  public let sampleRate: Double
  public let format: AVAudioFormat
  public private(set) var decks: [String: Deck] = [:]

  /// 0 = all A, 1 = all B, constant-power curve. Only decks "A" and "B" are faded.
  public var crossfader = 0.5 { didSet { applyGains() } }
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
    for (name, d) in decks { d.strip.outputVolume = Float(d.volume * crossfadeGain(name)) }
  }

  public func start() throws {
    engine.prepare()
    try engine.start()
  }

  public func stop() { engine.stop() }

  public subscript(name: String) -> Deck? { decks[name] }
}

/// A turntable plus its AVAudioSourceNode. Conforms to `JogClock` so a
/// `JogAdapter` can drive it directly.
public final class Deck: JogClock {
  public let name: String
  public let turntable: Turntable
  public let node: AVAudioSourceNode
  /// Band 0 low-pass, band 1 high-pass; see `filter`.
  public let filterNode = AVAudioUnitEQ(numberOfBands: 2)
  /// Channel strip: its output volume is volume x crossfader gain.
  public let strip = AVAudioMixerNode()
  public private(set) var loaded: SampleBuffer?
  public private(set) var title = "—"
  public private(set) var playing = false
  /// Cue points in samples, by slot.
  public private(set) var hotCues: [Int: Double] = [:]

  var onGainChange: (() -> Void)?

  /// 0...1 channel fader.
  public var volume = 0.8 { didSet { onGainChange?() } }

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
  public var pitch = 0.0 { didSet { turntable.send(.pitch(ratio: pitch * Self.pitchRange)) } }
  public static let pitchRange = 0.08

  init(name: String, sampleRate: Double, format: AVAudioFormat) {
    self.name = name
    let tt = Turntable(sampleRate: sampleRate)
    turntable = tt
    node = AVAudioSourceNode(format: format) { _, _, frames, abl in
      let list = UnsafeMutableAudioBufferListPointer(abl)
      guard let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      let r = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
      tt.render(frames: Int(frames), left: l, right: r)
      return noErr
    }
    for (band, type) in zip(filterNode.bands, [AVAudioUnitEQFilterType.lowPass, .highPass]) {
      band.filterType = type
      band.bypass = true
    }
  }

  public func load(_ buffer: SampleBuffer, title: String) {
    loaded = buffer
    self.title = title
    hotCues = [:]
    turntable.load(buffer)
  }

  /// Jump to the cue in `slot`, or set it at the playhead if empty.
  public func hotCue(_ slot: Int) {
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
    turntable.send(.transport(playing: on))
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
  public func nudge(_ ratio: Double) { turntable.send(.nudge(ratio: ratio)) }

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
