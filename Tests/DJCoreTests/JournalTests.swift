import Darwin
import Testing

@testable import DJCore

private let rate = 11_025.0
private let apc = "APC mini mk2 Control"

struct JournalCodecTests {
  static let spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
  static let note = TrackNote(
    id: "n-1", target: .track(cid: BeatsCID.shareCID(spec.payload)), title: "Neon Vale",
    text: "drop hits here", position: NotePosition(bar: 17, beat: 1, seconds: 31.75),
    created: journalDate(1_760_000_000.123), edited: journalDate(1_760_000_100.5))

  static var everyEvent: [JournalEvent] {
    var s = JournalState(
      sampleRate: 48_000,
      decks: [
        "A": DeckCheckpoint(
          source: .net(spec), params: DeckParams(), playing: true, leader: "B",
          voices: [
            3: VoiceSetting(tweak: VoiceTweak(), useSynth: true, instrument: "laser")
          ]),
        "B": DeckCheckpoint(source: .sample(id: "demo-loop", title: "demo", grid: nil)),
      ])
    s.clips = [
      ClipCheckpoint(
        id: "abc", title: "A loop 1", color: "red", gain: 0.5, muted: true, soloed: false,
        keyLock: true, quantum: 16, fade: .bar, looping: true)
    ]
    s.scenes = [LoopScene(name: "Scene 1", clips: [SceneClip(clipID: "abc", gain: 0.5)])]
    s.removed = [("def", 2)]
    s.locked = ["A.play"]
    s.stores = JournalStoreState(
      favorites: [Favorite(title: "x", source: .net(spec), added: wholeSecond(1_700_000_000))],
      crates: ["intro"], variations: ["laser": [VoiceVariation(name: "zap", params: VoiceTweak())]],
      notes: [note])
    return [
      .checkpoint(s),
      .action(.play(deck: "A", on: true)),
      .action(.clipMove(id: "abc", before: "def")),
      .action(.clipMove(id: "abc", before: nil)),
      .action(.lock(key: "A.hotcue.1", on: true)),
      .action(.lock(key: "A.hotcue.1", on: false)),
      .action(.clipQuantize(id: "abc", beats: 8)),
      .action(.clipFade(id: "abc", mode: nil)),
      .midi(port: apc, bytes: [0x90, 48, 0x7F]),
      .sampleFile(id: "abc123", path: "/tmp/a b.wav"),
      .libraryRestore(id: "abc", index: 3),
      .favoriteAdd(
        Favorite(
          title: "loop", source: .sample(id: "", title: "loop", grid: nil),
          added: wholeSecond(1_700_000_001), file: "/x.caf", tags: ["a", "b"])),
      .favoriteRemove(cid: "z4x"),
      .favoriteTags(cid: "z4x", tags: ["intro", "heavy"]),
      .favoriteTags(cid: "z4x", tags: []),
      .crateAdd(name: "set 1"),
      .crateDelete(name: "set 1"),
      .variationSave(
        instrument: "laser",
        variation: VoiceVariation(name: "short", params: VoiceTweak(), useSynth: true)),
      .variationRename(instrument: "laser", name: "short", to: "shorter"),
      .variationDelete(instrument: "laser", name: "shorter"),
      .noteAdd(note),
      .noteAdd(
        TrackNote(
          id: "n-2", target: .sample(id: "abc", file: "/x.caf"), text: "no place",
          created: journalDate(1_760_000_000))),
      .noteAdd(TrackNote(id: "n-3", target: .clip(id: "abc"), text: "c", created: journalDate(1))),
      .noteEdit(id: "n-1", text: "the drop", at: journalDate(1_760_000_200.25)),
      .noteDelete(id: "n-1"),
      .storesReplace(s.stores),
      .storesReplace(JournalStoreState()),
      .mark("session.start"),
    ]
  }

