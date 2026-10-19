import DJCore
import SwiftUI
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

  @Test func rewindingPutsTheAppBackAndJournalsIt() async throws {
    let m = try await model()
    let dj = try #require(m.engine)
    let dir = try #require(m.journalDir)
    defer { m.defaults.removeObject(forKey: AppModel.cratesKey) }
    // deck A plays the demo loop, which can't be starred (no file, no net): a track on B can
    _ = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    m.poll()
    dj.perform(.crossfader(0.3))
    _ = try await call(m, "notes", #"{"action":"add","deck":"A","text":"before"}"#)
    let seq = try #require(m.journal?.lastSeq)
    m.journal?.flush()
    let head = try #require(try newestJournal(dir).entries.first)
    // everything moves on
    dj.perform(.crossfader(0.9))
    _ = try await call(m, "notes", #"{"action":"add","deck":"A","text":"after"}"#)
    _ = try await call(m, "favorites", #"{"action":"add","deck":"B"}"#)
    m.newCrate("later")
    m.setLocked("A.play", true)
    #expect(!m.favorites.isEmpty)

    let r = try await m.rewindJournal(toSeq: seq)
    #expect(r.seq == seq)
    #expect(dj.crossfader == 0.3)
    #expect(m.notes.map(\.text) == ["before"])
    #expect(m.notesStore.list() == m.notes)
    #expect(m.favorites.isEmpty && m.favoritesStore.list().isEmpty)
    #expect(!m.crates.contains("later"))
    #expect(!dj.lockedActions.contains("A.play") && !m.lockedButtons.contains("A.play"))
    #expect(m.status.hasPrefix("rewound to seq \(seq)"))

    // the journal: append-only (line 0 as it was, the later events still there), then the
    // stores, the mark and a checkpoint
    m.journal?.flush()
    let c = try newestJournal(dir)
    #expect(c.entries.first == head)
    #expect(c.entries.contains { $0.event == .noteAdd(m.notes[0]) })
    #expect(
      c.entries.contains { if case .noteAdd(let n) = $0.event { n.text == "after" } else { false } }
    )
    let tail = c.entries.suffix(3).map(\.event)
    #expect(tail.first.map { if case .storesReplace = $0 { true } else { false } } == true)
    #expect(Array(tail)[1] == .mark(Journal.rewindMark(seq)))
    guard case .checkpoint(let cp)? = tail.last else {
      Issue.record("no checkpoint after the rewind")
      return
    }
    #expect(cp.crossfader == 0.3)
    #expect(cp.decks["A"]?.position != nil, "with playheads")
    #expect(c.entries.last?.seq == r.checkpointSeq)
    // and a replay ends in the post-rewind state
    let replay = try Journal.replay(c)
    #expect(replay.state.crossfader == 0.3)
    #expect(replay.stores.notes == m.notes)
    #expect(replay.stores.favorites.isEmpty)
    #expect(Journal.latestStores(in: dir) == m.storeSnapshot)
  }

  @Test func aReplayAfterARewindStartsFromItsCheckpoint() async throws {
    let m = try await model()
    let dj = try #require(m.engine)
    let dir = try #require(m.journalDir)
    dj.perform(.crossfader(0.2))
    let seq = try #require(m.journal?.lastSeq)
    dj.perform(.crossfader(0.9))
    let r = try await m.rewindJournal(toSeq: seq)
    dj.perform(.crossfader(0.6))
    m.journal?.flush()
    let c = try newestJournal(dir)
    #expect(c.rewindCheckpointIndices.map { c.entries[$0].seq } == [r.checkpointSeq])
    let near = try Journal.replay(c)
    #expect(near.startSeq == r.checkpointSeq)
    #expect(near.state.crossfader == 0.6)
    // nothing before a rewind carries over, so even a replay from line 0 starts there
    let full = try Journal.replay(c, fromStart: true)
    #expect(full.startSeq == r.checkpointSeq)
    #expect(full.state == near.state)
    // before it, the replay is what the rewind went past
    #expect(try Journal.replay(c, toSeq: seq + 1).state.crossfader == 0.9)
    // a session can't be cut across it; either side can
    let last = c.entries.last!.seq
    #expect(throws: JournalError.self) { try Journal.exportSession(c, from: 1, to: last) }
    let after = try Journal.exportSession(c, from: r.checkpointSeq + 1, to: last)
    #expect(after.crossfader == 0.2)
    _ = try Journal.exportSession(c, from: 1, to: seq + 1)
  }

  @Test func theSocketRewinds() async throws {
    let m = try await model()
    let dj = try #require(m.engine)
    dj.perform(.crossfader(0.25))
    let seq = try #require(m.journal?.lastSeq)
    dj.perform(.crossfader(0.75))
    let out = try await call(m, "journal", "{\"action\":\"rewind\",\"seq\":\(seq)}")
    #expect(out["rewound"]?.int == seq)
    #expect(out["checkpoint"]?.int == out["lastSeq"]?.int)
    #expect(dj.crossfader == 0.25)
    let marks = try await call(m, "journal", #"{"kind":"mark"}"#)
    #expect(
      marks["entries"]?.array?.contains { $0["summary"]?.string == "— rewind \(seq)" } == true)
    await #expect(throws: (any Error).self) {
      _ = try await self.call(m, "journal", #"{"action":"rewind","seq":99999}"#)
    }
    await #expect(throws: (any Error).self) {
      _ = try await self.call(m, "journal", #"{"action":"rewind"}"#)
    }
  }

  @Test func thePickerListsRewindPoints() async throws {
    let m = try await model()
    let dj = try #require(m.engine)
    for i in 0..<60 { dj.perform(.crossfader(Double(i) / 60)) }
    _ = try await call(m, "notes", #"{"action":"add","deck":"A","text":"here"}"#)
    m.poll()
    let recent = m.journalEntries
    let points = AppModel.rewindPoints(recent)
    #expect(points.map(\.seq) == points.map(\.seq).sorted(by: >), "newest first")
    #expect(points.first?.kind == .note)
    #expect(points.contains { $0.kind == .mark && $0.summary.contains("app.start") })
    #expect(points.last?.kind == .checkpoint && points.last?.seq == 0)
    // every 25th action, by seq
    let actions = points.filter { $0.kind == .action }
    #expect(!actions.isEmpty && actions.allSatisfy { $0.seq % AppModel.rewindEvery == 0 })
    let actionSeqs = recent.filter { if case .action = $0.event { true } else { false } }
      .map(\.seq).filter { $0 % AppModel.rewindEvery == 0 }
    #expect(Set(actions.map(\.seq)) == Set(actionSeqs))
    #expect(AppModel.rewindPoints(recent, limit: 2).count == 2)

    // past `recent`, the file's checkpoints
    let file = await m.fileRewindPoints()
    #expect(file.first?.seq == 0 && file.allSatisfy { $0.fromFile && $0.kind == .checkpoint })
    let tail = Array(recent.dropFirst(3))
    let older = AppModel.rewindPoints(tail, older: file)
    #expect(older.last?.seq == 0 && older.last?.fromFile == true)
    #expect(!older.dropLast().contains { $0.fromFile }, "only checkpoints before `recent`")
    #expect(!AppModel.rewindPoints(recent, older: file).contains { $0.fromFile })

    // rewind mode lays out in a deck column, the confirm strip open, ⟲ buttons not clipped
    let view = HistoryPanel(model: m, rewinding: true, picked: points[1])
      .padding(8).background(Color.black)
    savePNG(view, width: 300, height: 360, name: "history-rewind")
    let px = try #require(renderPixels(view, width: 300, height: 360))
    let drawn = px.count(inX: 0..<300, y: 0..<360) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(drawn > 2000, "rows drawn (\(drawn) lit pixels)")
    // the ⟲ column (orange) sits inside the right edge. The rows are drawn on their own at the
    // panel's inner width: in the panel they sit in a ScrollView, which ImageRenderer can't draw.
    let rowsView = RewindPointRows(points: points, picked: points[1].seq, busy: false) { _ in }
      .padding(8).background(Color.black)
    let rows = try #require(renderPixels(rowsView, width: 300, height: 360))
    let buttons = rows.count(inX: 240..<292, y: 0..<360) { r, g, b in r > 180 && g > 90 && b < 80 }
    #expect(buttons > 0, "⟲ buttons drawn at the right")
    let rowEdge = rows.count(inX: 296..<300, y: 0..<360) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(rowEdge == 0, "no row runs past the padding")
    let edge = px.count(inX: 296..<300, y: 0..<360) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(edge == 0, "nothing runs past the padding")
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
