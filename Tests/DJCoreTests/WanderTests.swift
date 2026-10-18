import Testing

@testable import DJCore

private let rate = 22_050.0

/// A context like a playing techno song's, for the pure planner.
private func context(
  _ spec: TrackSpec = TrackSpec(genre: "techno", seed: 42, structure: "standard"),
  locks: Set<String> = [], lockedActions: Set<String> = [], disabled: Set<String> = [],
  rolesOn: Set<String>? = nil, isLoop: Bool = false
) -> WanderContext {
  let roles = ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"]
  let voices = [
    WanderVoice(
      roles: ["kick", "snare", "hihat"], channel: 10, instrument: "drums",
      options: ["drums", "drums-909"]),
    WanderVoice(
      roles: ["bass"], channel: 2, instrument: "sub-bass", options: ["sub-bass", "acid"]),
    WanderVoice(roles: ["melody"], channel: 1, instrument: "lead", options: ["lead", "pluck"]),
    WanderVoice(roles: ["arp"], channel: 4, instrument: "arp", options: ["arp", "bell"]),
  ]
  var c = WanderContext(
    deck: "A", spec: spec, isLoop: isLoop, roles: roles,
    rolesOn: rolesOn ?? Set(roles).subtracting(disabled), disabledRoles: disabled, stemsMuted: [],
    lockedActions: lockedActions, locks: locks, voices: voices, anchorBPM: nil, key: nil)
  if locks.contains("tempo") { c.anchorBPM = Wander.bpm(of: spec) }
  if locks.contains("key"), let g = BeatsTables.shared.genres[spec.genre] {
    c.key = WanderKey(scale: g.scaleName, rootPC: g.rootNote % 12, offset: 0)
  }
  return c
}

/// Walk the planner `steps` moves: role and stem moves change the context's mix, swaps its spec.
private func walk(_ start: WanderContext, steps: Int) -> [WanderPlan] {
  var c = start
  var out: [WanderPlan] = []
  for step in 0..<steps {
    guard let p = Wander.plan(c, step: step) else { break }
    out.append(p)
    switch p.action {
    case .role(let r, let on):
      if on { c.rolesOn.insert(r) } else { c.rolesOn.remove(r) }
    case .stem(let s):
      if c.stemsMuted.contains(s) { c.stemsMuted.remove(s) } else { c.stemsMuted.insert(s) }
    case .swap(let spec): c.spec = spec
    default: break
    }
  }
  return out
}

struct WanderPlannerTests {
  @Test func theSameSpecAndStepsGiveTheSameMoves() {
    let a = walk(context(), steps: 200)
    let b = walk(context(), steps: 200)
    #expect(a.count == 200 && a == b)
    // another seed walks elsewhere
    let c = walk(context(TrackSpec(genre: "techno", seed: 43, structure: "standard")), steps: 200)
    #expect(a != c)
  }

  @Test func everyKindTurnsUpAboutAsOftenAsItsWeight() {
    var counts: [WanderMoveKind: Int] = [:]
    // many independent draws from one configuration (a long walk drifts genres: count from here)
    for step in 0..<4000 {
      if let p = Wander.plan(context(), step: step) { counts[p.kind, default: 0] += 1 }
    }
    for k in WanderMoveKind.allCases {
      let share = Double(counts[k] ?? 0) / 4000
      #expect(abs(share - Double(k.weight) / 100) < 0.03, "\(k): \(share)")
    }
  }

