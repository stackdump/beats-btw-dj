import Testing

@testable import DJCore

// The audio-thread contract for LOOP record: the capture taps on every deck's EQ (always on), the
// loop channel playing a clip, and a launch with no motor (`TurntableCommand.start`) allocate and
// free nothing on the render thread; nor do the loops' level ramps and fades (mute, solo, a
// level change, faded starts and stops, a fade-out brought back) or key lock's in-phase swap to a
// stretched copy and back. Release builds only (`make swift-rt-test`).
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
  func theCaptureTapsTheLoopChannelAndTheReverbDoNotAllocate() async throws {
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
    #expect(dj.loopState(clip.id) == .on)
    // reverb on deck A and on the loop channel (Apple's AUReverb2 on the render thread)
    a.reverb.wet = 0.3
    dj.loopChannel.reverb.wet = 0.4
    // a second take held while measuring (its draining is the main thread's, outside)
    #expect(dj.loopRecord("B", on: true))

    pullEngine(dj, buffer, cycles: 200, frames: 512)  // warm up
    var tally = Tally()
    let before = dj.frame
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 1000, frames: 512) })
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 30, frames: 4096) })
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 200, frames: 37) })
    // a loop out and back in (a load and a launch with no motor, applied on the render thread)
    dj.stopLoop(clip.id, now: true)
    pullEngine(dj, buffer, cycles: 4, frames: 512)
    dj.serviceLoopTakes()
    dj.startLoop(clip.id, atOnce: true)
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 100, frames: 512) })
    #expect(tally.allocs == 0, "the render path allocated \(tally.allocs) times")
    #expect(tally.frees == 0, "and freed \(tally.frees) times")

    // ...and all of it ran: every deck captured up to the render head, the loop channel is heard
    let ran = 1000 * 512 + 30 * 4096 + 200 * 37 + 4 * 512 + 100 * 512
    #expect(dj.frame == before + ran)
    for d in [a, dj["B"]!, dj.loopChannel] { #expect(d.capture.endFrame == d.renderedFrames) }
    var l: [Float] = []
    var r: [Float] = []
    let lc = dj.loopChannel
    _ = lc.capture.copy(from: lc.renderedFrames - 8192, to: lc.renderedFrames, left: &l, right: &r)
    #expect(l.count == 8192 && l.contains { abs($0) > 0.001 }, "the loop channel plays the clip")
    #expect(dj.loopState(clip.id) == .on)
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  @MainActor
  func loopFadesMuteSoloAndKeyLockSwapsDoNotAllocate() async throws {
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
    // two one-bar takes, looping
    pull(200)
    dj.loopRecord("A", on: true)
    pull(150)
    dj.loopRecord("A", on: false)
    pull(400)
    dj.loopRecord("A", on: true)
    pull(100)
    dj.loopRecord("A", on: false)
    pull(400)
    #expect(dj.clips.count == 2)
    let one = dj.clips[0].id
    let two = dj.clips[1].id
    #expect(dj.loopState(one) == .on && dj.loopState(two) == .on)
    dj.perform(.loopFade(mode: "bar"))
    pull(100)  // warm up

    // Only the render pulls are measured; the main thread's part (perform, serviceLoopTakes,
    // the stretch itself) runs between them.
    var tally = Tally()
    func measured(_ cycles: Int) {
      for _ in 0..<cycles {
        tally.add(countAllocations { pullEngine(dj, buffer, cycles: 1, frames: 512) })
        dj.serviceLoopTakes()
      }
    }
    dj.perform(.clipMute(id: one, on: true))
    measured(20)
    dj.perform(.clipSolo(id: two, on: true))
    measured(20)
    dj.perform(.clipGain(id: two, value: 0.3))
    measured(20)
    dj.perform(.clipSolo(id: two, on: false))
    dj.perform(.clipMute(id: one, on: false))
    measured(20)
    // out over a bar from the next downbeat, then in again over a bar
    dj.perform(.clipLoop(id: one, on: false))
    measured(420)
    #expect(dj.loopState(one) == .off)
    dj.perform(.clipLoop(id: one, on: true))
    measured(420)
    #expect(dj.loopState(one) == .on)
    // a fade-out brought back half way
    dj.perform(.clipLoop(id: two, on: false))
    for _ in 0..<420 where dj.loopState(two) == .stopping || dj.loopState(two) == .on {
      measured(1)
      if dj.loopState(two) == .stopping,
        let s = dj.loopVoices.first(where: { $0.clipID == two })?
          .stopFrame, dj.loopChannel.renderedFrames > s + 48_000
      {
        break
      }
    }
    dj.perform(.clipLoop(id: two, on: true))
    measured(40)
    #expect(dj.loopState(two) == .on)
    // key lock: the tempo moves, a stretched copy is made (inline, between pulls) and swapped
    // in on the render thread; then unlocked, swapped back
    dj.deterministic = true
    a.pitch = 0.5
    dj.perform(.loopKeyLock(on: true))
    measured(60)
    #expect(dj.isClipStretched(one) && dj.isClipStretched(two))
    dj.perform(.loopKeyLock(on: false))
    measured(20)
    #expect(!dj.isClipStretched(one))
    #expect(tally.allocs == 0, "the render path allocated \(tally.allocs) times")
    #expect(tally.frees == 0, "and freed \(tally.frees) times")
  }
}
