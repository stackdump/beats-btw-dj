import Foundation

// Curated stingers: what a net deck's Hit 1–4 fire. The three things a feature names:
// 1. the poke: the existing Hit buttons / `stinger` binding (`DeckAction.stinger`, `Deck.stinger`),
//    and Wander's stinger move;
// 2. the rule: the four Hits are a pure function of the configuration — the track's genre
//    (family), its sound palette, its seed, its key and tempo, and what is installed here
//    (`StingerCuration.resolve`, over `Resources/stingers/stingers.json`), seeded as
//    `SoundPalette.pick` seeds a role, so the same configuration always gets the same hits;
// 3. the boundary: a one-shot plays on the Hit's stinger net (the net clock), a macro on its own
//    quantise, a loop on the loop row's launch boundary in the deck's time.
//
// Nothing here touches beats' composition: the assignments live on the played project
// (`Project.stingers`, dj-only, never encoded) and a one-shot's sound in `TrackSound.curated`,
// so compose(), the share and its CID stay beats'. `WaveOptions()` (parity) curates nothing.

/// One candidate of the curated table.
public struct StingerCandidate: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    /// A sound on the Hit's stinger net (`option`, SoundPalette grammar).
    case oneShot
    /// A net or master macro by its beats id.
    case macro
    /// A clip launched on the loop row.
    case loop
  }

  /// A loop candidate's source.
  public enum LoopSource: Sendable, Equatable {
    /// An installed Apple Loop (`StockLoop`) matching `category` ("" = any) and every word of
    /// `query`. Local-only.
    case stock(category: String, query: String)
    /// A loop-library clip by id.
    case clip(String)
  }

  public var id: String
  public var kind: Kind
  public var label: String
  /// `oneShot`: the SoundPalette option it plays.
  public var option: String?
  /// `macro`: the NetMacro / MasterMacro id.
  public var macro: String?
  /// `loop`: where the clip comes from.
  public var loop: LoopSource?
  /// Bars it plays for (nil: one bar for a one-shot, the macro's own for a macro, the clip for a
  /// loop).
  public var bars: Int?
  /// `loop`: the longest clip it takes, in beats.
  public var maxBeats: Int
  /// `loop`: how far (relative) a stock loop's tempo may be from the track's (half and double
  /// time count).
  public var tempoTolerance: Double
  /// Genre families (`*` = any).
  public var families: [String]
  /// Palette ids (`*` = any; a track without one plays `studio`).
  public var palettes: [String]
  /// `any` (unpitched) or `tonal` (pitched on the stinger nets' note).
  public var key: String
  /// The track tempos it fits, BPM.
  public var tempo: ClosedRange<Double>

  /// It plays local-only content (an Apple Loop, Apple's GM bank, a local bank).
  public var isLocalOnly: Bool {
    if case .stock? = loop { return true }
    return option.map(SoundPalette.isLocalOnly(option:)) ?? false
  }
}

/// What one Hit fires, as `StingerCuration.resolve` assigned it.
public struct StingerAssignment: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case oneShot, macro, loop
    /// No candidate fits: the Hit's stinger net as before (the composer's instrument, voiced by
    /// the palette's `stinger` pool).
    case fallback
  }

  /// The resolved loop to launch.
  public struct Loop: Sendable, Equatable {
    /// A stock loop's file, or nil for a library clip.
    public var path: String?
    /// A library clip's id, or nil for a stock loop.
    public var clipID: String?
    public var name: String
    public var beats: Int
    public var bpm: Double
  }

  /// 0…3 (Hit 1…4).
  public var slot: Int
  public var kind: Kind
  /// The candidate's id, nil for a fallback.
  public var candidate: String?
  public var label: String
  public var option: String?
  public var macro: String?
  public var bars: Int?
  public var loop: Loop?
  public var localOnly = false

  /// The Hit's stinger net (`hit1`…`hit4`).
  public var netID: String { "hit\(slot + 1)" }

  public static func fallback(_ slot: Int) -> StingerAssignment {
    StingerAssignment(slot: slot, kind: .fallback, label: "stinger")
  }

  /// How the Hit button's help says it.
  public var help: String {
    switch kind {
    case .oneShot: "Hit \(slot + 1): \(label)"
    case .macro: "Hit \(slot + 1): \(label) (macro)"
    case .loop: "Hit \(slot + 1): \(label) — \(loop?.name ?? "loop")"
    case .fallback: "Hit \(slot + 1): the track's stinger"
    }
  }

  /// As `dj_state.decks.X.stingers` shows it.
  public var json: JSONValue {
    var o = JSONObject([
      ("hit", .int(slot + 1)), ("kind", .string(kind.rawValue)), ("label", .string(label)),
    ])
    if let candidate { o["candidate"] = .string(candidate) }
    if let option { o["option"] = .string(option) }
    if let macro { o["macro"] = .string(macro) }
    if let bars { o["bars"] = .int(bars) }
    if let loop {
      var l = JSONObject([
        ("name", .string(loop.name)), ("beats", .int(loop.beats)),
        ("bpm", .number((loop.bpm * 10).rounded() / 10)),
      ])
      if let p = loop.path { l["path"] = .string(p) }
      if let c = loop.clipID { l["clip"] = .string(c) }
      o["loop"] = .object(l)
    }
    if localOnly { o["localOnly"] = .bool(true) }
    return .object(o)
  }
}

