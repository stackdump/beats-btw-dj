@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// Where a sampled instrument comes from. Both live on this Mac and are never copied into
/// the repo or published: Apple's licence covers playing them, not redistributing them.
public enum SamplerSource: Hashable, Sendable, CustomStringConvertible {
  /// A Logic / GarageBand EXS instrument (absolute path).
  case exs(String)
  /// A General MIDI program (0-based) from macOS's own gs_instruments.dls.
  case gm(Int)

  public var description: String {
    switch self {
    case .exs(let p): return "exs:" + ((p as NSString).lastPathComponent as String)
    case .gm(let n): return "gm:\(n)"
    }
  }

  static let gmBank = URL(
    fileURLWithPath:
      "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
  static let roots = [
    "Logic/": "/Library/Application Support/Logic/Sampler Instruments/",
    "GarageBand/":
      "/Library/Application Support/GarageBand/Instrument Library/Sampler/Sampler Instruments/",
  ]

  /// `Logic/08 Guitars/Vintage Strat.exs` → its absolute path (absolute paths pass through).
  public static func exs(named name: String) -> SamplerSource {
    for (prefix, root) in roots where name.hasPrefix(prefix) {
      return .exs(root + name.dropFirst(prefix.count))
    }
    return .exs(name)
  }

  public var isAvailable: Bool {
    switch self {
    case .exs(let p): return FileManager.default.fileExists(atPath: p)
    case .gm: return FileManager.default.fileExists(atPath: Self.gmBank.path)
    }
  }
}

/// One Apple sampler (AUSampler), rendered by hand from inside a deck's own render callback
/// rather than as a node in the engine graph: it renders exactly once per cycle, its MIDI
/// lands on the exact sample, and offline (manual) rendering works the same.
///
/// Built and loaded off the audio thread. `send` and `renderAdding` are the only calls the
/// audio thread makes; neither allocates.
public final class SamplerInstrument: @unchecked Sendable {
  public let source: SamplerSource
  /// Output gain; `normalize` sets it before the instrument is published.
  public private(set) var gain: Double
  static let maxFrames = 4096
  /// Held while any sampler is set up or torn down, across every bank: CoreAudio traps when
  /// one AUSampler initialises while another uninitialises (and patched EXS copies share a
  /// cache file). Recursive, so a failed init that tears down inside it cannot deadlock.
  static let lifecycle = NSRecursiveLock()

  // AVAudioUnitSampler only loads instruments while attached to an engine; this one is
  // never started, it just holds the unit.
  private let holder = AVAudioEngine()
  private let unit = AVAudioUnitSampler()
  private let au: AUAudioUnit
  private let renderBlock: AURenderBlock
  private let midiBlock: AUScheduleMIDIEventBlock
  private let abl: UnsafeMutableAudioBufferListPointer
  private let left: UnsafeMutablePointer<Float>
  private let right: UnsafeMutablePointer<Float>
  private var timestamp = AudioTimeStamp()

  public init(source: SamplerSource, sampleRate: Double, gain: Double = 1) throws {
    self.source = source
    self.gain = gain
    holder.attach(unit)
    switch source {
    case .exs(let path):
      try unit.loadInstrument(at: try ExsNames.loadableURL(for: URL(fileURLWithPath: path)))
    case .gm(let program):
      try unit.loadSoundBankInstrument(
        at: SamplerSource.gmBank, program: UInt8(clamping: program),
        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    }
    au = unit.auAudioUnit
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    try au.outputBusses[0].setFormat(fmt)
    au.maximumFramesToRender = AUAudioFrameCount(Self.maxFrames)
    try au.allocateRenderResources()
    renderBlock = au.renderBlock
    guard let m = au.scheduleMIDIEventBlock else {
      throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "no MIDI block"])
    }
    midiBlock = m
    left = .allocate(capacity: Self.maxFrames)
    right = .allocate(capacity: Self.maxFrames)
    abl = AudioBufferList.allocate(maximumBuffers: 2)
    timestamp.mFlags = .sampleTimeValid
  }

