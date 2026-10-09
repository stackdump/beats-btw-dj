// A few finished rasters, kept by song (scope.js recomputes only on a project load; a deck that
// leads the master, loses the lead and gets it back is the same song and must not be ticked
// again).
//
// The key is the deck and its `trackSerial`: a process-unique number per loaded track, so equal
// keys are the same project and a cached scene never describes a different song. The cache is
// least-recently-used with a small capacity: a master has two decks, and a raster can hold a few
// megabytes of events.

/// Which song a raster belongs to.
public struct RasterSongKey: Hashable, Sendable {
  public var deck: String
  public var serial: Int32

  public init(deck: String, serial: Int32) {
    self.deck = deck
    self.serial = serial
  }
}

public struct RasterSceneCache: Sendable {
  /// Scenes kept: both decks of a master, and one spare for a track that was just replaced.
  public static let defaultCapacity = 3

  public let capacity: Int
  /// Least recently used first.
  private var entries: [(key: RasterSongKey, scene: RasterScene)] = []

  public init(capacity: Int = defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  public var count: Int { entries.count }
  /// The keys, least recently used first.
  public var keys: [RasterSongKey] { entries.map(\.key) }

  /// The scene of `key`, and the scene becomes the most recently used.
  public mutating func scene(for key: RasterSongKey) -> RasterScene? {
    guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
    let entry = entries.remove(at: i)
    entries.append(entry)
    return entry.scene
  }

  /// Keep `scene` as the most recently used; the least recently used one goes when the cache is
  /// over capacity.
  public mutating func insert(_ scene: RasterScene, for key: RasterSongKey) {
    entries.removeAll { $0.key == key }
    entries.append((key, scene))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
  }

  public mutating func removeAll() { entries.removeAll() }
}
