import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

// Sample auto-gain (LevelMatch.swift) as a setting: what it costs to measure, that it replays
// as it was played (on, off, switched mid-set; sessions and journals), and `LevelSurvey`, the
// spread report behind `djctl levels`.

private let rate = 22_050.0

private struct DemoSet {
  var session: Session
  var audio: RenderedAudio
  var journal: Journal.Contents?
  /// Deck B's `autoGain` at the end.
  var autoGain: Bool
}

/// Deck B plays the demo loop (levelled: its auto-gain is not 0), auto-gain `startOn` when the
/// set starts, switched off at block `offAt` (nil: never); recorded live, journaled too if asked.
@MainActor
private func playDemo(blocks: Int, startOn: Bool, offAt: Int?, journal: Bool = false) throws
  -> DemoSet
{
  let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
  dj.deterministic = true
  // the app sets it from its preference before anything loads
  dj.perform(.param(deck: "B", name: "autoGain", value: startOn ? 1 : 0))
  dj["B"]!.loadDemo()
  try dj.start()
  defer { dj.stop() }
  let box = StoreBox()
  let dir = journal ? tempJournalDir() : nil
  defer { if let dir { removeDir(dir) } }
  let j = try dir.map {
    try Journal(engine: dj, directory: $0, started: journalDate(1_760_000_000)) { box.state }
  }
  let recorder = try SessionRecorder.start(on: dj)
  let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
  var l: [Float] = []
  var r: [Float] = []
  for b in 0..<blocks {
    let (bl, br) = try conductor.step {
      if b == 0 { dj.perform(.play(deck: "B", on: true)) }
      if b == offAt { dj.perform(.param(deck: "B", name: "autoGain", value: 0)) }
    }
    l += bl
    r += br
  }
  let session = recorder.finish()
  j?.close()
  return DemoSet(
    session: session, audio: RenderedAudio(sampleRate: rate, left: l, right: r),
    journal: try dir.map(readNewestJournal), autoGain: dj["B"]!.autoGain)
}

@MainActor
struct SampleAutoGainTests {
  // MARK: the cost of measuring

  /// A whole long track measures (BS.1770 integrated, peak, band shares) in under half a
  /// second in release, so a load measures it there and then, before the first sample plays
  /// (no background pass, no glide in, nothing for a replay to race).
  @Test(.enabled(if: optimized, "timing is only meaningful in optimized builds"))
  func aTenMinuteSampleMeasuresInUnderHalfASecond() {
    let sr = 48_000.0
    let n = Int(600 * sr)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    var s: UInt32 = 1
    for i in 0..<n {
      s = s &* 1_664_525 &+ 1_013_904_223
      l[i] = Float(Int32(bitPattern: s)) / Float(Int32.max) * 0.2
      r[i] = l[i] * 0.9
    }
    let b = SampleBuffer(left: l, right: r, sampleRate: sr)
    let clock = ContinuousClock()
    var level: SampleLevel?
    let t = clock.measure { level = b.level }
    print("SampleAutoGainTests: ten minutes measured in \(t)")
    #expect(t < .milliseconds(500), "\(t)")
    #expect(level?.lufs != nil)
    // and cached: a second read is free
    #expect(clock.measure { _ = b.level } < .milliseconds(5))
  }

  // MARK: replays

  /// A set recorded with auto-gain off (the user's choice, over the app's default) replays
  /// with it off: byte for byte the audio, at the sample's own level.
  @Test func aSessionRecordedWithAutoGainOffReplaysWithItOff() throws {
    #expect(DemoLoop.make(sampleRate: rate).level.autoGainDB != 0, "the demo is levelled")
    let off = try playDemo(blocks: 120, startOn: false, offAt: nil)
    #expect(off.autoGain == false)
    #expect(off.session.params["B"]?.autoGain == false)
    #expect(!off.session.canonical.contains("autoGain"), "off is the wire default")
    let replay = try SessionPlayer(session: off.session).render()
    #expect(replay.left.contains { $0 != 0 })
    #expect(replay.left == off.audio.left && replay.right == off.audio.right)
    // it really is off: the same set with it on plays differently, and replays too
    let on = try playDemo(blocks: 120, startOn: true, offAt: nil)
    #expect(on.session.params["B"]?.autoGain == true)
    #expect(on.audio.left != off.audio.left)
    #expect(try SessionPlayer(session: on.session).render().left == on.audio.left)
  }

