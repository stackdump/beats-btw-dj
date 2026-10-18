import Foundation

// Notes on tracks: text pinned to what a deck plays, by its identity, and optionally to a moment
// in it. A net track is named by its share CID — genre, seed and every setting — so a note comes
// back whenever that configuration is played again (the walk revisits a known point); a sample
// by its audio's content id; a clip on the row by its id. Notes are journal events
// (`JournalEvent.noteAdd` …): the journal is their source of truth, `notes.json` the projection
// kept for a fast lookup at launch (`NotesStore`, checked against the newest journal).

/// What a note is about.
public enum NoteTarget: Equatable, Hashable, Sendable {
  /// A net track by its share CID (`DeckSourceDescriptor.favoriteCID`): the same configuration
  /// is the same track.
  case track(cid: String)
  /// A sample by its audio content id (`SampleBuffer.contentID`, or `demo-loop`), with the file it
  /// was loaded from when known (so a starred sample, named "file:" + path, finds it).
  case sample(id: String, file: String?)
  /// A LOOP-record clip on the row, by its id.
  case clip(id: String)

  /// "track:<cid>" | "sample:<content id>" | "clip:<id>": what notes are looked up by.
  public var key: String {
    switch self {
    case .track(let cid): "track:" + cid
    case .sample(let id, _): "sample:" + id
    case .clip(let id): "clip:" + id
    }
  }

  /// Does a favorite name this target? A net's favorite by its CID, a sample's by its file.
  public func matches(_ f: Favorite) -> Bool {
    switch self {
    case .track(let cid): return cid == f.cid
    case .sample(_, let file): return file.map(Favorite.fileCID) == f.cid
    case .clip: return false
    }
  }

  var json: JSONValue {
    switch self {
    case .track(let cid):
      return .object(JSONObject([("kind", .string("track")), ("cid", .string(cid))]))
    case .sample(let id, let file):
      var o = JSONObject([("kind", .string("sample")), ("id", .string(id))])
      if let file { o["file"] = .string(file) }
      return .object(o)
    case .clip(let id):
      return .object(JSONObject([("kind", .string("clip")), ("id", .string(id))]))
    }
  }

  init?(json v: JSONValue) {
    switch v["kind"]?.string {
    case "track":
      guard let c = v["cid"]?.string else { return nil }
      self = .track(cid: c)
    case "sample":
      guard let id = v["id"]?.string else { return nil }
      self = .sample(id: id, file: v["file"]?.string)
    case "clip":
      guard let id = v["id"]?.string else { return nil }
      self = .clip(id: id)
    default: return nil
    }
  }
}

/// A moment within the target: bar and beat (both from 1), and the time into the track.
public struct NotePosition: Equatable, Sendable {
  public var bar: Int
  public var beat: Int
  /// Seconds into the track at its own tempo (a net's ticks at its BPM; a sample's playhead).
  public var seconds: Double?
  public init(bar: Int, beat: Int = 1, seconds: Double? = nil) {
    self.bar = bar
    self.beat = beat
    self.seconds = seconds
  }

  /// "bar 17" or "bar 17.3".
  public var label: String { beat > 1 ? "bar \(bar).\(beat)" : "bar \(bar)" }

  var json: JSONValue {
    var o = JSONObject([("bar", .int(bar)), ("beat", .int(beat))])
    if let seconds { o["seconds"] = .number(seconds) }
    return .object(o)
  }

  init?(json v: JSONValue?) {
    guard let v, let bar = v["bar"]?.int else { return nil }
    self.init(bar: bar, beat: v["beat"]?.int ?? 1, seconds: v["seconds"]?.double)
  }
}

/// A note: text on a target, maybe at a position.
public struct TrackNote: Equatable, Sendable, Identifiable {
  public var id: String
  public var target: NoteTarget
  /// What the target played as when the note was made (for lists; never a key).
  public var title: String
  public var text: String
  public var position: NotePosition?
  public var created: Date
  public var edited: Date?

  public init(
    id: String = TrackNote.newID(), target: NoteTarget, title: String = "", text: String,
    position: NotePosition? = nil, created: Date = JournalTime.now(), edited: Date? = nil
  ) {
    self.id = id
    self.target = target
    self.title = title
    self.text = text
    self.position = position
    self.created = created
    self.edited = edited
  }

  /// A fresh id. Not derived from the configuration: a note is the user's, not the app's
  /// choice, and the id travels in the journal event, so a replay keeps it.
  public static func newID() -> String {
    "n-" + UUID().uuidString.lowercased().prefix(13).replacingOccurrences(of: "-", with: "")
  }

  var json: JSONValue {
    var o = JSONObject([
      ("id", .string(id)), ("target", target.json), ("title", .string(title)),
      ("text", .string(text)), ("created", .string(JournalTime.string(created))),
    ])
    if let position { o["at"] = position.json }
    if let edited { o["edited"] = .string(JournalTime.string(edited)) }
    return .object(o)
  }

  init?(json v: JSONValue) {
    guard let id = v["id"]?.string, let target = v["target"].flatMap(NoteTarget.init(json:)),
      let text = v["text"]?.string
    else { return nil }
    self.init(
      id: id, target: target, title: v["title"]?.string ?? "", text: text,
      position: NotePosition(json: v["at"]),
      created: v["created"]?.string.flatMap(JournalTime.date) ?? .distantPast,
      edited: v["edited"]?.string.flatMap(JournalTime.date))
  }
}

