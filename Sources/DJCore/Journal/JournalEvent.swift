import Foundation

// One line of the journal: what happened, when (the engine frame — the timebase replays use —
// and the wall clock, metadata only), in order. See Journal.swift.

/// Wall-clock stamps in the journal: ISO 8601 UTC with milliseconds. Metadata only (Derivation
/// rule): nothing the engine decides ever reads them back.
public enum JournalTime {
  nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let lock = NSLock()

  /// Now, to the millisecond (so a stamp survives its own encoding).
  public static func now() -> Date { rounded(Date()) }

  public static func rounded(_ d: Date) -> Date {
    Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000)
  }

  public static func string(_ d: Date) -> String { lock.withLock { formatter.string(from: d) } }
  public static func date(_ s: String) -> Date? { lock.withLock { formatter.date(from: s) } }
}

/// What the journal records. `action` and `midi` are the performance (every input
/// `DJEngine.perform` and the `ControllerRouter` see, the same as a session's events); the rest
/// are the state changes that are not pokes — the persistent stores and the notes — so a replay
/// rebuilds them too.
public enum JournalEvent: Equatable, Sendable {
  /// The full rebuildable state (`JournalState`): every file starts with one; mid-file ones
  /// (`Journal.checkpoint`) add the playheads and leave the stores out.
  case checkpoint(JournalState)
  case action(DeckAction)
  case midi(port: String, bytes: [UInt8])
  /// The sample with this content id was loaded from `path` (where a replay finds its audio).
  case sampleFile(id: String, path: String)
  /// A clip removed in an earlier run came back from the loop library's `removed/` into this
  /// run's removed list, at its old place (a `clipRestore` follows).
  case libraryRestore(id: String, index: Int)
  case favoriteAdd(Favorite)
  case favoriteRemove(cid: String)
  case favoriteTags(cid: String, tags: [String])
  /// A crate made (empty crates are kept by name; a crate is a favorites tag).
  case crateAdd(name: String)
  case crateDelete(name: String)
  case variationSave(instrument: String, variation: VoiceVariation)
  case variationRename(instrument: String, name: String, to: String)
  case variationDelete(instrument: String, name: String)
  case noteAdd(TrackNote)
  case noteEdit(id: String, text: String, at: Date)
  case noteDelete(id: String)
  /// A milestone with no state of its own: "app.start", "session.start", "session.saved <cid>".
  case mark(String)

  /// The `k` field of the line.
  public var kind: String {
    switch self {
    case .checkpoint: "checkpoint"
    case .action: "act"
    case .midi: "midi"
    case .sampleFile: "sample.file"
    case .libraryRestore: "library.restore"
    case .favoriteAdd: "favorite.add"
    case .favoriteRemove: "favorite.remove"
    case .favoriteTags: "favorite.tags"
    case .crateAdd: "crate.add"
    case .crateDelete: "crate.delete"
    case .variationSave: "variation.save"
    case .variationRename: "variation.rename"
    case .variationDelete: "variation.delete"
    case .noteAdd: "note.add"
    case .noteEdit: "note.edit"
    case .noteDelete: "note.delete"
    case .mark: "mark"
    }
  }

  public var isNote: Bool {
    switch self {
    case .noteAdd, .noteEdit, .noteDelete: true
    default: false
    }
  }

  /// The event's own fields (beside `v`, `seq`, `t`, `f`, `k`).
  var fields: [(String, JSONValue)] {
    switch self {
    case .checkpoint(let s): return [("state", s.json)]
    case .action(let a): return [("a", a.json)]
    case .midi(let port, let bytes):
      return [("p", .string(port)), ("b", .array(bytes.map { .int(Int($0)) }))]
    case .sampleFile(let id, let path): return [("id", .string(id)), ("path", .string(path))]
    case .libraryRestore(let id, let index): return [("id", .string(id)), ("index", .int(index))]
    case .favoriteAdd(let f): return [("favorite", f.json)]
    case .favoriteRemove(let cid): return [("cid", .string(cid))]
    case .favoriteTags(let cid, let tags):
      return [("cid", .string(cid)), ("tags", .array(tags.map { .string($0) }))]
    case .crateAdd(let name), .crateDelete(let name): return [("name", .string(name))]
    case .variationSave(let instrument, let v):
      return [("instrument", .string(instrument)), ("variation", v.json)]
    case .variationRename(let instrument, let name, let to):
      return [("instrument", .string(instrument)), ("name", .string(name)), ("to", .string(to))]
    case .variationDelete(let instrument, let name):
      return [("instrument", .string(instrument)), ("name", .string(name))]
    case .noteAdd(let n): return [("note", n.json)]
    case .noteEdit(let id, let text, let at):
      return [
        ("id", .string(id)), ("text", .string(text)), ("at", .string(JournalTime.string(at))),
      ]
    case .noteDelete(let id): return [("id", .string(id))]
    case .mark(let text): return [("text", .string(text))]
    }
  }

