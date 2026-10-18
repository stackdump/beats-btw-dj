import Foundation

/// A drum kit a net's drum lanes can play instead of beats' synth kit: a preset of an
/// installed sound bank (`SamplerSource.kit`). Named by `id` — the bank's file name, bank and
/// program (`MuseScore_General.sf2#128:0`) — so a share, a favorite or a session names the same
/// kit on any Mac that has the bank, and resolves to nothing (the synth kit) on one without.
public struct DrumKit: Hashable, Sendable, Identifiable {
  public var id: String
  /// The preset's name in its bank (`Standard`, `Room`, `Minecraft Kit`).
  public var name: String
  /// The bank's file name without its extension (`MuseScore_General`, `gs_instruments`).
  public var bank: String
  public var source: SamplerSource

  /// `Standard · MuseScore_General`.
  public var label: String { "\(name) · \(bank)" }
}

/// The drum kits installed on this Mac, and the GM keys the drum lanes play them on.
///
/// Kits come from every bank in the SoundFont folder (`SamplerSource.soundFontDir`, local-only
/// banks included) and from macOS's own `gs_instruments.dls`: each bank-128 (percussion)
/// preset, and each melodic preset named as a kit (`Minecraft Kit`: fixed-pitch zones on the
/// GM drum keys). Like every sampled sound, kits are played from where they are installed and
/// never copied into the repo, a release or the CDN.
public enum DrumKits {
  /// What a drum lane plays on a kit: its kind (`drumKind`, `.openHats` / `.crash`) on the
  /// General MIDI key for it.
  public static func gmNote(kind: String) -> Int {
    switch kind {
    case "kick": return 36
    case "snare": return 38
    case "clap": return 39
    case "hat": return 42
    case "openhat": return 46
    case "crash": return 49
    default: return 36
    }
  }

  /// How long a kit hit is held before its note-off: a cymbal rings, a drum stops on its own.
  static func holdMs(kind: String) -> Double {
    switch kind {
    case "crash": return 2500
    case "openhat": return 600
    default: return 400
    }
  }

  /// The velocity scale that moves a sampled hit by `db`: a sound bank's velocity curve is
  /// about 40 dB per decade of velocity (SoundFont 2.04's default `velocity → attenuation`,
  /// and DLS's), so × 10^(dB/40).
  public static func velocityScale(_ db: Double) -> Double { pow(10, db / 40) }

  /// Every kit on this Mac, scanned once (`rescan` after installing a bank).
  public static var installed: [DrumKit] {
    if let kits = cache.withLock({ $0 }) { return kits }
    return rescan()
  }
  private static let cache = LockedBox<[DrumKit]?>(nil)

  /// Scan again (after `djctl minecraft import` built or removed a bank).
  @discardableResult
  public static func rescan() -> [DrumKit] {
    let kits = scan(banks: banks())
    cache.withLock { $0 = kits }
    return kits
  }

