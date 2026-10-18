import Darwin
import Synchronization
import Testing

@testable import DJCore

// The occasional RT frees under a parallel run (`switchingTheTapOnAndOff…`,
// `voiceTweaksDoNotAllocate`: a few dozen mallocs and frees in a region that is otherwise
// clean) looked like the AUParameterCache trap: another AVAudioEngine connecting its mixers
// while a deck's samplers play. `samplersDoNotAllocateWhenAnotherEngineIsBuilt` builds that
// engine between measurements; these build engines on another thread *during* them, the way
// a parallel test run (or the app's `SessionPlayer`) does, and keep the first offending stacks
// (`countAllocations(stacks:)`) so a failure says where it came from.
//
// What the stacks showed (2026-10-18): with the parameter cache built at load
// (`SamplerInstrument.buildParameterCache`) the render thread no longer *allocates*, but it can
// still *free*: AUSampler reports a parameter change on every note-on, from its render, which
// walks AudioToolbox's process-wide listener map (`ListenerMap::NotifyParameterChange`, a caulk
// lock-free skiplist). Nodes another thread removes from that map while a walk is in flight
// (an AVAudioEngine and its units being torn down) are freed by whichever walker leaves last —
// sometimes the render thread (`node_allocator::end_traversal` → `free_node`): one to a few
// dozen frees per teardown, no mallocs. That is CoreAudio's, not ours, and the app meets it
// too when an offline engine is torn down while a deck plays. So these tests hold the render
// to no allocations at all, and to no frees but that reclamation; `make swift-rt-test` runs
// the allocation-counting suites one at a time (`--no-parallel`) so other tests' teardowns
// stay out of their measurements.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private func project(_ genre: String, _ seed: Double, _ structure: String) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

private final class Builder: Sendable {
  let go = Atomic<Bool>(false)
  let built = Atomic<Int>(0)
  let done = Atomic<Bool>(false)
  let failed = Atomic<Bool>(false)
}

/// Builds `count` offline engines, one after another, on a new pthread once `go` is set (each
/// connects mixers in this process, then is torn down there).
private func startBuilding(
  _ b: Builder, count: Int, sampleRate: Double, samplers: Bool = false
) -> pthread_t {
  let box = Unmanaged.passRetained(BuilderBody(b, count, sampleRate, samplers: samplers))
    .toOpaque()
  var thread: pthread_t?
  let err = pthread_create(
    &thread, nil,
    { ctx in
      let body = Unmanaged<BuilderBody>.fromOpaque(ctx).takeRetainedValue()
      body.run()
      return nil
    }, box)
  precondition(err == 0 && thread != nil, "pthread_create failed: \(err)")
  return thread!
}

private final class BuilderBody: Sendable {
  let b: Builder
  let count: Int
  let sampleRate: Double
  let samplers: Bool
  init(_ b: Builder, _ count: Int, _ sampleRate: Double, samplers: Bool) {
    self.b = b
    self.count = count
    self.sampleRate = sampleRate
    self.samplers = samplers
  }
  func run() {
    while !b.go.load(ordering: .acquiring) { sched_yield() }
    for i in 0..<count {
      do {
        if samplers {
          // as a bank loads one (`SamplerBank.slot(for:)`), then lets it go
          let inst = try SamplerInstrument.lifecycle.withLock {
            try SamplerInstrument(source: .gm(i % 100), sampleRate: sampleRate)
          }
          _ = inst.source
        } else {
          let dj = try DJEngine(decks: ["X", "Y"], offline: true, sampleRate: sampleRate)
          _ = dj["X"]
        }
      } catch {
        b.failed.store(true, ordering: .releasing)
      }
      b.built.add(1, ordering: .releasing)
    }
    b.done.store(true, ordering: .releasing)
  }
}

/// Renders `src` in `frames`-sized blocks on this thread until the builder is done (or a
/// deadline passes), plus `tail` blocks, measured. clock_gettime_nsec_np reads the clock
/// without allocating.
private func renderWhileBuilding(
  _ src: WaveDeckSource, _ b: Builder, frames: Int = 512, tail: Int = 200,
  between: (Int) -> Void = { _ in }
) -> (report: AllocationReport, blocks: Int) {
  var l = [Float](repeating: 0, count: frames)
  var r = [Float](repeating: 0, count: frames)
  var blocks = 0
  let report = l.withUnsafeMutableBufferPointer { lp in
    r.withUnsafeMutableBufferPointer { rp in
      countAllocations(stacks: true) {
        b.go.store(true, ordering: .releasing)
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 120 * 1_000_000_000
        while !b.done.load(ordering: .acquiring)
          && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline
        {
          between(blocks)
          src.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
          blocks += 1
        }
        for _ in 0..<tail {
          between(blocks)
          src.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
          blocks += 1
        }
      }
    }
  }
  return (report, blocks)
}

/// Frees that are AudioToolbox reclaiming its listener map's nodes (see the top of this file),
/// as opposed to anything the render path itself frees. Judged by the stacks kept, so it needs
/// `countAllocations(stacks: true)`.
private func onlyListenerMapReclamation(_ r: AllocationReport) -> Bool {
  r.frees == 0
    || (!r.stacks.isEmpty
      && r.stacks.allSatisfy {
        $0.contains("free") && $0.contains("ListenerMap") && $0.contains("end_traversal")
      })
}