  /// The event of a line, by its `k`; nil for a kind this build doesn't know (a reader skips it).
  init?(kind: String, _ v: JSONValue) {
    switch kind {
    case "checkpoint":
      guard let s = v["state"].flatMap(JournalState.init(json:)) else { return nil }
      self = .checkpoint(s)
    case "act":
      guard let a = v["a"].flatMap(DeckAction.init(json:)) else { return nil }
      self = .action(a)
    case "midi":
      guard let p = v["p"]?.string, let b = v["b"]?.ints else { return nil }
      self = .midi(port: p, bytes: b.map { UInt8(clamping: $0) })
    case "sample.file":
      guard let id = v["id"]?.string, let path = v["path"]?.string else { return nil }
      self = .sampleFile(id: id, path: path)
    case "library.restore":
      guard let id = v["id"]?.string else { return nil }
      self = .libraryRestore(id: id, index: v["index"]?.int ?? 0)
    case "favorite.add":
      guard let f = v["favorite"].flatMap(Favorite.init(json:)) else { return nil }
      self = .favoriteAdd(f)
    case "favorite.remove":
      guard let cid = v["cid"]?.string else { return nil }
      self = .favoriteRemove(cid: cid)
    case "favorite.tags":
      guard let cid = v["cid"]?.string else { return nil }
      self = .favoriteTags(cid: cid, tags: v["tags"]?.array?.compactMap(\.string) ?? [])
    case "crate.add", "crate.delete":
      guard let name = v["name"]?.string else { return nil }
      self = kind == "crate.add" ? .crateAdd(name: name) : .crateDelete(name: name)
    case "variation.save":
      guard let i = v["instrument"]?.string,
        let variation = v["variation"].flatMap(VoiceVariation.init(json:))
      else { return nil }
      self = .variationSave(instrument: i, variation: variation)
    case "variation.rename":
      guard let i = v["instrument"]?.string, let n = v["name"]?.string, let to = v["to"]?.string
      else { return nil }
      self = .variationRename(instrument: i, name: n, to: to)
    case "variation.delete":
      guard let i = v["instrument"]?.string, let n = v["name"]?.string else { return nil }
      self = .variationDelete(instrument: i, name: n)
    case "note.add":
      guard let n = v["note"].flatMap(TrackNote.init(json:)) else { return nil }
      self = .noteAdd(n)
    case "note.edit":
      guard let id = v["id"]?.string, let text = v["text"]?.string,
        let at = v["at"]?.string.flatMap(JournalTime.date)
      else { return nil }
      self = .noteEdit(id: id, text: text, at: at)
    case "note.delete":
      guard let id = v["id"]?.string else { return nil }
      self = .noteDelete(id: id)
    case "mark":
      guard let t = v["text"]?.string else { return nil }
      self = .mark(t)
    default: return nil
    }
  }

  /// One line for people (`djctl journal show`, the History panel).
  public var summary: String {
    switch self {
    case .checkpoint(let s):
      let decks = s.decks.keys.sorted().map { "\($0): \(s.decks[$0]!.source.summary)" }
      return (s.hasStores ? "checkpoint · " : "checkpoint (mid) · ")
        + (decks + ["\(s.clips.count) clips"]).joined(separator: " · ")
    case .action(let a): return a.summary
    case .midi(let port, let bytes):
      return "midi \(port) " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    case .sampleFile(let id, let path): return "sample \(id.prefix(10))… ← \(path)"
    case .libraryRestore(let id, _): return "loop \(id.prefix(10))… back from the library"
    case .favoriteAdd(let f): return "★ \(f.title)"
    case .favoriteRemove(let cid): return "☆ unstarred \(cid.prefix(14))…"
    case .favoriteTags(let cid, let tags):
      return "tags \(cid.prefix(14))… = "
        + (tags.isEmpty ? "none" : tags.map { "#" + $0 }.joined(separator: " "))
    case .crateAdd(let name): return "crate + \(name)"
    case .crateDelete(let name): return "crate − \(name)"
    case .variationSave(let i, let v): return "variation saved \(v.label(i))"
    case .variationRename(let i, let n, let to): return "variation \(i) · \(n) → \(to)"
    case .variationDelete(let i, let n): return "variation deleted \(i) · \(n)"
    case .noteAdd(let n):
      return "✎ \(n.title.isEmpty ? n.target.key : n.title)"
        + (n.position.map { " @ \($0.label)" } ?? "") + ": \(n.text)"
    case .noteEdit(_, let text, _): return "✎ edited: \(text)"
    case .noteDelete(let id): return "✎ deleted \(id)"
    case .mark(let t): return "— \(t)"
    }
  }

