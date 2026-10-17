import Foundation

/// A track worth keeping: what reloads it (a composed spec or a raw-`nets` share — the same
/// descriptor a session records — or, for a sample, the file it was loaded from), the title it
/// played under, and the user's own tags.
public struct Favorite: Equatable, Sendable {
  public var title: String
  public var source: DeckSourceDescriptor
  public var added: Date
  /// A sample's audio file (an Apple Loop, or a file loaded from disk); nil for nets.
  public var file: String?
  /// The user's labels ("intro", "heavy", "set 1"), in the order they were added.
  public var tags: [String]

  public init(
    title: String, source: DeckSourceDescriptor, added: Date = Date(), file: String? = nil,
    tags: [String] = []
  ) {
    self.title = title
    self.source = source
    self.added = added
    self.file = file
    self.tags = tags
  }

  /// What names a favorite: a net's share CID, a sample's file ("file:" + its path).
  public var cid: String { source.favoriteCID ?? file.map(Self.fileCID) ?? "" }

  public var isSample: Bool { source.favoriteCID == nil && file != nil }

  /// The name of a favorite sample loaded from `path`.
  public static func fileCID(_ path: String) -> String { "file:" + path }
}

extension DeckSourceDescriptor {
  /// What a favorite of this source is named by: the share CID of its envelope payload.
  /// Samples and empty decks can't be favorites (a file can move; the demo loop is always there).
  public var favoriteCID: String? {
    switch self {
    case .net(let spec): return BeatsCID.shareCID(spec.payload)
    case .rawNets(let payload): return BeatsCID.shareCID(payload)
    case .none, .sample: return nil
    }
  }
}

extension Deck {
  /// The net the deck is playing, as a descriptor a favorite (or a session) can reload.
  public var netSource: DeckSourceDescriptor? {
    guard mode == .net else { return nil }
    if let currentSpec { return .net(currentSpec) }
    if let currentRawNets { return .rawNets(payload: currentRawNets) }
    return nil
  }
}

/// Favorites on disk: one JSON file, newest first. Each entry keeps its source in the session
/// encoding, so a favorite reloads exactly the track that was playing (genre, seed, structure,
/// traits and overlays — not just the name, which ~1 in 1849 seeds share).
public struct FavoritesStore {
  public static let schema = "dj-vevr-se/favorites/v1"
  public let file: URL

  public init(file: URL = FavoritesStore.defaultFile) { self.file = file }

  public static var defaultFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/favorites.json")
  }

  /// Every favorite, newest first. A missing file is an empty list; entries that no longer
  /// decode are skipped rather than failing the rest.
  public func list() -> [Favorite] {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
      let doc = try? JSONValue.parse(text)
    else { return [] }
    return (doc["favorites"]?.array ?? []).compactMap { e in
      guard let s = e["source"], let source = DeckSourceDescriptor(json: s) else { return nil }
      let file = e["file"]?.string
      guard source.favoriteCID != nil || file != nil else { return nil }
      let added = e["added"]?.string.flatMap { Self.iso.date(from: $0) } ?? .distantPast
      return Favorite(
        title: e["title"]?.string ?? "", source: source, added: added, file: file,
        tags: e["tags"]?.array?.compactMap(\.string) ?? [])
    }
  }

  public func contains(cid: String) -> Bool { list().contains { $0.cid == cid } }

  /// Add (or move to the top, retitled) a favorite. Returns the new list.
  @discardableResult
  public func add(_ favorite: Favorite) throws -> [Favorite] {
    guard !favorite.cid.isEmpty else { return list() }
    var f = favorite
    // starring it again keeps its tags
    if f.tags.isEmpty, let old = list().first(where: { $0.cid == favorite.cid }) {
      f.tags = old.tags
    }
    let all = [f] + list().filter { $0.cid != favorite.cid }
    try write(all)
    return all
  }

  /// Remove the favorite with this CID. Returns the new list.
  @discardableResult
  public func remove(cid: String) throws -> [Favorite] {
    let all = list().filter { $0.cid != cid }
    try write(all)
    return all
  }

  /// Replace the tags of the favorite with this CID (trimmed, blanks and repeats dropped).
  /// Returns the new list.
  @discardableResult
  public func setTags(cid: String, _ tags: [String]) throws -> [Favorite] {
    var seen = Set<String>()
    let clean = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    let all = list().map { f in
      var f = f
      if f.cid == cid { f.tags = clean }
      return f
    }
    try write(all)
    return all
  }

  private func write(_ all: [Favorite]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let doc = JSONValue.object(
      JSONObject([
        ("schema", .string(Self.schema)),
        (
          "favorites",
          .array(
            all.map { f in
              {
                var o = JSONObject([
                  ("title", .string(f.title)), ("added", .string(Self.iso.string(from: f.added))),
                  ("source", f.source.json),
                ])
                if let file = f.file { o["file"] = .string(file) }
                if !f.tags.isEmpty { o["tags"] = .array(f.tags.map { .string($0) }) }
                return .object(o)
              }()
            })
        ),
      ]))
    try Data((doc.canonicalJS + "\n").utf8).write(to: file, options: .atomic)
  }

  nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
}

extension [Favorite] {
  /// Every tag used, most used first (then A–Z).
  public var allTags: [String] {
    var count: [String: Int] = [:]
    for f in self { for t in f.tags { count[t, default: 0] += 1 } }
    return count.keys.sorted { (count[$0]!, $1) > (count[$1]!, $0) }
  }

  /// The favorites carrying `tag` (all of them for nil).
  public func tagged(_ tag: String?) -> [Favorite] {
    guard let tag else { return self }
    return filter { $0.tags.contains(tag) }
  }
}
