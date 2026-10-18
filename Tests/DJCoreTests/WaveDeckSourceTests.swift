import Darwin
import Synchronization
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

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func pluckedStringsDoNotAllocate() {
    let sr = 48_000.0
    let runner = WaveRunner(sampleRate: sr, opts: .extended)
    // country plays guitars; check this seed really got a string before trusting the result
    let prepared = WaveRunner.prepare(
      project("country", 7, "minimal"), sampleRate: sr, opts: .extended)
    #expect(prepared.lanes.contains { $0.isPluck }, "a plucked lane to measure")
    runner.load(prepared: prepared)
    runner.setTempo(480)
    runner.play()
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { runner.process(lp.baseAddress!, rp.baseAddress!, frames: 128) }
        }
      }
    }
    run(200)
    let report = countAllocations {
      run(3000)
      runner.noteOn(52, velocity: 100)  // live keys strike a string too
      runner.noteOn(40, velocity: 90)
      run(200)
      runner.allNotesOff()
      run(100)
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func sampledInstrumentsDoNotAllocate() {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    // country plays sampled guitars and bass; check this seed really got one
    let prepared = WaveRunner.prepare(
      project("country", 7, "minimal"), sampleRate: sr, opts: .extended(samplers: src.samplers))
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 }, "a sampled lane to measure")
    src.load(prepared)
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { src.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) }
        }
      }
    }
    run(100)
    let report = countAllocations {
      run(1000)
      // the master chain after the samplers (they render inside the runner's block)
      src.fire(.phaserDrone)
      src.fire(.octaveDown)
      src.fire(.buildCrush)
      run(400)
      src.noteOn(52, velocity: 100)
      run(50)
      src.allNotesOff()
      src.panic()
      run(50)
    }
    #expect(report.allocations == 0, "render allocated \(report.allocations) times")
    #expect(report.frees == 0, "render freed \(report.frees) times")

    // Eviction while rendering: fill the bank with unreferenced GM programs (each renders
    // every block), then load one more on another thread while this one renders. The
    // evicted AUSampler is freed on the loading thread; render stays allocation-free.
    let bank = src.samplers
    let used = Set(prepared.lanes.map(\.samplerSlot).filter { $0 >= 0 })
    var p = 0
    while bank.count < SamplerBank.capacity && p < 64 {
      if let s = bank.slot(for: [.gm(p)]) { bank.release(s) }
      p += 1
    }
    #expect(bank.count == SamplerBank.capacity, "a full bank")
    let result = EvictionResult()
    // A dedicated thread, started here (creating one allocates), loading only once the
    // measured renders run: a detached Task may not get a cooperative thread under a loaded
    // parallel run, and the GM load can take a while, so the wait is a deadline, not a count.
    let loader = startThread {
      while !result.go.load(ordering: .acquiring) { sched_yield() }
      // a pitched program the fill didn't reach (unpitched SFX ones are turned away on load)
      result.slot.store(bank.slot(for: [.gm(80)]) ?? -1, ordering: .releasing)
    }
    run(10)
    let evicting = countAllocations {
      result.go.store(true, ordering: .releasing)
      // clock_gettime_nsec_np reads the clock without allocating (Date() would not do here)
      let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 120 * 1_000_000_000
      while result.slot.load(ordering: .acquiring) == -2
        && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline
      {
        run(1)
      }
      run(200)
    }
    pthread_join(loader, nil)
    let slot = result.slot.load(ordering: .acquiring)
    #expect(slot >= 0, "the load evicted a slot")
    #expect(!used.contains(slot), "never one the playing project references")
    #expect(bank.source(of: slot) == .gm(80))
    #expect(evicting.allocations == 0, "render allocated \(evicting.allocations) times")
    #expect(evicting.frees == 0, "render freed \(evicting.frees) times")
    if slot >= 0 { bank.release(slot) }
    src.drainRetired()
  }

  /// A deck plays sampled lanes while another engine is built in the same process (the app's
  /// `SessionPlayer` renders a set offline while the decks play; in a parallel test run, other
  /// tests build theirs). Connecting that engine's mixers used to make every sampler already
  /// loaded build its AudioToolbox parameter cache on its next note-on, on the render thread:
  /// 54 mallocs and 50 frees each (see `SamplerInstrument.buildParameterCache`).
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func samplersDoNotAllocateWhenAnotherEngineIsBuilt() throws {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    let prepared = WaveRunner.prepare(
      project("country", 7, "minimal"), sampleRate: sr, opts: .extended(samplers: src.samplers))
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 }, "a sampled lane to measure")
    src.load(prepared)
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { src.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) }
        }
      }
    }
    run(200)  // warm up, and every sampled lane has struck notes
    var engines: [DJEngine] = []
    for _ in 0..<2 {
      engines.append(try DJEngine(decks: ["X"], offline: true, sampleRate: sr))
      let report = countAllocations { run(400) }
      #expect(report.allocations == 0, "render allocated \(report.allocations) times")
      #expect(report.frees == 0, "render freed \(report.frees) times")
    }
    #expect(engines.count == 2)
    src.drainRetired()
  }
}