/// What the resolver may pick from on this Mac: which options play, which library clips exist,
/// which stock loops are installed. `stamp` names the content (it keys the resolver's cache).
public struct StingerContent: Sendable {
  public var option: @Sendable (String) -> Bool
  public var clips: Set<String>
  public var stock: [StockLoop]
  public var stamp: String

  public init(
    option: @escaping @Sendable (String) -> Bool, clips: Set<String> = [], stock: [StockLoop] = [],
    stamp: String = ""
  ) {
    self.option = option
    self.clips = clips
    self.stock = stock
    self.stamp = stamp
  }

  /// Everything a candidate names is there (tests).
  public static let everything = StingerContent(option: { _ in true }, stamp: "everything")
  /// Nothing installed: every Hit falls back unless a macro fits.
  public static let nothing = StingerContent(option: { _ in false }, stamp: "nothing")

  /// This Mac: the options that play here (`SoundPalette.unavailableReason`), and the stock loops
  /// the app has indexed (`setStock`; none until it has).
  public static var here: StingerContent {
    let stock = shelf.withLock { $0 }
    return StingerContent(
      option: { SoundPalette.unavailableReason(option: $0, role: "stinger") == nil },
      stock: stock, stamp: "here|\(stock.count)")
  }

  private static let shelf = LockedBox<[StockLoop]>([])

  /// The stock loops installed here (the app's index, `StockLoopLibrary.load`).
  public static func setStock(_ loops: [StockLoop]) { shelf.withLock { $0 = loops } }
}

/// The curated table and its resolver.
public enum StingerCuration {
  /// The stinger nets' note (`addStingerTracks`: a euclidean ring on 60).
  public static let stingerNote = 60
  public static let slotCount = 4

  struct Table: Sendable {
    var families: [String: String]
    var slots: [[StingerCandidate.Kind]]
    var candidates: [StingerCandidate]
  }

  static let table: Table = {
    guard let text = try? loadText(), let json = try? JSONValue.parse(text) else {
      return Table(families: [:], slots: [], candidates: [])
    }
    return parse(json)
  }()

  /// Every candidate in the table, in its order.
  public static var candidates: [StingerCandidate] { table.candidates }

  /// The family of a beats genre ("club", "bass"…), "" for one the table doesn't sort.
  public static func family(of genre: String) -> String { table.families[genre] ?? "" }

  /// The kinds each Hit draws from, in order of preference.
  public static var slotKinds: [[StingerCandidate.Kind]] { table.slots }

