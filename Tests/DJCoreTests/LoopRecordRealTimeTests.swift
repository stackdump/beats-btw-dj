import Testing

@testable import DJCore

// The audio-thread contract for LOOP record: the capture taps on every deck's EQ (always on), the
// loop channel playing a clip, and a launch with no motor (`TurntableCommand.start`) allocate and
// free nothing on the render thread. Release builds only (`make swift-rt-test`).
//
// NAME COUPLING: the Makefile's real-time run selects suites by 'RealTime': keep it in the name.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private struct Tally {
  var allocs = 0
  var frees = 0
  mutating func add(_ r: AllocationReport) {
    allocs += r.allocations
    frees += r.frees
  }
}

struct LoopRecordRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func theCaptureTapsAndTheLoopChannelDoNotAllocate() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let a = try #require(dj["A"])
    await a.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    a.setPlaying(true)
    dj["B"]!.loadDemo()
    dj["B"]!.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    func pull(_ cycles: Int, _ frames: Int) {
      for _ in 0..<cycles {
        pullEngine(dj, buffer, cycles: 1, frames: frames)
        dj.serviceLoopTakes()
      }
    }
    // a one-bar take, looping on the loop channel
    pull(200, 512)
    #expect(dj.loopRecord("A", on: true))
    pull(150, 512)
    dj.loopRecord("A", on: false)
    pull(400, 512)
    let clip = try #require(dj.clips.first)
    #expect(dj.loopChannel.playing && dj.loopChannel.clipID == clip.id)
    // a second take held while measuring (its draining is the main thread's, outside)
    #expect(dj.loopRecord("B", on: true))

    pullEngine(dj, buffer, cycles: 200, frames: 512)  // warm up
    var tally = Tally()
    let before = dj.frame
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 1000, frames: 512) })
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 30, frames: 4096) })
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 200, frames: 37) })
    // a launch with no motor, applied on the render thread
    dj.playClip(clip.id, on: "L")
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 100, frames: 512) })
    #expect(tally.allocs == 0, "the render path allocated \(tally.allocs) times")
    #expect(tally.frees == 0, "and freed \(tally.frees) times")

    // ...and all of it ran: every deck captured up to the render head, the loop channel is heard
    let ran = 1000 * 512 + 30 * 4096 + 200 * 37 + 100 * 512
    #expect(dj.frame == before + ran)
    for d in [a, dj["B"]!, dj.loopChannel] { #expect(d.capture.endFrame == d.renderedFrames) }
    var l: [Float] = []
    var r: [Float] = []
    let lc = dj.loopChannel
    _ = lc.capture.copy(from: lc.renderedFrames - 8192, to: lc.renderedFrames, left: &l, right: &r)
    #expect(l.count == 8192 && l.contains { abs($0) > 0.001 }, "the loop channel plays the clip")
  }
}
