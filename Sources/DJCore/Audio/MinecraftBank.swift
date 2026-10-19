@preconcurrency import AVFoundation
import Foundation

/// The Minecraft palette's sound bank: `minecraft-local.sf2`, built on this Mac from the user's
/// own installed game sounds (`MinecraftImport`, `djctl minecraft import`), with a sidecar
/// (`minecraft-local.json`) naming the asset index and every sample's SHA-1. It lives only in
/// the SoundFont folder (`SamplerSource.soundFontDir`); it is never committed, shipped or
/// published (`SessionPublish` refuses sessions that play it), and never joins the General MIDI
/// pools (`SamplerSource.localOnlyBanks`).
public enum MinecraftBank {
  public static let fileName = "minecraft-local.sf2"
  public static let sidecarName = "minecraft-local.json"
  /// The kit preset: fixed-pitch zones on the GM drum keys (melodic bank 0).
  public static let kitProgram = 127
  public static var kitID: String { "\(fileName)#0:\(kitProgram)" }
  /// The bank's layout, recorded in the sidecar and in the palette version a track records
  /// (`minecraft@32+b2`): 1 = one zone per tone program; 2 = each tone program in three
  /// octave zones (`MinecraftImport.octaveZones`). A sidecar without one is format 1.
  public static let formatVersion = 2

  public enum Kind: String, Sendable {
    /// Pitched, played across the keyboard from its root; `loop`: a crossfade loop holds it.
    case tone
    /// Fixed pitch, played as recorded on any key (stingers).
    case fx
  }

  /// One program of the bank: a Minecraft sound at a fixed program number.
  public struct Program: Sendable, Equatable {
    public var name: String
    public var program: Int
    /// The note block event that names it (its sound comes from sounds.json), or nil.
    public var event: String?
    /// The sound path (`note/harp2`), used when the event is missing.
    public var sound: String
    public var kind: Kind
    /// MIDI key the recording sounds at (Minecraft's note blocks are all F#).
    public var root: Int
    public var loop: Bool
    /// The first index that has it (copper trumpets came with index 30).
    public var minIndex: Int
  }

  private static func tone(
    _ name: String, _ program: Int, _ event: String, _ sound: String, root: Int,
    loop: Bool = false, minIndex: Int = 0
  ) -> Program {
    Program(
      name: name, program: program, event: "block.note_block." + event, sound: sound, kind: .tone,
      root: root, loop: loop, minIndex: minIndex)
  }

  private static func fx(_ name: String, _ program: Int, _ sound: String, event: String? = nil)
    -> Program
  {
    Program(
      name: name, program: program, event: event, sound: sound, kind: .fx, root: 60, loop: false,
      minIndex: 0)
  }

  /// Every program, at fixed numbers (sessions name sounds by program through the palette).
  /// Roots are the note blocks' F#: bass and didgeridoo F#2, guitar F#3, harp / bit / banjo /
  /// pling / iron xylophone / trumpets F#4, flute and cow bell F#5, bell, xylophone and chime
  /// F#6; the importer measures each and corrects the cents.
  public static let programs: [Program] =
    [
      tone("harp2", 0, "harp", "note/harp2", root: 66),
      tone("bassattack", 1, "bass", "note/bassattack", root: 42),
      tone("didgeridoo", 2, "didgeridoo", "note/didgeridoo", root: 42, loop: true),
      tone("guitar", 3, "guitar", "note/guitar", root: 54),
      tone("bit", 4, "bit", "note/bit", root: 66, loop: true),
      tone("banjo", 5, "banjo", "note/banjo", root: 66),
      tone("pling", 6, "pling", "note/pling", root: 66),
      tone("iron_xylophone", 7, "iron_xylophone", "note/iron_xylophone", root: 66),
      tone("flute", 8, "flute", "note/flute", root: 78, loop: true),
      tone("cow_bell", 9, "cow_bell", "note/cow_bell", root: 78),
      tone("bell", 10, "bell", "note/bell", root: 90),
      tone("xylobone", 11, "xylophone", "note/xylobone", root: 90),
      tone("icechime", 12, "chime", "note/icechime", root: 90),
      tone("trumpet", 13, "trumpet", "note/trumpet", root: 66, loop: true, minIndex: 30),
      tone(
        "trumpet_exposed", 14, "trumpet_exposed", "note/trumpet_exposed", root: 66, loop: true,
        minIndex: 30),
      tone(
        "trumpet_weathered", 15, "trumpet_weathered", "note/trumpet_weathered", root: 66,
        loop: true, minIndex: 30),
      tone(
        "trumpet_oxidized", 16, "trumpet_oxidized", "note/trumpet_oxidized", root: 66, loop: true,
        minIndex: 30),
    ]
    + (0..<8).map {
      fx(
        "goat_horn_call\($0)", 32 + $0, "item/goat_horn/call\($0)",
        event: "item.goat_horn.sound.\($0)")
    }
    + [
      fx("bell_use", 40, "block/bell/bell_use01"),
      fx("bell_resonate", 41, "block/bell/resonate"),
      fx("amethyst_shimmer", 42, "block/amethyst/shimmer"),
      fx("anvil_land", 43, "random/anvil_land"),
      fx("orb", 44, "random/orb"),
    ]