  @Test func everyEventKindRoundTripsThroughItsLine() throws {
    let kinds = Set(Self.everyEvent.map(\.kind))
    #expect(kinds.count == 18, "one of each kind: \(kinds.sorted())")
    for (i, ev) in Self.everyEvent.enumerated() {
      let e = JournalEntry(
        seq: i, time: journalDate(1_760_000_000.5 + Double(i)), frame: i * 128, event: ev)
      let line = e.line
      #expect(!line.contains("\n"))
      let back = try #require(JournalEntry(line: line), "\(ev.kind) decodes")
      #expect(back == e, "\(ev.kind) round-trips")
      #expect(back.line == line, "\(ev.kind) re-encodes to the same bytes")
    }
  }

  @Test func theNewPokesRoundTripAsDeckActions() throws {
    for a in [
      DeckAction.clipMove(id: "a", before: "b"), .clipMove(id: "a", before: nil),
      .lock(key: "B.macro.drop", on: true), .lock(key: "B.macro.drop", on: false),
      .clipQuantize(id: "a", beats: 32), .clipQuantize(id: "a", beats: nil),
      .clipFade(id: "a", mode: "beat"), .clipFade(id: "a", mode: nil),
    ] {
      #expect(DeckAction(json: try JSONValue.parse(a.json.jsStringified)) == a)
    }
  }

