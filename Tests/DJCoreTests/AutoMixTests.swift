import Testing

@testable import DJCore

private let rate = 22_050.0

/// An offline two-deck set: A plays a composed net, B holds the demo loop (as at launch).
/// Stepped block by block through `OfflineConductor` (the live app's housekeeping order), with
/// both decks' tick anchors read as it goes.
@MainActor
final class AutoMixRig {
  let dj: DJEngine
  let conductor: OfflineConductor
  let router: ControllerRouter
  var recorder: SessionRecorder?
  var left: [Float] = []
  var right: [Float] = []
  var keepAudio = false
  /// Every tick anchor each deck wrote, oldest first.
  var anchors: [String: [TickAnchor]] = ["A": [], "B": []]
  private var cursors: [String: WaveDeckSource.EventCursor] = [:]
  private var fires: [FireEvent] = []
  /// The crossfader after each housekeeping tick, with B's and A's net ticks then.
  var faders: [(frame: Int, x: Double, a: Int, b: Int)] = []

  init(
    _ spec: TrackSpec = TrackSpec(genre: "dnb", seed: 42), deterministic: Bool = true,
    record: Bool = false, autoMix: AutoMixSettings? = nil
  ) throws {
    dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = deterministic
    let a = dj["A"]!
    a.loadNet(PreparedTrack(spec: spec, sampleRate: rate, opts: a.waveOptions))
    dj["B"]!.loadDemo()
    if let autoMix { dj.setAutoMix(on: autoMix.on, bars: autoMix.bars, every: autoMix.every) }
    try dj.start()
    router = ControllerRouter(engine: dj)
    conductor = OfflineConductor(engine: dj, router: router)
    if record { recorder = try SessionRecorder.start(on: dj) }
    for n in ["A", "B"] { cursors[n] = WaveDeckSource.EventCursor() }
  }

  func stop() { dj.stop() }

  var a: Deck { dj["A"]! }
  var b: Deck { dj["B"]! }

  /// One block; `inputs` runs before it (as a set's pokes do).
  func step(_ inputs: () -> Void = {}) throws {
    let housekeeping = dj.frame % 512 == 0
    // the clocks as the housekeeping tick sees them (before the block renders)
    let seen = (a: a.wave.tick, b: b.wave.tick)
    let (l, r) = try conductor.step(inputs: inputs)
    if keepAudio {
      left += l
      right += r
    }
    for n in ["A", "B"] {
      var c = cursors[n]!
      var got: [TickAnchor] = []
      fires.removeAll(keepingCapacity: true)
      dj[n]!.wave.readEvents(&c, fires: &fires, anchors: &got)
      cursors[n] = c
      anchors[n]! += got
    }
    if housekeeping { faders.append((dj.frame, dj.crossfader, seen.a, seen.b)) }
  }

  /// Step until `done` (at most `limit` blocks); false if it never came.
  @discardableResult
  func run(until done: () -> Bool, limit: Int = 40_000, inputs: (Int) -> Void = { _ in }) throws
    -> Bool
  {
    var n = 0
    while !done() && n < limit {
      try step { inputs(n) }
      n += 1
    }
    return done()
  }

  func run(blocks: Int) throws { for _ in 0..<blocks { try step() } }

  /// The frame `deck` played step `step` of the project it was running then (its anchor
  /// `step + 1`, the tick count after it), the last such anchor.
  func frame(_ deck: String, step: Int, generation: Int32? = nil) -> Int? {
    anchors[deck]!.last {
      Int($0.tick) == step + 1 && !$0.flags.contains(.swap)
        && (generation == nil || $0.generation == generation!)
    }.map { Int($0.frame) }
  }
}

@MainActor
struct AutoMixTests {
  /// Turn auto-mix on with `bars`, play A, Mix now: the hand-off bar is A's bar 8.
  func started(_ rig: AutoMixRig, bars: Int = 4) throws {
    rig.dj.perform(.autoMix(on: true, bars: bars, every: 0))
    rig.dj.perform(.play(deck: "A", on: true))
    try rig.run(blocks: 4)
    rig.dj.perform(.autoMixNow)
    try rig.run(blocks: 4)
  }