  /// Consecutive events with the same key (a fader moved) fold into one row in a list.
  public var foldKey: String? {
    switch self {
    case .action(.param(let deck, let name, _)): "\(deck).\(name)"
    case .action(.crossfader): "crossfader"
    case .action(.master): "master"
    case .action(.clipGain(let id, _)): "gain.\(id)"
    case .action(.clipFx(let id, _)): "fx.\(id)"
    case .action(.voiceTweak(let deck, let ch, _)): "voice.\(deck).\(ch)"
    case .midi(let port, let bytes) where bytes.count == 3 && bytes[0] & 0xF0 == 0xB0:
      "cc.\(port).\(bytes[0]).\(bytes[1])"  // a knob turned
    default: nil
    }
  }
}

extension DeckSourceDescriptor {
  /// "net techno #42 (z4EBG…)", "sample demo loop", "empty".
  public var summary: String {
    switch self {
    case .none: return "empty"
    case .net(let s): return "net \(s.genre) #\(jsNumberString(s.seed))"
    case .rawNets(let p): return "share \(BeatsCID.shareCID(p).prefix(12))…"
    case .sample(let id, let title, _):
      return "sample " + (title.isEmpty ? String(id.prefix(10)) : title)
    }
  }
}

extension DeckAction {
  /// One line for people: "A play", "B volume 0.42", "A load net techno #42".
  public var summary: String {
    let j = json
    let op = j["op"]?.string ?? "?"
    switch self {
    case .param(let deck, let name, let value):
      return "\(deck) \(name) \(String(format: "%.2f", value))"
    case .crossfader(let v): return "crossfader \(String(format: "%.2f", v))"
    case .master(let v): return "master \(String(format: "%.2f", v))"
    case .play(let deck, let on): return "\(deck) \(on ? "play" : "pause")"
    case .load(let deck, let source): return "\(deck) load \(source.summary)"
    case .queueNext(let deck, let spec):
      return "\(deck) next up \(DeckSourceDescriptor.net(spec).summary)"
    case .lock(let key, let on): return "\(on ? "lock" : "unlock") \(key)"
    default:
      // the rest: the op, the deck, then the other fields
      var parts: [String] = []
      if let deck = j["deck"]?.string { parts.append(deck) }
      parts.append(op)
      for (k, v) in j.object?.entries ?? [] where k != "op" && k != "deck" {
        switch v {
        case .string(let s): parts.append("\(k)=\(s.count > 16 ? String(s.prefix(12)) + "…" : s)")
        case .number(let n): parts.append("\(k)=\(jsNumberString(n))")
        case .bool(let b): parts.append("\(k)=\(b)")
        case .null: continue
        default: parts.append("\(k)=…")
        }
      }
      return parts.joined(separator: " ")
    }
  }
}

/// One line of the journal.
public struct JournalEntry: Equatable, Sendable, Identifiable {
  public static let version = 1
  /// Line number in its file, from 0 (the checkpoint).
  public var seq: Int
  /// Wall clock when it was recorded: metadata only.
  public var time: Date
  /// Engine frame it was applied on (`DJEngine.frame`): the replay timebase.
  public var frame: Int
  public var event: JournalEvent
  public var id: Int { seq }

  public init(seq: Int, time: Date, frame: Int, event: JournalEvent) {
    self.seq = seq
    self.time = time
    self.frame = frame
    self.event = event
  }

  public var json: JSONValue {
    .object(
      JSONObject(
        [
          ("v", .int(Self.version)), ("seq", .int(seq)), ("t", .string(JournalTime.string(time))),
          ("f", .int(frame)), ("k", .string(event.kind)),
        ] + event.fields))
  }

  /// The line's text (canonical JSON: sorted keys, no newline).
  public var line: String { json.canonicalJS }

  public init?(json v: JSONValue) {
    guard let seq = v["seq"]?.int, let frame = v["f"]?.int, let kind = v["k"]?.string,
      let event = JournalEvent(kind: kind, v)
    else { return nil }
    self.init(
      seq: seq, time: v["t"]?.string.flatMap(JournalTime.date) ?? .distantPast, frame: frame,
      event: event)
  }

  public init?(line: String) {
    guard let v = try? JSONValue.parse(line) else { return nil }
    self.init(json: v)
  }
}