  /// The controller-only controls as actions (rewind, focus, STEMS, a master FX slider): each
  /// round-trips through its line, a slider's moves fold into one row like a knob's, and each
  /// reads as a line for people.
  @Test func theControllerActionsRoundTripFoldAndRead() throws {
    let actions: [DeckAction] = [
      .rewind(deck: "A"), .focus(deck: "L"), .stemMute(deck: "B", stem: "music", on: true),
      .stemMute(deck: "B", stem: "mic", on: false),
      .masterFx(deck: "A", key: "lp-freq", value: 0.25),
      .masterFx(deck: "L", key: "master-pitch", value: 1),
    ]
    for (i, a) in actions.enumerated() {
      #expect(DeckAction(json: try JSONValue.parse(a.json.jsStringified)) == a)
      let e = JournalEntry(seq: i + 1, time: journalDate(1), frame: i, event: .action(a))
      #expect(try #require(JournalEntry(line: e.line)).event == .action(a))
    }
    // a masterFx without its key does not decode
    #expect(
      DeckAction(json: try JSONValue.parse(#"{"op":"masterFx","deck":"A","value":1}"#)) == nil)
    let fx = JournalEvent.action(.masterFx(deck: "A", key: "lp-freq", value: 0.25))
    #expect(fx.foldKey == "A.fx.lp-freq")
    #expect(
      JournalEvent.action(.masterFx(deck: "A", key: "lp-freq", value: 0.9)).foldKey == fx.foldKey)
    #expect(
      JournalEvent.action(.masterFx(deck: "A", key: "hp-freq", value: 0.9)).foldKey != fx.foldKey)
    #expect(fx.foldKey != JournalEvent.action(.param(deck: "A", name: "filter", value: 0)).foldKey)
    #expect(JournalEvent.action(.rewind(deck: "A")).foldKey == nil)
    #expect(fx.summary == "A fx lp-freq 0.25")
    #expect(JournalEvent.action(.rewind(deck: "A")).summary == "A rewind")
    #expect(JournalEvent.action(.focus(deck: "L")).summary == "focus L")
    #expect(
      JournalEvent.action(.stemMute(deck: "B", stem: "mic", on: true)).summary
        == "B stem mic muted")
  }

  /// The master FX slider's mapping is one function, the controller's and the action's: 0…1 of
  /// the travel onto the slider's own range, rounded and clamped.
  @Test func aMasterFxPositionMapsOntoTheSlidersRange() {
    #expect(MasterFxKey.lpFreq.sliderValue(0) == 0 && MasterFxKey.lpFreq.sliderValue(1) == 100)
    #expect(MasterFxKey.lpFreq.sliderValue(0.254) == 25)
    #expect(MasterFxKey.masterPitch.sliderValue(0) == -12)
    #expect(MasterFxKey.masterPitch.sliderValue(0.5) == 0)
    #expect(MasterFxKey.masterPitch.sliderValue(1) == 12)
    #expect(
      MasterFxKey.crushBits.sliderValue(2) == 100 && MasterFxKey.crushBits.sliderValue(-1) == 0)
    #expect(MasterFxKey.distortion.sliderValue(.nan) == 0)
    // a controller fader at 64/127 lands where the action at the same position does
    #expect(MasterFxKey.phaserWet.sliderValue(64.0 / 127) == 50)
  }

  /// A clip's own launch boundary and fade are in a checkpoint only when it has them, and a
  /// restore gives them back.
  @Test func aCheckpointKeepsAClipsLaunchBoundaryAndFade() throws {
    let plain = ClipCheckpoint(id: "abc", title: "A loop 1")
    var s = JournalState(sampleRate: 48_000, clips: [plain])
    let before = s.json.canonicalJS
    #expect(!before.contains("quantum") && !before.contains("\"fade\""))
    s.clips[0].quantum = 16
    s.clips[0].fade = .off
    let back = try #require(JournalState(json: try JSONValue.parse(s.json.canonicalJS)))
    #expect(back.clips == s.clips)
    s.clips = [plain]
    #expect(s.json.canonicalJS == before, "without them: byte for byte as before")

    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 48_000)
    let n = 4800
    let b = SampleBuffer(left: (0..<n).map { Float($0 % 50) * 1e-3 }, sampleRate: 48_000)
    let c = LoopClip(
      id: b.contentID, title: "A loop 1", source: "A", bars: 1, bpm: 120, startBeat: 0,
      buffer: b, waveform: WaveformOverview(buffer: b, columns: 10))
    dj.restoreClips([c])
    dj.setClipQuantum(c.id, 32)
    dj.setClipFade(c.id, .beat)
    let state = JournalState(engine: dj)
    #expect(state.clips.first?.quantum == 32 && state.clips.first?.fade == .beat)
    let fresh = try DJEngine(decks: ["A"], offline: true, sampleRate: 48_000)
    state.restore(into: fresh) { $0 == c.id ? c : nil }
    #expect(fresh.clipQuantum(c.id) == 32 && fresh.clipFade(c.id) == .beat)
  }

  @Test func aLineCarriesTheFieldsTheFormatPromises() throws {
    let e = JournalEntry(
      seq: 7, time: journalDate(1_760_000_000.25), frame: 96_000,
      event: .action(.param(deck: "A", name: "volume", value: 0.5)))
    let v = try JSONValue.parse(e.line)
    #expect(v["v"]?.int == 1)
    #expect(v["seq"]?.int == 7)
    #expect(v["f"]?.int == 96_000)
    #expect(v["k"]?.string == "act")
    #expect(v["t"]?.string == "2025-10-09T08:53:20.250Z")
    #expect(v["a"]?["op"]?.string == "param")
  }

  @Test func aTornLastLineIsDroppedNotFatal() throws {
    let lines = Self.everyEvent.prefix(4).enumerated().map { i, ev in
      JournalEntry(seq: i, time: journalDate(Double(i)), frame: i, event: ev).line
    }
    let whole = lines.joined(separator: "\n") + "\n"
    #expect(Journal.parse(whole).entries.count == 4)
    #expect(!Journal.parse(whole).truncated)
    // the app stopped mid-write: the last line is cut short and has no newline
    let torn = String(whole.dropLast(9))
    let c = Journal.parse(torn)
    #expect(c.entries.count == 3)
    #expect(c.truncated)
    #expect(c.skipped.isEmpty)
    #expect(c.checkpoint != nil)
    // a bad line in the middle is skipped and reported, the rest still read
    let middle =
      [lines[0], "{not json", lines[1], #"{"v":9,"seq":2,"f":0,"k":"from.the.future"}"#, lines[2]]
      .joined(separator: "\n") + "\n"
    let m = Journal.parse(middle)
    #expect(m.entries.map(\.seq) == [0, 1, 2])
    #expect(m.skipped == [2, 4])
    #expect(!m.truncated)
  }

  @Test func theStoreEventsDoWhatTheStoresDo() {
    var s = JournalStoreState()
    let spec = Self.spec
    let f = Favorite(title: "t", source: .net(spec), added: wholeSecond(1))
    s.apply(.favoriteAdd(f))
    s.apply(.favoriteTags(cid: f.cid, tags: [" intro ", "Intro", "", "heavy"]))
    #expect(s.favorites.first?.tags == ["intro", "heavy"])
    // starring again keeps the tags, as FavoritesStore.add does
    s.apply(.favoriteAdd(Favorite(title: "t2", source: .net(spec), added: wholeSecond(2))))
    #expect(
      s.favorites.count == 1 && s.favorites[0].title == "t2" && s.favorites[0].tags.count == 2)
    s.apply(.crateAdd(name: " set 1 "))
    s.apply(.crateAdd(name: "set 1"))
    #expect(s.crates == ["set 1"])
    s.apply(
      .variationSave(
        instrument: "laser", variation: VoiceVariation(name: "a", params: VoiceTweak())))
    s.apply(.variationRename(instrument: "laser", name: "a", to: "b"))
    #expect(s.variations["laser"]?.map(\.name) == ["b"])
    s.apply(.variationDelete(instrument: "laser", name: "b"))
    #expect(s.variations["laser"] == nil)
    s.apply(.noteAdd(Self.note))
    s.apply(.noteEdit(id: "n-1", text: "  ", at: journalDate(5)))  // blank: ignored
    #expect(s.notes.first?.text == "drop hits here")
    s.apply(.noteEdit(id: "n-1", text: "big drop", at: journalDate(5)))
    #expect(s.notes.first?.text == "big drop" && s.notes.first?.edited == journalDate(5))
    #expect(s.notes.on(f).count == 1, "a favorite of the track carries its note")
    s.apply(.favoriteRemove(cid: f.cid))
    s.apply(.noteDelete(id: "n-1"))
    #expect(s == JournalStoreState(crates: ["set 1"]))
    let handled = s.apply(.action(.play(deck: "A", on: true)))
    #expect(!handled, "a poke is not a store event")
  }

  @Test func aStoresReplaceSetsEveryStore() throws {
    let spec = Self.spec
    var s = JournalStoreState()
    s.apply(.favoriteAdd(Favorite(title: "gone", source: .net(spec), added: wholeSecond(1))))
    s.apply(.crateAdd(name: "old crate"))
    s.apply(
      .variationSave(
        instrument: "laser", variation: VoiceVariation(name: "a", params: VoiceTweak())))
    s.apply(.noteAdd(Self.note))
    let replaced = JournalStoreState(
      favorites: [
        Favorite(
          title: "new", source: .net(TrackSpec(genre: "house", seed: 7)), added: wholeSecond(2),
          tags: ["warm"])
      ],
      crates: ["warm", "set 2"],
      variations: ["bass": [VoiceVariation(name: "deep", params: VoiceTweak(), useSynth: true)]],
      notes: [
        TrackNote(id: "n-9", target: .clip(id: "c"), text: "replaced", created: journalDate(3))
      ])
    let handled = s.apply(.storesReplace(replaced))
    #expect(handled)
    #expect(s == replaced, "nothing of the old stores is left")
    // later edits build on the replaced stores
    s.apply(.crateDelete(name: "set 2"))
    #expect(s.crates == ["warm"] && s.favorites == replaced.favorites)
    // an empty replace clears them all
    s.apply(.storesReplace(JournalStoreState()))
    #expect(s == JournalStoreState())
    // the line carries the whole state
    let e = JournalEntry(seq: 1, time: journalDate(4), frame: 0, event: .storesReplace(replaced))
    #expect(try #require(JournalEntry(line: e.line)).event == .storesReplace(replaced))
    #expect(e.event.foldKey == nil && !e.event.isNote)
  }
}

