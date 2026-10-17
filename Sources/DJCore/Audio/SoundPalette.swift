import Foundation

/// A sound palette (`Resources/voices/palettes.json`): a named sound world for a whole track,
/// the way a deck chooses what its track sounds like. For each role — the drums (`kit`), bass,
/// melody, harmony, arp, stingers — a pool of options (beats' synth voices, installed sampled
/// instruments by category, General MIDI programs from the SoundFonts, Apple's GM bank, a local
/// bank's programs, sampled or synth drum kits); a track plays one option per role, picked by
/// the track seed + role (`pick`, applied by `Project.applySound`), so the same configuration
/// always sounds the same. Chosen per track (`Track.palette`, the `tracks` override `palette`
/// on every channel; the poke `DeckAction.setPalette`) and carried into every new track the
/// deck makes (`TrackSpec.carryingSound`). The user's own choices win: a role's override
/// (`DeckAction.setRoleVoice`, the `tracks` override `voice`) or picked instrument plays
/// instead of the pick, and a kit pick (`Track.kit`) wins over the palette's kit. The default
/// palette (Studio) plays every instrument's own sound and is never written into a track.
public struct SoundPalette: Sendable, Equatable, Identifiable {
  public var id: String
  public var label: String
  /// An emoji for the chooser.
  public var icon: String
  /// `#RRGGBB`, the card's accent.
  public var color: String
  public var description: String
  /// Where Wander's palette hop may go from here.
  public var neighbours: [String]
  /// Role (bass, melody, harmony, arp, stinger, `*` = any other tonal role, `kit` = the
  /// drums) → options, in the order the chooser shows them.
  public var roles: [String: [String]]
  /// The genre whose room (`SpaceSpec.forGenre`) and echo (`EchoSpec.forGenre`, `none` = dry)
  /// the palette plays in; nil = the track's genre's.
  public var room: String?
  public var echo: String?

  /// A category played from one bank: sound names (programs), or a kit preset's program.
  public struct BankCategory: Sendable, Equatable {
    public var bank: String
    public var sounds: [String]
    public var kit: Int?
  }

  /// The roles a palette names, in the chooser's order.
  public static let roleOrder = ["kit", "bass", "melody", "harmony", "arp", "stinger"]

  private static let data = load()
  /// Every shipped palette, in the chooser's order (the default first).
  public static let all: [SoundPalette] = data.palettes
  public static let categories: [String: BankCategory] = data.categories
  /// The palette a track without one plays: Studio.
  public static let defaultID: String = data.defaultID

  public var isDefault: Bool { id == Self.defaultID }

  /// The palette a track names: its id, optionally with the asset version it was played with
  /// (`minecraft@32`, `recorded(_:)`).
  public static func named(_ id: String?) -> SoundPalette? {
    guard let id, !id.isEmpty else { return nil }
    let bare = id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id
    return all.first { $0.id == bare }
  }

  /// The palette a track plays: the one it names, else the default.
  public static func playing(_ id: String?) -> SoundPalette? { named(id) ?? named(defaultID) }

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

  /// What a track writes for palette `id`: nil for none or the default (a track without a
  /// palette plays the default, and its share stays as it was), else the id with its asset
  /// version (`recorded`) when it comes without one.
  public static func normalized(_ id: String?, dir: String = SamplerSource.soundFontDir)
    -> String?
  {
    guard let id, !id.isEmpty else { return nil }
    guard let p = named(id) else { return id }
    if p.isDefault { return nil }
    return version(id) == nil ? p.recorded(dir: dir) : id
  }

  // MARK: data

  static func load() -> (
    palettes: [SoundPalette], categories: [String: BankCategory], defaultID: String
  ) {
    let cats = (try? VoiceCatalog.loadText()).flatMap { try? JSONValue.parse($0) }
    let pals = (try? loadText()).flatMap { try? JSONValue.parse($0) }
    let c = cats.map { parse(categories: $0) } ?? [:]
    let (p, d) = pals.map { parse(palettes: $0) } ?? ([], "studio")
    return (p, c, d)
  }

