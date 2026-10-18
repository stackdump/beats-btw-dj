import Testing

@testable import DJCore

// The audio-thread contract for master macros on sample decks (`DeckRenderer.master`): every
// master macro fired on a playing sample deck (sweeps, holds, feel, pitch; the vinyl brake is a
// no-op there), stacked fires, sliders and panics mid-way allocate and free nothing on the render
// thread. Release builds only (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct SampleDeckMasterRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func sampleDeckMacrosDoNotAllocate() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    a.loadDemo()
    b.loadDemo()
    a.setPlaying(true)
    b.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // spun up, and warm
    var allocs = 0
    var frees = 0
    func measure(_ cycles: Int) {
      let r = countAllocations { pullEngine(dj, buffer, cycles: cycles, frames: 512) }
      allocs += r.allocations
      frees += r.frees
    }
    let keys = MasterFxKey.allCases
    for round in 0..<2 {
      for (i, m) in MasterMacro.allCases.enumerated() {
        // the pokes are the main thread's; only the renders are measured
        let deck = i % 2 == 0 ? a : b
        if round == 0 {
          dj.perform(.macro(deck: deck.name, id: m.id))  // on the deck's next bar
        } else {
          deck.fire(m, duration: i % 3 == 0 ? 1 : nil)
        }
        if i % 4 == 1 { deck.setMasterFx(keys[i % keys.count], i * 7) }
        measure(40)
        if i % 5 == 4 {
          dj.perform(.panic(deck: deck.name))
          measure(8)
        }
      }
      // let the stacked fires land and run out (a bar at 120 bpm is 188 blocks of 512)
      measure(400)
      dj.perform(.panic(deck: "A"))
      dj.perform(.panic(deck: "B"))
      measure(40)
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
  }
}
