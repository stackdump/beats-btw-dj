import Testing

@testable import DJCore

// The audio-thread contract for the FX unit: every knob moving on all three targets at once — a
// sample deck's bus (A), a playing net deck's chain and sends (B), the loops' bus (L) — with master
// macros stacked on top, kills and resets (some on the beat) and a panic, allocates and frees
// nothing on the render thread. Release builds only (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct FxUnitRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func knobsMovingOnEveryTargetDoNotAllocate() throws {
    let rate = 48_000.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    var ov = JSONObject()
    ov["seed"] = .number(11)
    let song = compose(genre: "trance", overrides: .object(ov))
    let b = dj["B"]!
    b.loadNet(
      WaveRunner.prepare(
        song, sampleRate: rate, opts: WaveOptions.extended(samplers: nil).forGenre("trance")),
      project: song)
    b.setPlaying(true)
    let clips = (0..<3).map { fxTestClip($0, amplitude: 0.3) }
    dj.restoreClips(clips)
    try dj.start()
    defer { dj.stop() }
    for c in clips { dj.startLoop(c.id, atOnce: true) }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // in, and warm
    #expect(b.fxUnitControls.contains(.room) && b.fxUnitControls.contains(.echo))
    var allocs = 0
    var frees = 0
    var where_ = ""
    func measure(_ cycles: Int) {
      let r = countAllocations(stacks: true) { pullEngine(dj, buffer, cycles: cycles, frames: 512) }
      allocs += r.allocations
      frees += r.frees
      if r.allocations + r.frees > 0 && where_.count < 20_000 { where_ += r.stackText }
      dj.serviceLoopTakes()
      b.wave.drainRetired()
    }
    let params = FxParam.allCases
    for step in 0..<240 {
      // the pokes are the main thread's; only the renders are measured
      for (t, deck) in ["A", "B", "L"].enumerated() {
        let p = params[(step + 4 * t) % params.count]
        let r = p.range
        let phase = Double((step * 7 + 13 * t) % 40) / 39
        dj.perform(.fx(deck: deck, param: p.id, value: r.lowerBound + phase * (r.upperBound - r.lowerBound)))
      }
      if step % 30 == 3 { dj.perform(.macro(deck: "B", id: "sweep-lp")) }
      if step % 30 == 9 { dj.perform(.macro(deck: "A", id: "riser")) }
      if step % 30 == 15 { dj.perform(.macro(deck: "L", id: "octave-up")) }
      if step % 40 == 20 { dj.perform(.fxKill(deck: "B", on: true, onBeat: true)) }
      if step % 40 == 30 { dj.perform(.fxKill(deck: "B", on: false, onBeat: false)) }
      if step % 50 == 25 { dj.perform(.fxReset(deck: "A", onBeat: true)) }
      if step % 50 == 45 { dj.perform(.fxReset(deck: "L", onBeat: false)) }
      if step % 60 == 59 { dj.perform(.panic(deck: "B")) }
      measure(2)
    }
    // everything back to neutral, the glides and the fades out
    for d in ["A", "B", "L"] { dj.perform(.fxReset(deck: d, onBeat: false)) }
    measure(100)
    #expect(allocs == 0, "the render path allocated \(allocs) times\(where_)")
    #expect(frees == 0, "and freed \(frees) times")
  }
}