/// The scripted performance the replay tests share: two decks, loads, knobs, a section jump,
/// a LOOP take and a grab (of the sample deck), clip moves and names, favorites and tags, a crate, a voice
/// variation, a lock (with the MIDI it locks), a note.
@MainActor
struct JournalReplayTests {
  struct Live {
    let state: JournalState
    let contents: Journal.Contents
    let audio: RenderedAudio
    /// The same performance through a `SessionRecorder` alongside (both sinks see each input).
    let session: Session
  }

  /// One live run for every test here (rendering it is the slow part).
  static let shared: Result<Live, Error> = Result { try perform() }

  static func perform(blocks: Int = 400) throws -> Live {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let box = StoreBox()
    let starred = Favorite(
      title: "old one", source: .net(TrackSpec(genre: "house", seed: 3)),
      added: wholeSecond(1_700_000_000), tags: ["warm"])
    box.state.favorites = [starred]
    try dj.start()
    defer { dj.stop() }
    let journal = try Journal(
      engine: dj, directory: dir, started: journalDate(1_760_000_000)
    ) { box.state }
    #expect(dj.journal === journal)
    let recorder = try SessionRecorder.start(on: dj)
    func store(_ e: JournalEvent) {
      journal.record(e)
      box.state.apply(e)
    }
    let router = ControllerRouter(engine: dj)
    router.attach(port: apc)
    let conductor = OfflineConductor(engine: dj, router: router)
    let net = TrackSpec(genre: "techno", seed: 7, structure: "standard")
    var l: [Float] = []
    var r: [Float] = []
    for b in 0..<blocks {
      let (bl, br) = try conductor.step {
        switch b {
        case 0:
          dj.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
          )
          dj.perform(.load(deck: "B", source: .net(net)))
          dj.perform(.play(deck: "A", on: true))
          dj.perform(.play(deck: "B", on: true))
        case 20:
          dj.perform(.param(deck: "A", name: "volume", value: 0.7))
          dj.perform(.crossfader(0.35))
          dj.perform(.param(deck: "B", name: "filter", value: 0.3))
          // B's sampled instruments may vary between renders (round robin, CLAUDE.md): keep it
          // out of the mix and the takes, so audio and clip ids compare exactly
          dj.perform(.param(deck: "B", name: "volume", value: 0))
        case 30: dj.perform(.loopRecord(deck: "A", on: true, bars: 1))
        case 32: dj.perform(.loopRecord(deck: "A", on: false))
        case 150: dj.perform(.section(deck: "B", index: 1))
        case 160:
          store(
            .favoriteAdd(
              Favorite(title: "B track", source: .net(net), added: wholeSecond(1_760_000_001))))
          store(.favoriteTags(cid: BeatsCID.shareCID(net.payload), tags: ["peak", "set 1"]))
          store(.crateAdd(name: "set 1"))
          store(.favoriteTags(cid: starred.cid, tags: []))
        case 170:
          dj.perform(.lock(key: "B.section", on: true))
          router.route(port: apc, bytes: [0x90, 48, 0x7F])
          router.route(port: apc, bytes: [0x80, 48, 0x00])
        case 180:
          let (target, title) = dj.noteTarget("B")!
          store(
            .noteAdd(
              TrackNote(
                id: "n-drop", target: target, title: title, text: "drop hits here",
                position: dj.notePosition("B"), created: journalDate(1_760_000_002))))
          store(
            .variationSave(
              instrument: "laser", variation: VoiceVariation(name: "zap", params: VoiceTweak())))
        case 200:
          // the controller-only controls, as actions: a master FX slider and a rewind on the
          // audible deck, the focus and a STEMS group on the net one
          dj.perform(.masterFx(deck: "A", key: "lp-freq", value: 0.6))
          dj.perform(.rewind(deck: "A"))
          dj.perform(.focus(deck: "B"))
          dj.perform(.stemMute(deck: "B", stem: "music", on: true))
        case 360: dj.perform(.grabBars(deck: "A", bars: 1))
        case 370:
          // both clips are on the row by now
          if let first = dj.clips.first {
            dj.perform(.clipRename(id: first.id, title: "the take"))
            dj.perform(.clipColor(id: first.id, color: LoopClip.palette.first))
            dj.perform(.clipMove(id: first.id, before: nil))
            dj.perform(.clipGain(id: first.id, value: 0.6))
          }
        case 380:
          if let c = dj.clips.first {
            store(
              .noteAdd(
                TrackNote(
                  id: "n-clip", target: .clip(id: c.id), text: "use in the break",
                  created: journalDate(1_760_000_003))))
          }
          dj.perform(.sceneSave(name: "Scene 1"))
        case 395: dj.perform(.param(deck: "A", name: "volume", value: 0.9))
        default: break
        }
      }
      l += bl
      r += br
    }
    let live = JournalState(engine: dj, stores: box.state)
    let session = recorder.finish()
    journal.close()
    #expect(dj.journal == nil)
    return Live(
      state: live, contents: try readNewestJournal(dir),
      audio: RenderedAudio(sampleRate: rate, left: l, right: r), session: session)
  }

  @Test func replayingTheJournalRebuildsTheLiveState() throws {
    let live = try Self.shared.get()
    let c = live.contents
    #expect(c.skipped.isEmpty && !c.truncated)
    #expect(c.entries.first.map { if case .checkpoint = $0.event { true } else { false } } == true)
    #expect(c.entries.map(\.seq) == Array(0..<c.entries.count), "sequence numbers in order")
    let frames = c.entries.map(\.frame)
    #expect(frames == frames.sorted(), "frames never go back")
    let kinds = Set(c.entries.map(\.event.kind))
    for k in [
      "checkpoint", "act", "midi", "favorite.add", "favorite.tags", "crate.add", "note.add",
      "variation.save",
    ] {
      #expect(kinds.contains(k), "journaled \(k)")
    }
    let events = c.entries.map(\.event)
    for a in [
      DeckAction.masterFx(deck: "A", key: "lp-freq", value: 0.6), .rewind(deck: "A"),
      .focus(deck: "B"), .stemMute(deck: "B", stem: "music", on: true),
    ] {
      #expect(events.contains(.action(a)), "journaled \(a.summary)")
    }
    #expect(live.state.clips.count == 2, "a take and a grab: \(live.state.clips.map(\.id))")
    #expect(live.state.clips.last?.title == "the take", "moved to the end, renamed")
    #expect(live.state.locked == ["B.section"])
    #expect(live.state.stores.notes.count == 2)
    #expect(
      live.state.decks["B"]?.source
        == .net(TrackSpec(genre: "techno", seed: 7, structure: "standard")))

    let replay = try Journal.replay(c)
    #expect(replay.warnings.isEmpty, "\(replay.warnings)")
    #expect(replay.lastSeq == c.entries.last?.seq)
    #expect(replay.state.json.canonicalJS == live.state.json.canonicalJS)
    #expect(replay.state == live.state)
  }

  @Test func aReplayIsDeterministic() throws {
    let live = try Self.shared.get()
    let a = try Journal.replay(live.contents, render: true)
    let b = try Journal.replay(live.contents, render: true)
    #expect(a.state == b.state)
    let audioA = try #require(a.audio)
    let audioB = try #require(b.audio)
    #expect(audioA.left == audioB.left && audioA.right == audioB.right)
    #expect(audioA.left.reduce(0) { max($0, abs($1)) } > 0.05, "it plays")
    // and it is the live audio, from the checkpoint on
    let n = min(audioA.frames, live.audio.frames)
    #expect(Array(audioA.left.prefix(n)) == Array(live.audio.left.prefix(n)))
  }

  @Test func aCrashedJournalStillReplaysToItsLastWholeLine() throws {
    let live = try Self.shared.get()
    let lines = live.contents.entries.map(\.line)
    let torn = lines.joined(separator: "\n") + "\n" + String(lines.last!.prefix(20))
    let c = Journal.parse(torn)
    #expect(c.truncated)
    #expect(c.entries.count == lines.count)
    let replay = try Journal.replay(c)
    #expect(replay.state == live.state)
  }

  @Test func replayStopsWhereItIsTold() throws {
    let live = try Self.shared.get()
    let c = live.contents
    // up to the favorites (seq of the first favorite.add): no note yet
    let fav = try #require(c.entries.first { $0.event.kind == "favorite.add" })
    let early = try Journal.replay(c, toSeq: fav.seq)
    #expect(early.lastSeq == fav.seq)
    #expect(early.stores.favorites.count == 2)
    #expect(early.stores.notes.isEmpty)
    #expect(early.stores.crates.isEmpty)
    // by time: a second in, before the favorites
    let t = try Journal.replay(c, endFrame: Int(rate))
    #expect(t.frames >= Int(rate))
    #expect(t.stores.favorites.count == 1)
  }

  @Test func aSliceExportsAsANormalSession() throws {
    let live = try Self.shared.get()
    let c = live.contents
    let section = try #require(
      c.entries.first { if case .action(.section) = $0.event { true } else { false } })
    let last = c.entries.last!.seq
    let session = try Journal.exportSession(c, from: section.seq, to: last)
    #expect(session.decks["B"] == .net(TrackSpec(genre: "techno", seed: 7, structure: "standard")))
    #expect(
      session.decks["A"]
        == .sample(
          id: "demo-loop", title: "demo loop", grid: BeatGrid(bpm: 120, offset: 0, confidence: 1)))
    #expect(session.params["A"]?.volume == 0.7)
    let kinds = session.events.map(\.kind)
    #expect(kinds.contains(.action(.play(deck: "A", on: true))), "a deck that was playing starts")
    #expect(kinds.contains(.action(.lock(key: "B.section", on: true))))
    #expect(
      session.events.first { if case .action(.section) = $0.kind { true } else { false } }?.frame
        == 0)
    // a normal session: it round-trips by CID and renders
    let back = try Session.decode(session.canonical, cid: session.cid)
    #expect(back == session)
    let audio = try SessionPlayer(session: session).render()
    #expect(audio.frames == session.frames)
    #expect(throws: JournalError.emptySlice) {
      try Journal.exportSession(c, from: last + 1, to: last + 5)
    }
  }
}