  @Test func aHandOffLandsOnItsBarsAndSwapsTheDecks() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    rig.a.autoAdvance = true  // auto-next must not restart the old deck
    rig.dj.perform(.wander(deck: "A", on: true))
    rig.dj.perform(.wanderPace(deck: "A", bars: 8))
    try started(rig)
    #expect(rig.dj.autoMix.handoffBar == 8, "Mix now: the first phrase boundary ≥ 4 bars on")
    #expect(rig.dj.autoMix.phase == .playing)
    // the prep point (bar 4): the next track is composed onto B, stopped, mix-in baked in
    #expect(try rig.run(until: { rig.dj.autoMix.run != nil }))
    #expect(rig.a.wave.tick / 16 == 4, "prepared at P = H - 8 … here H - 4 (Mix now)")
    let run = try #require(rig.dj.autoMix.run)
    #expect(rig.dj.autoMix.handoffs == 1 && run.plan.n == 0)
    #expect(["seed", "instrument", "genre"].contains(run.plan.kind))
    #expect(rig.b.mode == .net && rig.b.currentSpec == run.plan.spec && !rig.b.playing)
    #expect(rig.b.wave.latest?.songRests.mask(at: 0) == MixOutTail.restMask)
    #expect(rig.b.wave.latest?.songRests.mask(at: 4 * 16) == [])
    #expect(rig.a.wanderHeld && rig.b.wanderHeld)
    let wanderStep = rig.a.wander.step
    // the end: B is playing, A stopped on its tail's bar line and stays stopped
    #expect(try rig.run(until: { rig.dj.autoMix.run == nil }))
    #expect(rig.dj.autoMix.log.count == 1)
    let row = try #require(rig.dj.autoMix.log.first)
    #expect(row.from == "A" && row.to == "B" && row.bar == 8 && row.n == 0)
    #expect(rig.b.playing && !rig.a.playing)
    #expect(rig.dj.autoMix.playing == "B")
    #expect(rig.dj.crossfader == 1)
    #expect(rig.a.wander.step == wanderStep, "Wander held from P to the end")
    #expect(!rig.a.wanderHeld && !rig.b.wanderHeld)
    #expect(rig.b.leader == nil, "B follows no one after the hand-off")
    #expect(rig.a.wave.latest?.tail == MixOutTail(fromTick: 8 * 16, bars: 4))
    try rig.run(blocks: 600)
    #expect(!rig.a.playing && rig.a.advances == 0, "auto-next did not restart A")

    // B's first tick is A's hand-off bar line (step 128), to the sample
    let bStart = try #require(rig.frame("B", step: 0))
    let aH = try #require(rig.frame("A", step: 8 * 16))
    #expect(abs(bStart - aH) <= 1, "B starts on A's bar 8: \(bStart) vs \(aH)")
    // and stays on it: every bar line of the hand-off
    for k in 1..<4 {
      let bk = try #require(rig.frame("B", step: k * 16))
      let ak = try #require(rig.frame("A", step: (8 + k) * 16))
      #expect(abs(bk - ak) <= 1, "bar \(k): \(bk) vs \(ak)")
    }
    // A stopped on its bar 12: its last tick is step 191
    let aLast = rig.anchors["A"]!.last { !$0.flags.contains(.swap) }
    #expect(aLast.map { Int($0.tick) } == 12 * 16, "A's last step is the one before bar 12")

    // the crossfader: c0 until the hand-off, then one step per bar line, linear in position
    let during = rig.faders.filter { $0.b > 0 && $0.b <= 4 * 16 + 1 }
    for f in during {
      let k = min(4, (f.b - 1) / 16)
      #expect(abs(f.x - (0.5 + 0.5 * Double(k) / 4)) < 1e-12, "bar \(k): \(f.x)")
    }
    let before = rig.faders.filter { $0.b == 0 }
    #expect(before.allSatisfy { $0.x == 0.5 }, "nothing moves before the hand-off")
    let changes = zip(rig.faders, rig.faders.dropFirst()).filter { $0.0.x != $0.1.x }
    #expect(changes.count == 4, "four steps: \(changes.map(\.1.x))")
    for (_, f) in changes { #expect((f.b - 1) % 16 == 0, "on a bar line: B tick \(f.b)") }
  }

