import Foundation

/// An Apple Loop installed on this Mac (GarageBand / Logic content in `/Library/Audio/Apple
/// Loops`): what the deck's Load panel offers as stock loops. Apple's licence covers playing them
/// in your own music; like the sampled instruments they never enter the repo or the CDN.
public struct StockLoop: Equatable, Sendable, Hashable {
  public var path: String
  public var name: String
  /// The content pack's folder (`01 Hip Hop`, `Jam Pack Remix Tools`…).
  public var pack: String
  /// `Drums`, `Bass`, `Synths`, `Keyboards`, `Guitars`, `Percussion`… ("" when unset).
  public var category: String
  public var subcategory: String
  public var genre: String
  public var beats: Int
  public var seconds: Double
  /// `C`, `F#`… for tonal loops; nil for drums.
  public var key: String?

  /// Tempo from the loop's own beat count over its length (an Apple Loop is cut to whole beats),
  /// snapped to a whole BPM when within 0.1 of one (AAC's frame count runs a few frames short:
  /// 8 beats in 3.9994 s is 120.02).
  public var bpm: Double {
    guard seconds > 0 else { return 0 }
    let raw = Double(beats) * 60 / seconds
    return abs(raw - raw.rounded()) < 0.1 ? raw.rounded() : raw
  }

  public var url: URL { URL(fileURLWithPath: path) }
}

/// Reads an Apple Loop's metadata from its CAF chunks: `info` (genre) and the Apple Loops
/// `uuid` chunk (29819273-B5BF-4AEF-B78D-62D1EF90BB2C: category, subcategory, beat count, key
/// signature…), both a big-endian count then `key\0value\0` pairs; the length from `desc` +
/// `pakt` (frames). Only reads chunk headers and those small chunks, never the audio.
public enum AppleLoopMetadata {
  static let loopsUUID: [UInt8] = [
    0x29, 0x81, 0x92, 0x73, 0xB5, 0xBF, 0x4A, 0xEF, 0xB7, 0x8D, 0x62, 0xD1, 0xEF, 0x90, 0xBB, 0x2C,
  ]

  /// nil when it is not a CAF Apple Loop with a beat count (one-shots have none).
  public static func read(_ url: URL, pack: String) -> StockLoop? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    guard let magic = try? h.read(upToCount: 8), magic.count == 8,
      magic.prefix(4) == Data("caff".utf8)
    else { return nil }
    var fields: [String: String] = [:]
    var sampleRate = 0.0
    var framesPerPacket: UInt32 = 0
    var bytesPerPacket: UInt32 = 0
    var dataBytes: Int64 = 0
    var frames: Int64 = 0
    var packets: Int64 = 0
    var offset: UInt64 = 8
    let end = (try? h.seekToEnd()) ?? 0
    while offset + 12 <= end {
      try? h.seek(toOffset: offset)
      guard let head = try? h.read(upToCount: 12), head.count == 12 else { break }
      let type = String(decoding: head.prefix(4), as: UTF8.self)
      let size = Int64(
        bigEndian: head.subdata(in: 4..<12).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
      let body = offset + 12
      func chunk(max: Int) -> Data? {
        guard size >= 0, size <= max else { return nil }
        return try? h.read(upToCount: Int(size))
      }
      switch type {
      case "desc":
        if let d = chunk(max: 64), d.count >= 32 {
          sampleRate = Double(bitPattern: d.be64(0))
          bytesPerPacket = d.be32(16)
          framesPerPacket = d.be32(20)
        }
      case "pakt":
        if let d = try? h.read(upToCount: 24), d.count >= 24 {
          packets = Int64(bitPattern: d.be64(0))
          frames = Int64(bitPattern: d.be64(8))
        }
      case "data":
        dataBytes = max(0, size - 4)  // after the 4-byte edit count
      case "info":
        if let d = chunk(max: 4096) { pairs(d.dropFirst(4)).forEach { fields[$0] = $1 } }
      case "uuid":
        if let d = chunk(max: 16_384), d.count > 20, Array(d.prefix(16)) == loopsUUID {
          pairs(d.dropFirst(20)).forEach { fields[$0] = $1 }
        }
      default: break
      }
      guard size >= 0 else { break }  // a data chunk of unknown size runs to the end
      offset = body + UInt64(size)
    }
    guard let beats = fields["beat count"].flatMap({ Int($0) }), beats > 0, sampleRate > 0 else {
      return nil
    }
    // compressed audio counts its frames in `pakt`; PCM has none: its data bytes over the
    // bytes per packet (one frame each)
    let total =
      frames > 0
      ? frames
      : packets > 0
        ? packets * Int64(framesPerPacket)
        : bytesPerPacket > 0
          ? dataBytes / Int64(bytesPerPacket) * Int64(max(framesPerPacket, 1)) : 0
    guard total > 0 else { return nil }
    let key = fields["key signature"].flatMap { $0.isEmpty ? nil : $0 }
    return StockLoop(
      path: url.path, name: url.deletingPathExtension().lastPathComponent, pack: pack,
      category: fields["category"] ?? "", subcategory: fields["subcategory"] ?? "",
      genre: fields["genre"] ?? "", beats: beats, seconds: Double(total) / sampleRate, key: key)
  }

