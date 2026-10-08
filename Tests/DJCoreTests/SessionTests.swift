import Testing

@testable import DJCore

private let apc = "APC mini mk2 Control"
private let mpk = "MPK Mini Mk II"
private let inpulse = "DJControl Inpulse 200 Mk3"
private let rate = 22_050.0

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

struct SessionModelTests {
  static func sample() -> Session {
    let spec = TrackSpec(
      genre: "techno", seed: 42, structure: "standard", cohesion: "v2",
      extra: JSONObject([("bpm", .number(126))]))
    var pA = DeckParams()
    pA.volume = 0.7
    pA.autoAdvance = true
    return Session(
      sampleRate: 48_000, frames: 96_000,
      decks: [
        "A": .net(spec),
        "B": .sample(
          id: "abc123", title: "Loop <1> & more", grid: BeatGrid(bpm: 127.5, offset: 312.25)),
        "C": .none,
      ],
      params: ["A": pA, "B": DeckParams(), "C": DeckParams()], crossfader: 0.25, master: 0.9,
      events: [
        SessionEvent(frame: 0, kind: .midi(port: "APC mini mk2 Control", bytes: [0x90, 16, 0x7F])),
        SessionEvent(frame: 128, kind: .action(.play(deck: "A", on: true))),
        SessionEvent(frame: 256, kind: .action(.param(deck: "B", name: "filter", value: 0.31))),
        SessionEvent(frame: 300, kind: .action(.crossfader(0.5))),
        SessionEvent(frame: 301, kind: .action(.master(0.8))),
        SessionEvent(frame: 400, kind: .action(.load(deck: "A", source: .net(spec)))),
        SessionEvent(frame: 401, kind: .action(.queueNext(deck: "B", spec: spec))),
        SessionEvent(frame: 500, kind: .action(.hotCue(deck: "B", slot: 2))),
        SessionEvent(frame: 501, kind: .action(.clearCue(deck: "B", slot: 2))),
        SessionEvent(frame: 502, kind: .action(.cue(deck: "B"))),
        SessionEvent(frame: 510, kind: .action(.loop(deck: "B", op: "halve"))),
        SessionEvent(frame: 600, kind: .action(.section(deck: "A", index: 3))),
        SessionEvent(frame: 601, kind: .action(.role(deck: "A", role: "bass", on: false))),
        SessionEvent(frame: 602, kind: .action(.macro(deck: "A", id: "drop"))),
        SessionEvent(frame: 603, kind: .action(.panic(deck: "A"))),
        SessionEvent(frame: 604, kind: .action(.stinger(deck: "A", n: 2))),
        SessionEvent(frame: 700, kind: .action(.sync(deck: "B", align: "bar"))),
        SessionEvent(frame: 701, kind: .action(.quantize(deck: "B", mode: "beat"))),
        SessionEvent(frame: 702, kind: .action(.follow(deck: "B", leader: "A"))),
        SessionEvent(frame: 703, kind: .action(.follow(deck: "B", leader: nil))),
        SessionEvent(frame: 704, kind: .action(.autoAdvance(deck: "A", on: false))),
        SessionEvent(frame: 705, kind: .action(.nextTrack(deck: "A"))),
        SessionEvent(frame: 706, kind: .action(.grid(deck: "B", bpm: 128, offset: 10))),
        SessionEvent(
          frame: 800,
          kind: .action(
            .load(deck: "B", source: .sample(id: "demo-loop", title: "demo", grid: nil)))),
      ])
  }

  @Test func jsonRoundTripsEveryEventKind() throws {
    let s = Self.sample()
    let back = try Session(json: JSONValue.parse(s.json.jsStringified))
    #expect(back == s)
    #expect(back.cid == s.cid)
    // The decks' sources are plain beats share payloads.
    let a = try #require(s.json["decks"]?["A"]?["source"]?["share"])
    #expect(Share(payload: a).genre == "techno")
    #expect(s.json["decks"]?["A"]?["source"]?["cid"]?.string == BeatsCID.shareCID(a))
  }

  @Test func theCIDNamesTheContentAndNothingElse() throws {
    let s = Self.sample()
    #expect(s.cid.hasPrefix("z4EBG9"))  // CIDv1, dag-json, sha2-256, base58btc
    #expect(s.canonical == s.json.canonicalJS)
    #expect(s.cid == BeatsCID.shareCID(canonical: s.canonical))
    var t = s
    t.events[3] = SessionEvent(frame: 300, kind: .action(.crossfader(0.5000001)))
    #expect(t.cid != s.cid, "one changed value changes the name")
    var u = s
    u.events.append(SessionEvent(frame: 900, kind: .action(.panic(deck: "A"))))
    #expect(u.cid != s.cid)
    // key order in the text doesn't matter
    let text = s.json.jsStringified
    let reordered = try JSONValue.parse(text).canonicalJS
    #expect(try Session.decode(reordered).cid == s.cid)
  }

