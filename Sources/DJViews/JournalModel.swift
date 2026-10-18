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

  func controlJournal(_ p: JSONValue) -> JSONValue {
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
