import Testing

@testable import DJCore

// The journal is written on its own queue, from events recorded on the main / control side:
// nothing of it runs on the render thread. Measured, like the rest of the audio-thread
// contract: with a journal attached and its queue busy writing thousands of lines, rendering
// allocates and frees nothing. Release builds only (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct JournalRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func journalingWhileRenderingDoesNotAllocateOnTheRenderThread() async throws {
    let dir = tempJournalDir()
    defer { removeDir(dir) }
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let a = try #require(dj["A"])
    await a.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    a.setPlaying(true)
    dj["B"]!.loadDemo()
    dj["B"]!.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let journal = try Journal(engine: dj, directory: dir)
    let router = ControllerRouter(engine: dj)
    router.attach(port: "APC mini mk2 Control")
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    pullEngine(dj, buffer, cycles: 200, frames: 512)  // warm up

    var allocs = 0
    var frees = 0
    for round in 0..<20 {
      // the main side: inputs through every path, journaled (outside the measured region)
      for i in 0..<200 {
        dj.perform(.crossfader(Double((round * 200 + i) % 100) / 100))
        router.route(port: "APC mini mk2 Control", bytes: [0xB0, 48, UInt8(i % 128)])
        journal.record(.mark("load \(i)"))
      }
      // ...while the journal's queue writes them, the render thread renders
      let r = countAllocations { pullEngine(dj, buffer, cycles: 50, frames: 512) }
      allocs += r.allocations
      frees += r.frees
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
    journal.close()
    let c = try readNewestJournal(dir)
    #expect(c.entries.count == 1 + 20 * 200 * 3, "every line written")
    #expect(!c.truncated && c.skipped.isEmpty)
  }
}