  /// The kit preset's zones: GM keys → a sound, played at its own pitch.
  /// `level`: the energy of one hit against one kick (dB): the recordings are not balanced
  /// against each other (the snare and hat are a third of the kick's length), so the import
  /// scales them to a mixed kit's balance — in a bar of four kicks, two snares and sixteen
  /// hats, `MixBalance.targetDB`'s snare 6 dB and hats about 10 dB under the kick. A zone that
  /// reuses another's sound takes its level.
  public static let kitZones:
    [(name: String, sound: String, keys: ClosedRange<Int>, level: Double)] = [
      ("bd", "note/bd", 35...36, 0), ("snare", "note/snare", 37...41, -3),
      ("hat", "note/hat", 42...46, -13), ("crash", "note/hat", 49...57, -13),
    ]

  public static func program(named name: String) -> Int? {
    programs.first { $0.name == name }?.program
  }

  public static func path(dir: String = SamplerSource.soundFontDir) -> String {
    (dir as NSString).appendingPathComponent(fileName)
  }

  /// The bank's sidecar: what it was built from.
  public struct Sidecar: Sendable, Equatable {
    public static let schema = "dj-vevr-se/minecraft-local/v1"
    /// The asset index (`"32"`) the sounds came from.
    public var assetIndex: String
    /// Program name (and kit zone `kit:bd`…) → the object's SHA-1.
    public var sha1: [String: String]
    /// The programs built (some are missing from older indexes).
    public var programs: [String]
    /// The bank layout (`MinecraftBank.formatVersion` when it was built).
    public var format: Int

    /// What a track records as the palette's version: the asset index, plus the bank format
    /// when it is not 1 (`32+b2`), so a recording names the sounds and how they were cut.
    public var version: String { format > 1 ? "\(assetIndex)+b\(format)" : assetIndex }

    public var json: JSONValue {
      var o = JSONObject()
      o["schema"] = .string(Self.schema)
      o["assetIndex"] = .string(assetIndex)
      o["format"] = .number(Double(format))
      o["programs"] = .array(programs.map { .string($0) })
      var h = JSONObject()
      for k in sha1.keys.sorted() { h[k] = .string(sha1[k]!) }
      o["sha1"] = .object(h)
      return .object(o)
    }

    public init(
      assetIndex: String, sha1: [String: String], programs: [String],
      format: Int = MinecraftBank.formatVersion
    ) {
      self.assetIndex = assetIndex
      self.sha1 = sha1
      self.programs = programs
      self.format = format
    }

    init?(json v: JSONValue) {
      guard v["schema"]?.string == Self.schema, let i = v["assetIndex"]?.string else { return nil }
      assetIndex = i
      var h: [String: String] = [:]
      for (k, x) in v["sha1"]?.object?.entries ?? [] { h[k] = x.string }
      sha1 = h
      programs = (v["programs"]?.array ?? []).compactMap(\.string)
      format = v["format"]?.double.map { Int($0) } ?? 1
    }

