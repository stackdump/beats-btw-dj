import Foundation

/// A track worth keeping: what reloads it (a composed spec or a raw-`nets` share — the same
/// descriptor a session records) and the title it played under.
public struct Favorite: Equatable, Sendable {
  public var title: String
  public var source: DeckSourceDescriptor
  public var added: Date

  public init(title: String, source: DeckSourceDescriptor, added: Date = Date()) {
    self.title = title
    self.source = source
    self.added = added
  }

  /// The share CID of the track, which names a favorite (nil for sources that aren't nets).
  public var cid: String { source.favoriteCID ?? "" }
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
      guard let s = e["source"], let source = DeckSourceDescriptor(json: s),
        source.favoriteCID != nil
      else { return nil }
      let added = e["added"]?.string.flatMap { Self.iso.date(from: $0) } ?? .distantPast
      return Favorite(title: e["title"]?.string ?? "", source: source, added: added)
    }
  }

  public func contains(cid: String) -> Bool { list().contains { $0.cid == cid } }

  /// Add (or move to the top, retitled) a favorite. Returns the new list.
  @discardableResult
  public func add(_ favorite: Favorite) throws -> [Favorite] {
    guard favorite.source.favoriteCID != nil else { return list() }
    let all = [favorite] + list().filter { $0.cid != favorite.cid }
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
              .object(
                JSONObject([
                  ("title", .string(f.title)), ("added", .string(Self.iso.string(from: f.added))),
                  ("source", f.source.json),
                ]))
            })
        ),
      ]))
    try Data((doc.canonicalJS + "\n").utf8).write(to: file, options: .atomic)
  }

  nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
}
