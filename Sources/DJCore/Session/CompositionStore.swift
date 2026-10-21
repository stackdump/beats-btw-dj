import Foundation

// Every composition the MCP plays — `dj_compose`, `dj_inspired`, `dj_import` — is kept on disk
// for reference and replay: `~/Library/Application Support/dj-vevr-se/compositions/`
// (`$DJ_COMPOSITIONS_DIR` overrides), one JSON file per track, named
// `<UTC time>-<title slug>-<share cid[:8]>.json`. A file holds the request that made it (the
// roll you can read: parts, notes, tempo, brief; for an import, the source and its report) and
// the raw-nets envelope that was loaded (`envelope`, a share payload: `dj_compositions` load
// puts it back on a deck, and it is the same text `dj_load_share` takes). Each top-level key
// sits on its own line, so the file greps and diffs. The same envelope (same CID) is kept
// once. Nothing here publishes anything.

public struct CompositionStore {
  public let directory: URL

  public static var defaultDirectory: URL {
    if let d = ProcessInfo.processInfo.environment["DJ_COMPOSITIONS_DIR"], !d.isEmpty {
      return URL(fileURLWithPath: d, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/compositions", isDirectory: true)
  }

  public init(directory: URL = CompositionStore.defaultDirectory) { self.directory = directory }

  public struct Entry: Equatable {
    public var id: String  // the file name without .json
    public var url: URL
    public var name: String
    public var kind: String  // compose | inspired | import
    public var deck: String
    public var saved: String  // ISO-8601, UTC
    public var cid: String
    public var note: String?
    public var tempo: Double?
    /// Set planning: how hard it hits (0…1), its key ("A minor") and its length, when known.
    public var energy: Double?
    public var key: String?
    public var bars: Int?
  }

  public enum StoreError: Error, Equatable, CustomStringConvertible {
    case noMatch(String)
    case ambiguous(String, [String])
    case unreadable(String)
    public var description: String {
      switch self {
      case .noMatch(let q): return "no saved composition matches `\(q)` (see dj_compositions)"
      case .ambiguous(let q, let ids):
        return "`\(q)` matches \(ids.count): " + ids.prefix(6).joined(separator: ", ")
      case .unreadable(let id): return "can't read the saved composition \(id)"
      }
    }
  }

  static func slug(_ s: String) -> String {
    var out = ""
    for ch in s.lowercased() {
      if ch.isLetter || ch.isNumber, ch.isASCII {
        out.append(ch)
      } else if out.last != "-" {
        out.append("-")
      }
    }
    let t = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String((t.isEmpty ? "untitled" : t).prefix(40))
  }

  private static func stamp(_ d: Date, compact: Bool) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = compact ? "yyyyMMdd'T'HHmmss'Z'" : "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: d)
  }

  /// Keep one composition. `request`: what made it (the roll, or the import's source and
  /// report). Returns the file and whether this envelope (its CID) was already kept.
  @discardableResult
  public func save(
    kind: String, deck: String, envelope: JSONValue, request: JSONValue?, now: Date = Date()
  ) throws -> (url: URL, cid: String, existed: Bool) {
    let cid = BeatsCID.shareCID(envelope)
    let short = String(cid.suffix(8))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let old = files().first(where: { $0.lastPathComponent.hasSuffix("-\(short).json") }) {
      return (old, cid, true)
    }
    let name = envelope["name"]?.string ?? "untitled"
    let url = directory.appendingPathComponent(
      "\(Self.stamp(now, compact: true))-\(Self.slug(name))-\(short).json")
    var head = JSONObject([
      ("v", .int(1)), ("saved", .string(Self.stamp(now, compact: false))), ("kind", .string(kind)),
      ("deck", .string(deck)), ("name", .string(name)), ("cid", .string(cid)),
    ])
    if let n = envelope["note"]?.string { head["note"] = .string(n) }
    if let t = envelope["tempo"]?.double { head["tempo"] = .number(t) }
    if let e = request?["energy"]?.double { head["energy"] = .number(min(1, max(0, e))) }
    if let k = request?["key"]?.string, !k.isEmpty { head["key"] = .string(k) }
    if let steps = envelope["nets"]?.object?.entries.first?.value["places"]?.object?.entries.count {
      head["bars"] = .int(steps / 16)
    }
    if let request { head["request"] = request }
    head["envelope"] = envelope
    // one top-level key per line
    let lines = head.entries.map {
      "\(JSONValue.string($0.key).jsStringified):\($0.value.jsStringified)"
    }
    try ("{\n" + lines.joined(separator: ",\n") + "\n}\n").write(
      to: url, atomically: true, encoding: .utf8)
    return (url, cid, false)
  }

  /// The saved files, newest first. Built from `directory` as given (listing a directory can
  /// return /private/var for /var), so the URLs `save` and `list` give are the same.
  func files() -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted(by: >).map {
      directory.appendingPathComponent($0)
    }
  }

  /// Newest first.
  public func list() -> [Entry] {
    files().compactMap { url in
      guard let data = FileManager.default.contents(atPath: url.path),
        let doc = try? JSONValue.parse(String(decoding: data, as: UTF8.self))
      else { return nil }
      return Entry(
        id: url.deletingPathExtension().lastPathComponent, url: url,
        name: doc["name"]?.string ?? "", kind: doc["kind"]?.string ?? "",
        deck: doc["deck"]?.string ?? "", saved: doc["saved"]?.string ?? "",
        cid: doc["cid"]?.string ?? "", note: doc["note"]?.string, tempo: doc["tempo"]?.double,
        energy: doc["energy"]?.double, key: doc["key"]?.string, bars: doc["bars"]?.int)
    }
  }

  /// The envelope of one saved composition: `query` is the file id, or any part of it (a title
  /// word, a CID tail) that picks exactly one.
  public func envelope(matching query: String) throws -> (entry: Entry, envelope: JSONValue) {
    let all = list()
    let q = query.lowercased()
    let hits =
      all.filter { $0.id.lowercased() == q }.isEmpty
      ? all.filter { $0.id.lowercased().contains(q) } : all.filter { $0.id.lowercased() == q }
    guard !hits.isEmpty else { throw StoreError.noMatch(query) }
    guard hits.count == 1 else { throw StoreError.ambiguous(query, hits.map(\.id)) }
    guard let data = FileManager.default.contents(atPath: hits[0].url.path),
      let doc = try? JSONValue.parse(String(decoding: data, as: UTF8.self)),
      let env = doc["envelope"], env.object != nil
    else { throw StoreError.unreadable(hits[0].id) }
    return (hits[0], env)
  }
}