  /// The phrase levels are measured on: a strummed C chord, then single notes (the same
  /// one the synth voices are calibrated against).
  static let referencePhrase: [(note: Int, at: Double, seconds: Double)] = [
    (48, 0, 0.5), (52, 0.02, 0.5), (55, 0.04, 0.5), (60, 0.06, 0.5), (64, 0.5, 0.25),
    (67, 0.75, 0.25), (72, 1.0, 0.5),
  ]
  /// RMS of the lead synth voice on `referencePhrase`: what every sampled instrument is
  /// brought to, so a pick from any pool sits in the mix.
  public static let targetRMSdB = -27.5

  /// Off the audio thread, before publishing: play the reference phrase, measure it, set
  /// `gain` to land on `targetRMSdB`, then silence and reset the unit.
  func normalize(sampleRate sr: Double) {
    gain = 1
    let total = Int(2 * sr)
    let block = 512
    var buf = [Float](repeating: 0, count: block)
    var sum = 0.0
    var t = 0
    let ons = Self.referencePhrase.map { Int(($0.at * sr).rounded()) }
    let offs = Self.referencePhrase.map { Int((($0.at + $0.seconds) * sr).rounded()) }
    while t < total {
      let n = min(block, total - t)
      for (k, p) in Self.referencePhrase.enumerated() {
        if ons[k] >= t && ons[k] < t + n { send(0x90, UInt8(p.note), 100, at: ons[k] - t) }
        if offs[k] >= t && offs[k] < t + n { send(0x80, UInt8(p.note), 0, at: offs[k] - t) }
      }
      for i in 0..<n { buf[i] = 0 }
      buf.withUnsafeMutableBufferPointer { renderAdding(frames: n, $0.baseAddress!, nil) }
      for i in 0..<n { sum += Double(buf[i]) * Double(buf[i]) }
      t += n
    }
    let rms = 10 * log10(max(sum / Double(total), 1e-20))
    gain = min(20, max(0.02, pow(10, (Self.targetRMSdB - rms) / 20)))
    send(0xB0, 123, 0, at: 0)
    au.reset()
    timestamp.mSampleTime = 0
  }

  deinit {
    Self.lifecycle.withLock { au.deallocateRenderResources() }
    left.deallocate()
    right.deallocate()
    free(abl.unsafeMutablePointer)
  }

  /// Audio thread: a MIDI message `offset` samples into the next `renderAdding`.
  @inline(__always)
  func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, at offset: Int) {
    var bytes = (status, d1, d2)
    withUnsafeBytes(of: &bytes) {
      midiBlock(
        AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, 3,
        $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
    }
  }

  /// Audio thread: render `frames` and add them, × gain, into `out` (and `outR`; mono
  /// callers get the mid). Blocks over `maxFrames` lose MIDI timing past the first chunk.
  func renderAdding(
    frames: Int, _ out: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>?
  ) {
    var done = 0
    let g = Float(gain)
    while done < frames {
      let n = min(frames - done, Self.maxFrames)
      let bytes = UInt32(n * MemoryLayout<Float>.size)
      abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: left)
      abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: right)
      var flags = AudioUnitRenderActionFlags()
      let st = renderBlock(
        &flags, &timestamp, AUAudioFrameCount(n), 0, abl.unsafeMutablePointer, nil)
      timestamp.mSampleTime += Double(n)
      if st == noErr {
        if let outR {
          for i in 0..<n {
            out[done + i] += g * left[i]
            outR[done + i] += g * right[i]
          }
        } else {
          for i in 0..<n { out[done + i] += g * 0.5 * (left[i] + right[i]) }
        }
      }
      done += n
    }
  }
}

