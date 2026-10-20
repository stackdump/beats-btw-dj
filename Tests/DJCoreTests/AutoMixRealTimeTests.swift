import Testing

@testable import DJCore

// Auto-mix adds nothing to the audio thread: it works through commands that already exist (a
// prepared project, play, tempo, align, the strips' volume). Measured anyway, over a whole
// hand-off — the incoming compose landing, the mix-out swap, the start, the align, the
// crossfader steps, the tail's stop — with the main-thread housekeeping outside the measured
// region, as the app's hub runs it. Release builds only (`make swift-rt-test-filter`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct AutoMixRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func aHandOffAllocatesNothing() throws {
    let sr = 48_000.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
    dj.deterministic = true
    let a = try #require(dj["A"])
    a.loadNet(
      PreparedTrack(spec: TrackSpec(genre: "dnb", seed: 42), sampleRate: sr, opts: a.waveOptions))
    dj["B"]!.loadDemo()
    dj.autoMixArmDelay = 1  // a late start, so the correction's align is measured too
    dj.setAutoMix(on: true, bars: 4, every: 0)
    try dj.start()
    defer { dj.stop() }
    let router = ControllerRouter(engine: dj)
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    func housekeeping() {
      router.tick(now: Double(dj.frame) / sr)
      for d in dj.allDecks {
        d.turntable.drainRetired()
        d.service()
      }
      dj.serviceLoopTakes()
      dj.serviceWander()
      dj.serviceAutoMix()
    }
    a.setPlaying(true)
    housekeeping()
    pullEngine(dj, buffer, cycles: 40, frames: 128)  // warm up
    dj.autoMixNow()
    var allocs = 0
    var frees = 0
    var mixed = false
    var blocks = 0
    while blocks < 40_000 {
      housekeeping()
      if dj.autoMix.phase == .mixing { mixed = true }
      if mixed && dj.autoMix.run == nil { break }
      let r = countAllocations { pullEngine(dj, buffer, cycles: 4, frames: 128) }
      allocs += r.allocations
      frees += r.frees
      blocks += 4
    }
    #expect(mixed && dj.autoMix.log.count == 1, "a whole hand-off ran")
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
  }

  /// The level through a hand-off stays inside the measured dip (`AutoMix.maxDipLU`), never
  /// bumps more than the crossfade tolerance over the louder track, and never clips. Release
  /// only (a whole song rendered).
  @Test(.enabled(if: optimized, "a full render: release builds only"))
  func handOffLevelsStayWithinTheMeasuredDip() throws {
    for (genre, seed) in [("techno", 42.0), ("lofi", 7.0)] {
      let m = try AutoMixMeasure.run(genre: genre, seed: seed, bars: 8, every: 4)
      let h = try #require(m.handoffs.first)
      #expect(h.dipLU >= -AutoMix.maxDipLU, "\(genre) \(seed): dip \(h.dipLU)")
      #expect(h.bumpLU <= LevelMatch.crossfadeToleranceLU, "\(genre) \(seed): bump \(h.bumpLU)")
      #expect(m.truePeakDBTP < 0, "\(genre) \(seed): true peak \(m.truePeakDBTP)")
    }
  }
}