extension [TrackNote] {
  /// The notes on a target (by key), in track order: by position, unplaced first, then by when.
  public func on(_ key: String) -> [TrackNote] {
    filter { $0.target.key == key }.sorted {
      let a = $0.position.map { ($0.bar, $0.beat) } ?? (0, 0)
      let b = $1.position.map { ($0.bar, $0.beat) } ?? (0, 0)
      return a != b ? a < b : $0.created < $1.created
    }
  }

  /// The notes a favorite carries (its track's or its sample file's).
  public func on(_ favorite: Favorite) -> [TrackNote] {
    filter { $0.target.matches(favorite) }
  }

  // The edits as pure functions of the list: what `NotesStore` writes and a replay applies.

  /// Add a note (one with the same id is replaced).
  public func adding(_ note: TrackNote) -> [TrackNote] {
    filter { $0.id != note.id } + [note]
  }

  /// New text for a note (blank text is ignored).
  public func editing(_ id: String, text: String, at: Date) -> [TrackNote] {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return self }
    return map { n in
      var n = n
      if n.id == id {
        n.text = t
        n.edited = at
      }
      return n
    }
  }

  public func deleting(_ id: String) -> [TrackNote] { filter { $0.id != id } }
}

/// The notes on disk (`~/Library/Application Support/dj-vevr-se/notes.json`): the projection of
/// the journal's note events, written after each, so launch needn't read the journals. The
/// journal wins where they differ (`Journal.latestState`).
public struct NotesStore {
  public static let schema = "dj-vevr-se/notes/v1"
  public let file: URL

  public init(file: URL = NotesStore.defaultFile) { self.file = file }

  public static var defaultFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/notes.json")
  }

  /// Every note, in the order made. A missing or unreadable file is none.
  public func list() -> [TrackNote] {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
      let doc = try? JSONValue.parse(text)
    else { return [] }
    return (doc["notes"]?.array ?? []).compactMap(TrackNote.init(json:))
  }

  @discardableResult
  public func add(_ note: TrackNote) throws -> [TrackNote] { try write(list().adding(note)) }

  @discardableResult
  public func edit(_ id: String, text: String, at: Date) throws -> [TrackNote] {
    try write(list().editing(id, text: text, at: at))
  }

  @discardableResult
  public func delete(_ id: String) throws -> [TrackNote] { try write(list().deleting(id)) }

  /// Make the file exactly `all`.
  @discardableResult
  public func replaceAll(_ all: [TrackNote]) throws -> [TrackNote] { try write(all) }

  private func write(_ all: [TrackNote]) throws -> [TrackNote] {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let doc = JSONValue.object(
      JSONObject([("schema", .string(Self.schema)), ("notes", .array(all.map(\.json)))]))
    try Data((doc.canonicalJS + "\n").utf8).write(to: file, options: .atomic)
    return all
  }
}

extension DJEngine {
  /// What a note made on `deck` now is about, and the title it plays under: the deck's net
  /// track, the clip on it, or its sample. Nil for an empty deck.
  public func noteTarget(_ deck: String) -> (target: NoteTarget, title: String)? {
    guard let d = self[deck] else { return nil }
    switch d.mode {
    case .net:
      guard let cid = d.netSource?.favoriteCID else { return nil }
      return (.track(cid: cid), d.title)
    case .sample:
      if let id = d.clipID { return (.clip(id: id), d.title) }
      guard let buffer = d.loaded else { return nil }
      let id = d.isDemo ? DeckSourceDescriptor.demoID : sampleID(buffer)
      return (.sample(id: id, file: d.sourceFile?.path), d.title)
    }
  }

  /// Where `deck` is now within its track, as a note position: a net's bar and beat from its
  /// tick (a sixteenth), a sample's from its beat grid (bar 1 with no grid).
  public func notePosition(_ deck: String) -> NotePosition? {
    guard let d = self[deck] else { return nil }
    switch d.mode {
    case .net:
      let tick = d.wave.tick
      return NotePosition(
        bar: tick / 16 + 1, beat: (tick % 16) / 4 + 1,
        seconds: Double(tick) * 15 / max(d.netBaseBPM, 1))
    case .sample:
      guard d.loaded != nil else { return nil }
      let s = d.beatState
      return NotePosition(
        bar: (s?.bar ?? 0) + 1, beat: (s?.beatInBar ?? 0) + 1, seconds: d.positionSeconds)
    }
  }

  /// The id a loaded buffer is known by: the key `sampleLibrary` holds it under (the smallest,
  /// if several), else its content id.
  func sampleID(_ buffer: SampleBuffer) -> String {
    sampleLibrary.filter { $0.value === buffer }.keys.min() ?? buffer.contentID
  }

  /// A sample deck's file, for the journal: which content id came from which path, so a replay
  /// can find the audio (`JournalEvent.sampleFile`).
  func journalSampleFile(_ deck: Deck, _ url: URL) {
    guard let journal, deck.mode == .sample, let buffer = deck.loaded, !deck.isDemo else { return }
    journal.record(.sampleFile(id: sampleID(buffer), path: url.path))
  }
}