    public static func load(dir: String = SamplerSource.soundFontDir) -> Sidecar? {
      let p = (dir as NSString).appendingPathComponent(sidecarName)
      guard let text = try? String(contentsOfFile: p, encoding: .utf8),
        let v = try? JSONValue.parse(text)
      else { return nil }
      return Sidecar(json: v)
    }
  }

  /// The bank and its sidecar are in the SoundFont folder.
  public static func isInstalled(dir: String = SamplerSource.soundFontDir) -> Bool {
    FileManager.default.fileExists(atPath: path(dir: dir)) && Sidecar.load(dir: dir) != nil
  }

  /// Why the palette can't play here, or nil: the bank was never imported (and whether the
  /// game's assets are there to import it from).
  public static func unavailableReason(dir: String = SamplerSource.soundFontDir) -> String? {
    if isInstalled(dir: dir) { return nil }
    if let why = MinecraftAssets.unavailableReason() { return why }
    return "not imported yet: run `make minecraft` (djctl minecraft import)"
  }
}

/// Builds `minecraft-local.sf2` and its sidecar from the installed assets: each sound decoded
/// (AVAudioFile reads the Ogg Vorbis objects), mixed to mono, resampled to 44.1 kHz, peak
/// normalised and stored 16-bit; pitched sounds measured and tuned in the sample header,
/// steady tones (flute, didgeridoo, bit, trumpets) given a crossfade loop so a pad or a held
/// note can sustain; plucked ones stay one-shots. Each tone is also stored an octave down and an
/// octave up (`octaveShift`, band-limited, loop points scaled) and played from the nearest of
/// the three (`octaveZones`), so no key stretches the recording more than half an octave.
public enum MinecraftImport {
  public static let sampleRate = 44_100.0

  public struct Report: Sendable {
    public var assetIndex: String
    public var path: String
    public var programs: [(name: String, program: Int, cents: Double, loop: Bool)]
    public var skipped: [String]
    public var bytes: Int
  }

