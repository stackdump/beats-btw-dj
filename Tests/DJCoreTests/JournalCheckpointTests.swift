import Testing

@testable import DJCore

private let rate = 11_025.0

/// Checkpoints that carry the decks' playheads (`JournalState(engine:stores:playheads: true)`).
@MainActor
struct JournalCheckpointTests {
  static let spec = TrackSpec(genre: "techno", seed: 7, structure: "standard")

  static var withPositions: JournalState {
    JournalState(
      sampleRate: 48_000,
      decks: [
        "A": DeckCheckpoint(
          source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil),
          position: 12_345.5),
        "B": DeckCheckpoint(source: .net(spec), playing: true, position: 96),
        "C": DeckCheckpoint(source: .net(spec)),
      ])
  }

  @Test func aPositionRoundTripsThroughTheCheckpointLine() throws {
    let e = JournalEntry(
      seq: 0, time: journalDate(1_760_000_000), frame: 0, event: .checkpoint(Self.withPositions))
    let back = try #require(JournalEntry(line: e.line))
    #expect(back == e)
    #expect(back.line == e.line, "re-encodes to the same bytes")
    guard case .checkpoint(let s) = back.event else {
      Issue.record("not a checkpoint")
      return
    }
    #expect(s.decks["A"]?.position == 12_345.5)
    #expect(s.decks["B"]?.position == 96)
    #expect(s.decks["C"]?.position == nil, "written only when set")
  }

  @Test func anOldCheckpointHasNoPositionAndStaysByteForByte() throws {
    var old = Self.withPositions
    for k in old.decks.keys { old.decks[k]?.position = nil }
    let text = old.json.canonicalJS
    #expect(!text.contains("\"position\""), "no key without a position")
    #expect(text.contains(JournalState.schema), "schema stays v1")
    let back = try #require(JournalState(json: try JSONValue.parse(text)))
    #expect(back.decks.values.allSatisfy { $0.position == nil })
    #expect(back.json.canonicalJS == text)
  }

  @Test func aCheckpointKeepsPlayheadsOnlyWhenAsked() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    try dj.start()
    defer { dj.stop() }
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    for b in 0..<40 {
      _ = try conductor.step {
        if b == 0 {
          dj.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
          )
          dj.perform(.load(deck: "B", source: .net(Self.spec)))
          dj.perform(.play(deck: "A", on: true))
          dj.perform(.play(deck: "B", on: true))
        }
      }
    }
    let plain = JournalState(engine: dj)
    #expect(plain.decks.values.allSatisfy { $0.position == nil }, "opt-in")
    #expect(!plain.json.canonicalJS.contains("\"position\""))
    let kept = JournalState(engine: dj, playheads: true)
    #expect((kept.decks["A"]?.position ?? 0) > 0)
    #expect(kept.decks["B"]?.position == Double(try #require(dj["B"]).wave.tick))
  }

  /// A live run that plays both decks a while, stops them and lets them settle; its state with
  /// playheads, restored into a fresh engine, stands where it stood.
  @Test func aRestoreSeeksTheDecksToTheirPlayheads() throws {
    let live = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    live.deterministic = true
    try live.start()
    let conductor = OfflineConductor(engine: live, router: ControllerRouter(engine: live))
    for b in 0..<400 {
      _ = try conductor.step {
        switch b {
        case 0:
          live.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
          )
          live.perform(.load(deck: "B", source: .net(Self.spec)))
          live.perform(.play(deck: "A", on: true))
          live.perform(.play(deck: "B", on: true))
        case 250:
          live.perform(.play(deck: "A", on: false))
          live.perform(.play(deck: "B", on: false))
        default: break
        }
      }
    }
    let state = JournalState(engine: live, playheads: true)
    live.stop()
    let samplePos = try #require(state.decks["A"]?.position)
    let tick = try #require(state.decks["B"]?.position)
    #expect(samplePos > 0 && tick > 0, "the decks moved: \(samplePos) \(tick)")
    // through the checkpoint's JSON, as a journal file holds it
    let read = try #require(JournalState(json: try JSONValue.parse(state.json.canonicalJS)))

    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let warnings = read.restore(into: dj, clip: { _ in nil })
    #expect(warnings.isEmpty, "\(warnings)")
    try dj.start()
    defer { dj.stop() }
    let replay = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    _ = try replay.step()
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    #expect(!a.playing && !b.playing)
    #expect(b.wave.tick == Int(tick), "the net tick is exact")
    #expect(
      abs(a.turntable.position - samplePos) <= 128,
      "sample within a block: \(a.turntable.position) vs \(samplePos)")
  }

  // MARK: mid-file checkpoints

  /// A live run with two mid-file checkpoints (blocks 100 and 250) between knobs, a section jump
  /// and store edits on both sides of them.
  struct MidRun {
    let contents: Journal.Contents
    let live: JournalState
    let mids: [JournalEntry]
  }

  static func midRun() throws -> MidRun {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let box = StoreBox()
    box.state.crates = ["old"]
    try dj.start()
    defer { dj.stop() }
    let journal = try Journal(engine: dj, directory: dir, started: journalDate(1_760_000_000)) {
      box.state
    }
    func store(_ e: JournalEvent) {
      journal.record(e)
      box.state.apply(e)
    }
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    var mids: [JournalEntry] = []
    for b in 0..<400 {
      _ = try conductor.step {
        switch b {
        case 0:
          dj.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
          )
          dj.perform(.load(deck: "B", source: .net(Self.spec)))
          dj.perform(.play(deck: "A", on: true))
          dj.perform(.play(deck: "B", on: true))
        case 20:
          dj.perform(.param(deck: "A", name: "volume", value: 0.7))
          dj.perform(.param(deck: "B", name: "volume", value: 0))
          store(
            .favoriteAdd(
              Favorite(title: "B track", source: .net(Self.spec), added: wholeSecond(1_760_000_001))
            ))
        case 100: if let m = journal.checkpoint() { mids.append(m) }
        case 150:
          dj.perform(.section(deck: "B", index: 1))
          dj.perform(.crossfader(0.3))
          store(
            .noteAdd(
              TrackNote(
                id: "n-1", target: .track(cid: "x"), text: "here",
                created: journalDate(1_760_000_002))))
        case 250: if let m = journal.checkpoint() { mids.append(m) }
        case 300:
          dj.perform(.param(deck: "A", name: "volume", value: 0.5))
          store(.crateAdd(name: "set 1"))
        case 350: dj.perform(.lock(key: "B.section", on: true))
        default: break
        }
      }
    }
    let live = JournalState(engine: dj, stores: box.state)
    journal.close()
    return MidRun(contents: try readNewestJournal(dir), live: live, mids: mids)
  }

  static let mid: Result<MidRun, Error> = Result { try midRun() }

  @Test func aMidCheckpointKeepsPlayheadsAndLeavesTheStoresOut() throws {
    let run = try Self.mid.get()
    let c = run.contents
    #expect(run.mids.count == 2)
    #expect(c.checkpointIndices.count == 3, "line 0 and two mid ones")
    #expect(c.checkpointIndices.first == 0)
    #expect(c.checkpointIndices.dropFirst().map { c.entries[$0].seq } == run.mids.map(\.seq))
    let line0 = c.entries[0].line
    #expect(line0.contains("\"stores\""), "line 0 carries the stores")
    #expect(!line0.contains("\"position\""), "and no playheads")
    for m in run.mids {
      #expect(!m.line.contains("\"stores\""), "a mid checkpoint has no stores")
      #expect(m.line.contains("\"position\""), "but the playheads")
      let back = try #require(JournalEntry(line: m.line))
      #expect(back.line == m.line, "re-encodes to the same bytes")
      guard case .checkpoint(let s) = back.event else {
        Issue.record("not a checkpoint")
        continue
      }
      #expect(!s.hasStores)
      #expect(m.event.summary.hasPrefix("checkpoint (mid)"))
    }
    #expect(c.checkpoint?.hasStores == true, "Contents.checkpoint is still line 0's")
  }

  @Test func aReplayStartsFromTheNearestCheckpointAndEndsInTheSameState() throws {
    let run = try Self.mid.get()
    let c = run.contents
    try #require(run.mids.count == 2)
    let (m1, m2) = (run.mids[0], run.mids[1])
    let last = try #require(c.entries.last).seq

    let full = try Journal.replay(c, fromStart: true)
    let near = try Journal.replay(c)
    #expect(full.startSeq == 0)
    #expect(near.startSeq == m2.seq, "the last checkpoint")
    #expect(full.lastSeq == last && near.lastSeq == last)
    #expect(near.state == full.state)
    #expect(near.state.json.canonicalJS == run.live.json.canonicalJS, "the live state")
    #expect(near.stores == run.live.stores, "line 0's stores and every store event")
    #expect(near.stores.crates == ["old", "set 1"] && near.stores.notes.count == 1)

    // by sequence number: between the two mid checkpoints
    let between = m1.seq + 1
    let a = try Journal.replay(c, toSeq: between)
    let b = try Journal.replay(c, toSeq: between, fromStart: true)
    #expect(a.startSeq == m1.seq && b.startSeq == 0)
    #expect(a.lastSeq == b.lastSeq)
    #expect(a.state == b.state)
    #expect(a.stores.favorites.count == 1, "the favorite before the checkpoint is folded in")

    // on a checkpoint exactly: it is the start, nothing after it is applied
    let on = try Journal.replay(c, toSeq: m2.seq)
    #expect(on.startSeq == m2.seq && on.lastSeq == m2.seq)
    #expect(on.state == (try Journal.replay(c, toSeq: m2.seq, fromStart: true)).state)

    // before the first mid checkpoint: line 0
    #expect(try Journal.replay(c, toSeq: m1.seq - 1).startSeq == 0)

    // by time: between the two, frames still count from line 0
    let origin = c.entries[0].frame
    let t = (m1.frame + m2.frame) / 2 - origin
    let byTime = try Journal.replay(c, endFrame: t)
    #expect(byTime.startSeq == m1.seq)
    #expect(byTime.frames >= t)
    #expect(byTime.state == (try Journal.replay(c, endFrame: t, fromStart: true)).state)
  }

  @Test func checkpointsComeOnTheirCadence() throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    dj.deterministic = true
    try dj.start()
    defer { dj.stop() }
    let journal = try Journal(engine: dj, directory: dir)
    #expect(journal.checkpointSeconds == 60 && journal.checkpointEntries == 2000, "the defaults")
    journal.checkpointSeconds = 0.5
    journal.checkpointEntries = 5
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    #expect(journal.checkpointIfDue() == nil, "nothing recorded since line 0")
    for i in 0..<4 { journal.record(.mark("m\(i)")) }
    #expect(journal.checkpointIfDue() == nil, "4 entries, no time")
    journal.record(.mark("m4"))
    let byCount = try #require(journal.checkpointIfDue(), "5 entries")
    #expect(byCount.seq == 6)
    #expect(journal.checkpointIfDue() == nil, "just written")
    journal.record(.mark("later"))
    let f0 = dj.frame
    while dj.frame - f0 < Int(0.4 * rate) { _ = try conductor.step() }
    #expect(journal.checkpointIfDue() == nil, "not half a second yet")
    while dj.frame - f0 < Int(0.5 * rate) + 128 { _ = try conductor.step() }
    let byTime = try #require(journal.checkpointIfDue(), "half a second and an entry")
    #expect(byTime.seq == 8)
    let f1 = dj.frame
    while dj.frame - f1 < Int(rate) { _ = try conductor.step() }
    #expect(journal.checkpointIfDue() == nil, "an idle engine writes none")
    journal.close()
    let c = try readNewestJournal(dir)
    #expect(c.checkpointIndices.map { c.entries[$0].seq } == [0, 6, 8])
  }

  @Test func theLatestStoresSkipMidCheckpoints() throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    try dj.start()
    defer { dj.stop() }
    let box = StoreBox()
    box.state.crates = ["old"]
    let journal = try Journal(engine: dj, directory: dir) { box.state }
    func store(_ e: JournalEvent) {
      journal.record(e)
      box.state.apply(e)
    }
    store(.crateAdd(name: "before"))
    journal.checkpoint()
    store(
      .noteAdd(
        TrackNote(
          id: "n", target: .track(cid: "x"), text: "after", created: journalDate(1_760_000_000))))
    journal.checkpoint()
    journal.close()
    let s = try #require(Journal.latestStores(in: dir))
    #expect(s == box.state)
    #expect(s.crates == ["old", "before"] && s.notes.map(\.id) == ["n"])
  }
}