  @Test func decodeChecksTheCID() throws {
    let s = Self.sample()
    let decoded = try Session.decode(s.canonical, cid: s.cid)
    #expect(decoded == s)
    #expect(throws: SessionError.cidMismatch) { try Session.decode(s.canonical, cid: "zdjNope") }
    #expect(throws: SessionError.badSchema) {
      try Session.decode(#"{"schema":"other","sampleRate":1,"frames":1,"decks":{}}"#)
    }
  }

  @Test func contentIDsOfAudioAreStableAndSensitive() {
    let a = DemoLoop.make(sampleRate: 8000)
    let b = DemoLoop.make(sampleRate: 8000)
    #expect(a.contentID == b.contentID && a.contentID.count == 64)
    #expect(a.contentID != DemoLoop.make(sampleRate: 16000).contentID)
    let l = [Float](repeating: 0.25, count: 100)
    #expect(
      SampleBuffer(left: l, sampleRate: 8000).contentID
        != SampleBuffer(left: l + [0], sampleRate: 8000).contentID)
  }
}

struct SessionRecorderGuardTests {
  @Test func refusesToStartMidPerformance() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    #expect(throws: SessionError.notAtRest(deck: "A")) { try SessionRecorder.start(on: dj) }
    dj["A"]!.setPlaying(false)
    dj["B"]!.hotCue(0)
    #expect(throws: SessionError.notAtRest(deck: "B")) { try SessionRecorder.start(on: dj) }
  }

  @Test func refusesANetItCannotName() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    dj["A"]!.loadNet(
      compose(genre: "techno", overrides: .object(JSONObject([("seed", .number(1))]))))
    #expect(throws: SessionError.unrecordable(deck: "A")) { try SessionRecorder.start(on: dj) }
  }

  @Test func capturesTheStartingState() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadNet(PreparedTrack(spec: TrackSpec(genre: "jazz", seed: 3), sampleRate: rate))
    dj["B"]!.loadDemo()
    dj["A"]!.volume = 0.31
    dj["B"]!.pitch = -0.25
    dj.crossfader = 0.2
    dj.master = 0.55
    let r = try SessionRecorder.start(on: dj)
    let s = r.finish()
    #expect(dj.recorder == nil)
    #expect(s.decks["A"] == .net(TrackSpec(genre: "jazz", seed: 3)))
    #expect(
      s.decks["B"]
        == .sample(id: "demo-loop", title: "demo loop", grid: BeatGrid(bpm: 120, offset: 0)))
    #expect(s.params["A"]?.volume == 0.31 && s.params["B"]?.pitch == -0.25)
    #expect(s.crossfader == 0.2 && abs(s.master - 0.55) < 1e-6)
    #expect(s.events.isEmpty && s.frames == 0)
  }
}

/// The scripted set: hardware (three controllers) and UI inputs, in both deck kinds.
private func performance(_ dj: DJEngine, _ router: ControllerRouter, block b: Int) {
  func midi(_ port: String, _ bytes: [UInt8]) { router.route(port: port, bytes: bytes) }
  switch b {
  case 0:
    for p in [apc, mpk, inpulse] { router.attach(port: p) }
    dj.perform(.play(deck: "A", on: true))
    midi(inpulse, [0x92, 0x07, 0x7F])  // deck B PLAY
  case 20: midi(apc, [0x90, 48, 0x7F])  // deck A macro: drop
  case 60:
    dj.perform(.param(deck: "B", name: "filter", value: 0.2))
    dj.perform(.crossfader(0.7))
  case 80: midi(inpulse, [0x92, 0x08, 0x7F])  // touch deck B
  case 82, 84, 86, 88, 90: midi(inpulse, [0xB2, 0x0A, 0x05])  // scratch
  case 100: midi(inpulse, [0x92, 0x08, 0x00])  // release
  case 104: midi(inpulse, [0xB2, 0x09, 0x04])  // ring bend
  case 120:
    midi(apc, [0x90, 18, 0x7F])  // deck A section 2
    midi(apc, [0x90, 101, 0x7F])  // role: kick
  case 160: dj.perform(.sync(deck: "B", align: "beat"))
  case 200:
    dj.perform(
      .load(deck: "A", source: .net(TrackSpec(genre: "house", seed: 9, structure: "minimal"))))
    dj.perform(.play(deck: "A", on: true))
  case 260: dj.perform(.hotCue(deck: "B", slot: 0))
  case 300:
    dj.perform(.hotCue(deck: "B", slot: 0))
    dj.perform(.loop(deck: "B", op: "in"))
  case 330: dj.perform(.loop(deck: "B", op: "out"))
  case 350: dj.perform(.macro(deck: "A", id: "beat-repeat"))
  case 380:
    midi(mpk, [0x99, 36, 100])  // stinger
    midi(mpk, [0x90, 61, 110])  // live key
  case 420: midi(mpk, [0x80, 61, 0])
  case 440: midi(apc, [0x90, 59, 0x7F])  // panic
  default: break
  }
}

