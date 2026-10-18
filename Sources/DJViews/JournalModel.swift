import DJCore
import Foundation

// The app's side of the journal (DJCore/Journal): open one per run once the engine stands where
// the last run left it, keep the History panel's lines and each deck's note key fresh, and the
// notes themselves — journal events first, `notes.json` (their projection) after.

extension AppModel {
  /// What the stores hold now, for a checkpoint.
  var storeSnapshot: JournalStoreState {
    JournalStoreState(
      favorites: favoritesStore.list(), crates: defaults.stringArray(forKey: Self.cratesKey) ?? [],
      variations: variationStore.all(), notes: notes)
  }

  /// Replace every store wholesale (an import, a restore): journaled first (the source of
  /// truth), then the files — favorites, variations, notes — the crates default, and what the
  /// panels show. A file that fails to write still shows the new value, and `status` says so.
  func replaceStores(_ s: JournalStoreState) {
    journal?.record(.storesReplace(s))
    var failed: [String] = []
    do { try favoritesStore.replaceAll(s.favorites) } catch { failed.append("favorites: \(error)") }
    do { try variationStore.replaceAll(s.variations) } catch {
      failed.append("variations: \(error)")
    }
    do { _ = try notesStore.replaceAll(s.notes) } catch { failed.append("notes: \(error)") }
    defaults.set(s.crates, forKey: Self.cratesKey)
    favorites = s.favorites
    variations = s.variations
    notes = s.notes
    if !failed.isEmpty { status = "stores: " + failed.joined(separator: "; ") }
  }

  /// Start this run's journal in `dir` (its checkpoint is the state now). The newest journal is
  /// the notes' source of truth: if `notes.json` disagrees with it (a crash between the two
  /// writes, a file restored from a backup), the journal's notes win.
  func openJournal(_ dj: DJEngine, in dir: URL) {
    if let last = Journal.latestStores(in: dir), last.notes != notes {
      notes = (try? notesStore.replaceAll(last.notes)) ?? last.notes
    }
    do {
      journal = try Journal(engine: dj, directory: dir) { [weak self] in
        self?.storeSnapshot ?? JournalStoreState()
      }
      journal?.record(.mark("app.start \(BuildInfo.current.version)"))
    } catch {
      status = "journal: \(error)"
    }
  }

  func closeJournal() {
    journal?.record(.mark("app.stop"))
    journal?.close()
  }

  /// Per poll: a mid-file checkpoint when one is due (`Journal.checkpointIfDue`: a minute of
  /// engine time or 2000 entries), the History panel's lines when the journal moved, each deck's
  /// note key when its track changed.
  func pollJournal(_ dj: DJEngine) {
    journal?.checkpointIfDue()
    if let j = journal, j.lastSeq != journalSeen {
      journalSeen = j.lastSeq
      journalEntries = j.recent
    }
    var keys: [String: String] = [:]
    for name in dj.decks.keys {
      // the poll already hashed a net's CID (sourceCID); a sample's id is a lookup
      if let cid = decks[name]?.sourceCID, decks[name]?.isNet == true {
        keys[name] = NoteTarget.track(cid: cid).key
      } else if let t = dj.noteTarget(name) {
        keys[name] = t.target.key
      }
    }
    if keys != deckNoteKeys { deckNoteKeys = keys }
  }

  // MARK: rewind

