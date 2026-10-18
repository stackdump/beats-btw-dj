import Testing

@testable import DJCore

// A reset (`DJEngine.reset(to:clip:)`) is main-thread work: the row's voices fade out and are
// reloaded, the decks are emptied and loaded again, and every buffer and project they let go of
// comes back through the retire rings to be freed on the main thread. Measured: rendering through
// resets back and forth between two busy states allocates and frees nothing. Release builds only
// (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct JournalRewindRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func resettingWhileRenderingDoesNotAllocateOnTheRenderThread() async throws {
    let rate = 48_000.0
    let spec = TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))]))
    let clips = [fxTestClip(1), fxTestClip(2), fxTestClip(3)]
    let lookup: (String) -> LoopClip? = { id in clips.first { $0.id == id } }
    let demo = DeckSourceDescriptor.sample(
      id: DeckSourceDescriptor.demoID, title: "demo", grid: nil)
    // one: the demo on A, the net on B, both playing, clip 1 looping, clip 2 on the row
    let one = JournalState(
      sampleRate: rate,
      decks: [
        "A": DeckCheckpoint(source: demo, playing: true),
        "B": DeckCheckpoint(source: .net(spec), playing: true),
      ],
      clips: [
        ClipCheckpoint(id: clips[0].id, title: clips[0].title, looping: true),
        ClipCheckpoint(id: clips[1].id, title: clips[1].title),
      ])
    // two: swapped over, clips 2 and 3 looping, clip 1 removed
    let two = JournalState(
      sampleRate: rate,
      decks: [
        "A": DeckCheckpoint(source: .net(spec), playing: true),
        "B": DeckCheckpoint(source: demo, playing: true, leader: "A"),
      ],
      crossfader: 0.2,
      clips: [
        ClipCheckpoint(id: clips[1].id, title: clips[1].title, gain: 0.5, looping: true),
        ClipCheckpoint(id: clips[2].id, title: clips[2].title, muted: true, looping: true),
      ],
      removed: [(clips[0].id, 0)], locked: ["A.volume"])

    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true  // compiles inline, on this (main) thread
    try dj.start()
    defer { dj.stop() }
    let buffer = makeEngineRenderBuffer(dj, frames: 512)
    func service() {
      dj.serviceLoopTakes()
      for d in dj.allDecks { d.service() }
    }
    await dj.reset(to: one, clip: lookup)
    for _ in 0..<100 {  // warm up
      pullEngine(dj, buffer, cycles: 2, frames: 512)
      service()
    }

    var allocs = 0
    var frees = 0
    for round in 0..<12 {
      // the main side: the reset (outside the measured region)
      let warnings = await dj.reset(to: round % 2 == 0 ? two : one, clip: lookup)
      #expect(warnings.isEmpty, "\(warnings)")
      // ...then the render thread renders through the swap, fades and loads
      for _ in 0..<40 {
        let r = countAllocations { pullEngine(dj, buffer, cycles: 2, frames: 512) }
        allocs += r.allocations
        frees += r.frees
        service()
      }
    }
    #expect(allocs == 0, "the render path allocated \(allocs) times")
    #expect(frees == 0, "and freed \(frees) times")
    #expect(JournalState(engine: dj) == one, "the last reset stood")
  }
}