struct SessionReplayTests {
  /// Perform the set live (recording), return its session and audio.
  static func perform(blocks: Int = 520) throws -> (Session, RenderedAudio) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: rate))
    dj["B"]!.loadDemo()
    dj["A"]!.volume = 0.85
    try dj.start()
    defer { dj.stop() }
    let router = ControllerRouter(engine: dj)
    let recorder = try SessionRecorder.start(on: dj)
    let conductor = OfflineConductor(engine: dj, router: router)
    var l: [Float] = []
    var r: [Float] = []
    for b in 0..<blocks {
      let (bl, br) = try conductor.step { performance(dj, router, block: b) }
      l += bl
      r += br
    }
    return (recorder.finish(), RenderedAudio(sampleRate: rate, left: l, right: r))
  }

  @Test func theReplayIsTheSameAudioAsTheLiveSet() throws {
    let (session, live) = try Self.perform()
    #expect(session.frames == live.frames)
    #expect(session.events.count >= 25, "\(session.events.count) events")
    #expect(live.left.reduce(0) { max($0, abs($1)) } > 0.1)
    let replay = try SessionPlayer(session: session).render()
    #expect(replay.frames == live.frames)
    #expect(replay.left == live.left && replay.right == live.right)
  }

  @Test func twoRendersAreByteIdentical() throws {
    let (session, _) = try Self.perform(blocks: 300)
    let a = WAV.encode(try SessionPlayer(session: session).render(), float32: true)
    let b = WAV.encode(try SessionPlayer(session: session).render(), float32: true)
    #expect(a == b)
    #expect(a.count == 44 + session.frames * 8)
  }

  @Test func aSessionSurvivesItsOwnEnvelope() throws {
    let (session, live) = try Self.perform(blocks: 300)
    let revived = try Session.decode(session.canonical, cid: session.cid)
    #expect(revived == session)
    let replay = try SessionPlayer(session: revived).render()
    #expect(replay.left == Array(live.left.prefix(replay.frames)))
  }

  @Test func theRecordedInputsAreWhatWasDone() throws {
    let (s, _) = try Self.perform(blocks: 520)
    let kinds = s.events.map(\.kind)
    #expect(kinds.contains(.midi(port: apc, bytes: [0x90, 48, 0x7F])))
    #expect(kinds.contains(.action(.sync(deck: "B", align: "beat"))))
    #expect(kinds.contains(.action(.macro(deck: "A", id: "beat-repeat"))))
    #expect(s.events.map(\.frame) == s.events.map(\.frame).sorted())
    #expect(
      s.events.first { $0.kind == .midi(port: mpk, bytes: [0x90, 61, 110]) }?.frame == 380 * 128)
  }

  @Test func differentInputsGiveDifferentAudio() throws {
    let (session, live) = try Self.perform(blocks: 300)
    var changed = session
    let i = try #require(changed.events.firstIndex { $0.kind == .action(.crossfader(0.7)) })
    changed.events[i] = SessionEvent(
      frame: changed.events[i].frame, kind: .action(.crossfader(0.1)))
    let other = try SessionPlayer(session: changed).render()
    #expect(other.left != Array(live.left.prefix(other.frames)))
  }

  @Test func aMissingSampleIsReportedNotInvented() throws {
    var s = SessionModelTests.sample()
    s.decks = ["B": .sample(id: "deadbeef", title: "x", grid: nil)]
    s.params = [:]
    s.events = []
    s.frames = 1024
    s.sampleRate = rate
    #expect(throws: SessionError.missingSample(id: "deadbeef")) {
      try SessionPlayer(session: s).render()
    }
    let buf = DemoLoop.make(sampleRate: rate)
    let ok = try SessionPlayer(session: s, samples: { $0 == "deadbeef" ? buf : nil }).render()
    #expect(ok.frames == 1024)
  }
}

struct WAVTests {
  @Test func headerAndSamples() {
    let audio = RenderedAudio(sampleRate: 8000, left: [0, 0.5, -1, 1], right: [0.25, -0.5, 0, 2])
    let f = WAV.encode(audio, float32: true)
    #expect(Array(f.prefix(4)) == Array("RIFF".utf8) && Array(f[8..<12]) == Array("WAVE".utf8))
    #expect(f.count == 44 + 4 * 8)
    let p = WAV.encode(audio)
    #expect(p.count == 44 + 4 * 4)
    let le = { (o: Int) in Int(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)) }
    #expect(le(44 + 4) == 16384 || le(44 + 4) == 16383)  // 0.5 → ~16384
    #expect(le(44 + 8) == -32768 && le(44 + 12) == 32767)
    #expect(le(44 + 14) == 32767, "clipped, not wrapped")
  }
}
