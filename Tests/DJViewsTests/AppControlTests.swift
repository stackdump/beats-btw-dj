import Testing

@testable import DJCore
@testable import DJViews

/// The control socket's methods, driven straight into an offline engine.
@MainActor
struct AppControlTests {
  func model() throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj)
    m.start()
    return m
  }

  func call(_ m: AppModel, _ method: String, _ params: String = "{}") async throws -> JSONValue {
    try await m.control(method, try JSONValue.parse(params))
  }

  func favoritesModel() throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites())
    m.start()
    return m
  }

  @Test func favoritesStarListAndReloadATrack() async throws {
    let m = try favoritesModel()
    await #expect { try await call(m, "favorites", #"{"action":"add","deck":"A"}"#) } throws: {
      "\($0)".contains("nothing to star")  // the demo loop has no file
    }
    let b = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    #expect(b["share"]?["seed"]?.double == 42)
    #expect(b["favorite"]?.bool == false)
    let list = try await call(m, "favorites", #"{"action":"add","deck":"B"}"#)
    let cid = try #require(list["favorites"]?.array?.first?["cid"]?.string)
    #expect(list["favorites"]?.array?.first?["seed"]?.double == 42)
    #expect(try await call(m, "state")["decks"]?["B"]?["favorite"]?.bool == true)
    // load it onto the other deck, recorded as a load
    let rec = try SessionRecorder.start(on: try #require(m.engine))
    let a = try await call(
      m, "favorites", "{\"action\":\"load\",\"deck\":\"A\",\"cid\":\"\(cid)\"}")
    #expect(a["share"]?["seed"]?.double == 42)
    #expect(rec.finish().events.count == 1)
    // the list is on disk
    #expect(m.favoritesStore.list().count == 1)
    let after = try await call(m, "favorites", #"{"action":"remove","deck":"B"}"#)
    #expect(after["favorites"]?.array?.isEmpty == true)
  }

  /// dj_loops: the row's Undo, "Load source", Export (no panel) and "Stop all".
  @Test func loopsUndoExportAndStopAll() async throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (m, dj) = try LoopLibraryViewTests().model(takes: 2, library: lib)
    defer { dj.stop() }
    let ids = m.clips.map(\.id)
    func clipIDs(_ loops: JSONValue) -> [String]? {
      loops["clips"]?.array?.compactMap { $0["id"]?.string }
    }
    #expect(clipIDs(try await call(m, "loops")) == ids, "list is dj_state.loops")
    // undo: only right after a removal
    await #expect { try await call(m, "loops", #"{"action":"undo"}"#) } throws: {
      "\($0)".contains("nothing to undo")
    }
    _ = try await call(m, "perform", "{\"action\":{\"op\":\"clipRemove\",\"id\":\"\(ids[0])\"}}")
    #expect(m.clips.map(\.id) == [ids[1]])
    #expect(clipIDs(try await call(m, "loops", #"{"action":"undo"}"#)) == ids, "back where it was")
    #expect(m.lastRemoval == nil)
    // load source: the demo loop the takes came from, onto deck B
    let b = try await call(
      m, "loops", "{\"action\":\"loadSource\",\"id\":\"\(ids[0])\",\"deck\":\"B\"}")
    #expect(b["title"]?.string == "demo loop")
    await #expect {
      try await call(m, "loops", #"{"action":"loadSource","id":"nope","deck":"B"}"#)
    } throws: { "\($0)".contains("a clip on the row") }
    // export: written without a panel, and it decodes to the clip's frames
    let path = tempWAVPath()
    defer { removeFile(path) }
    let out = try await call(
      m, "loops", "{\"action\":\"export\",\"id\":\"\(ids[0])\",\"path\":\"\(path)\"}")
    let clip = try #require(dj.clip(ids[0]))
    #expect(out["path"]?.string == path)
    #expect(out["frames"]?.double == Double(clip.buffer.length))
    #expect(try decodedWAVFrames(path, sampleRate: clip.buffer.sampleRate) == clip.buffer.length)
    await #expect {
      try await call(m, "loops", "{\"action\":\"export\",\"id\":\"\(ids[0])\",\"path\":\"x.wav\"}")
    } throws: { "\($0)".contains("absolute") }
    // stop all: a clipLoop off for each looping clip, recorded
    for id in ids {
      _ = try await call(
        m, "perform", "{\"action\":{\"op\":\"clipLoop\",\"id\":\"\(id)\",\"on\":true}}")
    }
    #expect(Set(dj.loopingClips) == Set(ids))
    let rec = try SessionRecorder.start(on: dj)
    let stopped = try await call(m, "loops", #"{"action":"stopAll"}"#)
    #expect(Set(stopped["stopped"]?.array?.compactMap(\.string) ?? []) == Set(ids))
    #expect(rec.finish().events.count == ids.count, "one clipLoop off per clip")
    #expect(dj.loopingClips.isEmpty)
    #expect(clipIDs(stopped["loops"] ?? .null) == ids)
    await #expect { try await call(m, "loops", #"{"action":"shuffle"}"#) } throws: {
      "\($0)".contains("stopAll")
    }
  }

  @Test func copyADeckThenChangeAnInstrumentOnTheCopy() async throws {
    let m = try favoritesModel()
    _ = try await call(
      m, "generate", #"{"deck":"A","genre":"techno","seed":42,"structure":"minimal"}"#)
    let b = try await call(m, "copyDeck", #"{"from":"A","to":"B"}"#)
    let a = try await call(m, "state")["decks"]?["A"]
    #expect(b["share"]?["cid"] == a?["share"]?["cid"])
    let bass = try #require(b["instruments"]?["bass"]?.string)
    let other = try #require(
      BeatsTables.shared.instrumentSets["techno"]?["bass"]?.first { $0 != bass })
    let changed = try await call(
      m, "setInstrument", "{\"deck\":\"B\",\"role\":\"bass\",\"instrument\":\"\(other)\"}")
    #expect(changed["instruments"]?["bass"]?.string == other)
    #expect(changed["share"]?["cid"] != a?["share"]?["cid"])
    // deck A is untouched
    #expect(try await call(m, "state")["decks"]?["A"]?["instruments"]?["bass"]?.string == bass)
    await #expect {
      try await call(m, "setInstrument", #"{"deck":"B","role":"bass","instrument":"kazoo"}"#)
    } throws: { "\($0)".contains("can play:") }
    await #expect { try await call(m, "copyDeck", #"{"from":"A","to":"A"}"#) } throws: {
      "\($0)".contains("same deck")
    }
  }

  @Test(.enabled(if: installedAppleLoop != nil, "needs the Apple Loops content"))
  func aStockLoopListsAndLoadsWithItsOwnTempo() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary())
    m.start()
    let list = try await call(m, "stockLoops", #"{"category":"Drums"}"#)
    #expect(list["total"]?.double == 1)
    let path = try #require(list["loops"]?.array?.first?["path"]?.string)
    #expect(list["loops"]?.array?.first?["bpm"]?.double == 120)
    let a = try await call(
      m, "stockLoops", "{\"action\":\"load\",\"deck\":\"A\",\"path\":\"\(path)\"}")
    #expect(a["title"]?.string == "Chill Hip-Hop Beat 08" && a["mode"]?.string == "sample")
    #expect(a["bpm"]?.double == 120, "the loop's own tempo is the grid: no analysis")
    await #expect {
      try await call(m, "stockLoops", #"{"action":"load","deck":"A","path":"/nope.caf"}"#)
    } throws: { "\($0)".contains("from action list") }
  }

  @Test(.enabled(if: installedAppleLoop != nil, "needs the Apple Loops content"))
  func aStockLoopGoesOnTheRowOnceAndTheSetIsNotPublished() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary())
    m.start()
    let list = try await call(m, "stockLoops", #"{"category":"Drums"}"#)
    let path = try #require(list["loops"]?.array?.first?["path"]?.string)
    let rec = try SessionRecorder.start(on: dj)
    let clip = try await call(m, "stockLoops", "{\"action\":\"addToRow\",\"path\":\"\(path)\"}")
    #expect(clip["title"]?.string == "Chill Hip-Hop Beat 08" && clip["source"]?.string == "L")
    #expect(clip["provenance"]?["kind"]?.string == "stock")
    #expect(clip["provenance"]?["path"]?.string == path)
    let id = try #require(clip["id"]?.string)
    #expect(dj.loopingClips == [id], "it loops under the mixer")
    // the same loop again is the same clip
    let again = try await call(m, "stockLoops", "{\"action\":\"addToRow\",\"path\":\"\(path)\"}")
    #expect(again["id"]?.string == id)
    #expect(try await call(m, "state")["loops"]?["clips"]?.array?.count == 1)
    let session = rec.finish()
    #expect(session.importedClips.count == 2)
    #expect(throws: PublishError.self) {
      _ = try SessionBundle(session: session, renderedAt: "now", allowLocalOnly: true)
    }
    await #expect {
      try await call(m, "stockLoops", #"{"action":"addToRow","path":"/nope.caf"}"#)
    } throws: { "\($0)".contains("from action list") }
  }

  @Test(.enabled(if: installedAppleLoop != nil, "needs the Apple Loops content"))
  func aStockLoopCanBeStarredTaggedAndReloaded() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary())
    m.start()
    let list = try await call(m, "stockLoops", #"{"category":"Drums"}"#)
    let path = try #require(list["loops"]?.array?.first?["path"]?.string)
    _ = try await call(m, "stockLoops", "{\"action\":\"load\",\"deck\":\"A\",\"path\":\"\(path)\"}")
    #expect(m.decks["A"]?.sourceCID == "file:" + path, "a sample from a file can be starred")
    let added = try await call(m, "favorites", #"{"action":"add","deck":"A"}"#)
    let fav = try #require(added["favorites"]?.array?.first)
    #expect(fav["kind"]?.string == "sample" && fav["file"]?.string == path)
    #expect(m.isFavorite("A"))
    let cid = try #require(fav["cid"]?.string)
    let tagged = try await call(
      m, "favorites", "{\"action\":\"tags\",\"cid\":\"\(cid)\",\"tags\":[\"drums\",\"chill\"]}")
    #expect(
      tagged["favorites"]?.array?.first?["tags"]?.array == [.string("drums"), .string("chill")])
    let b = try await call(
      m, "favorites", "{\"action\":\"load\",\"deck\":\"B\",\"cid\":\"\(cid)\"}")
    #expect(b["title"]?.string == "Chill Hip-Hop Beat 08" && b["bpm"]?.double == 120)
    #expect(m.isFavorite("B"), "reloaded from its file: the same favorite")
    // the demo loop has no file: nothing to star
    m.loadDemo("B")
    m.poll()
    await #expect { try await call(m, "favorites", #"{"action":"add","deck":"B"}"#) } throws: {
      "\($0)".contains("nothing to star")
    }
  }

  @Test(.enabled(if: installedAppleLoop != nil, "needs the Apple Loops content"))
  func stockLoopsDropIntoCrates() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary())
    m.defaults = scratchDefaults()
    m.start()
    await m.loadStockLoops()
    let loop = try #require(m.stockLoops.first)
    m.newCrate("warmup")
    #expect(m.crates == ["warmup"] && m.favorites.isEmpty, "an empty crate is kept by name")
    m.addToCrate(loop.path, "warmup")
    m.addToCrate(loop.path, "peak")  // a loop can be in several crates
    m.addToCrate(loop.path, "warmup")  // and once per crate
    let f = try #require(m.favorites.first)
    #expect(f.isSample && f.file == loop.path && f.tags == ["warmup", "peak"])
    #expect(m.crates == ["warmup", "peak"])
    if case .sample(_, _, let g) = f.source { #expect(g?.bpm == loop.bpm) }
    #expect(await m.loadFavoriteNow("B", f))
    m.poll()
    #expect(m.decks["B"]?.title == loop.name, "a crate's loop loads like any favorite")
    m.removeFromCrate(f.cid, "peak")
    #expect(m.favorites.first?.tags == ["warmup"])
    m.deleteCrate("warmup")
    #expect(m.crates == ["peak"], "peak was made by name and stays until deleted")
    #expect(m.favorites.count == 1 && m.favorites.first?.tags == [], "the loop stays starred")
  }

  /// dj_favorites' crate actions: make one, fill it by cid (and by stock-loop path when the
  /// Apple Loops are installed), take one out, delete it; the favorites stay starred.
  @Test func cratesCanBeMadeFilledAndDeleted() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary())
    m.defaults = scratchDefaults()
    m.start()
    _ = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    let starred = try await call(m, "favorites", #"{"action":"add","deck":"B"}"#)
    let cid = try #require(starred["favorites"]?.array?.first?["cid"]?.string)
    #expect(starred["crates"]?.array?.isEmpty == true)

    let made = try await call(m, "favorites", #"{"action":"newCrate","crate":" warmup "}"#)
    #expect(made["crates"]?.array == [.string("warmup")], "an empty crate is kept by name")
    let filled = try await call(
      m, "favorites", "{\"action\":\"addToCrate\",\"crate\":\"peak\",\"cid\":\"\(cid)\"}")
    #expect(filled["crates"]?.array == [.string("warmup"), .string("peak")], "made on the way")
    _ = try await call(
      m, "favorites", "{\"action\":\"addToCrate\",\"crate\":\"warmup\",\"cid\":\"\(cid)\"}")
    _ = try await call(
      m, "favorites", "{\"action\":\"addToCrate\",\"crate\":\"warmup\",\"cid\":\"\(cid)\"}")
    #expect(m.favorites.first?.tags == ["peak", "warmup"], "once per crate")
    let listed = try await call(m, "favorites", #"{"action":"crates"}"#)
    #expect(listed["crates"]?.array?.count == 2)

    if installedAppleLoop != nil {
      await m.loadStockLoops()
      let loop = try #require(m.stockLoops.first)
      _ = try await call(
        m, "favorites",
        "{\"action\":\"addToCrate\",\"crate\":\"warmup\",\"path\":\"\(loop.path)\"}")
      let f = try #require(m.favorites.first { $0.file == loop.path })
      #expect(f.isSample && f.tags == ["warmup"], "a stock loop is starred, then put in the crate")
    }
    await #expect {
      try await call(m, "favorites", #"{"action":"addToCrate","crate":"x","path":"/nope.caf"}"#)
    } throws: { "\($0)".contains("no stock loop") }

    let out = try await call(
      m, "favorites",
      "{\"action\":\"removeFromCrate\",\"crate\":\"peak\",\"cid\":\"\(cid)\"}")
    #expect(m.favorites.first { $0.cid == cid }?.tags == ["warmup"])
    #expect(out["crates"]?.array?.contains(.string("peak")) == true, "made by name: still there")
    _ = try await call(m, "favorites", #"{"action":"deleteCrate","crate":"warmup"}"#)
    #expect(m.crates == ["peak"])
    #expect(m.favorites.allSatisfy { $0.tags.isEmpty }, "its favorites stay starred, untagged")
    #expect(m.favorites.contains { $0.cid == cid })

    for (params, words) in [
      (#"{"action":"newCrate"}"#, "`crate`"),
      (#"{"action":"addToCrate","crate":"x"}"#, "`cid`"),
      (#"{"action":"addToCrate","crate":"x","cid":"nope"}"#, "no favorite"),
      (#"{"action":"removeFromCrate","crate":"x","cid":"nope"}"#, "`cid`"),
      (#"{"action":"deleteCrate","crate":"never made"}"#, "no crate"),
    ] {
      await #expect { try await call(m, "favorites", params) } throws: { "\($0)".contains(words) }
    }
  }

  /// keepMove {deck, step}: ★ on a move of the walk, through the control method; journaled both
  /// ways, so the journal's stores hold the kept favorite.
  @Test func aWanderMoveCanBeStarredAndIsJournaled() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(
      engine: dj, favorites: temporaryFavorites(), voices: temporaryVoiceVariations(),
      notes: temporaryNotes(), journal: temporaryJournalDir())
    m.defaults = scratchDefaults()
    m.start()
    let dir = try #require(m.journalDir)
    _ = try await call(
      m, "generate", #"{"deck":"A","genre":"house","seed":5,"structure":"minimal"}"#)
    m.poll()
    let d = try #require(dj["A"])
    // every part kept: the walk only plays macros and stingers (no recompose to wait for)
    for r in d.roles { m.setWanderLock("A", WanderLock.keep(r), true) }
    m.setWanderPace("A", 4)
    m.setWander("A", true)
    for bar in 0...4 { d.advanceWander(toBar: bar, lockedActions: dj.lockedActions) }
    let move = try #require(d.wander.log.first)
    let spec = try #require(move.spec)
    #expect(!m.isFavoriteSpec(spec))

    let kept = try await call(
      m, "favorites", "{\"action\":\"keepMove\",\"deck\":\"A\",\"step\":\(move.step)}")
    #expect(kept["kept"]?.bool == true)
    let cid = try #require(kept["favorite"]?["cid"]?.string)
    #expect(m.isFavoriteSpec(spec) && kept["favorite"]?["genre"]?.string == "house")
    #expect(m.journal?.recent.contains { $0.event.kind == "favorite.add" } == true)
    // the journal rebuilds the stores with it
    m.journal?.flush()
    let c = try newestJournal(dir)
    var stores = try #require(c.checkpoint?.stores)
    for e in c.entries.dropFirst() { stores.apply(e.event) }
    #expect(stores.favorites.map(\.cid) == [cid])

    let again = try await call(
      m, "favorites", "{\"action\":\"keepMove\",\"deck\":\"A\",\"step\":\(move.step)}")
    #expect(again["kept"]?.bool == false && !m.isFavoriteSpec(spec), "again: unstarred")
    #expect(m.journal?.recent.map(\.event).contains(.favoriteRemove(cid: cid)) == true)

    for (params, words) in [
      (#"{"action":"keepMove","deck":"A"}"#, "`step`"),
      (#"{"action":"keepMove","deck":"A","step":999}"#, "no wander move"),
      (#"{"action":"keepMove","deck":"Z","step":0}"#, "no deck"),
    ] {
      await #expect { try await call(m, "favorites", params) } throws: { "\($0)".contains(words) }
    }
  }

  @Test func stateDescribesBothDecks() async throws {
    let s = try await call(try model(), "state")
    #expect(s["decks"]?["A"]?["mode"]?.string == "sample")
    #expect(s["decks"]?["B"]?["playing"]?.bool == false)
    #expect(s["crossfader"]?.double == 0.5)
    #expect(s["build"]?["id"]?.string == BuildInfo.current.id)
  }

  @Test func stateReportsLocksFollowHeadphonesAndView() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites())
    m.defaults = scratchDefaults()
    m.start()
    m.setLocked("play", true)
    m.setPFL("B", true)
    m.setHeadphoneMix(0.25)
    m.setHeadphoneLevel(0.5)
    m.showSoundboard = true
    m.scopeKind = .spectro
    m.scopeSource = .deck("A")
    m.newCrate("warmup")
    m.variations = ["bass": [VoiceVariation(name: "deep", params: VoiceTweak(), useSynth: true)]]
    _ = try await call(m, "perform", #"{"action":{"op":"loopFollow","mode":"source"}}"#)

    let s = try await call(m, "state")
    #expect(s["locked"]?.array?.compactMap(\.string) == ["play"])
    #expect(s["loops"]?["follow"]?["mode"]?.string == "source")
    #expect(s["headphones"]?["mix"]?.double == 0.25)
    #expect(s["headphones"]?["level"]?.double == 0.5)
    #expect(s["headphones"]?["pfl"]?["A"]?.bool == false)
    #expect(s["headphones"]?["pfl"]?["B"]?.bool == true)
    #expect(s["inpulseOutput"] != nil, "present, null when no Inpulse is attached")
    #expect(s["awake"]?.bool == false)
    #expect(s["view"]?["soundboard"]?.bool == true)
    #expect(s["scope"]?["kind"]?.string == "spectro")
    #expect(s["scope"]?["source"]?.string == "A")
    #expect(s["scope"]?["measured"]?.bool == false)
    #expect(s["stage"]?["open"]?.bool == false)
    #expect(s["stage"]?["visualizer"]?.string == "constellation")
    #expect(m.stageModel?.isAttached == false, "reading the stage does not attach its feed")
    #expect(s["crates"]?.array?.compactMap(\.string) == ["warmup"])
    #expect(s["variations"]?["bass"]?.array?.first?["name"]?.string == "deep")
    #expect(s["variations"]?["bass"]?.array?.first?["useSynth"]?.bool == true)
  }

  @Test func viewFoldsSectionsScopeAndStage() async throws {
    let m = try model()
    m.defaults = scratchDefaults()
    // nothing saved: the decks open on Perform, as DeckSections does
    let before = try await call(m, "view")
    #expect(before["sections"]?["A"]?.array?.compactMap(\.string) == ["perform"])

    let v = try await call(
      m, "view",
      #"""
      {"sections":{"A":["history","perform"],"B":[]},"loopMasterFx":true,
       "scope":{"open":true,"kind":"bands","source":"B","measured":true}}
      """#)
    // saved exactly as a click in DeckSections saves it: Section order, comma-separated
    #expect(m.defaults.string(forKey: "fold.A") == "perform,history")
    #expect(m.defaults.string(forKey: "fold.B") == "")
    #expect(v["sections"]?["A"]?.array?.compactMap(\.string) == ["perform", "history"])
    #expect(v["sections"]?["B"]?.array?.isEmpty == true)
    #expect(v["loopMasterFx"]?.bool == true && m.showLoopMasterFx)
    #expect(m.showScopes && m.scopeKind == .bands && m.scopeSource == .deck("B") && m.scopeMeasured)
    #expect(v["scope"]?["kind"]?.string == "bands")
    #expect(v["scope"]?["source"]?.string == "B")
    #expect(v["scope"]?["measured"]?.bool == true)

    // bad values change nothing
    await #expect(throws: (any Error).self) {
      try await call(m, "view", #"{"loopMasterFx":false,"sections":{"A":["mixer"]}}"#)
    }
    await #expect(throws: (any Error).self) {
      try await call(m, "view", #"{"scope":{"kind":"oscilloscope"}}"#)
    }
    #expect(m.showLoopMasterFx && m.defaults.string(forKey: "fold.A") == "perform,history")
    // without a window (tests) the Stage cannot open
    await #expect(throws: (any Error).self) {
      try await call(m, "view", #"{"stage":{"open":true}}"#)
    }

    var opened = 0
    var closed = 0
    m.openStageWindow = { opened += 1 }
    m.closeStageWindow = { closed += 1 }
    let s = try await call(
      m, "view",
      #"""
      {"stage":{"open":true,"source":"A","visualizer":"sonar","overlays":["tilt","bolts"],
       "background":"stars"}}
      """#)
    #expect(opened == 1 && closed == 0)
    let settings = try #require(m.stageModel?.settings)
    #expect(settings.source == .deck("A") && settings.visualizer == .sonar)
    #expect(settings.overlays == [.tilt, .bolts] && settings.bgMode == .stars)
    #expect(s["stage"]?["visualizer"]?.string == "sonar")
    #expect(s["stage"]?["overlays"]?.array?.compactMap(\.string) == ["bolts", "tilt"])
    #expect(s["stage"]?["background"]?.string == "stars")
    #expect(s["stage"]?["source"]?.string == "A")
    // the case's name is taken too
    _ = try await call(m, "view", #"{"stage":{"open":false,"visualizer":"constellation"}}"#)
    #expect(closed == 1 && settings.visualizer == .constellation)
    await #expect(throws: (any Error).self) {
      try await call(m, "view", #"{"stage":{"background":"plaid"}}"#)
    }
    #expect(settings.bgMode == .stars)
  }

  @Test func performGoesThroughTheEngine() async throws {
    let m = try model()
    let a = try await call(m, "perform", #"{"action":{"op":"play","deck":"A","on":true}}"#)
    #expect(a["playing"]?.bool == true)
    #expect(m.engine?["A"]?.playing == true)
    _ = try await call(m, "perform", #"{"action":{"op":"crossfader","value":0.1}}"#)
    #expect(m.engine?.crossfader == 0.1)
  }

  @Test func performIsRecordedLikeAButton() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let rec = try SessionRecorder.start(on: dj)
    _ = try await call(
      m, "perform", #"{"action":{"op":"param","deck":"B","name":"filter","value":0.2}}"#)
    #expect(
      rec.finish().events.map(\.kind) == [.action(.param(deck: "B", name: "filter", value: 0.2))])
  }

  @Test func badRequestsSayWhatIsWrong() async throws {
    let m = try model()
    for (params, words) in [
      (#"{"action":{"op":"play","deck":"C","on":true}}"#, "no deck"),
      (#"{"action":{"op":"spin","deck":"A"}}"#, "known `op`"),
      (#"{"action":{"op":"macro","deck":"A","macro":"drop"}}"#, "needs a net deck"),
      (#"{"action":{"op":"mixOut","deck":"A"}}"#, "mixOut needs a net deck"),
      (#"{"action":{"op":"mixIn","deck":"B","bars":2}}"#, "mixIn needs a net deck"),
      (#"{"action":{"op":"load","deck":"A","source":{"kind":"none"}}}"#, "dj_generate"),
    ] {
      await #expect {
        try await call(m, "perform", params)
      } throws: { "\($0)".contains(words) }
    }
    await #expect(throws: (any Error).self) { try await call(m, "nope") }
  }

  @Test func loopFollowAndGridGoThroughPerform() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let rec = try SessionRecorder.start(on: dj)
    _ = try await call(m, "perform", #"{"action":{"op":"loopFollow","mode":"source"}}"#)
    #expect(dj.loopFollow == .source)
    _ = try await call(
      m, "perform", #"{"action":{"op":"grid","deck":"A","bpm":96,"offset":0.25}}"#)
    #expect(dj["A"]?.beatGrid?.bpm == 96)
    #expect(dj["A"]?.beatGrid?.offset == 0.25)
    let kinds = rec.finish().events.map(\.kind)
    #expect(kinds.contains(.action(.loopFollow(mode: "source"))))
    #expect(kinds.contains(.action(.grid(deck: "A", bpm: 96, offset: 0.25))))
    for (params, words) in [
      (#"{"action":{"op":"loopFollow","mode":"quieter"}}"#, "loopFollow mode"),
      (#"{"action":{"op":"grid","deck":"A","bpm":0}}"#, "bpm must be > 0"),
      (#"{"action":{"op":"grid","deck":"B","bpm":-120}}"#, "bpm must be > 0"),
    ] {
      await #expect {
        try await call(m, "perform", params)
      } throws: { "\($0)".contains(words) }
    }
    #expect(dj.loopFollow == .source)
    #expect(dj["A"]?.beatGrid?.bpm == 96)
  }

  /// The controls only a controller had (rewind, deck focus, STEMS, a master FX slider) are
  /// dj_perform ops, recorded as actions, checked like the rest.
  @Test func controllerOnlyControlsGoThroughPerform() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    _ = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    let rec = try SessionRecorder.start(on: dj)
    _ = try await call(m, "perform", #"{"action":{"op":"focus","deck":"L"}}"#)
    #expect(dj.focus == "L")
    _ = try await call(m, "perform", #"{"action":{"op":"focus","deck":"B"}}"#)
    #expect(dj.focus == "B")
    #expect(try await call(m, "state")["focus"]?.string == "B")
    _ = try await call(
      m, "perform", #"{"action":{"op":"masterFx","deck":"B","key":"lp-freq","value":0.25}}"#)
    #expect(dj["B"]?.wave.masterFxSet[.lpFreq] == 25)
    _ = try await call(
      m, "perform", #"{"action":{"op":"masterFx","deck":"B","key":"master-pitch","value":1}}"#)
    #expect(dj["B"]?.wave.masterFxSet[.masterPitch] == 12)
    _ = try await call(
      m, "perform", #"{"action":{"op":"stemMute","deck":"B","stem":"music","on":true}}"#)
    #expect(dj["B"]?.isStemMuted("music") == true)
    // asking for the state it is already in changes nothing
    _ = try await call(
      m, "perform", #"{"action":{"op":"stemMute","deck":"B","stem":"music","on":true}}"#)
    #expect(dj["B"]?.isStemMuted("music") == true)
    _ = try await call(
      m, "perform", #"{"action":{"op":"stemMute","deck":"B","stem":"music","on":false}}"#)
    #expect(dj["B"]?.isStemMuted("music") == false)
    _ = try await call(m, "perform", #"{"action":{"op":"rewind","deck":"A"}}"#)
    let kinds = rec.finish().events.map(\.kind)
    #expect(kinds.contains(.action(.focus(deck: "L"))))
    #expect(kinds.contains(.action(.masterFx(deck: "B", key: "lp-freq", value: 0.25))))
    #expect(kinds.contains(.action(.stemMute(deck: "B", stem: "music", on: true))))
    #expect(kinds.contains(.action(.rewind(deck: "A"))))
    for (params, words) in [
      (#"{"action":{"op":"focus","deck":"C"}}"#, "no deck"),
      (#"{"action":{"op":"stemMute","deck":"A","stem":"music","on":true}}"#, "needs a net deck"),
      (#"{"action":{"op":"stemMute","deck":"B","stem":"drums","on":true}}"#, "stem must be"),
      (#"{"action":{"op":"masterFx","deck":"B","key":"wobble","value":0.5}}"#, "master FX key"),
      (#"{"action":{"op":"masterFx","deck":"B","key":"lp-freq","value":1.5}}"#, "0…1"),
      (#"{"action":{"op":"masterFx","deck":"B","value":0.5}}"#, "known `op`"),
    ] {
      await #expect {
        try await call(m, "perform", params)
      } throws: { "\($0)".contains(words) }
    }
  }

  @Test func generateLoadsALiveNetAndMacrosThenWork() async throws {
    let m = try model()
    let b = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    #expect(b["mode"]?.string == "net")
    #expect((b["sections"]?.array?.count ?? 0) > 0)
    #expect(b["roles"]?["kick"] != nil)
    _ = try await call(m, "perform", #"{"action":{"op":"macro","deck":"B","macro":"drop"}}"#)
    await #expect(throws: (any Error).self) {
      try await call(m, "perform", #"{"action":{"op":"macro","deck":"B","macro":"wobble"}}"#)
    }
    await #expect(throws: (any Error).self) {
      try await call(m, "generate", #"{"deck":"B","genre":"polka","seed":1}"#)
    }
  }

  /// `loadShare` (dj_load_share): share links and payloads from the JS fixtures go on a deck
  /// through `perform`, recorded as the load a replay needs.
  @Test func loadShareLoadsComposedAndRawNetsSharesAndRecordsThem() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let urls = try #require(try beatsFixture("share-urls")["urls"]?.array)
    let full = try #require(
      urls.first { $0["payload"]?["genre"]?.string == "house" && $0["z"] != nil })
    let raw = try #require(
      try beatsFixture("share-urls")["rawNets"]?.array?.first {
        $0["payload"]?["name"]?.string == "Hand Made"
      })
    let envelope = try #require(
      try beatsFixture("envelopes")["envelopes"]?.array?.first {
        $0["payload"]?["traits"]?["modal-interchange"] != nil && $0["project"] != nil
      })
    let rec = try SessionRecorder.start(on: dj)

    // a full share URL: composed
    let b = try await m.control(
      "loadShare",
      .object(JSONObject([("deck", .string("B")), ("link", full["url"]!)])))
    #expect(b["mode"]?.string == "net")
    #expect(b["share"]?["kind"]?.string == "net" && b["share"]?["genre"]?.string == "house")
    let houseSpec = try #require(TrackSpec(share: Share(payload: full["payload"]!)))
    #expect(dj["B"]?.currentSpec == houseSpec)

    // a raw-nets share link (its query alone)
    let a = try await m.control(
      "loadShare", .object(JSONObject([("deck", .string("A")), ("link", raw["search"]!)])))
    #expect(a["share"]?["kind"]?.string == "rawNets")
    #expect(a["share"]?["cid"]?.string == raw["cid"]!.string!)
    #expect(a["title"]?.string == "Hand Made")
    #expect(dj["A"]?.netProject?.modelCID == raw["project"]?["modelCID"]?.string)

    // an envelope payload, as JSON text and as an object
    let text = envelope["payload"]!.jsStringified
    let e = try await m.control(
      "loadShare", .object(JSONObject([("deck", .string("B")), ("link", .string(text))])))
    #expect(e["share"]?["kind"]?.string == "net")
    let envSpec = try #require(dj["B"]?.currentSpec)
    #expect(envSpec.layers.entries.isEmpty)
    #expect(envSpec.project().modelCID == envelope["project"]?["modelCID"]?.string)
    _ = try await m.control(
      "loadShare", .object(JSONObject([("deck", .string("B")), ("link", envelope["payload"]!)])))
    #expect(dj["B"]?.currentSpec == envSpec)

    let loads = rec.finish().events.map(\.kind)
    #expect(
      loads == [
        .action(.load(deck: "B", source: .net(houseSpec))),
        .action(.load(deck: "A", source: .rawNets(payload: raw["payload"]!))),
        .action(.load(deck: "B", source: .net(envSpec))),
        .action(.load(deck: "B", source: .net(envSpec))),
      ])
  }

  /// Load ▸ "Share link from clipboard" calls `AppModel.loadShare(deck, text)` with the
  /// pasteboard's string: a good link lands on the deck (recorded), a bad one only says why.
  @Test func theClipboardMenuItemLoadsAShareOrSaysWhy() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let raw = try #require(
      try beatsFixture("share-urls")["rawNets"]?.array?.first {
        $0["payload"]?["name"]?.string == "Hand Made"
      })
    let rec = try SessionRecorder.start(on: dj)
    m.loadShare("A", "  " + raw["search"]!.string! + "\n")  // pasted text, with whitespace
    for _ in 0..<2000 where dj["A"]?.mode != .net { try await Task.sleep(for: .milliseconds(5)) }
    #expect(dj["A"]?.mode == .net && dj["A"]?.title == "Hand Made")
    #expect(
      rec.finish().events.map(\.kind) == [
        .action(.load(deck: "A", source: .rawNets(payload: raw["payload"]!)))
      ])
    m.loadShare("B", "not a link")
    #expect(m.status.hasPrefix("share: not a beats share"))
    m.loadShare("B", "")  // an empty clipboard
    #expect(m.status.hasPrefix("share: "))
    #expect(dj["B"]?.mode == .sample, "nothing was loaded")
  }

  @Test func loadShareSaysWhatIsWrong() async throws {
    let m = try model()
    let urls = try #require(try beatsFixture("share-urls")["urls"]?.array)
    let short = try #require(urls.first { $0["needsFetch"]?.bool == true })
    let tampered = try #require(urls.first { $0["label"]?.string?.hasPrefix("tampered") == true })
    for (params, words) in [
      (#"{"deck":"A","link":"\#(short["url"]!.string!)"}"#, "short link"),
      (#"{"deck":"A","link":"\#(tampered["search"]!.string!)"}"#, "not a beats share"),
      (#"{"deck":"A","link":"{\"genre\":\"polka\",\"seed\":1}"}"#, "unknown genre"),
      (#"{"deck":"A"}"#, "`link` is required"),
      (#"{"deck":"C","link":"?g=house"}"#, "no deck"),
    ] {
      await #expect {
        try await call(m, "loadShare", params)
      } throws: { "\($0)".contains(words) }
    }
    #expect(m.engine?["A"]?.mode == .sample, "nothing was loaded")
  }

  @Test func catalogListsWhatTheToolsAccept() async throws {
    let c = try await call(try model(), "catalog")
    #expect(c["genres"]?.array?.contains(.string("techno")) == true)
    #expect(c["macros"]?.array?.contains { $0["id"]?.string == "drop" } == true)
    #expect((c["apcPads"]?.array?.count ?? 0) > 0)
  }

  @Test func padsPressTheOnScreenAPC() async throws {
    let m = try model()
    let s = try await call(m, "pad", #"{"group":"pads","index":0}"#)
    #expect(s["padsOnScreen"]?.bool == true)
    await #expect(throws: (any Error).self) {
      try await call(m, "pad", #"{"group":"pads","index":99}"#)
    }
  }

  @Test func catalogSaysWhatEachInstrumentSoundsLike() async throws {
    let c = try await call(try model(), "catalog")
    let sounds = Dictionary(
      uniqueKeysWithValues: (c["instruments"]?.array ?? []).compactMap { e in
        e["name"]?.string.map { ($0, e["sound"]?.string ?? "") }
      })
    // each instrument names its category and what this Mac has for it
    #expect(sounds["acoustic-guitar"]?.hasPrefix("guitar.acoustic: ") == true)
    #expect(sounds["supersaw"]?.hasSuffix("or table:saw") == true)
    #expect(sounds["distorted-guitar"]?.hasSuffix("or pluck") == true)
    #expect(c["voices"]?["bass.electric"]?.array?.isEmpty == false)

    #expect(sounds["drums-808"] == "drum kit")
  }

  @Test func auditionRendersAnInstrumentWithoutTouchingTheDecks() async throws {
    let m = try model()
    let before = try await call(m, "state")
    let a = try await call(
      m, "audition", #"{"instrument":"electric-guitar","notes":[40,45,50],"play":false}"#)
    #expect(a["sound"]?.string?.hasPrefix("guitar.electric") == true)
    let plays = a["plays"]?.string ?? ""
    #expect(
      plays.hasPrefix("exs:") || plays.hasPrefix("sf2:") || plays.hasPrefix("gm:"),
      "played \(plays)")
    #expect((a["rmsDB"]?.double ?? -200) > -40)
    #expect(a["path"]?.string?.hasSuffix("electric-guitar.wav") == true)
    #expect(try await call(m, "state") == before)
    await #expect(throws: (any Error).self) {
      try await call(m, "audition", #"{"instrument":"kazoo","play":false}"#)
    }
    await #expect(throws: (any Error).self) {
      try await call(m, "audition", #"{"instrument":"bass","sound":"tuba","play":false}"#)
    }
  }
}

/// dj_variations: the sound panel's saved variations through the control socket, on a
/// temporary store (never the user's voices.json), each edit journaled.
extension AppControlTests {
  @Test func variationsSaveApplyRenameDelete() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(
      engine: dj, favorites: temporaryFavorites(), voices: temporaryVoiceVariations(),
      notes: temporaryNotes(), journal: temporaryJournalDir())
    m.start()
    #expect(m.variationStore.file != VoiceVariationStore.defaultFile)
    let a = try await call(
      m, "generate", #"{"deck":"A","genre":"techno","seed":42,"structure":"minimal"}"#)
    let melody = try #require(
      a["voices"]?.array?.first { $0["role"]?.string?.contains("melody") == true })
    let ch = try #require(melody["channel"]?.int)
    let inst = try #require(melody["instrument"]?.string)

    // nothing saved; saving the instrument's own voice is refused
    #expect(try await call(m, "variations")["variations"] == .object(JSONObject()))
    await #expect {
      try await call(
        m, "variations", "{\"action\":\"save\",\"deck\":\"A\",\"channel\":\(ch),\"name\":\"zap\"}")
    } throws: { "\($0)".contains("own voice") }
    await #expect {
      try await call(m, "variations", #"{"action":"save","deck":"A","channel":99,"name":"zap"}"#)
    } throws: { "\($0)".contains("channels:") }

    // save what the channel sounds like
    _ = try await call(
      m, "perform",
      "{\"action\":{\"op\":\"voiceTweak\",\"deck\":\"A\",\"channel\":\(ch),\"params\":{\"gainDB\":-6,\"attack\":0.05}}}"
    )
    let saved = try await call(
      m, "variations", "{\"action\":\"save\",\"deck\":\"A\",\"channel\":\(ch),\"name\":\"soft\"}")
    let list = try #require(saved["variations"]?[inst]?.array)
    #expect(list.map { $0["name"]?.string } == ["soft"])
    #expect(list.first?["params"]?["gainDB"]?.double == -6)
    #expect(m.variationStore.list(inst).map(\.name) == ["soft"])
    let listed = try await call(m, "variations", "{\"instrument\":\"\(inst)\"}")
    #expect(listed["variations"]?[inst]?.array?.count == 1)

    // back to the instrument's voice, then apply it
    _ = try await call(
      m, "perform",
      "{\"action\":{\"op\":\"voiceTweak\",\"deck\":\"A\",\"channel\":\(ch),\"params\":{}}}")
    let applied = try await call(
      m, "variations", "{\"action\":\"apply\",\"deck\":\"A\",\"channel\":\(ch),\"name\":\"soft\"}")
    let voice = try #require(applied["voices"]?.array?.first { $0["channel"]?.int == ch })
    #expect(voice["tweak"]?["gainDB"]?.double == -6)
    #expect(voice["variation"]?.string == "soft")
    await #expect {
      try await call(
        m, "variations", "{\"action\":\"apply\",\"deck\":\"A\",\"channel\":\(ch),\"name\":\"loud\"}"
      )
    } throws: { "\($0)".contains("variations of \(inst): soft") }

    // rename, delete
    let renamed = try await call(
      m, "variations",
      "{\"action\":\"rename\",\"instrument\":\"\(inst)\",\"name\":\"soft\",\"to\":\"gentle\"}")
    #expect(renamed["variations"]?[inst]?.array?.map { $0["name"]?.string } == ["gentle"])
    let deleted = try await call(
      m, "variations",
      "{\"action\":\"delete\",\"deck\":\"A\",\"channel\":\(ch),\"name\":\"gentle\"}")
    #expect(deleted["variations"]?[inst]?.array?.isEmpty == true)
    #expect(m.variationStore.list(inst).isEmpty)
    await #expect { try await call(m, "variations", #"{"action":"tweak"}"#) } throws: {
      "\($0)".contains("list | save | apply | rename | delete")
    }

    // each edit is journaled; the apply as the panel's acts
    let events = (m.journal?.recent ?? []).map(\.event)
    #expect(events.contains { if case .variationSave = $0 { true } else { false } })
    #expect(events.contains(.variationRename(instrument: inst, name: "soft", to: "gentle")))
    #expect(events.contains(.variationDelete(instrument: inst, name: "gentle")))
    let tweaks = events.filter {
      if case .action(.voiceTweak(_, let c, let t)) = $0 {
        c == ch && t.gainDB == -6
      } else {
        false
      }
    }
    #expect(tweaks.count == 2, "the perform and the apply")
  }
}

/// The bottom bar's "Awake": a PreventUserIdleDisplaySleep assertion while on, saved.
@MainActor
struct ScreenWakeLockTests {
  @Test func awakeHoldsTheDisplayAssertionAndRemembersIt() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let m = AppModel(engine: dj)
    m.defaults = scratchDefaults()
    m.start()
    let display = "PreventUserIdleDisplaySleep"
    #expect(!m.keepScreenAwake && !m.screenWakeLock.isHeld)
    m.setKeepScreenAwake(true)
    #expect(m.screenWakeLock.isHeld)
    #expect(ownPowerAssertionTypes().contains(display), "\(ownPowerAssertionTypes())")
    #expect(m.defaults.bool(forKey: AppModel.keepScreenAwakeKey))
    #expect(m.controlState()["keepScreenAwake"] == .bool(true))
    m.setKeepScreenAwake(true)  // twice is still one hold
    m.setKeepScreenAwake(false)
    #expect(!m.screenWakeLock.isHeld)
    #expect(!ownPowerAssertionTypes().contains(display))
    #expect(!m.defaults.bool(forKey: AppModel.keepScreenAwakeKey))
  }
}
