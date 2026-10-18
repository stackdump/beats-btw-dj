import DJCore
import Testing

@testable import DJViews

/// The app journals what it changes: pokes through `perform`, and the store edits and notes
/// that are not pokes. Driven through the control socket's methods into an offline engine.
@MainActor
struct JournalViewTests {
  func model() async throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    try dj.start()
    let m = AppModel(
      engine: dj, favorites: temporaryFavorites(), voices: temporaryVoiceVariations(),
      notes: temporaryNotes(), journal: temporaryJournalDir())
    m.start()
    return m
  }

  func call(_ m: AppModel, _ method: String, _ params: String = "{}") async throws -> JSONValue {
    try await m.control(method, try JSONValue.parse(params))
  }

  @Test func notesGoOnTheTrackAndIntoTheJournal() async throws {
    let m = try await model()
    let dir = try #require(m.journalDir)
    _ = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    m.poll()
    let key = try #require(m.deckNoteKeys["B"])
    #expect(key.hasPrefix("track:z4"))
    let added = try await call(m, "notes", #"{"action":"add","deck":"B","text":"drop hits here"}"#)
    #expect(added["target"]?.string == key)
    #expect(added["bar"]?.int == 1)
    let id = try #require(added["id"]?.string)
    // the same track on the other deck shows the same note
    _ = try await call(
      m, "generate", #"{"deck":"A","genre":"techno","seed":42,"structure":"minimal"}"#)
    m.poll()
    #expect(m.deckNotes("A").map(\.id) == [id])
    // starred, the favorite carries it
    _ = try await call(m, "favorites", #"{"action":"add","deck":"B"}"#)
    #expect(m.favorites.first.map { m.favoriteNotes($0).count } == 1)
    _ = try await call(m, "notes", "{\"action\":\"edit\",\"id\":\"\(id)\",\"text\":\"the drop\"}")
    #expect(m.notes.first?.text == "the drop")
    #expect(m.notesStore.list() == m.notes, "notes.json is the projection")
    let listed = try await call(m, "notes", #"{"deck":"A"}"#)
    #expect(listed["notes"]?.array?.count == 1)
    // History shows it
    m.poll()
    #expect(m.journalEntries.contains { $0.event.isNote })
    let j = try await call(m, "journal", #"{"kind":"note."}"#)
    #expect(j["entries"]?.array?.count == 2)
    _ = try await call(m, "notes", "{\"action\":\"delete\",\"id\":\"\(id)\"}")
    #expect(m.notes.isEmpty)

    m.journal?.flush()
    let c = try newestJournal(dir)
    let kinds = c.entries.map(\.event.kind)
    for k in ["checkpoint", "mark", "act", "note.add", "note.edit", "note.delete", "favorite.add"] {
      #expect(kinds.contains(k), "journaled \(k)")
    }
    // and the journal rebuilds the stores the app holds
    var stores = try #require(c.checkpoint?.stores)
    for e in c.entries.dropFirst() { stores.apply(e.event) }
    #expect(stores.favorites.map(\.cid) == m.favorites.map(\.cid))
    #expect(stores.notes == m.notes)
  }

  @Test func storeEditsThatBypassedPerformAreJournaled() async throws {
    let m = try await model()
    let dj = try #require(m.engine)
    m.newCrate("set 1")
    m.deleteCrate("set 1")
    m.saveVariation("laser", name: "zap", VoiceSetting(instrument: "laser"))
    m.renameVariation("laser", "zap", to: "zip")
    m.deleteVariation("laser", "zip")
    m.setLocked("A.play", true)
    #expect(dj.lockedActions.contains("A.play"))
    m.setLocked("A.play", false)
    #expect(!dj.lockedActions.contains("A.play"))
    _ = try await call(m, "perform", #"{"action":{"op":"grabBars","deck":"A","bars":1}}"#)
    let events = (m.journal?.recent ?? []).map(\.event)
    #expect(events.contains(.crateAdd(name: "set 1")))
    #expect(events.contains(.crateDelete(name: "set 1")))
    #expect(events.contains { if case .variationSave = $0 { true } else { false } })
    #expect(events.contains(.variationRename(instrument: "laser", name: "zap", to: "zip")))
    #expect(events.contains(.variationDelete(instrument: "laser", name: "zip")))
    #expect(events.contains(.action(.lock(key: "A.play", on: true))))
    #expect(events.contains(.action(.lock(key: "A.play", on: false))))
    #expect(events.contains(.action(.grabBars(deck: "A", bars: 1))))
    m.defaults.removeObject(forKey: "crates")
  }

  @Test func replacingTheStoresRewritesTheFilesAndJournalsIt() async throws {
    let m = try await model()
    let dir = try #require(m.journalDir)
    defer { m.defaults.removeObject(forKey: AppModel.cratesKey) }
    m.newCrate("old crate")
    m.saveVariation("laser", name: "zap", VoiceSetting(instrument: "laser"))
    _ = try await call(m, "notes", #"{"action":"add","deck":"A","text":"old note"}"#)
    let replaced = replacementStores()
    m.replaceStores(replaced)
    // the files
    #expect(m.favoritesStore.list().map(\.cid) == replaced.favorites.map(\.cid))
    #expect(m.variationStore.all() == replaced.variations)
    #expect(m.notesStore.list() == replaced.notes)
    #expect(m.defaults.stringArray(forKey: AppModel.cratesKey) == replaced.crates)
    // what the panels show
    #expect(m.favorites.map(\.cid) == replaced.favorites.map(\.cid))
    #expect(m.variations == replaced.variations)
    #expect(m.notes == replaced.notes)
    #expect(m.crates == ["warm", "set 2"])
    #expect(m.storeSnapshot == replaced)
    // the journal: one event, and a replay of it ends with exactly these stores
    m.journal?.flush()
    let c = try newestJournal(dir)
    #expect(c.entries.map(\.event).contains(.storesReplace(replaced)))
    var stores = try #require(c.checkpoint?.stores)
    for e in c.entries.dropFirst() { stores.apply(e.event) }
    #expect(stores == replaced)
    #expect(Journal.latestStores(in: dir) == replaced)
  }

  @Test func theNewestJournalWinsOverNotesJSON() async throws {
    let first = try await model()
    let dir = try #require(first.journalDir)
    _ = try await call(first, "notes", #"{"action":"add","deck":"A","text":"keep me"}"#)
    first.stop()
    // notes.json lost the note (a crash between the writes, an old backup): the journal has it
    let store = temporaryNotes()
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let again = AppModel(
      engine: dj, favorites: temporaryFavorites(), voices: temporaryVoiceVariations(),
      notes: store, journal: dir)
    #expect(again.notes.isEmpty)
    again.start()
    #expect(again.notes.map(\.text) == ["keep me"])
    #expect(store.list().map(\.text) == ["keep me"])
    again.stop()
  }

  @Test func theHistoryFoldsAFaderSweep() {
    var entries: [JournalEntry] = []
    for i in 0..<10 {
      entries.append(
        JournalEntry(
          seq: i, time: .distantPast, frame: i,
          event: .action(.param(deck: "A", name: "volume", value: Double(i) / 10))))
    }
    entries.append(
      JournalEntry(
        seq: 10, time: .distantPast, frame: 10,
        event: .noteAdd(TrackNote(target: .clip(id: "c"), text: "x", created: .distantPast))))
    let rows = HistoryPanel.rows(entries, notesOnly: false)
    #expect(rows.count == 2)
    #expect(rows[0].entry.event.isNote)
    #expect(rows[1].count == 10 && rows[1].entry.seq == 9, "the newest of the sweep")
    #expect(HistoryPanel.rows(entries, notesOnly: true).count == 1)
  }
}