  /// Build the bank into `dir` (the SoundFont folder). Overwrites an earlier build.
  @discardableResult
  public static func run(assets: MinecraftAssets, to dir: String = SamplerSource.soundFontDir)
    throws -> Report
  {
    let index = Int(assets.indexID) ?? 0
    var writer = SF2Writer(name: "minecraft-local")
    var sha1: [String: String] = [:]
    var built: [(String, Int, Double, Bool)] = []
    var skipped: [String] = []
    for p in MinecraftBank.programs {
      guard index >= p.minIndex else {
        skipped.append("\(p.name) (asset index \(index) < \(p.minIndex))")
        continue
      }
      let sound = p.event.flatMap { assets.sounds(event: $0).first } ?? p.sound
      let file: (path: String, sha1: String)
      do { file = try assets.file(sound: sound) } catch {
        skipped.append("\(p.name): \(error)")
        continue
      }
      var pcm = try decode(file.path)
      var cents = 0.0
      var root = p.root
      var loop: Range<Int>?
      if p.kind == .tone {
        (root, cents) = measureRoot(pcm, near: p.root)
        if p.loop { loop = crossfadeLoop(&pcm, root: root, cents: cents) }
      }
      let release = p.kind == .fx ? 8 : (p.loop ? 0.15 : 1.2)
      var zones: [SF2Writer.Zone] = []
      if p.kind == .tone {
        for z in octaveZones(root: root) {
          let shifted = octaveShift(pcm, loop: loop, octaves: z.shift)
          let suffix = z.shift == 0 ? "" : (z.shift < 0 ? "-1" : "+1")
          let zoneRoot = root + 12 * z.shift
          let sample = writer.addSample(
            p.name + suffix, pcm: shifted.pcm, root: zoneRoot,
            correction: Int(-cents.rounded()), loop: shifted.loop)
          zones.append(
            SF2Writer.Zone(
              keys: z.keys, sample: sample, fixedPitch: false, rootKey: zoneRoot,
              loop: shifted.loop != nil, releaseSeconds: release))
        }
      } else {
        let sample = writer.addSample(p.name, pcm: pcm, root: root, correction: 0, loop: nil)
        zones.append(
          SF2Writer.Zone(
            keys: 0...127, sample: sample, fixedPitch: true, rootKey: root, loop: false,
            releaseSeconds: release))
      }
      writer.addPreset("mc \(p.name)", program: p.program, zones: zones)
      sha1[p.name] = file.sha1
      built.append((p.name, p.program, cents, loop != nil))
    }
    var kitZones: [SF2Writer.Zone] = []
    // the kit's sounds, each hit's energy brought to its level against the kick by cutting
    // (all are peak-normalised: only the louder ones can move)
    var kitPCM: [String: (name: String, pcm: [Float], level: Double)] = [:]
    var kitOrder: [String] = []
    for z in MinecraftBank.kitZones where kitPCM[z.sound] == nil {
      let file = try assets.file(sound: z.sound)
      kitPCM[z.sound] = (z.name, try decode(file.path), z.level)
      kitOrder.append(z.sound)
      sha1["kit:\(z.name)"] = file.sha1
    }
    // the kick lands where the quietest sound, at full scale, allows
    var kickAt = Double.infinity
    for s in kitOrder { kickAt = min(kickAt, hitEnergy(kitPCM[s]!.pcm) - kitPCM[s]!.level) }
    var kitSamples: [String: Int] = [:]
    for s in kitOrder {
      var k = kitPCM[s]!
      let cut = min(0, kickAt + k.level - hitEnergy(k.pcm))
      let g = Float(pow(10, cut / 20))
      for i in k.pcm.indices { k.pcm[i] *= g }
      kitSamples[s] = writer.addSample(
        "kit \(k.name)", pcm: k.pcm, root: 60, correction: 0, loop: nil)
    }
    for z in MinecraftBank.kitZones {
      kitZones.append(
        SF2Writer.Zone(
          keys: z.keys, sample: kitSamples[z.sound]!, fixedPitch: true, rootKey: 60,
          loop: false, releaseSeconds: 2))
      if sha1["kit:\(z.name)"] == nil {
        sha1["kit:\(z.name)"] = sha1["kit:\(kitPCM[z.sound]!.name)"]
      }
    }
    writer.addPreset("Minecraft Kit", program: MinecraftBank.kitProgram, zones: kitZones)
    let data = writer.data()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let out = MinecraftBank.path(dir: dir)
    try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    let sidecar = MinecraftBank.Sidecar(
      assetIndex: assets.indexID, sha1: sha1, programs: built.map(\.0),
      format: MinecraftBank.formatVersion)
    try (sidecar.json.canonicalJS + "\n").write(
      toFile: (dir as NSString).appendingPathComponent(MinecraftBank.sidecarName),
      atomically: true, encoding: .utf8)
    DrumKits.rescan()
    return Report(
      assetIndex: assets.indexID, path: out,
      programs: built.map { (name: $0.0, program: $0.1, cents: $0.2, loop: $0.3) },
      skipped: skipped, bytes: data.count)
  }

  /// A tone program's key zones: the recording an octave down below `root - 6`, as recorded
  /// from `root - 6` to `root + 6`, an octave up above — no key within 18 semitones of the root
  /// plays a sample more than six semitones from that sample's root. Together they cover 0…127 without overlap.
  public static func octaveZones(root: Int) -> [(keys: ClosedRange<Int>, shift: Int)] {
    let low = min(127, max(0, root - 6))
    let high = min(127, max(low, root + 6))
    var out: [(keys: ClosedRange<Int>, shift: Int)] = []
    if low > 0 { out.append((0...(low - 1), -1)) }
    out.append((low...high, 0))
    if high < 127 { out.append(((high + 1)...127, 1)) }
    return out
  }