private final class EvictionResult: Sendable {
  /// -2 while loading; then the slot, or -1 for none.
  let slot = Atomic<Int>(-2)
  let go = Atomic<Bool>(false)
}

/// Runs `body` on a new pthread (Foundation's `Thread` can't be imported next to Testing).
private func startThread(_ body: @escaping @Sendable () -> Void) -> pthread_t {
  let box = Unmanaged.passRetained(ThreadBody(body)).toOpaque()
  var thread: pthread_t?
  let err = pthread_create(
    &thread, nil,
    { ctx in
      let body = Unmanaged<ThreadBody>.fromOpaque(ctx).takeRetainedValue()
      body.run()
      return nil
    }, box)
  precondition(err == 0 && thread != nil, "pthread_create failed: \(err)")
  return thread!
}

private final class ThreadBody: Sendable {
  let run: @Sendable () -> Void
  init(_ run: @escaping @Sendable () -> Void) { self.run = run }
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
    // Sends run on this thread, so they stay outside the measured regions (a send also
    // drains the retire ring, i.e. frees a swapped-out project — main-thread work).
    var allocs = 0
    var frees = 0
    func measure(_ blocks: Int) {
      let r = countAllocations { run(blocks) }
      allocs += r.allocations
      frees += r.frees
    }
    measure(1500)
    src.panic()
    src.fire(.cut)
    src.noteOn(67, velocity: 80)
    measure(1000)
    // scratch: freeze, forward over ticks, back over them (un-firing), let go
    src.freeze()
    src.scrub(ticks: 9)
    measure(150)
    src.scrub(ticks: -14)
    measure(150)
    src.release()
    measure(200)
    // the master chain: every master macro (overlapping, so every slider and the feel tempo
    // move at once), re-fires mid-flight, a panic mid-ramp, permanent fires, hand moves, and
    // the full durations played out (8 bars at 520 BPM ≈ 3.7 s ≈ 1400 blocks)
    for m in MasterMacro.allCases { src.fire(m) }
    measure(300)
    src.fire(.sweepLp, bars: 8)
    src.fire(.phaserDrone, bars: 8)
    src.fire(.octaveUp, bars: 4)
    src.fire(.feelBuild, bars: 8)
    measure(37)
    src.fire(.sweepLp, bars: 8)  // re-fire: keeps the first start
    src.fire(.buildCrush, bars: 8)
    src.fire(.vinylBrake)
    measure(250)
    src.panic()
    measure(5)
    for m in [MasterMacro.filterRes, .pitchBend, .feelEuphoric, .riser, .reverbWash] {
      src.fire(m, bars: 0)
    }
    src.setMasterFx(.crushBits, 100)
    src.setMasterFx(.distortion, 100)
    src.setMasterFx(.masterPitch, -12)
    measure(400)
    src.fire(.feelReset, bars: 16)
    src.fire(.sweepHp, bars: 8)
    src.fire(.phaserDrone, bars: 8)
    measure(1500)
    src.stop()
    src.play()
    measure(100)
    #expect(allocs == 0, "render allocated \(allocs) times")
    #expect(frees == 0, "render freed \(frees) times")
    src.drainRetired()
  }
}