  /// `key\0value\0` pairs.
  static func pairs(_ d: Data) -> [(String, String)] {
    let parts = d.split(separator: 0, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    var out: [(String, String)] = []
    var i = 0
    while i + 1 < parts.count {
      if !parts[i].isEmpty { out.append((parts[i], parts[i + 1])) }
      i += 2
    }
    return out
  }
}

extension Data {
  fileprivate func be32(_ at: Int) -> UInt32 {
    subdata(in: (startIndex + at)..<(startIndex + at + 4)).withUnsafeBytes {
      UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
    }
  }
  fileprivate func be64(_ at: Int) -> UInt64 {
    subdata(in: (startIndex + at)..<(startIndex + at + 8)).withUnsafeBytes {
      UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))
    }
  }
}

/// Every stock loop on this Mac, scanned once and kept as an index in Application Support
/// (rescanned when a loops folder changes), so the Load panel opens at once.
public struct StockLoopLibrary: Sendable {
  public var roots: [URL]
  public var indexFile: URL

  public static let defaultRoots = [
    URL(fileURLWithPath: "/Library/Audio/Apple Loops"),
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Audio/Apple Loops"),
  ]

  public init(
    roots: [URL] = StockLoopLibrary.defaultRoots,
    indexFile: URL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/stock-loops.json")
  ) {
    self.roots = roots
    self.indexFile = indexFile
  }

  /// The index, or a fresh scan when there is none or a root's folders changed since.
  public func load() -> [StockLoop] {
    let stamp = rootsStamp()
    if let cached = readIndex(stamp: stamp) { return cached }
    let loops = scan()
    writeIndex(loops, stamp: stamp)
    return loops
  }

  /// Walk the roots; a loop's pack is its folder right under `<root>/<vendor>/`.
  public func scan() -> [StockLoop] {
    var out: [StockLoop] = []
    let fm = FileManager.default
    for root in roots {
      guard
        let walk = fm.enumerator(
          at: root, includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for case let url as URL in walk where url.pathExtension.lowercased() == "caf" {
        // resolve both sides alike: the walk may hand back /private/var for a /var root
        let file = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        let rel = file.hasPrefix(base + "/") ? file.dropFirst(base.count).split(separator: "/") : []
        let pack = rel.count >= 3 ? String(rel[1]) : (rel.first.map(String.init) ?? "")
        if let loop = AppleLoopMetadata.read(url, pack: pack) { out.append(loop) }
      }
    }
    return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Each root's pack folders and their modification dates: installing or removing content
  /// changes it.
  func rootsStamp() -> String {
    let fm = FileManager.default
    var parts: [String] = []
    for root in roots {
      for vendor in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
        let dir = root.appendingPathComponent(vendor)
        for pack in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
          let m =
            (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(pack).path))?[
              .modificationDate] as? Date
          parts.append("\(root.path)/\(vendor)/\(pack)@\(Int(m?.timeIntervalSince1970 ?? 0))")
        }
      }
    }
    return parts.joined(separator: "|")
  }

  private func readIndex(stamp: String) -> [StockLoop]? {
    guard let text = try? String(contentsOf: indexFile, encoding: .utf8),
      let doc = try? JSONValue.parse(text), doc["stamp"]?.string == stamp,
      let rows = doc["loops"]?.array
    else { return nil }
    return rows.compactMap { r in
      guard let path = r["path"]?.string, let beats = r["beats"]?.double,
        let seconds = r["seconds"]?.double
      else { return nil }
      return StockLoop(
        path: path, name: r["name"]?.string ?? "", pack: r["pack"]?.string ?? "",
        category: r["category"]?.string ?? "", subcategory: r["subcategory"]?.string ?? "",
        genre: r["genre"]?.string ?? "", beats: Int(beats), seconds: seconds,
        key: r["key"]?.string)
    }
  }

  private func writeIndex(_ loops: [StockLoop], stamp: String) {
    let rows: [JSONValue] = loops.map { l in
      var o = JSONObject([
        ("path", .string(l.path)), ("name", .string(l.name)), ("pack", .string(l.pack)),
        ("category", .string(l.category)), ("subcategory", .string(l.subcategory)),
        ("genre", .string(l.genre)), ("beats", .number(Double(l.beats))),
        ("seconds", .number(l.seconds)),
      ])
      if let k = l.key { o["key"] = .string(k) }
      return .object(o)
    }
    let doc = JSONValue.object(JSONObject([("stamp", .string(stamp)), ("loops", .array(rows))]))
    try? FileManager.default.createDirectory(
      at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(doc.canonicalJS.utf8).write(to: indexFile, options: .atomic)
  }
}

extension [StockLoop] {
  /// Loops matching `category` ("" = any) and every word of `query` (in name, pack, genre,
  /// subcategory), nearest in tempo to `bpm` first (half and double time count as near), then
  /// by name.
  public func matching(category: String, query: String, near bpm: Double?) -> [StockLoop] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    let hits = filter { l in
      (category.isEmpty || l.category == category)
        && words.allSatisfy { w in
          [l.name, l.pack, l.genre, l.subcategory].contains { $0.lowercased().contains(w) }
        }
    }
    guard let bpm, bpm > 0 else { return hits }
    func distance(_ l: StockLoop) -> Double {
      [0.5, 1, 2].map { abs(l.bpm * $0 - bpm) }.min() ?? .infinity
    }
    return hits.sorted {
      let a = distance($0)
      let b = distance($1)
      return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// The categories present, most loops first.
  public var categories: [String] {
    var count: [String: Int] = [:]
    for l in self where !l.category.isEmpty { count[l.category, default: 0] += 1 }
    return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
  }
}