  /// The lowpass both octave shifts run through: a Kaiser-windowed sinc (255 taps, β 6.5,
  /// cut at 0.24 fs) that is down more than 60 dB from 0.25 fs (11.025 kHz), the octave-up
  /// sample's new Nyquist — nothing above it folds back — and that also removes the images
  /// zero-stuffing leaves in the octave-down one. Unity gain at DC.
  static let octaveFilter: [Double] = {
    let taps = 255
    let beta = 6.5
    let fc = 0.24
    func i0(_ x: Double) -> Double {
      var sum = 1.0
      var term = 1.0
      var k = 1.0
      while term > 1e-12 * sum {
        term *= (x / (2 * k)) * (x / (2 * k))
        sum += term
        k += 1
      }
      return sum
    }
    let m = Double(taps - 1) / 2
    var h = (0..<taps).map { i -> Double in
      let t = Double(i) - m
      let sinc = t == 0 ? 2 * fc : sin(2 * Double.pi * fc * t) / (Double.pi * t)
      let r = t / m
      return sinc * i0(beta * (1 - r * r).squareRoot()) / i0(beta)
    }
    let dc = h.reduce(0, +)
    for i in h.indices { h[i] /= dc }
    return h
  }()

  /// `pcm` (and its loop) moved by `octaves` (−1, 0, +1) at the same sample rate: an octave
  /// up keeps every other sample of the lowpassed sound (half as long), an octave down
  /// zero-stuffs and lowpasses it (twice as long). Loop points scale with it (an octave up
  /// needs an even loop start, which `crossfadeLoop` gives). Pure: the same input gives the
  /// same bytes.
  static func octaveShift(_ pcm: [Float], loop: Range<Int>?, octaves: Int) -> (
    pcm: [Float], loop: Range<Int>?
  ) {
    let h = octaveFilter
    let c = (h.count - 1) / 2
    let n = pcm.count
    switch octaves {
    case 1:
      let count = (n + 1) / 2
      var out = [Float](repeating: 0, count: count)
      for j in 0..<count {
        let mid = 2 * j
        let lo = max(0, mid - c)
        let hi = min(n - 1, mid + c)
        var acc = 0.0
        if lo <= hi {
          for i in lo...hi { acc += h[mid - i + c] * Double(pcm[i]) }
        }
        out[j] = Float(acc)
      }
      let l = loop.flatMap { r -> Range<Int>? in
        let s = r.lowerBound / 2
        let e = s + Int((Double(r.count) / 2).rounded())
        return e + 8 < count && e > s ? s..<e : nil
      }
      return (out, l)
    case -1:
      let count = 2 * n
      var out = [Float](repeating: 0, count: count)
      for m in 0..<count {
        // taps k = m + c − 2i in 0..<h.count
        let iLo = max(0, (m + c - (h.count - 1) + 1) / 2)
        let iHi = min(n - 1, (m + c) / 2)
        var acc = 0.0
        if iLo <= iHi {
          for i in iLo...iHi { acc += h[m + c - 2 * i] * Double(pcm[i]) }
        }
        out[m] = Float(2 * acc)
      }
      return (out, loop.map { (2 * $0.lowerBound)..<(2 * $0.upperBound) })
    default:
      return (pcm, loop)
    }
  }

  /// A hit's energy, dB (its whole length).
  static func hitEnergy(_ pcm: [Float]) -> Double {
    var sum = 0.0
    for x in pcm { sum += Double(x) * Double(x) }
    return 10 * log10(max(sum, 1e-20))
  }

  /// The key a recording sounds at, near its nominal root (a semitone either way: an oxidized
  /// copper trumpet is not quite an F#), and how many cents off that key it is.
  static func measureRoot(_ pcm: [Float], near nominal: Int) -> (root: Int, cents: Double) {
    let probe = pcm.dropFirst(Int(0.02 * sampleRate)).prefix(Int(0.3 * sampleRate))
    var best = (root: nominal, cents: 0.0)
    var found = false
    for root in [nominal, nominal - 1, nominal + 1] {
      let e = pitchClassError(probe, note: root, sampleRate: sampleRate)
      guard e.level > 0 else { continue }
      if !found || abs(e.cents) < abs(best.cents) {
        best = (root, e.cents)
        found = true
      }
    }
    return best
  }