  /// The banks kits are looked for in: every .sf2 in the SoundFont folder (local-only ones
  /// too, sorted by name), then Apple's GM bank.
  static func banks(dir: String = SamplerSource.soundFontDir) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    var out = names.filter { $0.lowercased().hasSuffix(".sf2") }.sorted()
      .map { (dir as NSString).appendingPathComponent($0) }
    if FileManager.default.fileExists(atPath: SamplerSource.gmBank.path) {
      out.append(SamplerSource.gmBank.path)
    }
    return out
  }

  /// The kits in `banks`, bank by bank, each bank's in program order.
  public static func scan(banks: [String]) -> [DrumKit] {
    var out: [DrumKit] = []
    for path in banks {
      let file = (path as NSString).lastPathComponent
      let stem = (file as NSString).deletingPathExtension
      let presets =
        file.lowercased().hasSuffix(".dls") ? BankPresets.dls(path) : BankPresets.sf2(path)
      for p in presets.sorted(by: { ($0.bank, $0.program) < ($1.bank, $1.program) })
      where p.bank == 128 || isKitName(p.name) {
        out.append(
          DrumKit(
            id: "\(file)#\(p.bank):\(p.program)", name: p.name, bank: stem,
            source: .kit(path, bank: p.bank, program: p.program)))
      }
    }
    return out
  }

  /// A melodic preset that is a kit by its name.
  static func isKitName(_ name: String) -> Bool {
    let n = " " + name.lowercased() + " "
    return n.contains(" kit ") || n.contains(" drum kit") || n.hasSuffix(" kit ")
  }

  /// The kit an id names, wherever its bank is installed (the SoundFont folder, or Apple's GM
  /// bank for `gs_instruments.dls`); nil for an id that names no installed bank. Resolving
  /// reads no bank: a missing preset fails at load and the lane keeps its synth voice.
  public static func source(for id: String, dir: String = SamplerSource.soundFontDir)
    -> SamplerSource?
  {
    guard let parsed = parse(id) else { return nil }
    let path =
      parsed.file == SamplerSource.gmBank.lastPathComponent
      ? SamplerSource.gmBank.path : (dir as NSString).appendingPathComponent(parsed.file)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return .kit(path, bank: parsed.bank, program: parsed.program)
  }

  /// `file#bank:program` → its parts.
  static func parse(_ id: String) -> (file: String, bank: Int, program: Int)? {
    guard let hash = id.lastIndex(of: "#") else { return nil }
    let file = String(id[..<hash])
    let parts = id[id.index(after: hash)...].split(separator: ":")
    guard !file.isEmpty, !file.contains("/"), parts.count == 2, let b = Int(parts[0]),
      let p = Int(parts[1]), (0...128).contains(b), (0...127).contains(p)
    else { return nil }
    return (file, b, p)
  }

  /// The Brush kit of `kit`'s bank (`Brush.forGenre`'s snare on a sampled kit): its bank-128
  /// preset on GM2 / GS's Brush program (40), else the first one named as a brush kit; nil for
  /// a bank without one (the kit's own snare plays, softer) or a kit that isn't a bank-128 one.
  /// Reads the bank's preset list once per bank (prepare, off the audio thread).
  public static func brushKit(for kit: SamplerSource) -> SamplerSource? {
    guard case .kit(let path, let bank, _) = kit, bank == 128 else { return nil }
    let presets =
      brushCache.withLock({ $0[path] })
      ?? {
        let read =
          path.lowercased().hasSuffix(".dls") ? BankPresets.dls(path) : BankPresets.sf2(path)
        brushCache.withLock { $0[path] = read }
        return read
      }()
    guard let p = brushPreset(in: presets) else { return nil }
    return .kit(path, bank: p.bank, program: p.program)
  }
  private static let brushCache = LockedBox<[String: [BankPreset]]>([:])

  /// GM2 / GS's Brush kit program.
  static let brushProgram = 40

  /// The Brush kit among a bank's presets: bank 128 program 40, else the lowest bank-128
  /// program whose name has "brush" in it.
  static func brushPreset(in presets: [BankPreset]) -> BankPreset? {
    let kits = presets.filter { $0.bank == 128 }.sorted { $0.program < $1.program }
    return kits.first { $0.program == brushProgram }
      ?? kits.first { $0.name.lowercased().contains("brush") }
  }

  /// A readable name for a kit id (its preset's, when installed; else the id).
  public static func label(_ id: String) -> String {
    installed.first { $0.id == id }?.label ?? id
  }
}

/// A preset of a sound bank: its name, bank (128 = percussion) and program.
struct BankPreset: Equatable {
  var name: String
  var bank: Int
  var program: Int
}

