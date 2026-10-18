@preconcurrency import AVFoundation
import Testing

@testable import DJCore

/// The offline engine as the app runs it (`LoopRecordTests`' rig): 512-frame blocks, the takes
/// serviced between them.
@MainActor
private final class Rig {
  let dj: DJEngine
  let out: AVAudioPCMBuffer
  static let block = 512

  init(decks: [String] = ["A", "B"]) throws {
    dj = try DJEngine(decks: decks, offline: true, sampleRate: 48_000)
    out = AVAudioPCMBuffer(
      pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(Self.block))!
    dj.crossfader = 0
    dj.master = 1
    for d in dj.decks.values { d.volume = 1 }
  }

  func run(to frame: Int) throws {
    while dj.frame < frame {
      let n = min(Self.block, frame - dj.frame)
      guard try dj.engine.renderOffline(AVAudioFrameCount(n), to: out) == .success else { return }
      for d in dj.allDecks {
        d.turntable.drainRetired()
        d.service()
      }
      dj.serviceLoopTakes()
    }
  }

  func runUntilClip(limit: Int = 4 * 96_000) throws -> LoopClip? {
    let count = dj.clips.count
    let stop = dj.frame + limit
    while dj.clips.count == count, dj.frame < stop { try run(to: dj.frame + Self.block) }
    return dj.clips.count > count ? dj.clips.last : nil
  }

  /// Render until no clip is waiting to switch.
  func settle() throws {
    for _ in 0..<2000 where dj.clips.contains(where: { dj.loopSwitchFrame($0.id) != nil }) {
      try run(to: dj.frame + Self.block)
    }
    try run(to: dj.frame + 4096)
  }
}

private let bar = 96_000  // 120 bpm at 48 kHz
private let beat = bar / 4
/// A frame, in beats: a boundary is rounded up to a whole frame.
private let oneFrame = 1.0 / Double(beat)

/// Is beat `b` on a line every `q` beats (to within the frame it was rounded to)?
private func onLine(_ b: Double, every q: Double) -> Bool {
  let r = (b / q - (b / q).rounded()) * q
  return abs(r) <= oneFrame * 1.01
}