@MainActor
struct JournalFileTests {
  @Test func oneFilePerRunNamedByItsStartAndListedNewestFirst() throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let a = try Journal(engine: dj, directory: dir, started: journalDate(1_760_000_000))
    let b = try Journal(engine: dj, directory: dir, started: journalDate(1_760_000_000))
    let c = try Journal(engine: dj, directory: dir, started: journalDate(1_760_000_600))
    #expect(dj.journal === c, "the last one opened is the engine's")
    for j in [a, b, c] { j.close() }
    #expect(
      journalNames(dir)
        == [
          "journal-20251009T090320.000Z.jsonl", "journal-20251009T085320.000Z.jsonl",
          "journal-20251009T085320.000Z-2.jsonl",
        ].sorted(by: >))
    let text = newestJournalText(dir)
    #expect(text.hasPrefix(#"{"f":0,"k":"checkpoint","seq":0,"#))
    #expect(text.hasSuffix("\n"))
  }

  @Test func everyInputPathLandsInTheJournal() throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    let journal = try Journal(engine: dj, directory: dir)
    let router = ControllerRouter(engine: dj)
    router.attach(port: apc)
    dj.perform(.crossfader(0.2))  // the UI, MCP and the control socket all come this way
    router.route(port: apc, bytes: [0x90, 48, 0x7F])  // a controller (and on-screen pads)
    dj["A"]!.loadDemo()
    dj["A"]!.setBPM(100)  // a tap (the tempo analysis lands the same way)
    let recent = journal.recent.map(\.event)
    #expect(recent.contains(.action(.crossfader(0.2))))
    #expect(recent.contains(.midi(port: apc, bytes: [0x90, 48, 0x7F])))
    #expect(recent.contains(.action(.grid(deck: "A", bpm: 100, offset: 0))))
    journal.flush()
    let c = try readNewestJournal(dir)
    #expect(c.entries.map(\.event) == recent)
    #expect(journal.lastSeq == recent.count - 1)
    journal.close()
    dj.perform(.crossfader(0.9))
    #expect(try readNewestJournal(dir).entries.count == recent.count, "closed: nothing more")
  }

  @Test func notesKeyTracksByConfiguration() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let spec = TrackSpec(genre: "techno", seed: 5, structure: "standard")
    dj.perform(.load(deck: "A", source: .net(spec)))
    dj.perform(.load(deck: "B", source: .net(spec)))
    let a = try #require(dj.noteTarget("A"))
    #expect(a.target == .track(cid: BeatsCID.shareCID(spec.payload)))
    #expect(dj.noteTarget("B")?.target == a.target, "the same configuration is the same track")
    dj.perform(.load(deck: "B", source: .net(spec.nextVersion)))
    #expect(dj.noteTarget("B")?.target != a.target, "the next seed is another")
    #expect(dj.notePosition("A") == NotePosition(bar: 1, beat: 1, seconds: 0))
    dj.perform(
      .load(deck: "B", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil)))
    #expect(dj.noteTarget("B")?.target == .sample(id: "demo-loop", file: nil))
    let fav = Favorite(title: "t", source: .net(spec))
    #expect(a.target.matches(fav))
    #expect(
      NoteTarget.sample(id: "x", file: "/a.caf").matches(
        Favorite(title: "s", source: .sample(id: "", title: "s", grid: nil), file: "/a.caf")))
  }

  @Test func theNotesStoreIsTheJournalsProjection() throws {
    let store = tempNotesStore()
    let n = JournalCodecTests.note
    try store.add(n)
    try store.edit(n.id, text: "later", at: journalDate(9))
    #expect(store.list().first?.text == "later")
    var projected = JournalStoreState()
    projected.apply(.noteAdd(n))
    projected.apply(.noteEdit(id: n.id, text: "later", at: journalDate(9)))
    #expect(store.list() == projected.notes)
    try store.delete(n.id)
    #expect(store.list().isEmpty)
  }

  @Test func theNewestJournalSaysWhatTheStoresHold() throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    #expect(Journal.latestStores(in: dir) == nil)
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let first = try Journal(
      engine: dj, directory: dir, started: journalDate(1_760_000_000)
    ) { JournalStoreState(crates: ["old"]) }
    first.close()
    let j = try Journal(
      engine: dj, directory: dir, started: journalDate(1_760_000_100)
    ) { JournalStoreState(notes: [JournalCodecTests.note]) }
    j.record(.noteDelete(id: JournalCodecTests.note.id))
    j.record(.crateAdd(name: "new"))
    j.close()
    #expect(Journal.latestStores(in: dir) == JournalStoreState(crates: ["new"]))
  }

  @Test func aReplayEndsWithExactlyTheReplacedStores() throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let j = try Journal(
      engine: dj, directory: dir, started: journalDate(1_760_000_000)
    ) { JournalStoreState(crates: ["old"], notes: [JournalCodecTests.note]) }
    j.record(.crateAdd(name: "before"))
    let replaced = JournalStoreState(
      favorites: [
        Favorite(title: "f", source: .net(JournalCodecTests.spec), added: wholeSecond(5))
      ],
      crates: ["after"])
    j.record(.storesReplace(replaced))
    j.record(.action(.play(deck: "A", on: true)))
    j.close()
    #expect(Journal.latestStores(in: dir) == replaced)
    let c = try Journal.read(j.file)
    var stores = try #require(c.checkpoint?.stores)
    for e in c.entries.dropFirst() { stores.apply(e.event) }
    #expect(stores == replaced)
  }
}
