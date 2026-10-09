import Foundation

/// A sampled instrument found on this Mac, sorted into a category.
public struct CatalogSound: Hashable, Sendable {
  /// Display name (`Vintage Strat`).
  public var name: String
  public var category: String
  public var source: SamplerSource
}

/// Voicing: which sampled instrument a net plays. beats' composer still picks its instrument
/// names (so tracks stay beats-identical); each name maps to a category, and a net plays a
/// pick from everything installed in that category, seeded by the track and the net's role.
/// The rules and the name → category map are data (`Resources/voices/categories.json`); the
/// sounds are whatever this Mac has, scanned on first use, so newly installed GarageBand or
/// Logic content joins the pools without code changes.
public final class VoiceCatalog: @unchecked Sendable {
  public static let shared: VoiceCatalog = {
    do {
      return try VoiceCatalog(
        json: .parse(try loadText()), roots: Array(SamplerSource.roots.values))
    } catch { fatalError("voice categories: \(error)") }
  }()

  static func loadText() throws -> String {
    guard
      let url = Bundle.main.url(
        forResource: "categories", withExtension: "json", subdirectory: "voices")
        ?? Bundle.module.url(
          forResource: "categories", withExtension: "json", subdirectory: "voices")
    else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "voices/categories.json"])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  struct Rule {
    var category: String
    var any: [String]
    var not: [String]
  }

  let rules: [Rule]
  /// beats instrument name → category.
  public let categoryOf: [String: String]
  public let gm: [String: [Int]]
  public let keepSynth: Set<String>
  /// category → other categories whose sounds it also draws on.
  let extraPools: [String: [String]]
  /// Installed sounds, grouped by category, each group sorted by name.
  public let sounds: [String: [CatalogSound]]

  public init(json: JSONValue, roots: [String]) throws {
    rules = (json["rules"]?.array ?? []).compactMap { r in
      guard let c = r["category"]?.string else { return nil }
      return Rule(
        category: c, any: (r["any"]?.array ?? []).compactMap(\.string),
        not: (r["not"]?.array ?? []).compactMap(\.string))
    }
    var cat: [String: String] = [:]
    for (k, v) in json["instruments"]?.object?.entries ?? [] { cat[k] = v.string }
    categoryOf = cat
    var g: [String: [Int]] = [:]
    for (k, v) in json["gm"]?.object?.entries ?? [] { g[k] = (v.array ?? []).compactMap(\.int) }
    gm = g
    keepSynth = Set((json["keepSynth"]?.array ?? []).compactMap(\.string))
    var pools: [String: [String]] = [:]
    for (k, v) in json["pools"]?.object?.entries ?? [] {
      pools[k] = (v.array ?? []).compactMap(\.string)
    }
    extraPools = pools
    sounds = Self.scan(roots: roots, rules: rules)
  }

  // MARK: scan

  static func scan(roots: [String], rules: [Rule]) -> [String: [CatalogSound]] {
    var byKey: [String: (sound: CatalogSound, rank: Int)] = [:]
    let fm = FileManager.default
    for root in roots.sorted() {
      guard let walker = fm.enumerator(atPath: root) else { continue }
      while let rel = walker.nextObject() as? String {
        guard rel.hasSuffix(".exs") else { continue }
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let category = categorize(rel, rules: rules), category != "skip" else { continue }
        // Articulation and platform copies of one instrument count once.
        let (stem, rank) = canonical(name)
        let key = category + "|" + stem.lowercased()
        let sound = CatalogSound(
          name: stem, category: category,
          source: .exs((root as NSString).appendingPathComponent(rel)))
        if let have = byKey[key], have.rank <= rank { continue }
        byKey[key] = (sound, rank)
      }
    }
    var out: [String: [CatalogSound]] = [:]
    for (_, v) in byKey { out[v.sound.category, default: []].append(v.sound) }
    for k in out.keys { out[k]!.sort { $0.name < $1.name } }
    return out
  }

  /// The first rule whose words match the path (folders and name), lowercased.
  static func categorize(_ relPath: String, rules: [Rule]) -> String? {
    let text =
      " "
      + (relPath as NSString).deletingPathExtension.lowercased()
      .replacingOccurrences(of: "/", with: " / ")
    for r in rules where r.any.contains(where: { text.contains($0) }) {
      if r.not.contains(where: { text.contains($0) }) { continue }
      return r.category
    }
    return nil
  }

  /// `Trumpets+` / `Trumpets Legato` / `Flute iOS KB` → one stem; lower rank = preferred copy
  /// (the combined `+` patch, then the plain one, then articulations, then iOS copies).
  static func canonical(_ name: String) -> (String, Int) {
    var s = name
    var rank = 1
    if s.hasSuffix("+") {
      s.removeLast()
      rank = 0
    }
    for (suffix, r) in [
      (" iOS KB", 3), (" KB", 3), (" Legato", 2), (" Staccato", 2), (" Crescendo", 2),
    ] where s.hasSuffix(suffix) {
      s.removeLast(suffix.count)
      rank = max(rank, r)
    }
    if s.hasSuffix(" iOS") {
      s.removeLast(4)
      rank = 3
    }
    return (s.trimmingCharacters(in: .whitespaces), rank)
  }

  // MARK: choosing

  /// Every sound a category can play (its own, then any pools it borrows).
  public func pool(_ category: String) -> [CatalogSound] {
    var out = sounds[category] ?? []
    for extra in extraPools[category] ?? [] { out += sounds[extra] ?? [] }
    return out
  }

  /// What a net with `instrument` should try, in order: the seeded pick from its category's
  /// pool, the rest of the pool, then the category's GM programs. nil when the pick is the
  /// synth voice (categories in `keepSynth` offer it) or the instrument has no category.
  public func sources(instrument: String, role: String, seed: Double) -> [SamplerSource]? {
    guard let category = categoryOf[instrument] else { return nil }
    let pool = pool(category)
    let synth = keepSynth.contains(category)
    let count = pool.count + (synth ? 1 : 0)
    var ordered: [SamplerSource] = []
    if count > 0 {
      let pick = Int(Self.stableHash("\(seed)|\(role)|\(category)") % UInt64(count))
      if synth && pick == pool.count { return nil }
      for k in 0..<pool.count { ordered.append(pool[(pick + k) % pool.count].source) }
    }
    ordered += (gm[category] ?? []).map { .gm($0) }
    return ordered.isEmpty ? nil : ordered
  }

  /// FNV-1a: the same on every run (Swift's `Hasher` is seeded per process).
  static func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
      h ^= UInt64(b)
      h = h &* 0x100_0000_01b3
    }
    return h
  }
}