/// A deck's samplers. Loaded off the audio thread (`slot(for:)`), published with a release
/// store; the audio thread sees slots `0..<count` and nothing is ever replaced or removed
/// while the bank lives, so it never races a load.
public final class SamplerBank: @unchecked Sendable {
  public static let capacity = 24
  public let sampleRate: Double
  private let slots: UnsafeMutablePointer<Unmanaged<SamplerInstrument>?>
  private let published = Atomic<Int>(0)
  private let lock = NSLock()
  private var bySource: [SamplerSource: Int] = [:]
  private var unloadable: Set<SamplerSource> = []

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(repeating: nil, count: Self.capacity)
  }

  deinit {
    for i in 0..<published.load(ordering: .acquiring) { slots[i]?.release() }
    slots.deallocate()
  }

  /// Off the audio thread: the slot playing the first of `sources` that loads, loading (and
  /// level-normalising) it if needed. nil when none loads or the bank is full (the caller
  /// falls back to a synth voice).
  public func slot(for sources: [SamplerSource]) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    for s in sources {
      if let i = bySource[s] { return i }
      if unloadable.contains(s) || !s.isAvailable { continue }
      let n = published.load(ordering: .relaxed)
      guard n < Self.capacity else { return nil }
      let loaded = SamplerInstrument.lifecycle.withLock {
        try? SamplerInstrument(source: s, sampleRate: sampleRate)
      }
      guard let inst = loaded else {
        unloadable.insert(s)
        continue
      }
      inst.normalize(sampleRate: sampleRate)
      slots[n] = Unmanaged.passRetained(inst)
      published.store(n + 1, ordering: .releasing)
      bySource[s] = n
      return n
    }
    return nil
  }

  /// What a slot plays (main thread; for display and tests).
  public func source(of slot: Int) -> SamplerSource? {
    guard slot < count else { return nil }
    return slots[slot]!.takeUnretainedValue().source
  }

  /// Audio thread: loaded slots.
  @inline(__always) var count: Int { published.load(ordering: .acquiring) }

  @inline(__always)
  func send(_ slot: Int, _ status: UInt8, _ d1: UInt8, _ d2: UInt8, at offset: Int) {
    slots[slot]!._withUnsafeGuaranteedRef { $0.send(status, d1, d2, at: offset) }
  }

  @inline(__always)
  func renderAll(
    frames: Int, _ out: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>?
  ) {
    for i in 0..<count {
      slots[i]!._withUnsafeGuaranteedRef { $0.renderAdding(frames: frames, out, outR) }
    }
  }
}

/// Old EXS files keep each sample's name in a 64-byte field that was once limited to 31
/// characters (`Acoustic Guitar_conso#9FC40.caf`); AUSampler looks for that name and fails.
/// The full name is stored further on in the same chunk, so a patched copy (cached under
/// Application Support, never the original) loads.
enum ExsNames {
  static func loadableURL(for url: URL) throws -> URL {
    let data = try Data(contentsOf: url)
    guard let patched = patch(data) else { return url }
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJApp/exs", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent(url.lastPathComponent)
    if (try? Data(contentsOf: out)) != patched { try patched.write(to: out) }
    return out
  }

  /// The file with every truncated sample name replaced, or nil if none was truncated.
  static func patch(_ data: Data) -> Data? {
    var b = [UInt8](data)
    let tag: [UInt8] = Array("TBOS".utf8)
    var changed = false
    var i = 0
    while i + 68 <= b.count {
      guard b[i] == tag[0], b[i + 1] == tag[1], b[i + 2] == tag[2], b[i + 3] == tag[3] else {
        i += 1
        continue
      }
      let field = b[(i + 4)..<(i + 68)]
      let name = Array(field.prefix { $0 != 0 })
      if let hash = name.firstIndex(of: UInt8(ascii: "#")), hash > 0 {
        let stem = Array(name[..<hash])
        if let full = findFullName(b, stem: stem, from: i + 68, to: min(b.count, i + 1200)),
          full.count < 64
        {
          for k in 0..<64 { b[i + 4 + k] = k < full.count ? full[k] : 0 }
          changed = true
        }
      }
      i += 68
    }
    return changed ? Data(b) : nil
  }

  private static func findFullName(_ b: [UInt8], stem: [UInt8], from: Int, to: Int) -> [UInt8]? {
    guard !stem.isEmpty, to - from >= stem.count else { return nil }
    var j = from
    while j + stem.count <= to {
      if b[j] == stem[0] && Array(b[j..<(j + stem.count)]) == stem && (j == 0 || b[j - 1] == 0) {
        let full = Array(b[j...].prefix { $0 != 0 })
        if !full.contains(UInt8(ascii: "#")) { return full }
      }
      j += 1
    }
    return nil
  }
}

extension WaveDeckSource {
  /// Main thread: which of the latest project's nets play on a sampler, and from what
  /// (net id → "exs:Vintage Strat.exs" / "gm:25"). The rest play synth voices.
  public var sampledNets: [String: String] {
    guard let p = latest else { return [:] }
    var out: [String: String] = [:]
    for lane in p.lanes where lane.samplerSlot >= 0 {
      out[lane.netId] = samplers.source(of: lane.samplerSlot)?.description ?? "?"
    }
    return out
  }
}
