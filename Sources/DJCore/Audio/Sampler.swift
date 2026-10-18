@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// Where a sampled instrument comes from. All of it lives on this Mac and is never copied
/// into the repo or published: Apple's licence covers playing its content, not redistributing
/// it, and SoundFonts are downloaded (`make soundfonts`), not checked in.
public enum SamplerSource: Hashable, Sendable, CustomStringConvertible {
  /// A Logic / GarageBand EXS instrument (absolute path).
  case exs(String)
  /// A General MIDI program (0-based) from macOS's own gs_instruments.dls.
  case gm(Int)
  /// A General MIDI program (0-based) from a SoundFont bank (absolute path to the .sf2),
  /// melodic bank (MSB 0x79).
  case sf2(String, program: Int)
  /// A drum kit from a sound bank (.sf2 or .dls, absolute path) for a net's drum lanes
  /// (`DrumKits`): `bank` 128 is the percussion bank (MSB 0x78, GM kits), any other a melodic
  /// bank whose preset maps fixed-pitch drum zones onto the GM keys (a "kit" preset). Played
  /// only when a track picks it (`Track.kit`); beats' synth kits are the default.
  case kit(String, bank: Int, program: Int)

  public var description: String {
    switch self {
    case .exs(let p): return "exs:" + ((p as NSString).lastPathComponent as String)
    case .gm(let n): return "gm:\(n)"
    case .sf2(let p, let n): return "sf2:" + ((p as NSString).lastPathComponent as String) + "#\(n)"
    case .kit(let p, let b, let n):
      return "kit:" + ((p as NSString).lastPathComponent as String) + "#\(b):\(n)"
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

  /// A drum kit (`kit`), level-checked as one (`SamplerInstrument.normalizeKit`).
  public var isKit: Bool {
    if case .kit = self { return true }
    return false
  }

  public var isAvailable: Bool {
    switch self {
    case .exs(let p), .sf2(let p, _), .kit(let p, _, _):
      return FileManager.default.fileExists(atPath: p)
    case .gm: return FileManager.default.fileExists(atPath: Self.gmBank.path)
    }
  }

  /// Where SoundFonts are looked for: `$DJ_SOUNDFONTS`, else
  /// `~/Library/Application Support/dj-vevr-se/soundfonts` (`make soundfonts` fills it).
  public static var soundFontDir: String {
    if let d = ProcessInfo.processInfo.environment["DJ_SOUNDFONTS"], !d.isEmpty { return d }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/soundfonts").path
  }

  /// The floor under every category: General MIDI from a free, complete bank.
  public static let floorSoundFont = "MuseScore_General.sf2"

  /// Banks in the SoundFont folder that are not General MIDI and so never join a category's
  /// `gm` programs: they are played only by name (`minecraft-local.sf2`: the Minecraft
  /// palette's own programs and kit, built on this Mac from the user's game assets).
  public static let localOnlyBanks: Set<String> = ["minecraft-local.sf2"]

  /// The .sf2 banks in `dir`, in the order voicing tries them: any others by name, then
  /// `floorSoundFont` last (the floor).
  public static func soundFonts(in dir: String = soundFontDir) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.filter { $0.lowercased().hasSuffix(".sf2") && !localOnlyBanks.contains($0) }
      .sorted { ($0 == floorSoundFont ? 1 : 0, $0) < ($1 == floorSoundFont ? 1 : 0, $1) }
      .map { (dir as NSString).appendingPathComponent($0) }
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
  /// What `normalize` last measured: RMS (dB) on the reference phrase, the A3 tuning error
  /// (cents) and whether the held A3 still sounded when it was measured. Kept so a bank can
  /// say why it turned a sound away.
  private(set) var lastCheck: (rmsDB: Double, cents: Double, held: Bool)?

  public init(source: SamplerSource, sampleRate: Double, gain: Double = 1) throws {
    self.source = source
    self.gain = gain
    holder.attach(unit)
    // Load samples whole instead of streaming them from disk: a streaming thread that falls
    // behind (a busy machine) changes what renders — renders stop being deterministic and
    // live playback can drop out. Costs memory (an EXS guitar is ~50 MB).
    var stream: UInt32 = 0
    AudioUnitSetProperty(
      unit.audioUnit, kMusicDeviceProperty_StreamFromDisk, kAudioUnitScope_Global, 0, &stream,
      UInt32(MemoryLayout<UInt32>.size))
    switch source {
    case .exs(let path):
      try unit.loadInstrument(at: try ExsNames.loadableURL(for: URL(fileURLWithPath: path)))
    case .gm(let program):
      try unit.loadSoundBankInstrument(
        at: SamplerSource.gmBank, program: UInt8(clamping: program),
        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    case .sf2(let path, let program):
      try unit.loadSoundBankInstrument(
        at: URL(fileURLWithPath: path), program: UInt8(clamping: program),
        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    case .kit(let path, let bank, let program):
      let percussion = bank >= 128
      try unit.loadSoundBankInstrument(
        at: URL(fileURLWithPath: path), program: UInt8(clamping: program),
        bankMSB: UInt8(
          percussion ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
        bankLSB: UInt8(clamping: percussion ? 0 : bank))
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
    Self.buildParameterCache(unit.audioUnit)
  }

  /// AUSampler reports a parameter change on every note-on, from inside its render. Once an
  /// AVAudioMixerNode is connected anywhere in the process *after* this unit exists (another
  /// AVAudioEngine's graph: `SessionPlayer` rendering a set offline while the decks play),
  /// AudioToolbox answers that report by building the unit's parameter cache, lazily, on the
  /// render thread: about 54 mallocs and 50 frees per sampler, once. Building it here instead
  /// (adding a parameter listener builds it) leaves nothing for the render thread to build.
  /// Measured by `samplersDoNotAllocateWhenAnotherEngineIsBuilt` (WaveDeckSourceTests) and,
  /// with the engine built during the renders, `SamplerConcurrentEngineRealTimeTests`. What
  /// is left is not ours to fix: that same report walks AudioToolbox's process-wide listener
  /// map, and the walk that leaves last frees the nodes other threads removed meanwhile (an
  /// engine torn down while a deck plays: a few frees on the render thread, no mallocs).
  private static func buildParameterCache(_ unit: AudioUnit) {
    var listener: AUParameterListenerRef?
    let created = AUListenerCreateWithDispatchQueue(
      &listener, 0, DispatchQueue.global(), { _, _, _ in })
    guard created == noErr, let listener else { return }
    var param = AudioUnitParameter(
      mAudioUnit: unit, mParameterID: AudioUnitParameterID(kAUSamplerParam_Gain),
      mScope: kAudioUnitScope_Global, mElement: 0)
    if AUListenerAddParameter(listener, nil, &param) == noErr {
      AUListenerRemoveParameter(listener, nil, &param)
    }
    AUListenerDispose(listener)
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

  /// Worst pitch error (cents, in whatever octave it sounds) a sound may have to be played.
  /// Character patches are a few cents out; past this a pick would clash with the track's key.
  public static let maxDetuneCents = 30.0
  /// Below this on the reference phrase a sound is treated as silent (missing samples).
  public static let silentRMSdB = -70.0

  /// Off the audio thread, before publishing: play the reference phrase, measure it, set
  /// `gain` to land on `targetRMSdB`, then silence and reset the unit. Returns false for a
  /// sound not fit to play — silent, or out of tune past `maxDetuneCents`.
  /// `tuning: false` (a local-only bank, `SamplerSource.isLocalOnly`: its importer tuned it,
  /// and its one-shots are too short to hold a note 0.1 s in) checks the level only.
  @discardableResult
  func normalize(sampleRate sr: Double, tuning: Bool = true) -> Bool {
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
    guard tuning else {
      send(0xB0, 123, 0, at: 0)
      au.reset()
      timestamp.mSampleTime = 0
      lastCheck = (rms, 0, true)
      return rms > Self.silentRMSdB
    }
    // Tuning: one held A3, measured 0.1–0.4 s in.
    send(0xB0, 123, 0, at: 0)
    au.reset()
    var held = [Float](repeating: 0, count: Int(0.4 * sr))
    send(0x90, 57, 100, at: 0)
    var t2 = 0
    while t2 < held.count {
      let n = min(block, held.count - t2)
      held.withUnsafeMutableBufferPointer { renderAdding(frames: n, $0.baseAddress! + t2, nil) }
      t2 += n
    }
    let pitch = pitchClassError(held[Int(0.1 * sr)...], note: 57, sampleRate: sr)
    send(0xB0, 123, 0, at: 0)
    au.reset()
    timestamp.mSampleTime = 0
    lastCheck = (rms, pitch.cents, pitch.level > 0)
    return rms > Self.silentRMSdB && pitch.level > 0 && abs(pitch.cents) <= Self.maxDetuneCents
  }

  /// The phrase a drum kit is measured on: a bar at 120 BPM of four-on-the-floor kick,
  /// sixteenth hats and a backbeat snare, on the GM keys the drum lanes play
  /// (`DrumKits.gmNote`).
  static let kitPhrase: [(note: Int, at: Double, seconds: Double)] = (0..<16).flatMap {
    i -> [(note: Int, at: Double, seconds: Double)] in
    let at = Double(i) * 0.125
    var hits: [(note: Int, at: Double, seconds: Double)] = [(42, at, 0.1)]
    if i % 4 == 0 { hits.append((36, at, 0.3)) }
    if i % 8 == 4 { hits.append((38, at, 0.3)) }
    return hits
  }
  /// RMS of beats' synth kit ("drums") on `kitPhrase` at velocity 100 (measured:
  /// `SampledKitTests.theSynthKitSetsTheKitTarget`): what a sampled kit is brought to, so a
  /// sampled kit sits in the mix where the synth kit did.
  public static let kitTargetRMSdB = -15.0
  /// The kit voices that must sound for a kit to play: kick, snare, closed hat.
  static let kitVoices = [36, 38, 42]

  /// `normalize` for a drum kit: level-matched on `kitPhrase` to `kitTargetRMSdB`, and turned
  /// away if its kick, snare or closed hat is silent. No tuning check (drums are unpitched).
  @discardableResult
  func normalizeKit(sampleRate sr: Double) -> Bool {
    gain = 1
    let rms = phraseRMS(Self.kitPhrase, seconds: 2.25, sampleRate: sr)
    var quietest = 0.0
    for note in Self.kitVoices {
      let r = phraseRMS([(note, 0, 0.3)], seconds: 0.3, sampleRate: sr)
      quietest = min(quietest, r)
    }
    gain = min(20, max(0.02, pow(10, (Self.kitTargetRMSdB - rms) / 20)))
    lastCheck = (min(rms, quietest), 0, quietest > Self.silentRMSdB)
    return rms > Self.silentRMSdB && quietest > Self.silentRMSdB
  }

  /// RMS (dB) of `phrase` played at velocity 100 over `seconds`, then silenced and reset.
  private func phraseRMS(
    _ phrase: [(note: Int, at: Double, seconds: Double)], seconds: Double, sampleRate sr: Double
  ) -> Double {
    let total = Int(seconds * sr)
    let block = 512
    var buf = [Float](repeating: 0, count: block)
    var sum = 0.0
    var t = 0
    let ons = phrase.map { Int(($0.at * sr).rounded()) }
    let offs = phrase.map { Int((($0.at + $0.seconds) * sr).rounded()) }
    while t < total {
      let n = min(block, total - t)
      for (k, p) in phrase.enumerated() {
        if offs[k] >= t && offs[k] < t + n { send(0x80, UInt8(p.note), 0, at: offs[k] - t) }
        if ons[k] >= t && ons[k] < t + n { send(0x90, UInt8(p.note), 100, at: ons[k] - t) }
      }
      for i in 0..<n { buf[i] = 0 }
      buf.withUnsafeMutableBufferPointer { renderAdding(frames: n, $0.baseAddress!, nil) }
      for i in 0..<n { sum += Double(buf[i]) * Double(buf[i]) }
      t += n
    }
    send(0xB0, 123, 0, at: 0)
    au.reset()
    timestamp.mSampleTime = 0
    return 10 * log10(max(sum / Double(max(1, total)), 1e-20))
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

/// A deck's samplers: `capacity` slots, loaded off the audio thread (`slot(for:)`).
///
/// References: `slot(for:)` takes one on the slot it returns and `release` gives it back.
/// A `WaveProject` holds one per sampled lane until it is freed, which happens off the audio
/// thread (the deck's retire ring), so a slot that no live project — current, pending or
/// fading — plays has no references.
///
/// Eviction: a full bank reuses the least recently used slot with no references, in two
/// phases. Its bit in `active` is cleared, so the audio thread neither sends it MIDI nor
/// renders it; the loader then waits until no block that could have seen the bit set is
/// still running (`epoch` is odd while one is), and only then frees the old AUSampler and
/// publishes the new one in its place. The audio thread never frees, locks or waits.
public final class SamplerBank: @unchecked Sendable {
  public static let capacity = 24
  public let sampleRate: Double
  private let slots: UnsafeMutablePointer<Unmanaged<SamplerInstrument>?>
  /// Bit i: slot i holds an instrument the audio thread may play.
  private let active = Atomic<UInt64>(0)
  /// Bumped as the audio thread starts and ends a block: odd while one is in flight.
  private let epoch = Atomic<UInt64>(0)
  /// Serialises loads and evictions (held across a load, never by the audio thread).
  private let lock = NSLock()
  private var bySource: [SamplerSource: Int] = [:]
  private var unloadable: Set<SamplerSource> = []
  /// Why each source in `unloadable` (or missing from disk) was turned away.
  private var failures: [SamplerSource: String] = [:]
  private var filled = 0
  private var lastUsed = [UInt64](repeating: 0, count: capacity)
  private var uses: UInt64 = 0
  /// References and what each slot plays, behind their own short lock: releasing a project
  /// or asking what a slot plays never waits behind a load.
  private let table = Mutex(Table())

  private struct Table {
    var refs = [Int](repeating: 0, count: SamplerBank.capacity)
    var sources = [SamplerSource?](repeating: nil, count: SamplerBank.capacity)
  }

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(repeating: nil, count: Self.capacity)
  }

  deinit {
    for i in 0..<Self.capacity { slots[i]?.release() }
    slots.deallocate()
  }

  /// Off the audio thread: the slot playing the first of `sources` that loads, loading (and
  /// level-normalising) it if needed (evicting an unreferenced slot when the bank is full), with one reference taken
  /// on it for the caller to `release`. nil when none loads or every slot is referenced (the
  /// caller falls back to a synth voice).
  public func slot(for sources: [SamplerSource]) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    for s in sources {
      if let i = bySource[s] {
        acquire(i)
        return i
      }
      if unloadable.contains(s) { continue }
      if !s.isAvailable {
        failures[s] = "not on disk"
        continue
      }
      guard let target = freeSlot() else { return nil }
      // Load first, so a source that fails to load costs nothing already playing.
      var loadError: Error?
      let loaded = SamplerInstrument.lifecycle.withLock { () -> SamplerInstrument? in
        do { return try SamplerInstrument(source: s, sampleRate: sampleRate) } catch {
          loadError = error
          return nil
        }
      }
      guard let inst = loaded else {
        unloadable.insert(s)
        failures[s] = "load failed: \(loadError.map { Self.describe($0) } ?? "unknown")"
        continue
      }
      if s.isKit {
        guard inst.normalizeKit(sampleRate: sampleRate) else {
          unloadable.insert(s)
          failures[s] = String(
            format: "a kit without a kick, snare or hat (quietest %.1f dB)",
            inst.lastCheck?.rmsDB ?? -200)
          continue
        }
      } else if !inst.normalize(sampleRate: sampleRate, tuning: !s.isLocalOnly) {
        unloadable.insert(s)  // silent or out of tune: never published
        let c = inst.lastCheck
        let rms = c.map { String(format: "%.1f", $0.rmsDB) } ?? "?"
        let cents = c.map { String(format: "%+.0f", $0.cents) } ?? "?"
        failures[s] =
          (c.map { $0.rmsDB <= SamplerInstrument.silentRMSdB } ?? false)
          ? "silent (\(rms) dB)"
          : (c.map { !$0.held } ?? false)
            ? "silent 0.1 s into a held note: too short to tune"
            : "out of tune (\(cents) cents, limit \(Int(SamplerInstrument.maxDetuneCents)))"
        continue
      }
      if target < filled { evict(target) } else { filled += 1 }
      slots[target] = Unmanaged.passRetained(inst)
      bySource[s] = target
      table.withLock { $0.sources[target] = s }
      acquire(target)
      active.bitwiseOr(1 << UInt64(target), ordering: .releasing)
      return target
    }
    return nil
  }

  /// Why `slot(for:)` turned `source` away: not on disk, failed to load (with the system's
  /// error, e.g. an OSStatus), silent, or out of tune. nil if it hasn't been tried or loaded.
  public func loadFailure(for source: SamplerSource) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return bySource[source] == nil ? failures[source] : nil
  }

  private static func describe(_ error: Error) -> String {
    let e = error as NSError
    return "\(e.domain) \(e.code): \(e.localizedDescription)"
  }

  /// Off the audio thread: give back a reference `slot(for:)` took.
  public func release(_ slot: Int) {
    table.withLock {
      assert($0.refs[slot] > 0, "sampler slot \(slot) released more than taken")
      $0.refs[slot] -= 1
    }
  }

  /// What a slot plays (any thread but the audio thread; for display and tests).
  public func source(of slot: Int) -> SamplerSource? {
    guard slot >= 0, slot < Self.capacity else { return nil }
    return table.withLock { $0.sources[slot] }
  }

  /// References held on a slot (tests).
  func references(of slot: Int) -> Int { table.withLock { $0.refs[slot] } }

  // lock held
  private func acquire(_ i: Int) {
    table.withLock { $0.refs[i] += 1 }
    uses += 1
    lastUsed[i] = uses
  }

  // lock held: a never-used slot, else the least recently used one nothing references.
  private func freeSlot() -> Int? {
    if filled < Self.capacity { return filled }
    let refs = table.withLock { $0.refs }
    var best: Int?
    for i in 0..<Self.capacity where refs[i] == 0 {
      if best == nil || lastUsed[i] < lastUsed[best!] { best = i }
    }
    return best
  }

  // lock held, slot unreferenced: take it from the audio thread, then free what it played.
  private func evict(_ i: Int) {
    active.bitwiseAnd(~(1 << UInt64(i)), ordering: .sequentiallyConsistent)
    // A block that started before the bit cleared may still be using the slot; one that
    // starts after cannot (both sides are sequentially consistent). Wait out the former.
    let e = epoch.load(ordering: .sequentiallyConsistent)
    if e & 1 == 1 {
      while epoch.load(ordering: .acquiring) == e { usleep(100) }
    }
    if let old = table.withLock({ t -> SamplerSource? in
      defer { t.sources[i] = nil }
      return t.sources[i]
    }) {
      bySource[old] = nil
    }
    let inst = slots[i]
    slots[i] = nil
    inst?.release()  // tears down under `SamplerInstrument.lifecycle` (its deinit)
  }

  /// One past the highest slot the audio thread may play.
  @inline(__always) var count: Int {
    64 - active.load(ordering: .acquiring).leadingZeroBitCount
  }

  /// Audio thread: start a block. Returns the slots it may send to and render (bit i =
  /// slot i); pass that to `send` and `renderAll`, then call `endBlock`.
  @inline(__always)
  func beginBlock() -> UInt64 {
    epoch.wrappingAdd(1, ordering: .sequentiallyConsistent)
    return active.load(ordering: .sequentiallyConsistent)
  }

  @inline(__always)
  func endBlock() { epoch.wrappingAdd(1, ordering: .releasing) }

  /// Audio thread, inside a block, `slot` active in it (or an offline caller holding a
  /// reference on `slot`).
  @inline(__always)
  func send(_ slot: Int, _ status: UInt8, _ d1: UInt8, _ d2: UInt8, at offset: Int) {
    slots[slot]!._withUnsafeGuaranteedRef { $0.send(status, d1, d2, at: offset) }
  }

  @inline(__always)
  func renderAll(
    _ live: UInt64, frames: Int, _ out: UnsafeMutablePointer<Float>,
    _ outR: UnsafeMutablePointer<Float>?
  ) {
    var m = live
    while m != 0 {
      let i = m.trailingZeroBitCount
      m &= m - 1
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
  /// (net id → "exs:Vintage Strat.exs" / "sf2:MuseScore_General.sf2#30" / "gm:25"). The
  /// rest play synth voices.
  public var sampledNets: [String: String] {
    guard let p = latest else { return [:] }
    var out: [String: String] = [:]
    for lane in p.lanes where lane.samplerSlot >= 0 {
      out[lane.netId] = samplers.source(of: lane.samplerSlot)?.description ?? "?"
    }
    return out
  }
}

/// How far `x` (a held `note`) sits from that note's pitch class, in cents, whatever octave it
/// sounds in (a glockenspiel speaks two octaves up): the strongest partial within ±100 cents
/// of the note in octaves −2…+3, by Hann-windowed DFT in 1-cent steps.
func pitchClassError(_ x: ArraySlice<Float>, note: Int, sampleRate sr: Double) -> (
  cents: Double, octave: Int, level: Double
) {
  let v = Array(x)
  let n = v.count
  guard n > 16 else { return (0, 0, 0) }
  var w = [Double](repeating: 0, count: n)
  for i in 0..<n {
    w[i] = Double(v[i]) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
  }
  var best = (cents: 0.0, octave: 0, level: -1.0)
  for oct in -2...3 {
    let base = 440 * pow(2, Double(note + 12 * oct - 69) / 12)
    guard base < sr * 0.45 else { continue }
    var c = -100.0
    while c <= 100 {
      let k = 2 * Double.pi * base * pow(2, c / 1200) / sr
      var re = 0.0
      var im = 0.0
      // rotate a phasor instead of calling cos/sin per sample
      let cr = cos(k)
      let ci = -sin(k)
      var pr = 1.0
      var pi = 0.0
      for i in 0..<n {
        re += w[i] * pr
        im += w[i] * pi
        let t = pr * cr - pi * ci
        pi = pr * ci + pi * cr
        pr = t
      }
      let mag = re * re + im * im
      if mag > best.level { best = (c, oct, mag) }
      c += 1
    }
  }
  return best
}