/// Reads a sound bank's preset list without its samples (`phdr` of a SoundFont 2, the
/// instrument headers of a DLS): a 200 MB bank costs a few kB of reads.
enum BankPresets {
  /// A SoundFont's presets (`pdta`/`phdr`), the terminal `EOP` left out.
  static func sf2(_ path: String) -> [BankPreset] {
    guard let f = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? f.close() }
    guard let riff = read(f, 12), riff.count == 12, riff.prefix(4) == Data("RIFF".utf8),
      riff.suffix(4) == Data("sfbk".utf8)
    else { return [] }
    let end = UInt64(riff.u32(4)) + 8
    var at: UInt64 = 12
    while at + 12 <= end {
      try? f.seek(toOffset: at)
      guard let head = read(f, 12), head.count == 12 else { break }
      let size = UInt64(head.u32(4))
      if head.prefix(4) == Data("LIST".utf8) && head.suffix(4) == Data("pdta".utf8) {
        var sub = at + 12
        let listEnd = at + 8 + size
        while sub + 8 <= listEnd {
          try? f.seek(toOffset: sub)
          guard let ch = read(f, 8), ch.count == 8 else { break }
          let n = UInt64(ch.u32(4))
          if ch.prefix(4) == Data("phdr".utf8) {
            guard let body = read(f, Int(n)) else { return [] }
            var out: [BankPreset] = []
            var i = 0
            while i + 38 <= body.count {
              let name = body.cString(i, 20)
              let program = Int(body.u16(i + 20))
              let bank = Int(body.u16(i + 22))
              i += 38
              if i + 38 > body.count { break }  // the last record is EOP
              out.append(BankPreset(name: name, bank: bank, program: program))
            }
            return out
          }
          sub += 8 + n + (n & 1)
        }
        return []
      }
      at += 8 + size + (size & 1)
    }
    return []
  }

  /// A DLS bank's instruments (`lins` / `ins ` / `insh` + `INAM`): a drum instrument
  /// (`F_INSTRUMENT_DRUMS`) as bank 128, a melodic one in its CC0 bank.
  static func dls(_ path: String) -> [BankPreset] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
      data.count >= 12, data.prefix(4) == Data("RIFF".utf8),
      data.subdata(in: 8..<12) == Data("DLS ".utf8)
    else { return [] }
    var out: [BankPreset] = []
    func walk(_ from: Int, _ to: Int, _ visit: (String, String?, Int, Int) -> Void) {
      var at = from
      while at + 8 <= to {
        let id = String(decoding: data.subdata(in: at..<(at + 4)), as: UTF8.self)
        let size = Int(data.u32(at + 4))
        let body = at + 8
        guard body + size <= data.count else { return }
        let type =
          (id == "LIST" && size >= 4)
          ? String(decoding: data.subdata(in: body..<(body + 4)), as: UTF8.self) : nil
        visit(id, type, body, size)
        at = body + size + (size & 1)
      }
    }
    walk(12, data.count) { id, type, body, size in
      guard id == "LIST", type == "lins" else { return }
      walk(body + 4, body + size) { id, type, ib, isz in
        guard id == "LIST", type == "ins " else { return }
        var name = ""
        var bank = -1
        var program = 0
        walk(ib + 4, ib + isz) { id, type, b, sz in
          if id == "insh", sz >= 12 {
            let ulBank = data.u32(b + 4)
            program = Int(data.u32(b + 8) & 0x7F)
            bank = ulBank & 0x8000_0000 != 0 ? 128 : Int((ulBank >> 8) & 0x7F)
          } else if id == "LIST", type == "INFO" {
            walk(b + 4, b + sz) { id, _, nb, nsz in
              if id == "INAM" { name = data.cString(nb, nsz) }
            }
          }
        }
        if bank >= 0 { out.append(BankPreset(name: name, bank: bank, program: program)) }
      }
    }
    return out
  }

  private static func read(_ f: FileHandle, _ n: Int) -> Data? {
    try? f.read(upToCount: n)
  }
}

extension Data {
  fileprivate func u16(_ i: Int) -> UInt16 {
    let b = startIndex + i
    return UInt16(self[b]) | UInt16(self[b + 1]) << 8
  }
  fileprivate func u32(_ i: Int) -> UInt32 {
    let b = startIndex + i
    return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16
      | UInt32(self[b + 3]) << 24
  }
  fileprivate func cString(_ i: Int, _ n: Int) -> String {
    let b = startIndex + i
    let bytes = self[b..<(b + n)].prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
  }
}

/// A value behind a lock (a cache several threads read).
final class LockedBox<T>: @unchecked Sendable {
  private var value: T
  private let lock = NSLock()
  init(_ v: T) { value = v }
  func withLock<R>(_ body: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