private func warm(_ src: WaveDeckSource, _ n: Int, frames: Int = 512) {
  var l = [Float](repeating: 0, count: frames)
  var r = [Float](repeating: 0, count: frames)
  l.withUnsafeMutableBufferPointer { lp in
    r.withUnsafeMutableBufferPointer { rp in
      for _ in 0..<n { src.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!) }
    }
  }
}

@Suite(.serialized) struct SamplerConcurrentEngineRealTimeTests {
  /// A sampled deck plays while engines are built and torn down on another thread.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aSampledDeckDoesNotAllocateWhileEnginesAreBuiltConcurrently() {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    let prepared = WaveRunner.prepare(
      project("country", 7, "minimal"), sampleRate: sr, opts: .extended(samplers: src.samplers))
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 }, "a sampled lane to measure")
    src.load(prepared)
    src.setTempo(480)
    src.play()
    warm(src, 200)  // every sampled lane has struck notes
    let b = Builder()
    let thread = startBuilding(b, count: 4, sampleRate: sr)
    let (report, blocks) = renderWhileBuilding(src, b)
    let built = b.built.load(ordering: .acquiring)
    if b.done.load(ordering: .acquiring) {
      pthread_join(thread, nil)
    } else {
      pthread_detach(thread)
    }
    #expect(built == 4, "every engine was built inside the measured renders (\(built))")
    let failed = b.failed.load(ordering: .acquiring)
    #expect(!failed, "the engines built")
    #expect(blocks > 200)
    #expect(
      report.allocations == 0, "render allocated \(report.allocations) times\(report.stackText)")
    #expect(
      onlyListenerMapReclamation(report),
      "render freed \(report.frees) times\(report.stackText)")
    src.drainRetired()
  }

  /// The sound panel's voice tweaks (as `voiceTweaksDoNotAllocate`), with engines being built
  /// concurrently: a sampled channel switched to its synth voice and back while it plays.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func voiceTweaksDoNotAllocateWhileEnginesAreBuiltConcurrently() {
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
    let full = VoiceTweak(
      gainDB: 6, attack: 0.03, decayScale: 2, maxDecay: 2, lowpass: 1500, distortion: 0.5,
      vibratoRate: 5, vibratoDepth: 0.01, pitchFrom: 4, pitchTo: 1, pitchTime: 0.1)
    // made here, off the measured region (they are what `setVoice` sends)
    var cmds: [WaveCommand] = []
    for ch in tonal.sorted() {
      let v = prepared.channelVoice(ch)?.voice
      cmds.append(
        .voice(VoiceLaneParams(channel: ch, tweak: full, useSynth: false, voice: v, sampleRate: sr))
      )
      cmds.append(
        .voice(
          VoiceLaneParams(
            channel: ch, tweak: VoiceTweak(), useSynth: false, voice: nil, sampleRate: sr)))
    }
    if let ch = sampled {
      cmds.append(
        .voice(
          VoiceLaneParams(channel: ch, tweak: full, useSynth: true, voice: nil, sampleRate: sr)))
      cmds.append(
        .voice(
          VoiceLaneParams(
            channel: ch, tweak: VoiceTweak(), useSynth: false, voice: nil, sampleRate: sr)))
    }
    warm(src, 100)
    let b = Builder()
    let thread = startBuilding(b, count: 4, sampleRate: sr)
    // a command every 20 blocks, round and round, while the engines build
    let (report, _) = renderWhileBuilding(src, b) { i in
      if i % 20 == 0 { src.send(cmds[(i / 20) % cmds.count]) }
    }
    let built = b.built.load(ordering: .acquiring)
    if b.done.load(ordering: .acquiring) {
      pthread_join(thread, nil)
    } else {
      pthread_detach(thread)
    }
    #expect(built == 4, "every engine was built inside the measured renders (\(built))")
    #expect(
      report.allocations == 0, "render allocated \(report.allocations) times\(report.stackText)")
    #expect(
      onlyListenerMapReclamation(report),
      "render freed \(report.frees) times\(report.stackText)")
  }

  /// Samplers loaded and torn down on another thread while a sampled deck plays (the
  /// Instruments panel, an eviction, a second deck's track).
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aSampledDeckDoesNotFreeWhileSamplersLoadConcurrently() {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    let prepared = WaveRunner.prepare(
      project("country", 7, "minimal"), sampleRate: sr, opts: .extended(samplers: src.samplers))
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 }, "a sampled lane to measure")
    src.load(prepared)
    src.setTempo(480)
    src.play()
    warm(src, 200)
    let b = Builder()
    let thread = startBuilding(b, count: 40, sampleRate: sr, samplers: true)
    let (report, _) = renderWhileBuilding(src, b)
    let built = b.built.load(ordering: .acquiring)
    if b.done.load(ordering: .acquiring) {
      pthread_join(thread, nil)
    } else {
      pthread_detach(thread)
    }
    #expect(built == 40, "every sampler was loaded inside the measured renders (\(built))")
    #expect(
      report.allocations == 0, "render allocated \(report.allocations) times\(report.stackText)")
    #expect(
      onlyListenerMapReclamation(report),
      "render freed \(report.frees) times\(report.stackText)")
    src.drainRetired()
  }
}