  /// Switched off during the set: the setting is an action, so the replay switches it at the
  /// same frame (the gain glides out the same way: it is derived, not recorded).
  @Test func switchingItOffMidSetReplays() throws {
    let live = try playDemo(blocks: 160, startOn: true, offAt: 60)
    #expect(live.autoGain == false)
    #expect(live.session.params["B"]?.autoGain == true)
    let toggles = live.session.events.filter {
      if case .action(.param(_, "autoGain", _)) = $0.kind { true } else { false }
    }
    #expect(toggles.count == 1)
    let replay = try SessionPlayer(session: live.session).render()
    #expect(replay.left == live.audio.left && replay.right == live.audio.right)
  }

  /// A journal: the checkpoint holds the deck setting, the switch is an action; the replay
  /// ends with it off and plays what the live set did.
  @Test(arguments: [true, false])
  func aJournalReplaysTheSetting(startOn: Bool) throws {
    let live = try playDemo(
      blocks: 160, startOn: startOn, offAt: startOn ? 60 : nil, journal: true)
    let contents = try #require(live.journal)
    #expect(contents.checkpoint?.decks["B"]?.params.autoGain == startOn)
    let replay = try Journal.replay(contents, render: true)
    #expect(replay.warnings.isEmpty, "\(replay.warnings)")
    #expect(replay.state.decks["B"]?.params.autoGain == false)
    let audio = try #require(replay.audio)
    let n = min(audio.frames, live.audio.frames)
    #expect(n > 0)
    #expect(Array(audio.left.prefix(n)) == Array(live.audio.left.prefix(n)))
  }

  // MARK: what gets a level

  /// A stock loop (or any file) loads through `perform` with its decoded buffer and gets the
  /// deck's auto-gain; a buffer measured before the load (off the main thread, as the app's
  /// decode task does) keeps that measure.
  @Test func aStockLoopLoadGetsItsLevel() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    dj.perform(.param(deck: "A", name: "autoGain", value: 1))
    let buffer = DemoLoop.make(sampleRate: rate)
    let level = buffer.level  // the decode task's pre-measure
    dj.perform(
      .load(deck: "A", source: .sample(id: "", title: "a stock loop", grid: nil)), buffer: buffer)
    let a = try #require(dj["A"])
    #expect(a.sampleLevel == level)
    #expect(a.autoGainDB == level.autoGainDB && a.autoGainDB != 0)
    // a net leaves nothing to level
    a.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 1, structure: "minimal"), sampleRate: rate,
        opts: a.waveOptions))
    #expect(a.sampleLevel == nil && a.autoGainDB == 0)
  }

  // MARK: the survey (djctl levels)

  private func entry(_ lufs: Double?, peak: Double = -10, low: Double = 0.3, high: Double = 0.1)
    -> LevelSurvey.Entry
  {
    LevelSurvey.Entry(
      name: "\(lufs ?? 0)",
      level: SampleLevel(lufs: lufs, peakDB: peak, lowShare: low, highShare: high))
  }

  @Test func theSurveyReportsTheSpreadBeforeAndAfter() {
    let ref = LevelMatch.referenceLUFS
    let s = LevelSurvey(entries: [
      entry(ref - 6, peak: -12),  // +6 dB, room under the ceiling: lands
      entry(ref + 4),  // −4 dB: lands
      entry(ref - 20, peak: -30),  // past the ±12 dB clamp: 8 LU short
      entry(ref - 6, peak: -3),  // the peak allows only +2 dB: 4 LU short
      entry(nil),  // silence: not counted
    ])
    #expect(s.spreadBefore == 24)
    #expect(abs((s.spreadAfter ?? 0) - 8) < 1e-9)
    #expect(s.exceptions.map(\.limitedBy) == ["maxGain", "peak"])
    #expect(s.summary["within"] as? Int == 2)
    #expect(s.summary["silent"] as? Int == 1)
    // a partial loop is measured against its own target (4 LU under)
    let bass = entry(ref + LevelMatch.partialOffsetDB, low: 0.9, high: 0)
    #expect(bass.level.partial && bass.errorBefore == 0 && bass.errorAfter == 0)
  }

  @Test func theStockPickIsTheSameEveryRun() {
    func loop(_ c: String, _ i: Int) -> StockLoop {
      StockLoop(
        path: "/\(c)/\(i < 10 ? "0" : "")\(i)", name: "\(i)", pack: "p", category: c,
        subcategory: "", genre: "", beats: 8, seconds: 4, key: nil)
    }
    let loops = (0..<10).map { loop("Bass", $0) } + (0..<3).map { loop("Drums", $0) }
    let pick = LevelSurvey.pick(loops.reversed(), perCategory: 4)
    #expect(
      pick.map(\.path) == [
        "/Bass/00", "/Bass/02", "/Bass/05", "/Bass/07", "/Drums/00", "/Drums/01", "/Drums/02",
      ])
    #expect(LevelSurvey.pick(loops.shuffled(), perCategory: 4) == pick)
  }
}