  /// A sound file as mono float at `sampleRate`, peak-normalised to −1 dBFS.
  static func decode(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    guard
      let input = AVAudioPCMBuffer(
        pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw CocoaError(.fileReadCorruptFile) }
    try file.read(into: input)
    let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    let capacity = AVAudioFrameCount(
      Double(input.frameLength) * sampleRate / inFormat.sampleRate + 1024)
    guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let fed = LockedBox(false)
    var err: NSError?
    let status = converter.convert(to: output, error: &err) { _, outStatus in
      if fed.withLock({ f in
        defer { f = true }
        return f
      }) {
        outStatus.pointee = .endOfStream
        return nil
      }
      outStatus.pointee = .haveData
      return input
    }
    if status == .error { throw err ?? CocoaError(.fileReadCorruptFile) }
    var pcm = Array(
      UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
    if peak > 0 {
      let g = Float(0.891) / peak
      for i in pcm.indices { pcm[i] *= g }
    }
    return pcm
  }

  /// A loop over whole periods of the note in the steady middle of the sound, its end
  /// crossfaded into what precedes its start (30 ms) so the jump back is seamless.
  static func crossfadeLoop(_ pcm: inout [Float], root: Int, cents: Double) -> Range<Int>? {
    let f0 = 440 * pow(2, (Double(root) - 69) / 12) * pow(2, cents / 1200)
    let period = sampleRate / f0
    let n = pcm.count
    let start = Int(Double(n) * 0.3) & ~1  // even: the octave-up copy halves it exactly
    let periods = max(1, (0.12 * sampleRate / period).rounded())
    let length = Int((periods * period).rounded())
    let end = start + length
    let fade = min(Int(0.03 * sampleRate), length / 2, start)
    guard end + 8 < n, fade > 8 else { return nil }
    for i in 0..<fade {
      let t = Float(i) / Float(fade)
      pcm[end - fade + i] = pcm[end - fade + i] * (1 - t) + pcm[start - fade + i] * t
    }
    return start..<end
  }
}

/// A minimal SoundFont 2 writer: mono 16-bit samples, one instrument per preset.
struct SF2Writer {
  struct Zone {
    var keys: ClosedRange<Int>
    var sample: Int
    /// Every key plays the sample at its own pitch (scaleTuning 0).
    var fixedPitch: Bool
    var rootKey: Int
    var loop: Bool
    var releaseSeconds: Double
    /// Zone attenuation, dB (`initialAttenuation`, written when > 0).
    var attenuationDB = 0.0
  }

  let name: String
  private var smpl = Data()
  private var shdr = Data()
  private var sampleCount = 0
  private var presets: [(name: String, program: Int, zones: [Zone])] = []

  init(name: String) { self.name = name }

  /// Add a sample; returns its index.
  mutating func addSample(
    _ name: String, pcm: [Float], root: Int, correction: Int, loop: Range<Int>?
  ) -> Int {
    let start = UInt32(smpl.count / 2)
    for x in pcm {
      let v = Int16(max(-32767, min(32767, (x * 32767).rounded())))
      withUnsafeBytes(of: v.littleEndian) { smpl.append(contentsOf: $0) }
    }
    let end = UInt32(smpl.count / 2)
    smpl.append(Data(count: 46 * 2))  // the 46 zero frames the spec asks after each sample
    let ls = loop.map { start + UInt32($0.lowerBound) } ?? start
    let le = loop.map { start + UInt32($0.upperBound) } ?? max(start, end - 1)
    var h = Data()
    h.appendFixed(name, 20)
    for v in [start, end, ls, le, UInt32(MinecraftImport.sampleRate)] { h.appendLE(v) }
    h.append(UInt8(clamping: root))
    h.append(UInt8(bitPattern: Int8(clamping: correction)))
    h.appendLE(UInt16(0))  // sample link
    h.appendLE(UInt16(1))  // mono
    shdr.append(h)
    sampleCount += 1
    return sampleCount - 1
  }

  mutating func addPreset(_ name: String, program: Int, zones: [Zone]) {
    presets.append((name, program, zones))
  }

