import Testing

@testable import DJCore

// The audio-thread contract for per-loop FX: changing the FX of loops that are playing (mode
// swaps through dry, smoothed drive / tone / mix, on and off, the limiter engaging and letting
// go) allocates and frees nothing on the render thread, under the mixer or on a deck the clip
// was moved onto. Release builds only
// (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct LoopFxRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func changingFxOnPlayingLoopsDoesNotAllocate() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let clips = (0..<4).map { fxTestClip($0, amplitude: 0.3) }
    dj.restoreClips(clips)
    try dj.start()
    defer { dj.stop() }
    for c in clips { dj.startLoop(c.id, atOnce: true) }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // in, and warm
    #expect(clips.allSatisfy { dj.loopState($0.id) == .on })
    let settings: [LoopFX] =
      LoopFX.presets.map(\.fx) + [
        LoopFX(drive: 24, autoLevel: false),  // the limiter holds the channel
        LoopFX(drive: 24, mode: .fold, amount: 1, tone: 0.1),
        LoopFX(mode: .crush, amount: 1, bits: 3, downsample: 16),
        LoopFX(drive: 12, mode: .tube, amount: 0.9, mix: 0.5, trim: -6),
        LoopFX(bypass: true, drive: 24, mode: .hard),
        LoopFX(),
      ]
    var allocs = 0
    var frees = 0
    for round in 0..<3 {
      for (k, fx) in settings.enumerated() {
        // the pokes are the main thread's; only the renders are measured
        for (i, c) in clips.enumerated() where (i + k + round) % 2 == 0 || k == settings.count - 1 {
          dj.perform(.clipFx(id: c.id, fx: fx))
        }
        let r = countAllocations { pullEngine(dj, buffer, cycles: 12, frames: 512) }
        allocs += r.allocations
        frees += r.frees
        dj.serviceLoopTakes()
      }
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
    #expect(clips.allSatisfy { dj.clipFx($0.id) == LoopFX() })
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func changingFxOfAClipOnADeckDoesNotAllocate() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let clips = [fxTestClip(0, amplitude: 0.3), fxTestClip(1, amplitude: 0.3)]
    dj.restoreClips(clips)
    try dj.start()
    defer { dj.stop() }
    dj.playClip(clips[0].id, on: "A")
    dj.playClip(clips[1].id, on: "B")
    dj.perform(.play(deck: "A", on: true))
    dj.perform(.play(deck: "B", on: true))
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // in, and warm
    let settings: [LoopFX] =
      LoopFX.presets.map(\.fx) + [
        LoopFX(drive: 24, autoLevel: false),  // the deck's limiter holds it
        LoopFX(mode: .crush, amount: 1, bits: 3, downsample: 16),
        LoopFX(bypass: true, drive: 24, mode: .hard),
        LoopFX(),
      ]
    var allocs = 0
    var frees = 0
    for _ in 0..<3 {
      for fx in settings {
        for c in clips { dj.perform(.clipFx(id: c.id, fx: fx)) }
        let r = countAllocations { pullEngine(dj, buffer, cycles: 12, frames: 512) }
        allocs += r.allocations
        frees += r.frees
      }
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
    #expect(!dj["A"]!.renderer.fxRunning && !dj["B"]!.renderer.fxRunning)
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func launchingScenesWithFxDoesNotAllocate() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let clips = (0..<4).map { fxTestClip($0, amplitude: 0.3) }
    dj.restoreClips(clips)
    try dj.start()
    defer { dj.stop() }
    dj.setLoopQuantum(1)
    for c in clips { dj.startLoop(c.id, atOnce: true) }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // in, and warm
    let p = LoopFX.presets.map(\.fx)
    let fold = LoopFX(drive: 24, mode: .fold, amount: 1, tone: 0.1)
    let crush = LoopFX(mode: .crush, amount: 1, bits: 3, downsample: 16)
    // every clip in with FX of its own (mode swaps on the boundary, through dry), half of them
    // (the rest out, one turned off), and all in again with others
    dj.restoreScenes([
      LoopScene(name: "all", clips: zip(clips, p[1...4]).map { SceneClip(clipID: $0.id, fx: $1) }),
      LoopScene(
        name: "half",
        clips: [
          SceneClip(clipID: clips[0].id, gain: 0.5, fx: LoopFX()),
          SceneClip(clipID: clips[2].id, fx: crush),
        ]),
      LoopScene(
        name: "again",
        clips: zip(clips, [fold, crush, LoopFX(drive: 24, autoLevel: false), p[5]]).map {
          SceneClip(clipID: $0.id, fx: $1)
        }),
    ])
    var allocs = 0
    var frees = 0
    for _ in 0..<3 {
      for name in ["all", "half", "again"] {
        // the launch is the main thread's; only the renders (across its boundary) are measured
        dj.perform(.sceneLaunch(name: name, clips: nil))
        let r = countAllocations { pullEngine(dj, buffer, cycles: 60, frames: 512) }
        allocs += r.allocations
        frees += r.frees
        dj.serviceLoopTakes()
      }
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
    #expect(clips.allSatisfy { dj.loopState($0.id) == .on })
    #expect(dj.clipFx(clips[0].id) == fold && dj.clipFx(clips[3].id) == p[5])
  }
}