extension WaveDeckSourceTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func voiceTweaksDoNotAllocate() {
    // the sound panel while the song plays: every parameter, a pitch sweep switched on (a saw
    // takes up its band-limited tables), Reset, and a sampled channel to its synth voice and back
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    let p = TrackSpec(genre: "country", seed: 7, structure: "minimal").project()
    let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: .extended(samplers: src.samplers))
    src.load(prepared)
    src.setTempo(480)
    src.play()
    let tonal = Set(prepared.lanes.filter { $0.isTonal && $0.channel >= 0 }.map(\.channel))
    let sampled = prepared.lanes.first { $0.sampledSlot >= 0 && $0.channel >= 0 }?.channel
    #expect(!tonal.isEmpty && sampled != nil, "tonal and sampled channels to tweak")
    // made on the main thread (they are what `setVoice` sends)
    let full = VoiceTweak(
      gainDB: 6, attack: 0.03, decayScale: 2, maxDecay: 2, lowpass: 1500, distortion: 0.5,
      vibratoRate: 5, vibratoDepth: 0.01, pitchFrom: 4, pitchTo: 1, pitchTime: 0.1)
    var cmds: [WaveCommand] = []
    for ch in tonal.sorted() {
      let v = prepared.channelVoice(ch)?.voice
      cmds.append(
        .voice(VoiceLaneParams(channel: ch, tweak: full, useSynth: false, voice: v, sampleRate: sr))
      )
      cmds.append(
        .voice(
          VoiceLaneParams(
            channel: ch, tweak: VoiceTweak(lowpass: 0, pitchTime: 0), useSynth: false, voice: v,
            sampleRate: sr)))
    }
    var synth: [WaveCommand] = []
    if let ch = sampled {
      synth.append(
        .voice(
          VoiceLaneParams(channel: ch, tweak: full, useSynth: true, voice: nil, sampleRate: sr)))
      synth.append(
        .voice(
          VoiceLaneParams(
            channel: ch, tweak: VoiceTweak(), useSynth: false, voice: nil, sampleRate: sr)
        ))
    }
    let reset = tonal.sorted().map {
      WaveCommand.voice(
        VoiceLaneParams(
          channel: $0, tweak: VoiceTweak(), useSynth: false, voice: nil, sampleRate: sr))
    }
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { src.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) }
        }
      }
    }
    run(100)
    let report = countAllocations {
      for c in cmds {
        src.send(c)
        run(20)
      }
      for c in synth {
        src.send(c)
        run(200)
      }
      for c in reset { src.send(c) }
      run(200)
    }
    #expect(report.allocations == 0, "render allocated \(report.allocations) times")
    #expect(report.frees == 0, "render freed \(report.frees) times")
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func laserSweepsDoNotAllocate() {
    let sr = 48_000.0
    let runner = WaveRunner(sampleRate: sr, opts: .extended)
    // a song whose melody is a laser (synth voice: no sampler bank here)
    var p = project("trance", 7, "minimal")
    var lasers = 0
    for id in p.nets.keys where p.nets[id]!.track.group == "melody" {
      p.nets[id]!.track.instrument = "laser"
      lasers += 1
    }
    let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: .extended)
    #expect(lasers > 0 && prepared.lanes.contains { $0.pmOn }, "a swept lane to measure")
    runner.load(prepared: prepared)
    runner.setTempo(480)
    runner.play()
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { runner.process(lp.baseAddress!, rp.baseAddress!, frames: 128) }
        }
      }
    }
    run(200)
    let report = countAllocations { run(3000) }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