  /// Put the app back where the journal stood at `seq`: the file is flushed and replayed (off the
  /// main actor, from the nearest checkpoint) to `seq`; the engine is reset to that state
  /// (`DJEngine.reset(to:clip:)`) and the stores replaced (`replaceStores`, journaled), then the
  /// journal gets a `rewind <seq>` mark and a checkpoint with playheads — a replay past it starts
  /// there. The journal stays append-only: everything after `seq` is still in it, line 0 too.
  /// A live engine's replay need not be what was heard (renders, takes): `status` says so.
  @discardableResult
  func rewindJournal(toSeq seq: Int) async throws -> JournalRewind {
    guard let dj = engine, let j = journal else { throw JournalRewindError.noJournal }
    let last = j.lastSeq
    guard (0...last).contains(seq) else { throw JournalRewindError.badSeq(seq, last: last) }
    j.flush()
    let file = j.file
    // the clips' audio: the row's and the removed ones this run has, then the library on disk
    var have: [String: LoopClip] = [:]
    for c in dj.clips { have[c.id] = c }
    for r in dj.removedClips where have[r.clip.id] == nil { have[r.clip.id] = r.clip }
    let known = have
    let samples = dj.sampleLibrary
    let store = takeStore
    let queue = saveQueue
    let sr = dj.sampleRate
    status = "rewinding to seq \(seq)…"
    let result = try await Task.detached(priority: .userInitiated) {
      let c = try Journal.read(file)
      return try Journal.replay(
        c, toSeq: seq, playheads: true, samples: { samples[$0] },
        clips: { id in
          known[id] ?? store.flatMap { s in queue.sync { s.removedClip(id, sampleRate: sr) } }
        })
    }.value
    // the app moved on while it replayed (stopped, another journal)
    guard engine === dj, journal === j else { throw JournalRewindError.superseded }
    let warnings =
      result.warnings
      + (await dj.reset(to: result.state) { id in
        known[id] ?? store.flatMap { s in queue.sync { s.removedClip(id, sampleRate: sr) } }
      })
    replaceStores(result.stores)
    lockedButtons = dj.lockedActions
    defaults.set(lockedButtons.sorted(), forKey: Self.lockedButtonsKey)
    j.record(.mark(Journal.rewindMark(seq)))
    let cp = j.checkpoint(playheads: true)
    poll()
    var line = "rewound to seq \(seq)"
    if !warnings.isEmpty { line += " (\(warnings.count) warning\(warnings.count == 1 ? "" : "s"))" }
    if !dj.deterministic { line += " — replayed, so it may differ from what played live" }
    status = line
    return JournalRewind(
      seq: seq, startSeq: result.startSeq, checkpointSeq: cp?.seq ?? j.lastSeq,
      warnings: warnings)
  }

  // MARK: notes

  /// The notes on what `deck` plays now, in track order.
  func deckNotes(_ deck: String) -> [TrackNote] {
    deckNoteKeys[deck].map { notes.on($0) } ?? []
  }

  /// The notes on a clip of the row.
  func clipNotes(_ id: String) -> [TrackNote] { notes.on(NoteTarget.clip(id: id).key) }

  /// The notes a favorite carries (its track's, or its sample file's).
  func favoriteNotes(_ f: Favorite) -> [TrackNote] { notes.on(f) }

  /// A note on what `deck` plays, at the bar it is on now. Nil if the deck holds nothing.
  @discardableResult
  func addNote(_ deck: String, _ text: String) -> TrackNote? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, let dj = engine, let (target, title) = dj.noteTarget(deck) else { return nil }
    return add(TrackNote(target: target, title: title, text: t, position: dj.notePosition(deck)))
  }

  /// A note on a clip of the row (no position: the clip is short).
  @discardableResult
  func addClipNote(_ id: String, _ text: String) -> TrackNote? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, let c = engine?.clip(id) else { return nil }
    return add(TrackNote(target: .clip(id: id), title: c.title, text: t))
  }

  private func add(_ n: TrackNote) -> TrackNote {
    journal?.record(.noteAdd(n))  // the journal first: it is the source of truth
    notes = (try? notesStore.add(n)) ?? notes.adding(n)
    return n
  }

  func editNote(_ id: String, _ text: String) {
    let at = JournalTime.now()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    journal?.record(.noteEdit(id: id, text: text, at: at))
    notes = (try? notesStore.edit(id, text: text, at: at)) ?? notes.editing(id, text: text, at: at)
  }

  func deleteNote(_ id: String) {
    journal?.record(.noteDelete(id: id))
    notes = (try? notesStore.delete(id)) ?? notes.deleting(id)
  }

  /// The one-tap notes (no keyboard): what a DJ marks most.
  static let quickNotes = ["drop", "build", "break", "mix in", "mix out", "★"]
}

