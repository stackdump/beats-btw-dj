import Foundation

/// A whole-track sound palette (`Resources/voices/categories.json` → `palettes`): every role's
/// category for the track — the drums' kit, the bass, lead, pad, arp and stinger pools — from
/// one local bank (`bankCategories`). Chosen per track (`Track.palette`, the `tracks` override
/// `palette` on every channel; the poke `DeckAction.setPalette`). The user's own picks still
/// win: a role whose instrument was picked (`Track.picked`) voices as it would without the
/// palette, and a kit pick (`Track.kit`) wins over the palette's kit. Picks inside a category
/// are seeded by the track seed + role, as voicing's are.
public struct SoundPalette: Sendable, Equatable, Identifiable {
  public var id: String
  public var label: String
  /// Role (a net's group or riff group: kick, snare, hihat, clap, bass, melody, harmony, pad,
  /// arp, stinger) → category.
  public var roles: [String: String]

  /// A category played from one bank: sound names (programs), or a kit preset's program.
  public struct BankCategory: Sendable, Equatable {
    public var bank: String
    public var sounds: [String]
    public var kit: Int?
  }

  public static let all: [SoundPalette] = load().palettes
  public static let categories: [String: BankCategory] = load().categories

  /// The palette a track names: its id, optionally with the asset version it was played with
  /// (`minecraft@32`, `recorded(_:)`).
  public static func named(_ id: String?) -> SoundPalette? {
    guard let id, !id.isEmpty else { return nil }
    let bare = id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id
    return all.first { $0.id == bare }
  }

  /// The asset version a recorded palette names (`minecraft@32` → "32"), or nil.
  public static func version(_ id: String?) -> String? {
    guard let id, let at = id.firstIndex(of: "@") else { return nil }
    let v = id[id.index(after: at)...]
    return v.isEmpty ? nil : String(v)
  }

  /// How a track records this palette: with the version of what it plays here (the Minecraft
  /// bank's asset index, from its sidecar, whose per-sample SHA-1s pin the sounds), so a
  /// session, favorite or loop names what it was made with.
  public func recorded(dir: String = SamplerSource.soundFontDir) -> String {
    if banks.contains(MinecraftBank.fileName),
      let index = MinecraftBank.Sidecar.load(dir: dir)?.assetIndex
    {
      return "\(id)@\(index)"
    }
    return id
  }

  static func load() -> (palettes: [SoundPalette], categories: [String: BankCategory]) {
    guard let text = try? VoiceCatalog.loadText(), let json = try? JSONValue.parse(text) else {
      return ([], [:])
    }
    return parse(json)
  }

  static func parse(_ json: JSONValue) -> (
    palettes: [SoundPalette], categories: [String: BankCategory]
  ) {
    var cats: [String: BankCategory] = [:]
    for (k, v) in json["bankCategories"]?.object?.entries ?? [] {
      guard let bank = v["bank"]?.string else { continue }
      cats[k] = BankCategory(
        bank: bank, sounds: (v["sounds"]?.array ?? []).compactMap(\.string), kit: v["kit"]?.int)
    }
    var out: [SoundPalette] = []
    for (k, v) in json["palettes"]?.object?.entries ?? [] {
      guard let roles = v["roles"]?.object else { continue }
      var r: [String: String] = [:]
      for (role, c) in roles.entries { r[role] = c.string }
      out.append(SoundPalette(id: k, label: v["label"]?.string ?? k, roles: r))
    }
    return (out, cats)
  }

  /// The banks this palette plays.
  public var banks: Set<String> {
    Set(roles.values.compactMap { Self.categories[$0]?.bank })
  }

  /// Why the palette can't play on this Mac, or nil (its bank imported; for the Minecraft
  /// palette, from the game's installed assets).
  public func unavailableReason(dir: String = SamplerSource.soundFontDir) -> String? {
    if banks.contains(MinecraftBank.fileName) { return MinecraftBank.unavailableReason(dir: dir) }
    for b in banks.sorted()
    where !FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(b)) {
      return "\(b) is not installed"
    }
    return nil
  }

  /// Its banks are installed (cheap: what prepare asks for every lane).
  public func isPlayable(dir: String = SamplerSource.soundFontDir) -> Bool {
    banks.allSatisfy { b in
      b == MinecraftBank.fileName
        ? MinecraftBank.isInstalled(dir: dir)
        : FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(b))
    }
  }

  /// Plays only on this Mac (built from content that may not be shared): never published.
  public var isLocalOnly: Bool { !banks.isDisjoint(with: SamplerSource.localOnlyBanks) }

  /// The kit id the palette's drums play (`DrumKits`), or nil.
  public var kit: String? {
    for role in ["kick", "snare", "hihat", "clap"] {
      if let c = roles[role].flatMap({ Self.categories[$0] }), let p = c.kit {
        return "\(c.bank)#0:\(p)"
      }
    }
    return nil
  }

  /// The kit a track's palette gives its drums, when the palette's bank is installed.
  public static func kit(for palette: String?, dir: String = SamplerSource.soundFontDir) -> String?
  {
    guard let p = named(palette), p.isPlayable(dir: dir) else { return nil }
    return p.kit
  }

  /// What a net of `role` tries first under this palette: its category's sounds, the seeded
  /// pick first (track seed + role), then the rest. nil when the palette has no category for
  /// the role or its bank is not installed (the role voices as without a palette).
  public func sources(role: String, seed: Double, dir: String = SamplerSource.soundFontDir)
    -> [SamplerSource]?
  {
    guard let category = roles[role], let c = Self.categories[category], !c.sounds.isEmpty,
      isPlayable(dir: dir)
    else { return nil }
    let built =
      c.bank == MinecraftBank.fileName ? MinecraftBank.Sidecar.load(dir: dir)?.programs : nil
    let programs = c.sounds.filter { built?.contains($0) ?? true }.compactMap { name in
      c.bank == MinecraftBank.fileName ? MinecraftBank.program(named: name) : nil
    }
    guard !programs.isEmpty else { return nil }
    let path = (dir as NSString).appendingPathComponent(c.bank)
    let pick = Int(VoiceCatalog.stableHash("\(seed)|\(role)|\(category)") % UInt64(programs.count))
    return (0..<programs.count).map { .sf2(path, program: programs[(pick + $0) % programs.count]) }
  }
}

extension SamplerSource {
  /// From a bank that is only ever played on this Mac (`localOnlyBanks`): level-checked on load
  /// but not tuning-checked (its importer tuned it; its one-shots are too short to measure).
  public var isLocalOnly: Bool {
    switch self {
    case .sf2(let p, _), .kit(let p, _, _):
      return SamplerSource.localOnlyBanks.contains((p as NSString).lastPathComponent)
    case .exs, .gm: return false
    }
  }
}
