import Testing

@testable import DJCore

// The audio-thread contract for the loops' master FX: every master macro fired on "L" while loops
// play (sweeps, holds, feel, the vinyl brake and its release, stacked fires, panics mid-way) and
// the faders aimed at the loops allocate and free nothing on the render thread. Release builds
// only (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct LoopMasterRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func loopMasterMacrosOnPlayingLoopsDoNotAllocate() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    let clips = (0..<4).map { fxTestClip($0, amplitude: 0.3) }
    dj.restoreClips(clips)
    try dj.start()
    defer { dj.stop() }
    for c in clips { dj.startLoop(c.id, atOnce: true) }
    dj.perform(.clipFx(id: clips[0].id, fx: LoopFX.presets[2].fx))
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // in, and warm
    #expect(clips.allSatisfy { dj.loopState($0.id) == .on })
    let bus = try #require(dj.loopMaster)
    var allocs = 0
    var frees = 0
    func measure(_ cycles: Int) {
      let r = countAllocations { pullEngine(dj, buffer, cycles: cycles, frames: 512) }
      allocs += r.allocations
      frees += r.frees
      dj.serviceLoopTakes()
    }
    for round in 0..<2 {
      for (i, m) in MasterMacro.allCases.enumerated() {
        // the pokes are the main thread's; only the renders are measured
        if round == 0 {
          dj.perform(.macro(deck: "L", id: m.id))  // on the next bar line
        } else {
          dj.fireLoopMaster(m, bars: i % 3 == 0 ? 1 : nil, atOnce: true)
        }
        if i % 4 == 1 { bus.setSlider(MasterFxKey.allCases[i % MasterFxKey.allCases.count], i * 7) }
        measure(24)
        if i % 5 == 4 {
          dj.perform(.panic(deck: "L"))
          measure(6)
        }
      }
      // the brake through its release, and a panic in the middle of one
      dj.fireLoopMaster(.vinylBrake, bars: 1, atOnce: true)
      measure(200)
      dj.fireLoopMaster(.vinylBrake, bars: 2, atOnce: true)
      measure(40)
      dj.perform(.panic(deck: "L"))
      measure(40)
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
  }
}
