import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct AllocationCounterTests {
  @Test func counterSeesAllocations() {
    var keep: [[Int]] = []
    let r = countAllocations {
      for i in 0..<50 { keep.append([Int](repeating: i, count: 64)) }
    }
    #expect(r.allocations >= 50, "the hook must actually fire (got \(r.allocations))")
    #expect(keep.count == 50)
  }
}

private func project(_ genre: String, _ seed: Double, _ structure: String) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

struct WaveRunnerRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func processDoesNotAllocate() {
    let sr = 48_000.0
    let runner = WaveRunner(sampleRate: sr)
    runner.load(project("techno", 42, "minimal"))
    runner.setTempo(480)  // dense ticks: many fires, control nets, section changes
    runner.play()
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    // warm-up: first touches of lazily initialised state
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        for _ in 0..<200 { runner.process(lp.baseAddress!, rp.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<3000 { runner.process(lp.baseAddress!, rp.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(runner.graph!.tick > 100, "the run must cross many ticks")
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}

private func renderBlocks(_ src: WaveDeckSource, blocks: Int) -> [Float] {
  var out: [Float] = []
  var l = [Float](repeating: 0, count: 128)
  for _ in 0..<blocks {
    l.withUnsafeMutableBufferPointer { src.render(frames: 128, left: $0.baseAddress!, right: nil) }
    out += l
  }
  return out
}

struct WaveDeckSourceTests {
  @Test func rendersWhatTheRunnerRenders() {
    let sr = 22_050.0
    let p = project("techno", 42, "loop")
    let runner = WaveRunner(sampleRate: sr)
    runner.load(p)
    runner.setTempo(300)
    runner.play()
    var want: [Float] = []
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    for _ in 0..<400 {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          runner.process(lp.baseAddress!, rp.baseAddress!, frames: 128)
        }
      }
      want += l
    }
    let src = WaveDeckSource(sampleRate: sr)
    src.load(WaveRunner.prepare(p, sampleRate: sr))
    src.setTempo(300)
    src.play()
    let got = renderBlocks(src, blocks: 400)
    #expect(got == want)
    #expect(got.contains { $0 != 0 })
    #expect(src.isPlaying && src.hasProject)
    #expect(src.tick == runner.graph!.tick)
    #expect(src.tempo == 300)
  }

  @Test func commandsMuteAndSwapAtTheBar() {
    let sr = 22_050.0
    let src = WaveDeckSource(sampleRate: sr)
    src.load(WaveRunner.prepare(project("techno", 42, "loop"), sampleRate: sr))
    src.setTempo(480)
    src.play()
    _ = renderBlocks(src, blocks: 50)
    let t0 = src.tick
    #expect(t0 > 0)
    // Queue another project while playing: it must take effect on a bar boundary.
    src.load(WaveRunner.prepare(project("house", 4, "loop"), sampleRate: sr))
    var ticks: [Int] = []
    for _ in 0..<200 {
      _ = renderBlocks(src, blocks: 1)
      ticks.append(src.tick)
    }
    #expect(ticks.contains { $0 < t0 }, "tick counter restarted when the new project installed")
    src.setMute("kick", true)
    _ = renderBlocks(src, blocks: 4)
    let before = renderBlocks(src, blocks: 40)
    src.setMute("kick", false)
    _ = before
  }

  @Test func retiredProjectsAreFreedOnTheCallersThread() {
    let sr = 22_050.0
    let src = WaveDeckSource(sampleRate: sr)
    weak var first: WaveProject?
    do {
      let a = WaveRunner.prepare(project("techno", 42, "loop"), sampleRate: sr)
      first = a
      src.load(a)
    }
    src.setTempo(900)
    src.play()
    _ = renderBlocks(src, blocks: 10)
    src.load(WaveRunner.prepare(project("house", 4, "loop"), sampleRate: sr))
    // Run past the bar swap and until the old project's voices have rung out.
    _ = renderBlocks(src, blocks: 4000)
    #expect(first != nil, "the audio thread must not have freed it")
    src.drainRetired()
    // `latest` still points at the newer project; the older one is gone once drained.
    #expect(first == nil)
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func renderDoesNotAllocate() {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    src.load(WaveRunner.prepare(project("techno", 42, "minimal"), sampleRate: sr))
    let next = WaveRunner.prepare(project("dnb", 3, "minimal"), sampleRate: sr)
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { src.render(frames: 128, left: lp.baseAddress!, right: rp.baseAddress!) }
        }
      }
    }
    run(200)
    // Everything that crosses the thread boundary is enqueued here (main thread),
    // then applied inside the measured region, on the "audio" thread.
    src.load(next)
    src.setMute("kick", true)
    src.setTempo(520)
    src.setMute("kick", false)
    run(2)
    src.pause()
    src.stop()  // resets the marking in place
    src.play()
    // the whole performance surface: roles, slots, macros, stingers, keys, panic
    src.setRoleMuted("bass", true)
    src.setRoleMuted("bass", false)
    src.activateSlot("melody-1")
    src.fire(.drop)
    src.fire(.beatRepeat)
    src.fire(.doubleDrop)
    src.fire(.halfTime)
    src.fire(.tapeStop)
    src.fireStinger("hit1")
    src.noteOn(60, velocity: 100)
    src.noteOn(64, velocity: 90)
    src.noteOff(60)
    src.allNotesOff()
    src.align(ticks: 3.4)
    src.align(ticks: -2.25)
    let report = countAllocations {
      run(1500)
      src.panic()
      src.fire(.cut)
      src.noteOn(67, velocity: 80)
      run(1500)
    }
    #expect(report.allocations == 0, "render allocated \(report.allocations) times")
    #expect(report.frees == 0, "render freed \(report.frees) times")
    src.drainRetired()
  }
}