/// What `AppModel.rewindJournal` did.
struct JournalRewind: Equatable {
  /// The sequence number it went back to.
  var seq: Int
  /// The checkpoint its replay started from.
  var startSeq: Int
  /// The checkpoint it wrote (a replay past the rewind starts there).
  var checkpointSeq: Int
  /// Clips or samples whose audio is gone.
  var warnings: [String]
}

enum JournalRewindError: Error, Equatable, CustomStringConvertible {
  case noJournal
  case badSeq(Int, last: Int)
  case superseded
  var description: String {
    switch self {
    case .noJournal: "no journal is open"
    case .badSeq(let s, let last): "no seq \(s) in this journal (0…\(last))"
    case .superseded: "the app moved on during the rewind"
    }
  }
}

// MARK: control socket / MCP (dj_notes, dj_journal)

extension AppModel {
  func noteJSON(_ n: TrackNote) -> JSONValue {
    var o = JSONObject([
      ("id", .string(n.id)), ("target", .string(n.target.key)), ("title", .string(n.title)),
      ("text", .string(n.text)), ("created", .string(JournalTime.string(n.created))),
    ])
    if let p = n.position {
      o["bar"] = .int(p.bar)
      o["beat"] = .int(p.beat)
      if let s = p.seconds { o["seconds"] = .number(s) }
    }
    if let e = n.edited { o["edited"] = .string(JournalTime.string(e)) }
    return .object(o)
  }

  func controlNotes(_ p: JSONValue) throws -> JSONValue {
    poll()
    let deck = p["deck"]?.string
    if let deck, engine?[deck] == nil { throw ControlRequestError.bad("no deck \(deck)") }
    switch p["action"]?.string ?? "list" {
    case "list":
      let list: [TrackNote]
      if let deck {
        list = deckNotes(deck)
      } else if let key = p["target"]?.string {
        list = notes.on(key)
      } else if let clip = p["clip"]?.string {
        list = clipNotes(clip)
      } else {
        list = notes
      }
      var o = JSONObject([("notes", .array(list.map(noteJSON)))])
      if let deck { o["target"] = deckNoteKeys[deck].map { .string($0) } ?? .null }
      return .object(o)
    case "add":
      let text = p["text"]?.string ?? ""
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ControlRequestError.bad("`text` is required")
      }
      let added: TrackNote?
      if let clip = p["clip"]?.string {
        added = addClipNote(clip, text)
        if added == nil { throw ControlRequestError.bad("no clip \(clip) on the row") }
      } else if let deck {
        added = addNote(deck, text)
        if added == nil { throw ControlRequestError.bad("deck \(deck) holds nothing to note") }
      } else {
        throw ControlRequestError.bad("`deck` or `clip` is required")
      }
      return added.map(noteJSON) ?? .null
    case "edit":
      guard let id = p["id"]?.string, notes.contains(where: { $0.id == id }) else {
        throw ControlRequestError.bad("no note with that `id` (see action list)")
      }
      editNote(id, p["text"]?.string ?? "")
      return notes.first { $0.id == id }.map(noteJSON) ?? .null
    case "delete":
      guard let id = p["id"]?.string, notes.contains(where: { $0.id == id }) else {
        throw ControlRequestError.bad("no note with that `id` (see action list)")
      }
      deleteNote(id)
      return .object(JSONObject([("deleted", .string(id))]))
    case let other:
      throw ControlRequestError.bad("action must be list | add | edit | delete, not \(other)")
    }
  }

  func controlJournal(_ p: JSONValue) async throws -> JSONValue {
    switch p["action"]?.string ?? "list" {
    case "list": break
    case "rewind":
      guard let seq = p["seq"]?.int else { throw ControlRequestError.bad("`seq` is required") }
      let r: JournalRewind
      do { r = try await rewindJournal(toSeq: seq) } catch let e as JournalRewindError {
        throw ControlRequestError.bad(e.description)
      }
      return .object(
        JSONObject([
          ("rewound", .int(r.seq)), ("startSeq", .int(r.startSeq)),
          ("checkpoint", .int(r.checkpointSeq)), ("lastSeq", .int(journal?.lastSeq ?? -1)),
          ("warnings", .array(r.warnings.map { .string($0) })), ("status", .string(status)),
        ]))
    case let other:
      throw ControlRequestError.bad("action must be list | rewind, not \(other)")
    }
    let limit = min(Journal.recentCapacity, max(1, p["limit"]?.int ?? 50))
    let kind = p["kind"]?.string
    let entries = (journal?.recent ?? []).filter { e in
      kind.map { e.event.kind == $0 || ($0.hasSuffix(".") && e.event.kind.hasPrefix($0)) } ?? true
    }
    return .object(
      JSONObject([
        ("file", journal.map { .string($0.file.path) } ?? .null),
        ("lastSeq", .int(journal?.lastSeq ?? -1)),
        (
          "entries",
          .array(
            entries.suffix(limit).map { e in
              var o = e.json.object ?? JSONObject()
              o["summary"] = .string(e.event.summary)
              if case .checkpoint = e.event { o["state"] = .string("(checkpoint)") }
              return .object(o)
            })
        ),
      ]))
  }
}