  static func loadText() throws -> String {
    guard
      let url = Bundle.main.url(forResource: "palettes", withExtension: "json", subdirectory: "voices")
        ?? Bundle.module.url(
          forResource: "palettes", withExtension: "json", subdirectory: "voices")
    else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "voices/palettes.json"])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  static func parse(categories json: JSONValue) -> [String: BankCategory] {
    var cats: [String: BankCategory] = [:]
    for (k, v) in json["bankCategories"]?.object?.entries ?? [] {
      guard let bank = v["bank"]?.string else { continue }
      cats[k] = BankCategory(
        bank: bank, sounds: (v["sounds"]?.array ?? []).compactMap(\.string), kit: v["kit"]?.int)
    }
    return cats
  }

  static func parse(palettes json: JSONValue) -> ([SoundPalette], String) {
    var out: [SoundPalette] = []
    for (k, v) in json["palettes"]?.object?.entries ?? [] {
      guard let roles = v["roles"]?.object else { continue }
      var r: [String: [String]] = [:]
      for (role, opts) in roles.entries { r[role] = (opts.array ?? []).compactMap(\.string) }
      out.append(
        SoundPalette(
          id: k, label: v["label"]?.string ?? k, icon: v["icon"]?.string ?? "",
          color: v["color"]?.string ?? "#8E8E93", description: v["description"]?.string ?? "",
          neighbours: (v["neighbours"]?.array ?? []).compactMap(\.string), roles: r,
          room: v["hints"]?["room"]?.string, echo: v["hints"]?["echo"]?.string))
    }
    return (out, json["default"]?.string ?? out.first?.id ?? "studio")
  }

  // MARK: pools

  /// The options for `role` (`*` for a tonal role the palette doesn't name), nil = the role
  /// plays its instrument's own sound.
  public func pool(_ role: String) -> [String]? {
    if let p = roles[role], !p.isEmpty { return p }
    return role == "kit" ? nil : roles["*"].flatMap { $0.isEmpty ? nil : $0 }
  }

  /// `role`'s options that can play on this Mac, in order.
  public func available(_ role: String, dir: String = SamplerSource.soundFontDir) -> [String] {
    (pool(role) ?? []).filter { Self.unavailableReason(option: $0, role: role, dir: dir) == nil }
  }

  /// The option a net of `role` plays under this palette: one of the available options,
  /// picked by the track seed and the net (`key`: its id, so each stinger hit gets its own).
  /// nil when the palette has no pool for the role, or none of it is installed.
  public func pick(
    role: String, key: String, seed: Double, dir: String = SamplerSource.soundFontDir
  ) -> String? {
    let ok = available(role, dir: dir)
    guard !ok.isEmpty else { return nil }
    let i = Int(VoiceCatalog.stableHash("\(seed)|\(key)|palette:\(id)") % UInt64(ok.count))
    return ok[i]
  }

  /// Why the palette can't play on this Mac, or nil: its bank is missing (for the Minecraft
  /// palette, from the game's installed assets), or a role it names has nothing installed.
  public func unavailableReason(dir: String = SamplerSource.soundFontDir) -> String? {
    if banks.contains(MinecraftBank.fileName),
      let why = MinecraftBank.unavailableReason(dir: dir)
    {
      return why
    }
    for (role, why) in roleReport(dir: dir) { if let why { return "\(role): \(why)" } }
    return nil
  }

  /// Every role the palette names with why nothing of it can play here (nil: something can).
  public func roleReport(dir: String = SamplerSource.soundFontDir) -> [(String, String?)] {
    let names = Self.roleOrder.filter { roles[$0] != nil } + (roles["*"] != nil ? ["*"] : [])
    return names.map { role in
      let opts = pool(role) ?? []
      if opts.contains(where: { Self.unavailableReason(option: $0, role: role, dir: dir) == nil })
      {
        return (role, nil)
      }
      let why = opts.compactMap { Self.unavailableReason(option: $0, role: role, dir: dir) }
      return (role, why.first ?? "no options")
    }
  }

  /// It can play here.
  public func isPlayable(dir: String = SamplerSource.soundFontDir) -> Bool {
    unavailableReason(dir: dir) == nil
  }

  // MARK: options

  /// `synth:<name>` → name.
  public static func synthName(_ option: String) -> String? {
    option.hasPrefix("synth:") ? String(option.dropFirst(6)) : nil
  }

  /// `inst:<name>` → name: the role plays as if `name` were picked for it.
  public static func pickedName(_ option: String) -> String? {
    option.hasPrefix("inst:") ? String(option.dropFirst(5)) : nil
  }

  /// Why `option` can't play for `role` here, or nil when it can. Looked at once per option
  /// (the deck panel asks on every poll); `rescan` after installing or removing a bank.
  public static func unavailableReason(
    option: String, role: String, dir: String = SamplerSource.soundFontDir
  ) -> String? {
    let key = "\(dir)|\(role == "kit" ? "kit" : "tonal")|\(option)"
    if let hit = optionCache.withLock({ $0[key] }) { return hit }
    let why = check(option: option, role: role, dir: dir)
    optionCache.withLock { $0[key] = .some(why) }
    return why
  }
  private static let optionCache = LockedBox<[String: String?]>([:])

  /// Look at what is installed again (after `make soundfonts` or `djctl minecraft import`).
  public static func rescan() { optionCache.withLock { $0 = [:] } }

  static func check(option: String, role: String, dir: String) -> String? {
    let fm = FileManager.default
    if option == "own" || option == "synth" { return nil }
    if let name = synthName(option) ?? pickedName(option) {
      if role == "kit" { return isSynthDrumKit(name) ? nil : "no synth kit \(name)" }
      return knownInstrument(name) ? nil : "no instrument \(name)"
    }
    if role == "kit" {
      if let b = bankCategory(option) {
        guard b.kit != nil else { return "\(option) has no kit" }
        return bankReason(b.bank, dir: dir)
      }
      guard let parsed = DrumKits.parse(option) else { return "not a kit: \(option)" }
      return DrumKits.source(for: option, dir: dir) == nil ? "\(parsed.file) is not installed" : nil
    }
    if option.hasPrefix("cat:") {
      let c = String(option.dropFirst(4))
      if !VoiceCatalog.shared.pool(c).isEmpty { return nil }
      if !(VoiceCatalog.shared.gm[c] ?? []).isEmpty && !SamplerSource.soundFonts(in: dir).isEmpty {
        return nil
      }
      return "no \(c) sound installed (make soundfonts installs the General MIDI floor)"
    }
    if option.hasPrefix("gm:") {
      guard Int(option.dropFirst(3)) != nil else { return "not a program: \(option)" }
      return SamplerSource.soundFonts(in: dir).isEmpty
        ? "\(SamplerSource.floorSoundFont) is not installed (make soundfonts)" : nil
    }
    if option.hasPrefix("dls:") {
      guard Int(option.dropFirst(4)) != nil else { return "not a program: \(option)" }
      return fm.fileExists(atPath: SamplerSource.gmBank.path)
        ? nil : "Apple's gs_instruments.dls is not on this Mac"
    }
    if let b = bankCategory(option) {
      guard !b.sounds.isEmpty else { return "\(option) has no sounds" }
      return bankReason(b.bank, dir: dir)
    }
    return "unknown option \(option)"
  }

  private static func bankReason(_ bank: String, dir: String) -> String? {
    if bank == MinecraftBank.fileName {
      return MinecraftBank.isInstalled(dir: dir)
        ? nil : MinecraftBank.unavailableReason(dir: dir) ?? "\(bank) is not installed"
    }
    return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(bank))
      ? nil : "\(bank) is not installed"
  }

  static func bankCategory(_ option: String) -> BankCategory? {
    option.hasPrefix("bank:") ? categories[String(option.dropFirst(5))] : nil
  }

  /// A beats instrument the synth engine voices (its own table or its families' words).
  static func knownInstrument(_ name: String) -> Bool {
    if InstrumentTable.shared.entries[name] != nil || VoiceCatalog.shared.categoryOf[name] != nil {
      return true
    }
    return BeatsTables.shared.instrumentSets.values.contains { set in
      set.values.contains { $0.contains(name) }
    }
  }

  /// What `option` plays for `role` on a sampler: the seeded sound first (track seed + role),
  /// then the rest; nil for an option that plays a synth voice (or nothing installed).
  public static func sources(
    option: String, role: String, seed: Double, dir: String = SamplerSource.soundFontDir
  ) -> [SamplerSource]? {
    var out: [SamplerSource] = []
    if option.hasPrefix("cat:") {
      let c = String(option.dropFirst(4))
      let pool = VoiceCatalog.shared.pool(c)
      if !pool.isEmpty {
        let pick = Int(VoiceCatalog.stableHash("\(seed)|\(role)|\(c)") % UInt64(pool.count))
        for k in 0..<pool.count { out += pool[(pick + k) % pool.count].sources }
      }
      let programs = VoiceCatalog.shared.gm[c] ?? []
      for bank in SamplerSource.soundFonts(in: dir) {
        out += programs.map { .sf2(bank, program: $0) }
      }
    } else if option.hasPrefix("gm:"), let n = Int(option.dropFirst(3)) {
      out = SamplerSource.soundFonts(in: dir).map { .sf2($0, program: n) }
    } else if option.hasPrefix("dls:"), let n = Int(option.dropFirst(4)) {
      if FileManager.default.fileExists(atPath: SamplerSource.gmBank.path) { out = [.gm(n)] }
    } else if let c = bankCategory(option), !c.sounds.isEmpty, bankReason(c.bank, dir: dir) == nil
    {
      let category = String(option.dropFirst(5))
      let built =
        c.bank == MinecraftBank.fileName ? MinecraftBank.Sidecar.load(dir: dir)?.programs : nil
      let programs = c.sounds.filter { built?.contains($0) ?? true }.compactMap { name in
        c.bank == MinecraftBank.fileName ? MinecraftBank.program(named: name) : nil
      }
      guard !programs.isEmpty else { return nil }
      let path = (dir as NSString).appendingPathComponent(c.bank)
      let pick = Int(
        VoiceCatalog.stableHash("\(seed)|\(role)|\(category)") % UInt64(programs.count))
      out = (0..<programs.count).map {
        .sf2(path, program: programs[(pick + $0) % programs.count])
      }
    }
    return out.isEmpty ? nil : out
  }

  /// What a net of `role` tries first under this palette (its seeded pick's sounds), nil when
  /// the pick plays a synth voice, the palette has no pool for the role, or nothing of it is
  /// installed.
  public func sources(role: String, seed: Double, dir: String = SamplerSource.soundFontDir)
    -> [SamplerSource]?
  {
    guard let opt = pick(role: role, key: role, seed: seed, dir: dir) else { return nil }
    return Self.sources(option: opt, role: role, seed: seed, dir: dir)
  }

  /// The kit id a kit option plays (`DrumKits`), "synth" for one of beats' synth kits, nil for
  /// an option that is no kit.
  public static func kitID(option: String) -> String? {
    if option == "synth" || option == "own" || synthName(option) != nil { return "synth" }
    if let b = bankCategory(option), let p = b.kit { return "\(b.bank)#0:\(p)" }
    return DrumKits.parse(option) != nil ? option : nil
  }

  // MARK: what it plays from

  /// The banks this palette plays (local banks and Apple's GM bank).
  public var banks: Set<String> {
    var out: Set<String> = []
    for opts in roles.values {
      for o in opts {
        if let b = Self.bankCategory(o) { out.insert(b.bank) }
        if o.hasPrefix("dls:") { out.insert(SamplerSource.gmBank.lastPathComponent) }
        if let k = DrumKits.parse(o) { out.insert(k.file) }
      }
    }
    return out
  }

  /// Plays content that may only be played on this Mac (the Minecraft bank built from the
  /// user's game, Apple's GM bank): never published.
  public var isLocalOnly: Bool { roles.values.joined().contains(where: Self.isLocalOnly(option:)) }

  /// An option (or kit id) that plays local-only content (`SamplerSource.localOnlyFiles`).
  public static func isLocalOnly(option: String) -> Bool {
    if option.hasPrefix("dls:") { return true }
    if let b = bankCategory(option) { return SamplerSource.localOnlyFiles.contains(b.bank) }
    if let k = DrumKits.parse(option) { return SamplerSource.localOnlyFiles.contains(k.file) }
    return false
  }

  /// The kit id the palette's drums play first (`DrumKits`), or nil (a synth kit).
  public var kit: String? {
    for o in roles["kit"] ?? [] {
      if let k = Self.kitID(option: o), k != "synth" { return k }
    }
    return nil
  }

  /// The kit a track's palette gives its drums, when the palette can play here.
  public static func kit(for palette: String?, dir: String = SamplerSource.soundFontDir) -> String?
  {
    guard let p = named(palette), p.isPlayable(dir: dir) else { return nil }
    return p.kit
  }

  // MARK: labels

  /// A short name for what `option` plays as `role` with `seed` (the sound a category picks,
  /// a GM program's name, a kit's preset).
  public static func label(
    option: String, role: String, seed: Double = 0, dir: String = SamplerSource.soundFontDir
  ) -> String {
    if option == "own" { return role == "kit" ? "synth kit" : "own sound" }
    if option == "synth" { return role == "kit" ? "synth kit" : "synth voice" }
    if let n = synthName(option) {
      return role == "kit" ? "\(n.replacingOccurrences(of: "drums-", with: "")) synth kit" : n
    }
    if let n = pickedName(option) { return n }
    if role == "kit" {
      if let id = kitID(option: option) { return DrumKits.label(id) }
      return option
    }
    if option.hasPrefix("cat:") {
      let c = String(option.dropFirst(4))
      let pool = VoiceCatalog.shared.pool(c)
      if !pool.isEmpty {
        return pool[Int(VoiceCatalog.stableHash("\(seed)|\(role)|\(c)") % UInt64(pool.count))].name
      }
      if let p = VoiceCatalog.shared.gm[c]?.first { return GeneralMIDI.name(p) }
      return c
    }
    if option.hasPrefix("gm:"), let n = Int(option.dropFirst(3)) { return GeneralMIDI.name(n) }
    if option.hasPrefix("dls:"), let n = Int(option.dropFirst(4)) {
      return GeneralMIDI.name(n) + " (Apple)"
    }
    if let b = bankCategory(option) {
      let category = String(option.dropFirst(5))
      if let s = sources(option: option, role: role, seed: seed, dir: dir)?.first,
        case .sf2(_, let prog) = s, let p = MinecraftBank.programs.first(where: { $0.program == prog })
      {
        return p.name
      }
      return b.sounds.first ?? category
    }
    return option
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

  /// Bank files whose sounds a published set may not play (`Session.localOnlySounds`): the
  /// local banks, and Apple's GM bank when a palette or kit names it.
  public static var localOnlyFiles: Set<String> {
    localOnlyBanks.union([gmBank.lastPathComponent])
  }
}