  func data() -> Data {
    func chunk(_ id: String, _ body: Data) -> Data {
      var d = Data(id.utf8)
      d.appendLE(UInt32(body.count))
      d.append(body)
      if body.count % 2 == 1 { d.append(0) }
      return d
    }
    func list(_ type: String, _ body: Data) -> Data { chunk("LIST", Data(type.utf8) + body) }
    func gen(_ op: UInt16, _ amount: UInt16) -> Data {
      var d = Data()
      d.appendLE(op)
      d.appendLE(amount)
      return d
    }
    func signed(_ v: Int) -> UInt16 { UInt16(bitPattern: Int16(clamping: v)) }
    var inst = Data()
    var ibag = Data()
    var igen = Data()
    var phdr = Data()
    var pbag = Data()
    var pgen = Data()
    var bagIndex = 0
    var genIndex = 0
    for (i, p) in presets.enumerated() {
      inst.appendFixed(p.name, 20)
      inst.appendLE(UInt16(bagIndex))
      for z in p.zones {
        ibag.appendLE(UInt16(genIndex))
        ibag.appendLE(UInt16(0))
        bagIndex += 1
        var g = Data()
        g += gen(43, UInt16(z.keys.lowerBound) | UInt16(z.keys.upperBound) << 8)  // keyRange
        let release = Int((1200 * log2(max(0.001, z.releaseSeconds))).rounded())
        g += gen(38, signed(release))  // releaseVolEnv (timecents)
        if z.loop { g += gen(54, 1) }  // sampleModes: loop continuously
        if z.fixedPitch { g += gen(56, 0) }  // scaleTuning 0: every key at the root's pitch
        if z.attenuationDB > 0 {  // initialAttenuation, centibels
          g += gen(48, UInt16(min(1440, (z.attenuationDB * 10).rounded())))
        }
        g += gen(58, UInt16(z.rootKey))  // overridingRootKey
        g += gen(53, UInt16(z.sample))  // sampleID (last)
        igen.append(g)
        genIndex += g.count / 4
      }
      phdr.appendFixed(p.name, 20)
      phdr.appendLE(UInt16(p.program))
      phdr.appendLE(UInt16(0))  // bank
      phdr.appendLE(UInt16(i))  // preset bag index
      for _ in 0..<3 { phdr.appendLE(UInt32(0)) }
      pbag.appendLE(UInt16(i))
      pbag.appendLE(UInt16(0))
      pgen += gen(41, UInt16(i))  // instrument
    }
    inst.appendFixed("EOI", 20)
    inst.appendLE(UInt16(bagIndex))
    ibag.appendLE(UInt16(genIndex))
    ibag.appendLE(UInt16(0))
    igen += gen(0, 0)
    phdr.appendFixed("EOP", 20)
    phdr.appendLE(UInt16(0))
    phdr.appendLE(UInt16(0))
    phdr.appendLE(UInt16(presets.count))
    for _ in 0..<3 { phdr.appendLE(UInt32(0)) }
    pbag.appendLE(UInt16(presets.count))
    pbag.appendLE(UInt16(0))
    pgen += gen(0, 0)
    var eos = Data()
    eos.appendFixed("EOS", 20)
    eos.append(Data(count: 26))
    var ifil = Data()
    ifil.appendLE(UInt16(2))
    ifil.appendLE(UInt16(1))
    let info = list(
      "INFO",
      chunk("ifil", ifil) + chunk("isng", Data("EMU8000\0".utf8))
        + chunk("INAM", Data((name + "\0").utf8)))
    let sdta = list("sdta", chunk("smpl", smpl))
    let pdta = list(
      "pdta",
      chunk("phdr", phdr) + chunk("pbag", pbag) + chunk("pmod", Data(count: 10))
        + chunk("pgen", pgen) + chunk("inst", inst) + chunk("ibag", ibag)
        + chunk("imod", Data(count: 10)) + chunk("igen", igen) + chunk("shdr", shdr + eos))
    let body = Data("sfbk".utf8) + info + sdta + pdta
    var out = Data("RIFF".utf8)
    out.appendLE(UInt32(body.count))
    out.append(body)
    return out
  }
}

extension Data {
  fileprivate mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
    Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
  }
  fileprivate mutating func appendFixed(_ s: String, _ n: Int) {
    var b = Array(s.utf8.prefix(n - 1))
    b += [UInt8](repeating: 0, count: n - b.count)
    append(contentsOf: b)
  }
}