// MARK: rewind picker (the History panel)

/// A row of the History panel's rewind picker: somewhere the journal can go back to.
struct RewindPoint: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable { case mark, note, checkpoint, action }
  var seq: Int
  var time: Date
  var summary: String
  var kind: Kind
  /// Read from the file: older than the journal's `recent` lines.
  var fromFile = false
  var id: Int { seq }

  /// One action in this many is a rewind point (marks, notes and checkpoints always are).
  static let every = 25

  /// The point an entry offers: every mark, note and checkpoint, and every `every`th action
  /// (by seq, so the picks don't shift as the list grows). Nil for the rest.
  init?(_ e: JournalEntry, every: Int = RewindPoint.every, fromFile: Bool = false) {
    let kind: Kind
    switch e.event {
    case .checkpoint: kind = .checkpoint
    case .mark: kind = .mark
    case .action, .midi:
      guard every > 0, e.seq % every == 0 else { return nil }
      kind = .action
    case let ev where ev.isNote: kind = .note
    default: return nil
    }
    self.init(seq: e.seq, time: e.time, summary: e.event.summary, kind: kind, fromFile: fromFile)
  }

  init(seq: Int, time: Date, summary: String, kind: Kind, fromFile: Bool = false) {
    self.seq = seq
    self.time = time
    self.summary = summary
    self.kind = kind
    self.fromFile = fromFile
  }
}

extension AppModel {
  static let rewindEvery = RewindPoint.every

  /// The rewind picker's rows, newest first: the points in `recent` (at most `limit`), then the
  /// file's checkpoints from before them (`older`, from `fileRewindPoints`).
  static func rewindPoints(
    _ recent: [JournalEntry], older: [RewindPoint] = [], every: Int = rewindEvery,
    limit: Int = HistoryPanel.shown
  ) -> [RewindPoint] {
    var out: [RewindPoint] = []
    for e in recent.reversed() {
      guard out.count < limit else { break }
      if let p = RewindPoint(e, every: every) { out.append(p) }
    }
    let first = recent.first?.seq ?? Int.max
    out += older.filter { $0.seq < first }.sorted { $0.seq > $1.seq }
    return out
  }

  /// The checkpoints in this run's journal file (flushed, read off the main actor), newest
  /// first: how the picker reaches back past `recent`.
  func fileRewindPoints() async -> [RewindPoint] {
    guard let j = journal else { return [] }
    j.flush()
    let file = j.file
    return await Task.detached(priority: .utility) {
      guard let c = try? Journal.read(file) else { return [] }
      return c.checkpointIndices.reversed().compactMap {
        RewindPoint(c.entries[$0], fromFile: true)
      }
    }.value
  }
}