  @Test func aLateArmIsCorrectedBeforeItIsHeard() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    rig.dj.autoMixArmDelay = 1  // the start commands land a housekeeping tick (512 frames) late
    try started(rig)
    #expect(try rig.run(until: { rig.dj.autoMix.log.count == 1 }))
    let bStart = try #require(rig.frame("B", step: 0))
    let aH = try #require(rig.frame("A", step: 8 * 16))
    #expect(bStart - aH > 100, "the start was late: \(bStart - aH) frames")
    // corrected in the hand-off's first bar: from bar 1 on, to the sample
    for k in 1..<4 {
      let bk = try #require(rig.frame("B", step: k * 16))
      let ak = try #require(rig.frame("A", step: (8 + k) * 16))
      #expect(abs(bk - ak) <= 1, "bar \(k): \(bk) vs \(ak)")
    }
  }

  @Test func steeringPausesExpressionDoesNot() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    rig.dj.perform(.autoMix(on: true, bars: 4, every: 4))
    rig.dj.perform(.play(deck: "A", on: true))
    try rig.run(blocks: 8)
    #expect(rig.dj.autoMix.phase == .playing && rig.dj.autoMix.handoffBar == 32)
    // expression: knobs, macros, mutes
    rig.dj.perform(.param(deck: "A", name: "eqLow", value: 0.2))
    rig.dj.perform(.macro(deck: "A", id: "sweep-lp"))
    rig.dj.perform(.role(deck: "A", role: "bass", on: false))
    try rig.run(blocks: 8)
    #expect(!rig.dj.autoMix.paused)
    // steering: a hot cue on A
    rig.dj.perform(.hotCue(deck: "A", slot: 0))
    try rig.run(blocks: 8)
    #expect(rig.dj.autoMix.paused && rig.dj.autoMix.phase == .paused)
    #expect(rig.dj.autoMix.handoffBar == nil)
    let pausedAt = rig.a.wave.tick / 16
    #expect(try rig.run(until: { !rig.dj.autoMix.paused }))
    #expect(rig.a.wave.tick / 16 == pausedAt + AutoMix.quietBars, "a phrase of quiet bars")
    // it counts again from where it resumed
    #expect(rig.dj.autoMix.handoffBar == 40, "\(String(describing: rig.dj.autoMix.handoffBar))")
  }

  @Test func aCueIsUsedAsIs() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    let cue = TrackSpec(genre: "dnb", seed: 777)
    rig.dj.perform(.autoMix(on: true, bars: 4, every: 0))
    rig.dj.perform(.play(deck: "A", on: true))
    try rig.run(blocks: 8)
    rig.dj.perform(.load(deck: "B", source: .net(cue)))
    #expect(!rig.dj.autoMix.paused, "a load on the idle deck is a cue, not a pause")
    rig.dj.perform(.autoMixNow)
    #expect(try rig.run(until: { rig.dj.autoMix.run != nil }))
    #expect(rig.dj.autoMix.run?.plan.kind == "cued")
    #expect(rig.b.currentSpec == cue)
    #expect(try rig.run(until: { rig.dj.autoMix.run == nil }))
    #expect(rig.dj.autoMix.log.first?.kind == "cued" && rig.b.currentSpec == cue)
    #expect(rig.b.playing && !rig.a.playing)
  }

  @Test func theCrossfaderTouchTakesTheFader() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    try started(rig)
    #expect(try rig.run(until: { rig.dj.autoMix.phase == .mixing && rig.b.wave.tick > 20 }))
    rig.dj.perform(.crossfader(0.3))
    #expect(try rig.run(until: { rig.dj.autoMix.run == nil }))
    #expect(rig.dj.crossfader == 0.3, "the user's crossfader stays where they left it")
    #expect(rig.dj.autoMix.log.count == 1, "the rest of the hand-off completed")
    #expect(rig.b.playing && !rig.a.playing)
  }

  @Test func playStopAborts() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    try started(rig)
    #expect(try rig.run(until: { rig.dj.autoMix.phase == .mixing && rig.b.wave.tick > 20 }))
    let x = rig.dj.crossfader
    rig.dj.perform(.play(deck: "B", on: false))
    try rig.run(blocks: 8)
    #expect(rig.dj.autoMix.run == nil && rig.dj.autoMix.log.isEmpty)
    #expect(rig.dj.autoMix.paused)
    #expect(rig.dj.crossfader == x, "nothing undone, nothing moved")
    #expect(!rig.a.wanderHeld && !rig.b.wanderHeld)
  }

  @Test func idleReasons() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    rig.dj.perform(.autoMix(on: true, bars: 8, every: 0))
    rig.dj.serviceAutoMix()
    #expect(rig.dj.autoMix.phase == .idle && rig.dj.autoMix.idle == "start a deck")
    // both playing: the louder is "playing", it waits for the other
    rig.a.setPlaying(true)
    rig.b.setPlaying(true)
    rig.dj.crossfader = 0.2
    rig.dj.serviceAutoMix()
    #expect(rig.dj.autoMix.playing == "A" && rig.dj.autoMix.idle == "B is playing too")
    rig.b.setPlaying(false)
    // a sample the user loaded on the idle deck is never started
    rig.b.load(SampleBuffer(left: [Float](repeating: 0, count: 4410), right: nil, sampleRate: rate), title: "x")
    rig.dj.serviceAutoMix()
    #expect(rig.dj.autoMix.idle?.hasPrefix("B holds a sample") == true)
    // the demo loop (or nothing) is not the user's: replaced by the next track
    rig.b.loadDemo()
    rig.dj.serviceAutoMix()
    #expect(rig.dj.autoMix.idle == nil && rig.dj.autoMix.phase == .playing)
    // every new-track move locked
    for r in ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"] {
      rig.a.setWanderLock(WanderLock.keep(r), true)
    }
    rig.dj.serviceAutoMix()
    #expect(rig.dj.autoMix.idle?.hasPrefix("every move is locked") == true)
    // a sample deck playing: wait for a cue
    rig.a.setPlaying(false)
    rig.b.setPlaying(true)
    rig.dj.serviceAutoMix()
    #expect(rig.dj.autoMix.idle?.hasPrefix("B plays a sample") == true)
    rig.dj.perform(.autoMix(on: false, bars: 8, every: 0))
    #expect(rig.dj.autoMix.phase == .off)
  }

  @Test func aCheckpointMidHandOffCarriesIt() throws {
    let rig = try AutoMixRig()
    defer { rig.stop() }
    try started(rig)
    #expect(try rig.run(until: { rig.dj.autoMix.phase == .mixing && rig.b.wave.tick > 20 }))
    let s = JournalState(engine: rig.dj)
    let v = s.json
    #expect(v["mixer"]?["autoMix"]?["run"]?["in"]?.string == "B")
    let back = try #require(JournalState(json: v))
    #expect(back == s)
    #expect(back.autoMix.run == rig.dj.autoMix.run)
    // stood in a fresh engine, it takes the hand-off up where it was
    let fresh = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    fresh.deterministic = true
    back.restore(into: fresh, clip: { _ in nil })
    #expect(fresh.autoMix.run == rig.dj.autoMix.run)
    #expect(fresh["A"]!.wanderHeld && fresh["B"]!.wanderHeld)
    #expect(fresh["B"]!.leader === fresh["A"]!)
  }

  @Test func theMixOutAheadIsTheHandMixOut() throws {
    let rig = try AutoMixRig(deterministic: true)
    defer { rig.stop() }
    try started(rig)
    #expect(try rig.run(until: { rig.dj.autoMix.run != nil }))
    // what auto-mix prepares ahead at P (live), from A's state at P …
    let point = rig.a.mixOutPoint(atBar: 8, bars: 4)
    let ahead = try #require(rig.a.moveRequest(toTick: point.tick, tail: point.tail, rest: nil))
      .prepare()
    // … is what the hand mixOut in bar H − 1 (which the replay runs) loads
    #expect(try rig.run(until: { rig.dj.autoMix.run?.mixOutLoaded == true }))
    let hand = try #require(rig.a.wave.latest)
    #expect(ahead.startTick == hand.startTick && ahead.tail == hand.tail)
    #expect(ahead.rests == hand.rests && ahead.songRests == hand.songRests)
    #expect(ahead.gain == hand.gain && ahead.trackSerial == hand.trackSerial)
    #expect(ahead.energy == hand.energy && ahead.duckDepth == hand.duckDepth)
  }
}