/// General MIDI program names (0-based), as MuseScore_General names them.
public enum GeneralMIDI {
  public static func name(_ program: Int) -> String {
    names.indices.contains(program) ? names[program] : "GM \(program)"
  }

  static let names = [
    "Grand Piano", "Bright Grand Piano", "Electric Grand", "Honky-Tonk Piano",
    "Tine Electric Piano", "FM Electric Piano", "Harpsichord", "Clavinet", "Celesta",
    "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
    "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion",
    "Harmonica", "Bandoneon", "Nylon String Guitar", "Steel String Guitar", "Jazz Guitar",
    "Clean Guitar", "Palm Muted Guitar", "Overdrive Guitar", "Distortion Guitar",
    "Guitar Harmonics", "Acoustic Bass", "Fingered Bass", "Picked Bass", "Fretless Bass",
    "Slap Bass", "Pop Bass", "Synth Bass 1", "Synth Bass 2", "Violin", "Viola", "Cello",
    "Contrabass", "Strings Tremolo", "Strings Pizzicato", "Harp", "Timpani", "Strings Fast",
    "Strings Slow", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs",
    "Synth Voice", "Orchestra Hit", "Trumpet", "Trombone", "Tuba", "Harmon Mute Trumpet",
    "French Horns", "Brass Section", "Synth Brass 1", "Synth Brass 2", "Soprano Sax", "Alto Sax",
    "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet", "Piccolo", "Flute",
    "Recorder", "Pan Flute", "Bottle Chiff", "Shakuhachi", "Whistle", "Ocarina", "Square Lead",
    "Saw Lead", "Calliope Lead", "Chiffer Lead", "Charang", "Solo Vox", "5th Saw Wave",
    "Bass & Lead", "Fantasia", "Warm Pad", "Polysynth", "Space Voice", "Bowed Glass", "Metal Pad",
    "Halo Pad", "Sweep Pad", "Ice Rain", "Soundtrack", "Crystal", "Atmosphere", "Brightness",
    "Goblin", "Echo Drops", "Star Theme", "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba",
    "Bagpipe", "Fiddle", "Shenai", "Tinker Bell", "Agogo", "Steel Drums", "Woodblock",
    "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal", "Fret Noise", "Breath Noise",
    "Sea Shore", "Bird Tweet", "Telephone", "Helicopter", "Applause", "Gun Shot",
  ]
}
