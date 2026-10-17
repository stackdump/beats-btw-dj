import Testing

@testable import DJCore

// The audio-thread contract for launching: a scene switching clips in and out on one boundary,
// with a level change landing on that frame inside a block (`LoopBankCommand.gainAt`), allocates
// and frees nothing on the render thread. Release builds only (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct LoopLaunchRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func aSceneLaunchDoesNotAllocate() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let a = try #require(dj["A"])
    await a.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    func pull(_ cycles: Int) {
      for _ in 0..<cycles {
        pullEngine(dj, buffer, cycles: 1, frames: 512)
        dj.serviceLoopTakes()
      }
    }
    // two one-bar takes, both looping
    pull(200)
    #expect(dj.loopRecord("A", on: true))
    pull(150)
    dj.loopRecord("A", on: false)
    pull(400)
    #expect(dj.loopRecord("A", on: true))
    pull(100)
    dj.loopRecord("A", on: false)
    pull(400)
    #expect(dj.clips.count == 2)
    let (one, two) = (dj.clips[0], dj.clips[1])
    // "one at half": a scene with the first clip only, at another level
    dj.setClipGain(one.id, 0.5)
    dj.stopLoop(two.id, now: true)
    pull(4)
    dj.saveScene("one")
    dj.setClipGain(one.id, 1)
    dj.startLoop(two.id, atOnce: true)
    pull(200)
    #expect(dj.loopState(two.id) == .on && dj.loopState(one.id) == .on)

    pullEngine(dj, buffer, cycles: 200, frames: 512)  // warm up
    dj.setLoopQuantum(1)
    let at = try #require(dj.launchScene("one"))
    #expect(dj.loopState(two.id) == .stopping)
    var allocs = 0
    var frees = 0
    let r = countAllocations { pullEngine(dj, buffer, cycles: 200, frames: 512) }
    allocs += r.allocations
    frees += r.frees
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
    #expect(dj.frame > at)
    dj.serviceLoopTakes()
    #expect(dj.loopState(one.id) == .on && dj.loopState(two.id) == .off)
  }
}