  static func loadText() throws -> String {
    guard
      let url = Bundle.main.url(
        forResource: "stingers", withExtension: "json", subdirectory: "stingers")
        ?? Bundle.module.url(
          forResource: "stingers", withExtension: "json", subdirectory: "stingers")
    else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "stingers/stingers.json"])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  static func parse(_ json: JSONValue) -> Table {
    var families: [String: String] = [:]
    for (family, genres) in json["families"]?.object?.entries ?? [] {
      for g in genres.array?.compactMap(\.string) ?? [] { families[g] = family }
    }
    let slots: [[StingerCandidate.Kind]] = (json["slots"]?.array ?? []).map {
      ($0.array ?? []).compactMap { $0.string.flatMap(StingerCandidate.Kind.init(rawValue:)) }
    }
    let candidates = (json["candidates"]?.array ?? []).compactMap(parse(candidate:))
    return Table(families: families, slots: slots, candidates: candidates)
  }

  static func parse(candidate v: JSONValue) -> StingerCandidate? {
    guard let id = v["id"]?.string, let kind = v["kind"]?.string.flatMap(StingerCandidate.Kind.init)
    else { return nil }
    var loop: StingerCandidate.LoopSource?
    if let s = v["stock"] {
      loop = .stock(category: s["category"]?.string ?? "", query: s["query"]?.string ?? "")
    } else if let c = v["clip"]?.string {
      loop = .clip(c)
    }
    let t = v["tempo"]?.array?.compactMap(\.double) ?? []
    let lo = t.first ?? 0
    let hi = t.count > 1 ? t[1] : 999
    return StingerCandidate(
      id: id, kind: kind, label: v["label"]?.string ?? id, option: v["option"]?.string,
      macro: v["macro"]?.string, loop: loop, bars: v["bars"]?.int,
      maxBeats: v["maxBeats"]?.int ?? 16, tempoTolerance: v["tempoTolerance"]?.double ?? 0.12,
      families: v["families"]?.array?.compactMap(\.string) ?? ["*"],
      palettes: v["palettes"]?.array?.compactMap(\.string) ?? ["*"],
      key: v["key"]?.string ?? "any", tempo: min(lo, hi)...max(lo, hi))
  }

  /// The track's key, as the key fit reads it.
  public struct Key: Sendable, Equatable {
    public var root: Int
    public var intervals: [Int]
    public init(root: Int, intervals: [Int]) {
      self.root = root
      self.intervals = intervals
    }

    /// A project's root and scale, nil without a root.
    public init?(_ project: Project) {
      guard let r = project.rootNote else { return nil }
      self.init(root: r, intervals: scaleIntervals("\(project.scaleName)Scale"))
    }

    /// The scale holds `note`'s pitch class.
    public func holds(_ note: Int) -> Bool {
      intervals.contains(((note - root) % 12 + 12) % 12)
    }
  }

  /// The four Hits for a configuration: for each Hit, the first kind (`slots`) with an eligible
  /// candidate not already taken by an earlier Hit, drawn from them by `seed` + Hit (candidates
  /// naming the family or palette outright weigh double); a Hit with none falls back. `bpm`:
  /// the track's tempo (nil: the genre's); `key`: its key (nil: tonal candidates fit).
  /// Deterministic: the same arguments give the same assignments.
  public static func resolve(
    genre: String, palette: String?, seed: Double, installed: StingerContent,
    bpm: Double? = nil, key: Key? = nil
  ) -> [StingerAssignment] {
    let paletteID = SoundPalette.playing(palette)?.id ?? "studio"
    let tempo = bpm ?? BeatsTables.shared.genres[genre]?.bpm ?? 120
    let cacheKey =
      "\(genre)|\(paletteID)|\(seed)|\(tempo)|\(key.map { "\($0.root):\($0.intervals)" } ?? "-")|\(installed.stamp)"
    if !installed.stamp.isEmpty, let hit = cache.withLock({ $0[cacheKey] }) { return hit }
    let out = compute(
      genre: genre, paletteID: paletteID, seed: seed, installed: installed, tempo: tempo, key: key)
    if !installed.stamp.isEmpty {
      cache.withLock {
        if $0.count > 256 { $0 = [:] }
        $0[cacheKey] = out
      }
    }
    return out
  }

  private static let cache = LockedBox<[String: [StingerAssignment]]>([:])

  /// Forget resolved Hits (what is installed changed: `SoundPalette.rescan`, `setStock`).
  static func clearCache() { cache.withLock { $0 = [:] } }

  static func compute(
    genre: String, paletteID: String, seed: Double, installed: StingerContent, tempo: Double,
    key: Key?
  ) -> [StingerAssignment] {
    let family = family(of: genre)
    var taken: Set<String> = []
    var out: [StingerAssignment] = []
    for slot in 0..<slotCount {
      let kinds = table.slots.indices.contains(slot) ? table.slots[slot] : []
      var picked: StingerAssignment?
      for kind in kinds {
        var pool: [StingerCandidate] = []
        for c in table.candidates where c.kind == kind && !taken.contains(c.id) {
          guard fits(c, family: family, palette: paletteID, tempo: tempo, key: key),
            available(c, installed: installed, tempo: tempo)
          else { continue }
          let weight =
            (c.families.contains(family) ? 2 : 1) * (c.palettes.contains(paletteID) ? 2 : 1)
          pool += Array(repeating: c, count: weight)
        }
        guard !pool.isEmpty else { continue }
        let h = VoiceCatalog.stableHash("\(seed)|hit\(slot + 1)|stinger:\(genre)|\(paletteID)")
        let c = pool[Int(h % UInt64(pool.count))]
        taken.insert(c.id)
        picked = assignment(c, slot: slot, seed: seed, installed: installed, tempo: tempo)
        break
      }
      out.append(picked ?? .fallback(slot))
    }
    return out
  }

  /// The candidate fits the track: family, palette, tempo, key.
  static func fits(
    _ c: StingerCandidate, family: String, palette: String, tempo: Double, key: Key?
  ) -> Bool {
    guard c.families.contains("*") || (!family.isEmpty && c.families.contains(family)) else {
      return false
    }
    guard c.palettes.contains("*") || c.palettes.contains(palette) else { return false }
    guard c.tempo.contains(tempo) else { return false }
    if c.key == "tonal", let key, !key.holds(stingerNote) { return false }
    return true
  }

  /// What it plays is here (and, for a macro, one this app plays).
  static func available(_ c: StingerCandidate, installed: StingerContent, tempo: Double) -> Bool {
    switch c.kind {
    case .oneShot: return c.option.map(installed.option) ?? false
    case .macro: return c.macro.map(Deck.isMacro(id:)) ?? false
    case .loop: return !loops(c, installed: installed, tempo: tempo).isEmpty
    }
  }

  /// A loop candidate's matches here, nearest the track's tempo first, then by name.
  static func loops(_ c: StingerCandidate, installed: StingerContent, tempo: Double)
    -> [StingerAssignment.Loop]
  {
    switch c.loop {
    case .clip(let id)?:
      return installed.clips.contains(id)
        ? [StingerAssignment.Loop(path: nil, clipID: id, name: c.label, beats: 0, bpm: tempo)] : []
    case .stock(let category, let query)?:
      func ratio(_ l: StockLoop) -> Double {
        [0.5, 1, 2].map { abs(l.bpm * $0 - tempo) / max(tempo, 1) }.min() ?? .infinity
      }
      return installed.stock.matching(category: category, query: query, near: tempo)
        .filter { $0.beats > 0 && $0.beats <= c.maxBeats && ratio($0) <= c.tempoTolerance }
        .map {
          StingerAssignment.Loop(
            path: $0.path, clipID: nil, name: $0.name, beats: $0.beats, bpm: $0.bpm)
        }
    case nil:
      return []
    }
  }

  static func assignment(
    _ c: StingerCandidate, slot: Int, seed: Double, installed: StingerContent, tempo: Double
  ) -> StingerAssignment {
    var a = StingerAssignment(
      slot: slot, kind: .fallback, candidate: c.id, label: c.label, bars: c.bars,
      localOnly: c.isLocalOnly)
    switch c.kind {
    case .oneShot:
      a.kind = .oneShot
      a.option = c.option
    case .macro:
      a.kind = .macro
      a.macro = c.macro
    case .loop:
      a.kind = .loop
      // the nearest few in tempo, one drawn by the seed: a pack's variants all get a turn
      let near = Array(loops(c, installed: installed, tempo: tempo).prefix(8))
      if !near.isEmpty {
        let h = VoiceCatalog.stableHash("\(seed)|hit\(slot + 1)|loop:\(c.id)")
        a.loop = near[Int(h % UInt64(near.count))]
      }
    }
    return a
  }
}

extension Project {
  /// Play `assignments` on this project's Hits: they are kept (`stingers`), each one-shot's
  /// option goes on its stinger net (`TrackSound.curated`; the user's role override still
  /// wins), and the sounds are resolved again (`applySound`). The composition is untouched.
  public mutating func curateStingers(_ assignments: [StingerAssignment], seed: Double) {
    stingers = assignments
    for a in assignments {
      guard var nb = nets[a.netID] else { continue }
      nb.track.sound.curated = a.kind == .oneShot ? a.option : nil
      nets[a.netID] = nb
    }
    applySound(seed: seed)
  }

  /// This project's Hits resolved for `genre` from its palette, key and tempo.
  public func resolvedStingers(genre: String, seed: Double, installed: StingerContent)
    -> [StingerAssignment]
  {
    StingerCuration.resolve(
      genre: genre, palette: palette, seed: seed, installed: installed,
      bpm: tempo > 0 ? tempo : nil, key: StingerCuration.Key(self))
  }
}