  @Test func disabledKeptAndLockedRolesAreNeverTouched() {
    let c = context(
      locks: [WanderLock.keep("melody")], lockedActions: ["A.roleMute.kick"], disabled: ["bass"])
    for p in walk(c, steps: 400) {
      if case .role(let r, _) = p.action { #expect(!["bass", "melody", "kick"].contains(r)) }
      if case .stem(let s) = p.action {
        #expect(s != "music" && s != "mic", "both hold the melody")
      }
      if p.kind == .instrument { #expect(!p.detail.contains("melody")) }
      if case .swap(let spec) = p.action {
        // the kept melody's instrument comes with every new track (on the channel the melody
        // plays in that genre)
        let picks = (spec.layers["tracks"]?.object?.entries ?? []).compactMap {
          $0.1["instrument"]?.string
        }
        #expect(picks.contains("lead"), "\(p.detail)")
      }
    }
  }

  @Test func lockedButtonsAreSkipped() {
    let locked: Set<String> = Set(
      Wander.netMacros.map { "A.macro.\($0.id)" } + ["A.stinger.0", "A.stinger.1"])
    let plans = walk(context(lockedActions: locked), steps: 400)
    #expect(!plans.contains { $0.kind == .macro }, "every net macro is locked")
    for p in plans {
      if case .stinger(let n) = p.action { #expect(n >= 2) }
    }
  }

  @Test func aLockedDimensionsMovesNeverOccur() {
    let cases: [(String, Set<WanderMoveKind>)] = [
      ("arrangement", [.role, .stem]), ("fx", [.macro, .fx, .stinger]),
      ("instruments", [.instrument]), ("structure", [.structure]), ("genre", [.genre]),
    ]
    for (lock, gone) in cases {
      let plans = walk(context(locks: [lock]), steps: 400)
      #expect(plans.count == 400)
      #expect(plans.allSatisfy { !gone.contains($0.kind) }, "\(lock)")
    }
  }

  @Test func withGenreLockedTheWalkNeverChangesGenre() {
    let plans = walk(context(locks: ["genre"]), steps: 600)
    for p in plans {
      if case .swap(let s) = p.action { #expect(s.genre == "techno") }
    }
    #expect(plans.contains { $0.kind == .seed })
  }

  @Test func theTempoLockKeepsTheWalkNearItsTempo() {
    let c = context(locks: ["tempo"])
    let anchor = Wander.bpm(of: c.spec)
    var hops = 0
    for p in walk(c, steps: 800) {
      guard case .swap(let s) = p.action else { continue }
      #expect(abs(Wander.bpm(of: s) / anchor - 1) <= WanderLock.tempoTolerance, "\(p.detail)")
      if p.kind == .genre { hops += 1 }
    }
    #expect(hops > 0, "techno has neighbours within 6 %")
    // unlocked, the walk does leave that range (it is the lock doing it)
    let free = walk(context(), steps: 800).compactMap { p -> Double? in
      if case .swap(let s) = p.action { return Wander.bpm(of: s) }
      return nil
    }
    #expect(free.contains { abs($0 / anchor - 1) > WanderLock.tempoTolerance })
  }

  @Test func theKeyLockKeepsTheScaleAndRootAndPinsTheKey() {
    let c = context(TrackSpec(genre: "house", seed: 3, structure: "standard"), locks: ["key"])
    let t = BeatsTables.shared
    for p in walk(c, steps: 600) {
      guard case .swap(let s) = p.action else { continue }
      let g = t.genres[s.genre]!
      #expect(g.scaleName == "MinorScale" && g.rootNote % 12 == 0, "\(s.genre)")
      #expect(s.pinnedKeyOffset == 0, "the key rides in the spec for a key-moving pass")
    }
  }

  @Test func theStructureLockKeepsTheFamily() {
    let t = BeatsTables.shared
    for p in walk(context(locks: ["structure"]), steps: 600) {
      guard case .swap(let s) = p.action else { continue }
      #expect(s.structure == "standard" && t.family(of: s.genre) == t.family(of: "techno"))
    }
  }

  @Test func theInstrumentsLockCarriesEveryInstrument() {
    for p in walk(context(locks: ["instruments"]), steps: 300) {
      guard case .swap(let s) = p.action, s.genre == "techno" else { continue }
      #expect(s.layers["tracks"]?["2"]?["instrument"]?.string == "sub-bass", "\(p.detail)")
      #expect(s.layers["tracks"]?["1"]?["instrument"]?.string == "lead")
    }
  }

  @Test func withEverythingLockedThereIsNoMove() {
    let all = Set(WanderLock.dimensions).union(
      ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"].map(WanderLock.keep))
    let c = context(locks: all)
    #expect(Wander.plan(c, step: 0) == nil)
    #expect(!Wander.canMove(c))
    // one dimension free: it moves again
    var some = all
    some.remove("fx")
    #expect(Wander.plan(context(locks: some), step: 0)?.kind.lock == "fx")
  }

  @Test func neighboursAreNearInTempoAndStable() {
    let n = Wander.neighbours(of: "techno")
    #expect(n.contains("house") && n.contains("garage") && !n.contains("techno"))
    #expect(n == n.sorted())
    for g in BeatsTables.shared.genreIDs { #expect(!Wander.neighbours(of: g).isEmpty, "\(g)") }
  }

  @Test func theMixNeverEmpties() {
    var c = context()
    c.rolesOn = ["kick", "bass"]
    for step in 0..<200 {
      guard let p = Wander.plan(c, step: step), case .role(_, let on) = p.action else { continue }
      #expect(on, "down to two parts: only bring one back")
    }
  }
}

struct WanderCodecTests {
  @Test func theActionsRoundTrip() {
    let actions: [DeckAction] = [
      .wander(deck: "A", on: true), .wander(deck: "B", on: false),
      .wanderPace(deck: "A", bars: 8),
      .wanderLock(deck: "B", dimension: "genre", on: true),
      .wanderLock(deck: "A", dimension: WanderLock.keep("bass"), on: false),
    ]
    for a in actions { #expect(DeckAction(json: a.json) == a, "\(a)") }
    #expect(DeckAction.wander(deck: "A", on: true).json["op"]?.string == "wander")
  }

  @Test func theStartingWanderStateRoundTripsAndStaysOutOfOldSets() {
    var p = DeckParams()
    #expect(p.json["wander"] == nil, "untouched: the text (and CID) is as before")
    p.wander.on = true
    p.wander.pace = 4
    p.wander.step = 17
    p.wander.locks = ["tempo", "key", WanderLock.keep("bass")]
    p.wander.anchorBPM = 128
    p.wander.key = WanderKey(scale: "MinorScale", rootPC: 9, offset: -3)
    p.wander.paused = true
    p.wander.quietBars = 2
    #expect(DeckParams(json: p.json) == p)
  }
}

/// The walk on a deck: boundaries, steering, locks, replay.
@MainActor
struct WanderDeckTests {
  func make(_ spec: TrackSpec = TrackSpec(genre: "techno", seed: 42, structure: "standard")) throws
    -> (DJEngine, Deck)
  {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let d = dj["A"]!
    d.loadNet(PreparedTrack(spec: spec, sampleRate: rate, opts: d.waveOptions))
    dj["B"]!.loadDemo()
    return (dj, d)
  }

  @Test func movesLandOnPaceBoundaries() throws {
    let (dj, d) = try make()
    dj.perform(.wanderPace(deck: "A", bars: 4))
    // every part kept: the walk only plays macros and stingers (no recompose: a quick test)
    for r in d.roles { dj.perform(.wanderLock(deck: "A", dimension: WanderLock.keep(r), on: true)) }
    dj.perform(.wander(deck: "A", on: true))
    for bar in 0..<13 { d.advanceWander(toBar: bar, lockedActions: dj.lockedActions) }
    #expect(d.wander.log.map(\.bar) == [4, 8, 12], "the last bar of each 4-bar phrase")
    #expect(d.wander.step == 3)
    // the same bar again (polled 100×/s) takes nothing
    d.advanceWander(toBar: 12, lockedActions: dj.lockedActions)
    #expect(d.wander.step == 3)
    // pace 8: the next move is in bar 16 (the end of the phrase 8…15)
    dj.perform(.wanderPace(deck: "A", bars: 8))
    for bar in 13..<16 { d.advanceWander(toBar: bar, lockedActions: dj.lockedActions) }
    #expect(d.wander.log.map(\.bar) == [4, 8, 12, 16])
  }

  @Test func aTempoLockSetBeforeAnyTrackHoldsTheFirstOneWalkedFrom() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let d = dj["A"]!
    d.setWanderLock("tempo", true)  // as the app restores it at launch: nothing loaded yet
    d.setWanderLock("key", true)
    #expect(d.wander.anchorBPM == nil && d.wander.key == nil)
    let spec = TrackSpec(genre: "house", seed: 5, structure: "minimal")
    d.loadNet(PreparedTrack(spec: spec, sampleRate: rate, opts: d.waveOptions))
    for r in d.roles { d.setWanderLock(WanderLock.keep(r), true) }  // no recompose
    d.setWanderPace(4)
    d.setWander(true)
    for bar in 1...3 { d.advanceWander(toBar: bar, lockedActions: []) }
    #expect(d.wander.anchorBPM == 124 && d.wander.key?.scale == "MinorScale")
    #expect(d.wander.log.count == 1)
  }

  @Test func offOrOnASampleDeckNothingMoves() throws {
    let (dj, d) = try make()
    dj.perform(.wanderPace(deck: "A", bars: 4))
    for bar in 0..<9 { d.advanceWander(toBar: bar, lockedActions: []) }
    #expect(d.wander.log.isEmpty, "off")
    let b = dj["B"]!
    dj.perform(.wander(deck: "B", on: true))
    for bar in 0..<40 { b.advanceWander(toBar: bar, lockedActions: []) }
    #expect(
      b.wander.log.isEmpty && b.wanderIdleReason(lockedActions: [])?.contains("sample") == true)
  }

  @Test func theWheelGrabsTheWalkAndAQuietPhraseGivesItBack() throws {
    let (dj, d) = try make()
    let s = SurfaceController(profile: .inpulse200MK3, engine: dj)
    dj.perform(.wanderPace(deck: "A", bars: 4))
    dj.perform(.wander(deck: "A", on: true))
    d.setPlaying(true)
    dj.focus = "A"
    s.handle(bytes: [0xB0, 0x01, 0x01])  // browser wheel, one click on
    #expect(d.wander.paused && d.currentSpec?.seed == 43)
    // a phrase of four quiet bars: no move while paused, then it walks again
    for bar in 1...4 { d.advanceWander(toBar: bar, lockedActions: []) }
    #expect(!d.wander.paused && d.wander.log.isEmpty)
    // a turn mid-phrase starts the count again
    s.handle(bytes: [0xB0, 0x01, 0x7F])
    #expect(d.wander.paused && d.currentSpec?.seed == 42)
    for bar in 5...7 { d.advanceWander(toBar: bar, lockedActions: []) }
    #expect(d.wander.paused, "three quiet bars are not a phrase")
    d.advanceWander(toBar: 8, lockedActions: [])
    #expect(!d.wander.paused)
    d.advanceWander(toBar: 11, lockedActions: [])
    #expect(d.wander.log.map(\.bar) == [12])
  }

  @Test func shiftAndTheWheelSetThePaceAndThePushTogglesIt() throws {
    let (dj, d) = try make()
    let s = SurfaceController(profile: .inpulse200MK3, engine: dj)
    dj.focus = "A"
    #expect(d.wander.pace == 16)
    s.handle(bytes: [0xB3, 0x01, 0x01])
    #expect(d.wander.pace == 32)
    s.handle(bytes: [0xB3, 0x01, 0x01])
    #expect(d.wander.pace == 32, "stops at 32")
    for _ in 0..<4 { s.handle(bytes: [0xB3, 0x01, 0x7F]) }
    #expect(d.wander.pace == 4, "and at 4")
    s.handle(bytes: [0x90, 0x00, 0x7F])  // browser push
    #expect(d.wander.on)
    s.handle(bytes: [0x90, 0x00, 0x00])  // its release does nothing
    #expect(d.wander.on)
    s.handle(bytes: [0x90, 0x00, 0x7F])
    #expect(!d.wander.on)
    // locked (right-click ▸ Disable on the Wander button): the push does nothing
    dj.lockedActions = ["A.wander"]
    s.handle(bytes: [0x90, 0x00, 0x7F])
    #expect(!d.wander.on)
  }

  @Test func theWheelStepsASongAndTheTransportKeepsGoing() throws {
    let (dj, d) = try make()
    let s = SurfaceController(profile: .inpulse200MK3, engine: dj)
    try dj.start()
    defer { dj.stop() }
    d.setPlaying(true)
    dj.focus = "A"
    let router = ControllerRouter(engine: dj)
    let conductor = OfflineConductor(engine: dj, router: router)
    while d.wave.tick < 40 { _ = try conductor.step() }  // into the third bar
    s.handle(bytes: [0xB0, 0x01, 0x01])
    #expect(d.currentSpec == TrackSpec(genre: "techno", seed: 43, structure: "standard"))
    let before = d.wave.tick
    while d.wave.activeGeneration != d.wave.latest?.generation { _ = try conductor.step() }
    // the new seed came in at the next bar, where the song had got to: not at its first bar
    #expect(d.playing && d.wave.isPlaying)
    #expect(d.wave.tick >= 48 && d.wave.tick >= before, "tick \(d.wave.tick)")
  }

  @Test func aGenreMoveChangesGenreAndKeepsPlaying() throws {
    let (dj, d) = try make(TrackSpec(genre: "techno", seed: 42, structure: "minimal"))
    try dj.start()
    defer { dj.stop() }
    d.setPlaying(true)
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    while d.wave.tick < 3 * 16 { _ = try conductor.step() }  // in bar 4: a 4-bar phrase's last
    // the first step this spec draws a genre move at
    let c = try #require(d.wanderContext(lockedActions: []))
    let step = try #require((0..<400).first { Wander.plan(c, step: $0)?.kind == .genre })
    d.setWander(true)
    d.wander.step = step
    let move = try #require(d.takeWanderMove(bar: 3, lockedActions: []))
    #expect(move.kind == .genre && move.cid != nil)
    let genre = try #require(move.spec?.genre)
    #expect(genre != "techno" && d.currentSpec?.genre == genre)
    while d.wave.activeGeneration != d.wave.latest?.generation { _ = try conductor.step() }
    #expect(d.playing && d.wave.isPlaying && d.wave.tick >= 64, "in at the phrase start")
    #expect(d.netBaseBPM == BeatsTables.shared.genres[genre]!.bpm)
  }

  @Test func theDeckStateShowsTheWalk() throws {
    let (dj, d) = try make()
    dj.perform(.wanderPace(deck: "A", bars: 4))
    dj.perform(.wander(deck: "A", on: true))
    for bar in 0..<4 { d.advanceWander(toBar: bar, lockedActions: []) }
    let j = d.wanderJSON(lockedActions: [])
    #expect(j["on"] == .bool(true) && j["pace"] == .int(4))
    #expect(j["log"]?.array?.count == 1 && j["nextMoveInBars"] != nil)
    #expect(d.wanderIdleReason(lockedActions: []) == nil)
    for dim in WanderLock.dimensions { d.setWanderLock(dim, true) }
    for r in d.roles { d.setWanderLock(WanderLock.keep(r), true) }
    #expect(d.wanderIdleReason(lockedActions: [])?.contains("locked") == true)
  }
}

@MainActor
struct WanderReplayTests {
  /// A set with wander on, at a fast tempo so phrases go by: performed live (recorded), then
  /// replayed. Returns the live log and audio and the session.
  static func perform(blocks: Int) throws -> (Session, [WanderMove], RenderedAudio, Trace) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let spec = TrackSpec(
      genre: "techno", seed: 42, structure: "standard",
      extra: JSONObject([("bpm", .number(240))]))
    dj["A"]!.loadNet(PreparedTrack(spec: spec, sampleRate: rate, opts: dj["A"]!.waveOptions))
    dj["B"]!.loadDemo()
    // a lock set before the recording starts is part of its starting state
    dj["A"]!.setWanderLock("genre", true)
    dj["A"]!.setWanderLock("instruments", true)
    try dj.start()
    defer { dj.stop() }
    let router = ControllerRouter(engine: dj)
    let recorder = try SessionRecorder.start(on: dj)
    let conductor = OfflineConductor(engine: dj, router: router)
    var l: [Float] = []
    var r: [Float] = []
    var trace = Trace()
    for b in 0..<blocks {
      let (bl, br) = try conductor.step {
        switch b {
        case 0:
          dj.perform(.wanderPace(deck: "A", bars: 4))
          dj.perform(.wander(deck: "A", on: true))
          dj.perform(.play(deck: "A", on: true))
        case 700: dj.perform(.wanderLock(deck: "A", dimension: "fx", on: true))
        default: break
        }
      }
      l += bl
      r += br
      trace.note(frame: l.count, dj)
    }
    return (
      recorder.finish(), dj["A"]!.wander.log, RenderedAudio(sampleRate: rate, left: l, right: r),
      trace
    )
  }

  /// Where a render was, block by block: each deck's tick at a block's end, and what every lane
  /// of the project it last handed over plays (a sampler source, or "synth") whenever that
  /// changes. Enough to say, of a replay that parts from its live set, at which bar and whether
  /// a lane's sound differs (a pick, or a sampler that loaded on one side only).
  struct Trace {
    struct Sounds {
      var frame: Int
      var generation: Int32
      var lanes: [String]
    }
    var ends: [Int] = []
    var ticks: [String: [Int]] = [:]
    var sounds: [String: [Sounds]] = [:]

    mutating func note(frame: Int, _ dj: DJEngine) {
      ends.append(frame)
      for (name, d) in dj.decks {
        ticks[name, default: []].append(d.wave.tick)
        guard let p = d.wave.latest, sounds[name]?.last?.generation != p.generation else {
          continue
        }
        let lanes = p.lanes.enumerated().map { i, lane in
          "\(i) \(lane.netId): "
            + (p.samplers?.source(of: lane.samplerSlot).map(\.description) ?? "synth")
        }
        sounds[name, default: []].append(
          Sounds(frame: frame, generation: p.generation, lanes: lanes))
      }
    }

    /// The block `frame` falls in.
    func block(of frame: Int) -> Int { ends.firstIndex { $0 > frame } ?? max(0, ends.count - 1) }

    /// What `deck`'s lanes played at `frame`.
    func lanes(_ deck: String, at frame: Int) -> [String] {
      sounds[deck]?.last { $0.frame <= frame }?.lanes ?? sounds[deck]?.first?.lanes ?? []
    }
  }

  /// nil if the two renders are the same; else where they part: the first frame that differs,
  /// each deck's bar there, and any lane whose sound differs.
  static func divergence(
    live: RenderedAudio, _ lt: Trace, replay: RenderedAudio, _ rt: Trace
  ) -> String? {
    let n = min(live.frames, replay.frames)
    let first = (0..<n).first {
      live.left[$0] != replay.left[$0] || live.right[$0] != replay.right[$0]
    }
    guard let f = first ?? (live.frames == replay.frames ? nil : n) else { return nil }
    var out = [
      "frames \(live.frames) live, \(replay.frames) replay; first difference at frame \(f)"
    ]
    if f < n {
      out.append(
        String(
          format: "  live %.6f/%.6f, replay %.6f/%.6f", live.left[f], live.right[f], replay.left[f],
          replay.right[f]))
    }
    let lb = lt.block(of: f)
    let rb = rt.block(of: f)
    for deck in lt.ticks.keys.sorted() {
      let tl = lt.ticks[deck].map { $0[min(lb, $0.count - 1)] } ?? -1
      let tr = rt.ticks[deck].map { $0[min(rb, $0.count - 1)] } ?? -1
      out.append(
        "  deck \(deck): live bar \(tl / 16) (tick \(tl)), replay bar \(tr / 16) (tick \(tr))")
      let a = lt.lanes(deck, at: f)
      let b = rt.lanes(deck, at: f)
      for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : "-"
        let y = i < b.count ? b[i] : "-"
        if x != y { out.append("    lane differs: live \(x) | replay \(y)") }
      }
      if a == b { out.append("    every lane's sound matches (\(a.count) lanes)") }
    }
    return out.joined(separator: "\n")
  }

  @Test func aPartingNamesItsFrameBarAndLane() throws {
    func trace(_ sound: String) -> Trace {
      var t = Trace()
      t.ends = [100, 200, 300]
      t.ticks = ["A": [15, 16, 17]]
      t.sounds = [
        "A": [
          .init(frame: 100, generation: 1, lanes: ["0 kick: synth", "1 bass-0: synth"]),
          .init(frame: 200, generation: 2, lanes: ["0 kick: synth", "1 bass-0: " + sound]),
        ]
      ]
      return t
    }
    let a = RenderedAudio(
      sampleRate: rate, left: [Float](repeating: 0, count: 300),
      right: [Float](repeating: 0, count: 300))
    var b = a
    #expect(Self.divergence(live: a, trace("gm:33"), replay: b, trace("gm:33")) == nil)
    b.left[250] = 0.5
    let m = try #require(Self.divergence(live: a, trace("gm:33"), replay: b, trace("synth")))
    #expect(m.contains("frame 250") && m.contains("bar 1 (tick 17)"), "\(m)")
    #expect(m.contains("lane differs: live 1 bass-0: gm:33 | replay 1 bass-0: synth"), "\(m)")
  }

  @Test func aReplayWalksTheSamePath() throws {
    let (session, log, live, liveTrace) = try Self.perform(blocks: 1400)
    #expect(log.count >= 2, "\(log.map(\.detail))")
    #expect(session.params["A"]?.wander.locks == ["genre", "instruments"])
    #expect(
      !session.events.contains { e in
        if case .action(.macro) = e.kind { return true }
        return false
      }, "the moves are derived, not recorded")
    let player = SessionPlayer(session: session)
    var replayTrace = Trace()
    player.onBlock = { dj, frames in replayTrace.note(frame: frames, dj) }
    let replay = try player.render()
    #expect(player.wanderLogs["A"] == log)
    let parted = Self.divergence(live: live, liveTrace, replay: replay, replayTrace)
    #expect(parted == nil, "and sounds the same:\n\(parted ?? "")")
  }
}