/// Whole sets: recorded, replayed, replayed again.
@MainActor
struct AutoMixSessionTests {
  @Test func aSetWithAutoMixReplaysToTheByte() throws {
    let rig = try AutoMixRig(
      record: true, autoMix: AutoMixSettings(on: true, bars: 4, every: 0))
    defer { rig.stop() }
    rig.keepAudio = true
    rig.dj.perform(.play(deck: "A", on: true))
    try rig.run(blocks: 4)
    rig.dj.perform(.autoMixNow)
    // two hand-offs: A → B, then B → A
    #expect(try rig.run(until: { rig.dj.autoMix.log.count == 1 }))
    rig.dj.perform(.autoMixNow)
    #expect(try rig.run(until: { rig.dj.autoMix.log.count == 2 }))
    try rig.run(blocks: 200)
    let log = rig.dj.autoMix.log
    #expect(log.map(\.from) == ["A", "B"] && log.map(\.to) == ["B", "A"])
    #expect(log.map(\.n) == [0, 1])
    #expect(rig.a.playing && !rig.b.playing)
    let session = rig.recorder!.finish()
    #expect(session.autoMix.settings == AutoMixSettings(on: true, bars: 4, every: 0))
    let actions = session.events.compactMap { e -> DeckAction? in
      if case .action(let a) = e.kind { return a }
      return nil
    }
    #expect(actions == [.play(deck: "A", on: true), .autoMixNow, .autoMixNow], "only the pokes")
    let back = try Session.decode(session.canonical, cid: session.cid)
    #expect(back == session)
    let p1 = SessionPlayer(session: back)
    let x = try p1.render()
    let y = try SessionPlayer(session: back).render()
    #expect(sameSamples(x.left, rig.left) == .identical, "the replay is the live set")
    #expect(sameSamples(x.right, rig.right) == .identical, "the replay is the live set")
    #expect(sameSamples(x.left, y.left) == .identical, "two renders, same bytes")
    #expect(sameSamples(x.right, y.right) == .identical, "two renders, same bytes")
  }