@MainActor
struct LoopLaunchTests {
  /// Two one-bar takes of a net deck at 120 bpm on deck A, both looping under the mixer.
  private func twoTakes(_ rig: Rig) async throws -> (LoopClip, LoopClip) {
    let d = try #require(rig.dj["A"])
    await d.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    d.setPlaying(true)
    try rig.dj.start()
    try rig.run(to: bar + 100)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: 2 * bar - 100)
    rig.dj.loopRecord("A", on: false)
    let one = try #require(try rig.runUntilClip())
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: rig.dj.frame + bar / 2)
    rig.dj.loopRecord("A", on: false)
    let two = try #require(try rig.runUntilClip())
    try rig.settle()
    return (one, two)
  }

  /// The loop channel's loudest sample in the 256 frames before `frame`, and the 2048 from it.
  private func edge(_ l: Deck, _ frame: Int) -> (before: Float, after: Float) {
    var bl: [Float] = []
    var br: [Float] = []
    var al: [Float] = []
    var ar: [Float] = []
    _ = l.capture.copy(from: frame - 256, to: frame, left: &bl, right: &br)
    _ = l.capture.copy(from: frame, to: frame + 2048, left: &al, right: &ar)
    return (bl.map(abs).max() ?? 0, al.map(abs).max() ?? 0)
  }

  @Test func withFourBarsAStartLandsOnAPhraseOfTheDeck() async throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    let l = rig.dj.loopChannel
    rig.dj.stopAllLoops()
    try rig.settle()
    #expect(rig.dj.loopingClips.isEmpty)
    rig.dj.perform(.loopQuantize(beats: 16))
    #expect(rig.dj.loopQuantum == 16)
    let clock = rig.dj.loopClock(for: one)
    #expect(clock.ref === rig.dj["A"])
    let now = l.renderedFrames
    let down = clock.nextBoundary(after: now + DJEngine.loopLead, every: 16)
    #expect(onLine(clock.beat(down), every: 16), "on a 16-beat line of A's own count")
    #expect(Int((clock.beat(down) / 4).rounded()) % 4 == 0, "bar 1, 5, 9… (0-based 0, 4, 8…)")
    #expect(down - now <= 16 * beat + DJEngine.loopLead)

    rig.dj.perform(.clipLoop(id: one.id, on: true))
    #expect(rig.dj.loopState(one.id) == .starting)
    #expect(rig.dj.loopSwitchFrame(one.id) == down)
    let cd = try #require(rig.dj.loopCountdown(one.id))
    #expect(abs(cd.beats - Double(down - now) / Double(beat)) < 0.05, "\(cd)")
    #expect(cd.of >= cd.beats)
    #expect(rig.dj.loopSwitchFrame(two.id) == nil, "not waiting")

    // half way there it counts down; on the boundary it comes in, frame-exact
    let half = now + (down - now) / 2
    try rig.run(to: half)
    let mid = try #require(rig.dj.loopCountdown(one.id))
    #expect(mid.beats < cd.beats && mid.beats > 0)
    try rig.run(to: down + bar / 2)
    #expect(rig.dj.loopState(one.id) == .on && rig.dj.loopCountdown(one.id) == nil)
    let e = edge(l, down)
    #expect(e.before == 0 && e.after > 0.001, "comes in at frame \(down): \(e)")

    // and goes out on a phrase line too
    rig.dj.perform(.clipLoop(id: one.id, on: false))
    let out = try #require(rig.dj.loopSwitchFrame(one.id))
    #expect(onLine(rig.dj.loopClock(for: one).beat(out), every: 16))
  }

  @Test func onTheBeatAStartWaitsAtMostABeat() async throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (one, _) = try await twoTakes(rig)
    rig.dj.stopAllLoops()
    try rig.settle()
    rig.dj.perform(.loopQuantize(beats: 1))
    rig.dj.perform(.loopQuantize(beats: 3))  // not one of the boundaries offered: refused
    #expect(rig.dj.loopQuantum == 1)
    let now = rig.dj.loopChannel.renderedFrames
    rig.dj.perform(.clipLoop(id: one.id, on: true))
    let at = try #require(rig.dj.loopSwitchFrame(one.id))
    #expect(at - now <= beat + DJEngine.loopLead)
    #expect(onLine(rig.dj.loopClock(for: one).beat(at), every: 1))
    #expect(DJEngine.quantumLabel(1) == "beat" && DJEngine.quantumLabel(4) == "bar")
    #expect(DJEngine.quantumLabel(8) == "2 bars" && DJEngine.quantumLabel(32) == "8 bars")
  }

  @Test func aSceneStartsExactlyItsClipsAndStopsTheOthersOnOneBoundary() async throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    // "Scene 1": just one (at 0.6); "Scene 2": just two
    rig.dj.perform(.clipLoop(id: two.id, on: false))
    try rig.settle()
    rig.dj.perform(.clipGain(id: one.id, value: 0.6))
    #expect(rig.dj.nextSceneName == "Scene 1")
    rig.dj.perform(.sceneSave(name: rig.dj.nextSceneName))
    rig.dj.perform(.clipLoop(id: one.id, on: false))
    rig.dj.perform(.clipLoop(id: two.id, on: true))
    try rig.settle()
    rig.dj.perform(.sceneSave(name: rig.dj.nextSceneName))
    #expect(rig.dj.scenes.map(\.name) == ["Scene 1", "Scene 2"])
    #expect(rig.dj.scenes[0].clips == [SceneClip(clipID: one.id, gain: 0.6)])
    #expect(rig.dj.scenes[1].clips == [SceneClip(clipID: two.id, gain: 1)])
    rig.dj.perform(.clipGain(id: one.id, value: 0.2))

    rig.dj.perform(.loopQuantize(beats: 8))
    rig.dj.perform(.sceneLaunch(name: "Scene 1", clips: nil))
    #expect(rig.dj.loopState(one.id) == .starting && rig.dj.loopState(two.id) == .stopping)
    let at = try #require(rig.dj.loopSwitchFrame(one.id))
    #expect(rig.dj.loopSwitchFrame(two.id) == at, "in and out on the same frame")
    #expect(onLine(rig.dj.loopClock(for: one).beat(at), every: 8), "a 2-bar line")
    #expect(rig.dj.clipGain(one.id) == 0.6, "the scene's level")
    try rig.run(to: at + 4096)
    #expect(rig.dj.loopState(one.id) == .on && rig.dj.loopState(two.id) == .off)
    #expect(rig.dj.loopingClips == [one.id])

    // a scene with a clip already in keeps it in, and drops the rest
    rig.dj.perform(.clipLoop(id: two.id, on: true))
    try rig.settle()
    rig.dj.perform(.sceneLaunch(name: "Scene 2", clips: nil))
    #expect(rig.dj.loopState(two.id) == .on, "already in: stays in")
    #expect(rig.dj.loopState(one.id) == .stopping)
    try rig.settle()
    #expect(rig.dj.loopingClips == [two.id])

    // a recorded launch carries its clips, so a replay needs no saved scene
    rig.dj.perform(.sceneLaunch(name: "gone", clips: [SceneClip(clipID: one.id, gain: 0.5)]))
    try rig.settle()
    #expect(rig.dj.loopingClips == [one.id] && rig.dj.clipGain(one.id) == 0.5)
    rig.dj.perform(.sceneLaunch(name: "nothing like it", clips: nil))
    #expect(rig.dj.loopingClips == [one.id], "an unknown scene does nothing")
  }

  @Test func aWaitingLoopFollowsItsDeckWhenTheTempoMovesDuringTheCountdown() async throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (one, _) = try await twoTakes(rig)
    let a = try #require(rig.dj["A"])
    let l = rig.dj.loopChannel
    rig.dj.stopAllLoops()
    try rig.settle()
    rig.dj.perform(.loopQuantize(beats: 32))
    // just past an 8-bar line, so the wait is a long one
    while rig.dj.loopClock(for: one).nextBoundary(
      after: l.renderedFrames + DJEngine.loopLead, every: 32) - l.renderedFrames < 5 * bar
    {
      try rig.run(to: rig.dj.frame + bar / 2)
    }
    rig.dj.perform(.clipLoop(id: one.id, on: true))
    let planned = try #require(rig.dj.loopSwitchFrame(one.id))
    let line = rig.dj.loopClock(for: one).beat(planned)
    #expect(onLine(line, every: 32))
    // a bar into the countdown, deck A's tempo fader goes up 5 %: its line comes sooner
    try rig.run(to: rig.dj.frame + bar)
    a.pitch = 0.625
    try rig.run(to: rig.dj.frame + 8 * Rig.block)
    let moved = try #require(rig.dj.loopSwitchFrame(one.id))
    #expect(moved < planned - 10_000, "follows the deck: \(moved) vs \(planned)")
    #expect(abs(rig.dj.loopClock(for: one).beat(moved) - line) < 0.01, "the same line of A")
    try rig.run(to: moved + bar / 2)
    #expect(rig.dj.loopState(one.id) == .on)
    let e = edge(l, moved)
    #expect(e.before == 0 && e.after > 0.001, "comes in on the moved frame: \(e)")
    // and in phase with A, at A's new tempo
    let v = try #require(rig.dj.loopVoices.firstIndex { $0.clipID == one.id })
    let tt = try #require(l.bank).voices[v]
    let phase = (tt.position / Double(tt.length)).truncatingRemainder(dividingBy: 1)
    let s = try #require(a.beatState)
    let err = abs(phase - s.barPhase)
    #expect(min(err, 1 - err) < 0.01, "\(phase) vs \(s.barPhase)")
  }

  @Test func aMuteDuringASceneCountdownLeavesTheScenesLevelForTheBoundary() throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (x, y) = (testClip(1), testClip(2))
    rig.dj.restoreClips([x, y])
    try rig.dj.start()
    rig.dj.setLooping(x.id, true)
    rig.dj.setLooping(y.id, true)
    try rig.settle()
    let l = rig.dj.loopChannel
    func level(_ from: Int, _ to: Int) -> Double {
      var left: [Float] = []
      var right: [Float] = []
      _ = l.capture.copy(from: from, to: to, left: &left, right: &right)
      return left.map { Double(abs($0)) }.reduce(0, +) / Double(max(1, left.count))
    }
    rig.dj.perform(.loopQuantize(beats: 16))
    let at = rig.dj.launchScene(clips: [
      SceneClip(clipID: x.id, gain: 0.5), SceneClip(clipID: y.id, gain: 1),
    ])
    #expect(at - l.renderedFrames > bar, "a 4-bar countdown")
    try rig.run(to: rig.dj.frame + 4 * Rig.block)
    let both = level(l.renderedFrames - 1024, l.renderedFrames)
    rig.dj.perform(.clipMute(id: y.id, on: true))
    try rig.run(to: at - 4096)
    let before = level(at - 8192, at - 4096)
    try rig.run(to: at + 8192)
    let after = level(at + 2048, at + 6144)
    // x alone at 1 until the boundary (y muted), then at the scene's 0.5
    #expect(abs(before / both - 0.0150 / 0.0400) < 0.02, "x still at 1: \(before) of \(both)")
    #expect(abs(after / before - 0.5) < 0.02, "the scene's level on its boundary: \(after)")
  }

  @Test func scenesAreRenamedOverwrittenDeletedAndFollowACrop() async throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    rig.dj.perform(.sceneSave(name: "Scene 1"))
    #expect(Set(rig.dj.scenes[0].clips.map(\.clipID)) == [one.id, two.id])
    #expect(rig.dj.scenes[0].clips.map(\.clipID) == [one.id, two.id], "in row order")
    rig.dj.perform(.sceneRename(name: "Scene 1", to: "drop"))
    rig.dj.perform(.sceneSave(name: rig.dj.nextSceneName))
    #expect(rig.dj.scenes.map(\.name) == ["drop", "Scene 2"])
    rig.dj.perform(.sceneRename(name: "drop", to: "Scene 2"))
    #expect(rig.dj.scenes.map(\.name) == ["drop", "Scene 2"], "a name already taken is refused")
    // overwrite: the same name, what plays now
    rig.dj.perform(.clipLoop(id: two.id, on: false))
    try rig.settle()
    rig.dj.perform(.sceneSave(name: "drop"))
    #expect(rig.dj.scenes[0].name == "drop" && rig.dj.scenes[0].clips.map(\.clipID) == [one.id])
    // a crop takes the original's place in its scenes
    let cropped = try #require(rig.dj.cropClip(one.id, from: 0, to: 2))
    #expect(rig.dj.scenes[0].clips.map(\.clipID) == [cropped])
    #expect(rig.dj.scenes[1].clips.map(\.clipID) == [cropped, two.id])
    rig.dj.perform(.sceneDelete(name: "drop"))
    #expect(rig.dj.scenes.map(\.name) == ["Scene 2"])
    #expect(rig.dj.nextSceneName == "Scene 3", "Scene 2 is taken")
  }

  @Test func aSceneLaunchIsRecordedWithItsClips() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let c = testClip(1)
    dj.restoreClips([c])
    dj.setLooping(c.id, true)
    dj.setClipGain(c.id, 0.7)
    dj.saveScene("S")
    dj.setLoopQuantum(16)
    let rec = try SessionRecorder.start(on: dj)
    dj.perform(.sceneLaunch(name: "S", clips: nil))
    let events = rec.finish().events.map(\.kind)
    #expect(
      events == [
        .action(.loopQuantize(beats: 16)),
        .action(.sceneLaunch(name: "S", clips: [SceneClip(clipID: c.id, gain: 0.7)])),
      ], "the starting boundary first (a replay starts at a bar), then the scene, spelled out")
  }

  @Test func aSceneSetsItsClipsFxOnItsBoundaryFrame() throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let c = testClip(1)
    let d = testClip(2)
    rig.dj.restoreClips([c, d])
    try rig.dj.start()
    rig.dj.perform(.clipLoop(id: c.id, on: true))
    rig.dj.perform(.clipLoop(id: d.id, on: true))
    try rig.settle()
    let crunch = LoopFX(drive: 9, mode: .hard, amount: 0.55, tone: 0.75)
    let fuzz = LoopFX(drive: 18, mode: .soft, amount: 0.9, tone: 0.6)
    rig.dj.perform(.clipFx(id: c.id, fx: crunch))
    rig.dj.perform(.sceneSave(name: "S"))
    #expect(
      rig.dj.scenes[0].clips == [SceneClip(clipID: c.id, fx: crunch), SceneClip(clipID: d.id)],
      "FX kept only where they were on")
    rig.dj.perform(.clipFx(id: c.id, fx: LoopFX()))
    rig.dj.perform(.clipFx(id: d.id, fx: fuzz))
    try rig.run(to: rig.dj.frame + 4096)
    let bank = try #require(rig.dj.loopChannel.bank)
    let v = try #require(rig.dj.loopVoices.firstIndex { $0.clipID == c.id })
    #expect(!bank.fx[v].running, "dry before the launch")

    rig.dj.perform(.loopQuantize(beats: 4))
    let at = try #require(rig.dj.launchScene("S"))
    #expect(rig.dj.clipFx(c.id) == crunch, "the clip's FX are the scene's at once")
    #expect(rig.dj.clipFx(d.id) == fuzz, "a clip saved dry keeps the FX it has")
    try rig.run(to: at)
    #expect(!bank.fx[v].running, "the voice waits for the boundary")
    try rig.run(to: at + 1)
    #expect(bank.fx[v].running, "and takes them on its frame")
    #expect(rig.dj.loopState(c.id) == .on && rig.dj.loopState(d.id) == .on)
  }

  @Test func sceneFxAreRecordedAndEncodedOnlyWhenSet() throws {
    let crunch = LoopFX(drive: 9, mode: .hard, amount: 0.55, tone: 0.75)
    // without FX a scene encodes as it did before scenes kept them
    #expect(
      [SceneClip(clipID: "abc", gain: 0.5)].json.canonicalJS == #"[{"clip":"abc","gain":0.5}]"#)
    let withFx = [SceneClip(clipID: "abc", gain: 0.5, fx: crunch), SceneClip(clipID: "def")]
    #expect([SceneClip](json: withFx.json) == withFx)
    #expect([SceneClip](json: [SceneClip(clipID: "abc")].json)[0].fx == nil, "nil stays nil")
    let scene = LoopScene(name: "drop", clips: withFx)
    #expect(LoopScene(json: scene.json) == scene)
    let a = DeckAction.sceneLaunch(name: "drop", clips: withFx)
    #expect(DeckAction(json: a.json) == a, "\(a.json.canonicalJS)")

    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let c = testClip(1)
    dj.restoreClips([c])
    dj.setLooping(c.id, true)
    dj.setClipFx(c.id, crunch)
    dj.saveScene("S")
    let rec = try SessionRecorder.start(on: dj)
    dj.perform(.sceneLaunch(name: "S", clips: nil))
    let launches = rec.finish().events.compactMap { e -> [SceneClip]? in
      if case .action(.sceneLaunch(_, let clips)) = e.kind { return clips }
      return nil
    }
    #expect(launches == [[SceneClip(clipID: c.id, fx: crunch)]], "the recorded launch carries them")

    // an old scene (no FX) leaves the clip's alone; one with FX off turns them off
    let fuzz = LoopFX(drive: 18, mode: .soft, amount: 0.9, tone: 0.6)
    dj.setClipFx(c.id, fuzz)
    dj.launchScene(clips: [SceneClip(clipID: c.id)])
    #expect(dj.clipFx(c.id) == fuzz)
    dj.launchScene(clips: [SceneClip(clipID: c.id, fx: LoopFX())])
    #expect(dj.clipFx(c.id) == LoopFX())
  }

  @Test func theLaunchActionsRoundTrip() {
    for a in [
      DeckAction.loopQuantize(beats: 16), .sceneSave(name: "Scene 1"),
      .sceneLaunch(name: "Scene 1", clips: nil),
      .sceneLaunch(
        name: "drop", clips: [SceneClip(clipID: "abc", gain: 0.5), SceneClip(clipID: "def")]),
      .sceneRename(name: "Scene 1", to: "drop"), .sceneDelete(name: "drop"),
    ] {
      #expect(DeckAction(json: a.json) == a, "\(a.json.canonicalJS)")
    }
  }

  @Test func scenesSurviveTheLibrary() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let row = [testClip(1), testClip(2)]
    let scenes = [
      LoopScene(name: "Scene 1", clips: [SceneClip(clipID: row[0].id, gain: 0.25)]),
      LoopScene(name: "drop", clips: row.map { SceneClip(clipID: $0.id) }),
    ]
    try lib.save(row, scenes: scenes)
    #expect(lib.loadScenes() == scenes)
    #expect(lib.load(sampleRate: 48_000).map(\.id) == row.map(\.id), "the loops as before")
    try lib.save([row[1]])
    #expect(lib.loadScenes() == scenes, "saving the row alone keeps the scenes")
    try lib.save(row, scenes: [])
    #expect(lib.loadScenes().isEmpty)
    #expect(tempLoopLibrary().loadScenes().isEmpty, "no library, no scenes")
  }

  @Test func aLevelChangeLandsOnItsFrame() {
    // the bank on its own: a constant clip, its level dropped to a quarter at frame 700
    let bank = LoopBank(sampleRate: 48_000)
    let n = 4096
    let tt = bank.voices[0]
    tt.load(SampleBuffer(left: [Float](repeating: 0.5, count: n), sampleRate: 48_000))
    tt.send(.loop(start: 0, end: Double(n)))
    tt.send(.start)
    bank.send(.gain(voice: 0, 1))
    bank.send(.start(voice: 0, frame: 0, fade: 0))
    bank.send(.gainAt(voice: 0, 0.25, frame: 700))
    var out: [Float] = []
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    defer { l.deallocate() }
    for b in 0..<3 {
      bank.render(frames: 512, left: l, right: nil, startFrame: b * 512)
      out += UnsafeBufferPointer(start: l, count: 512)
    }
    // it starts on its frame and ramps there over `rampFrames`, like any level change
    let r = bank.rampFrames
    #expect(out[100..<700].allSatisfy { abs($0 - 0.5) < 1e-6 }, "\(out[699])")
    #expect(out[701] < 0.5 && out[701] > 0.125, "\(out[701])")
    #expect(zip(out[700..<700 + r], out[701...]).allSatisfy { $1 <= $0 + 1e-6 }, "falling")
    #expect(out[(700 + r)..<1536].allSatisfy { abs($0 - 0.125) < 1e-6 }, "\(out[700 + r])")
    // a plain level change cancels one still waiting
    bank.send(.gainAt(voice: 0, 0, frame: 2000))
    bank.send(.gain(voice: 0, 1))
    bank.render(frames: 512, left: l, right: nil, startFrame: 1536)
    bank.render(frames: 512, left: l, right: nil, startFrame: 2048)
    #expect(UnsafeBufferPointer(start: l, count: 512).allSatisfy { abs($0 - 0.5) < 1e-6 })
  }

  // MARK: a clip's own launch boundary

  @Test func aClipsOwnBoundaryOverridesTheRowsButAScenesDoesNot() async throws {
    let rig = try Rig()
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    rig.dj.stopAllLoops()
    try rig.settle()
    rig.dj.perform(.loopQuantize(beats: 1))
    rig.dj.perform(.clipQuantize(id: one.id, beats: 16))
    rig.dj.perform(.clipQuantize(id: two.id, beats: 3))  // not offered: refused
    #expect(rig.dj.clipQuantum(one.id) == 16 && rig.dj.clipQuantum(two.id) == nil)
    #expect(rig.dj.quantum(for: one.id) == 16 && rig.dj.quantum(for: two.id) == 1)
    #expect(rig.dj.quantum(for: nil) == 1)

    // one waits for a 4-bar phrase line, two (following the row) at most a beat
    let now = rig.dj.loopChannel.renderedFrames
    rig.dj.perform(.clipLoop(id: one.id, on: true))
    rig.dj.perform(.clipLoop(id: two.id, on: true))
    let a = try #require(rig.dj.loopSwitchFrame(one.id))
    let b = try #require(rig.dj.loopSwitchFrame(two.id))
    #expect(onLine(rig.dj.loopClock(for: one).beat(a), every: 16), "its own boundary")
    #expect(b - now <= beat + DJEngine.loopLead, "the row's")
    #expect(onLine(rig.dj.loopClock(for: two).beat(b), every: 1))
    try rig.settle()

    // its stop waits for its own line too
    rig.dj.perform(.clipLoop(id: one.id, on: false))
    let out = try #require(rig.dj.loopSwitchFrame(one.id))
    #expect(onLine(rig.dj.loopClock(for: one).beat(out), every: 16))
    try rig.settle()

    // a scene switches on the row's boundary, whatever its clips say
    rig.dj.perform(.loopQuantize(beats: 4))
    rig.dj.perform(.clipQuantize(id: one.id, beats: 32))
    let then = rig.dj.loopChannel.renderedFrames
    rig.dj.perform(.sceneLaunch(name: "s", clips: [SceneClip(clipID: one.id)]))
    let at = try #require(rig.dj.loopSwitchFrame(one.id))
    #expect(at - then <= 4 * beat + DJEngine.loopLead, "a bar at most, not 8")
    #expect(rig.dj.loopSwitchFrame(two.id) == at)

    // null follows the row again
    rig.dj.perform(.clipQuantize(id: one.id, beats: nil))
    #expect(rig.dj.clipQuantum(one.id) == nil && rig.dj.quantum(for: one.id) == 4)
  }

  @Test func aClipsBoundaryAndFadeGoWithItAndAreForgottenWithIt() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let c = testClip(1)
    let d = testClip(2)
    dj.restoreClips([c, d])
    dj.setClipQuantum(c.id, 8)
    dj.setClipFade(c.id, .bar)
    #expect(dj.clipLaunch == [c.id: ClipLaunch(quantum: 8, fade: .bar)], "only clips with one")
    // taken off and put back: as it was
    dj.removeClip(c.id)
    #expect(dj.clipQuantum(c.id) == nil && dj.clipFade(c.id) == nil && dj.clipLaunch.isEmpty)
    #expect(dj.removedClips.first?.sound == ClipSound(quantum: 8, fade: .bar))
    dj.restoreClip(c.id)
    #expect(dj.clipQuantum(c.id) == 8 && dj.clipFade(c.id) == .bar)
    // the library's, back on a fresh row (unknown ids skipped)
    let fresh = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    fresh.restoreClips([c, d])
    fresh.restoreClipLaunch([c.id: ClipLaunch(quantum: 16), "gone": ClipLaunch(fade: .off)])
    #expect(fresh.clipQuantum(c.id) == 16 && fresh.clipFade(c.id) == nil)
    #expect(fresh.clipLaunch.keys.sorted() == [c.id])
  }

  @Test func theClipLaunchActionsRoundTripAndRecord() throws {
    for a in [
      DeckAction.clipQuantize(id: "abc", beats: 16), .clipQuantize(id: "abc", beats: nil),
      .clipFade(id: "abc", mode: "bar"), .clipFade(id: "abc", mode: nil),
    ] {
      #expect(DeckAction(json: a.json) == a, "\(a.json.canonicalJS)")
      #expect(a.clipIDs == ["abc"])
    }
    #expect(
      DeckAction.clipQuantize(id: "x", beats: nil).json.canonicalJS
        == #"{"beats":null,"id":"x","op":"clipQuantize"}"#)
    #expect(JournalEvent.action(.clipQuantize(id: "x", beats: 4)).foldKey == "quantize.x")
    #expect(JournalEvent.action(.clipFade(id: "x", mode: nil)).foldKey == "fade.x")

    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let c = testClip(1)
    dj.restoreClips([c])
    let rec = try SessionRecorder.start(on: dj)
    dj.perform(.clipQuantize(id: c.id, beats: 32))
    dj.perform(.clipFade(id: c.id, mode: "beat"))
    dj.perform(.clipFade(id: c.id, mode: "nonsense"))  // not a fade: ignored
    let events = rec.finish().events.map(\.kind)
    #expect(events.count == 3)
    #expect(dj.clipQuantum(c.id) == 32 && dj.clipFade(c.id) == .beat)
    // a replay, on a fresh engine, does the same
    let fresh = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    fresh.restoreClips([c])
    for case .action(let a) in events { fresh.perform(a) }
    #expect(fresh.clipQuantum(c.id) == 32 && fresh.clipFade(c.id) == .beat)
    fresh.perform(.clipFade(id: c.id, mode: nil))
    #expect(fresh.clipFade(c.id) == nil)
  }

  @Test func clipLaunchSurvivesTheLibraryAndIsLeftOutWithout() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let row = [testClip(1), testClip(2)]
    try lib.save(row)
    let plain = try String(contentsOf: lib.indexFile, encoding: .utf8)
    #expect(!plain.contains("quantum") && !plain.contains("\"fade\""), "nothing when unset")
    #expect(LoopLibrary.entry(row[0]) == LoopLibrary.entry(row[0], launch: ClipLaunch()))
    let launch = [row[0].id: ClipLaunch(quantum: 8, fade: .beat)]
    try lib.save(row, launch: launch)
    #expect(lib.loadLaunch() == launch)
    try lib.save(row)
    #expect(lib.loadLaunch() == launch, "saving the row alone keeps them")
    try lib.save(row, launch: [:])
    #expect(lib.loadLaunch().isEmpty)
    #expect(try String(contentsOf: lib.indexFile, encoding: .utf8) == plain, "byte for byte")
  }
}

/// A one-bar clip at 120 bpm whose samples say which clip it is.
private func testClip(_ n: Int) -> LoopClip {
  let len = 96_000
  let l = (0..<len).map { i in Float(n) * 0.01 + Float(i % 100) * 1e-4 }
  let b = SampleBuffer(left: l, right: l.map { -$0 }, sampleRate: 48_000)
  return LoopClip(
    id: b.contentID, title: "A loop \(n)", source: "A", bars: 1, bpm: 120, startBeat: 0,
    buffer: b, waveform: WaveformOverview(buffer: b, columns: 40))
}
