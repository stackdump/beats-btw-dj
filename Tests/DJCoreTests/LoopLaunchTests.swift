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
    bank.send(.start(voice: 0, frame: 0))
    bank.send(.gainAt(voice: 0, 0.25, frame: 700))
    var out: [Float] = []
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    defer { l.deallocate() }
    for b in 0..<3 {
      bank.render(frames: 512, left: l, right: nil, startFrame: b * 512)
      out += UnsafeBufferPointer(start: l, count: 512)
    }
    #expect(out[100..<700].allSatisfy { abs($0 - 0.5) < 1e-6 }, "\(out[699])")
    #expect(out[700..<1536].allSatisfy { abs($0 - 0.125) < 1e-6 }, "\(out[700])")
    // a plain level change cancels one still waiting
    bank.send(.gainAt(voice: 0, 0, frame: 2000))
    bank.send(.gain(voice: 0, 1))
    bank.render(frames: 512, left: l, right: nil, startFrame: 1536)
    bank.render(frames: 512, left: l, right: nil, startFrame: 2048)
    #expect(UnsafeBufferPointer(start: l, count: 512).allSatisfy { abs($0 - 0.5) < 1e-6 })
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