  @Test func aDeferIsRecordedAndReplayed() async throws {
    let rig = try AutoMixRig(deterministic: false, record: true)
    defer { rig.stop() }
    rig.dj.autoMixComposeStalls = true  // the first compose never lands
    rig.dj.perform(.autoMix(on: true, bars: 4, every: 0))
    rig.dj.perform(.play(deck: "A", on: true))
    try rig.run(blocks: 4)
    rig.dj.perform(.autoMixNow)
    // to the mix-out point: the incoming is not there, the hand-off moves a phrase on
    #expect(try rig.run(until: { rig.dj.autoMix.run?.handoffBar == 16 }))
    // the second compose (asked for at the defer) lands while the set waits
    var waited = 0
    while rig.dj.autoMix.run?.incomingReady != true && waited < 3_000 {
      try await Task.sleep(for: .milliseconds(5))
      waited += 1
    }
    #expect(rig.dj.autoMix.run?.incomingReady == true)
    var blocks = 0
    while rig.dj.autoMix.log.isEmpty && blocks < 40_000 {
      try rig.step()
      blocks += 1
      if blocks % 64 == 0 { await Task.yield() }
    }
    #expect(rig.dj.autoMix.log.first?.bar == 16)
    let session = rig.recorder!.finish()
    let defers = session.events.filter {
      if case .action(.autoMixDefer(0)) = $0.kind { return true }
      return false
    }
    #expect(defers.count == 1)
    // the replay (inline composes, never late) defers at the same frame and walks the same way
    let player = SessionPlayer(session: session)
    var replayLog: [AutoMixHandoff] = []
    player.onBlock = { dj, _ in replayLog = dj.autoMix.log }
    _ = try player.render()
    #expect(replayLog.first?.bar == 16 && replayLog.first?.n == 0)
    #expect(replayLog.first?.spec == rig.dj.autoMix.log.first?.spec)
  }
}
