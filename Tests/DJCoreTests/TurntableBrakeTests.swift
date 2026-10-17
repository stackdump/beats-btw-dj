import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

// dj's vinyl-brake (TurntableBrake.swift): on a project prepared with `turntableBrake` the deck's
// whole output spins down — pitch and tempo falling with the rate — stops, and drops back in on
// the beat a deck that never braked is on. The parity path (`WaveOptions()`) keeps beats'
// octave-down compound.

private let rate = 22_050.0
private let block = 128

private func project(_ genre: String, _ seed: Double, _ structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

/// A source playing `p` at `tempo`, prepared for the turntable brake (or not: parity).
private func source(
  _ p: Project, tempo: Double = 120, brake: Bool = true, silentNets: Bool = false
) -> WaveDeckSource {
  let src = WaveDeckSource(sampleRate: rate)
  var o = WaveOptions()
  o.turntableBrake = brake
  if silentNets { o.roleFilter = RoleFilter(solo: []) }  // the nets run, no notes
  src.load(WaveRunner.prepare(p, sampleRate: rate, opts: o))
  src.setTempo(tempo)
  src.play()
  return src
}

/// Render `srcs` side by side, `blocks` blocks of 128; `at(b)` runs before block `b`, `after(b)`
/// after it. Returns each source's left channel.
private func render(
  _ srcs: [WaveDeckSource], blocks: Int, at: (Int) -> Void = { _ in },
  after: (Int) -> Void = { _ in }
) -> [[Float]] {
  var outs = [[Float]](repeating: [], count: srcs.count)
  var l = [Float](repeating: 0, count: block)
  var r = [Float](repeating: 0, count: block)
  for b in 0..<blocks {
    at(b)
    for (i, src) in srcs.enumerated() {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          src.render(frames: block, left: lp.baseAddress!, right: rp.baseAddress!)
        }
      }
      outs[i] += l
    }
    after(b)
  }
  return outs
}

/// Upward zero crossings per frame over `x[range]` (first to last crossing, interpolated).
private func crossingRate(_ x: [Float], _ range: Range<Int>) -> Double {
  var first = -1.0
  var last = -1.0
  var count = 0
  for i in (range.lowerBound + 1)..<range.upperBound where x[i - 1] < 0 && x[i] >= 0 {
    let t = Double(i - 1) + Double(-x[i - 1]) / Double(x[i] - x[i - 1])
    if first < 0 { first = t }
    last = t
    count += 1
  }
  return count > 1 ? Double(count - 1) / (last - first) : 0
}

/// The source's net position in ticks.
private func position(_ src: WaveDeckSource) -> Double { Double(src.tick) + src.tickPhase }

private func maxStep(_ x: [Float], _ range: Range<Int>) -> Float {
  var m: Float = 0
  for i in (range.lowerBound + 1)..<range.upperBound { m = max(m, abs(x[i] - x[i - 1])) }
  return m
}

struct TurntableBrakeTests {
  /// One bar at 120 BPM: 2 s; three quarters of it spinning down.
  let barFrames = Int(rate * 2)
  var stopFrames: Double { Double(barFrames) * TurntableBrake.spinDown }
  let fireBlock = 40

  @Test func pitchAndTempoFallWithTheRate() {
    // a held live note over silent nets: the pitch, and the net clock, fall as r(t) = 1 − t/T
    let p = project("techno", 42)
    let src = source(p, silentNets: true)
    let ref = source(p, silentNets: true)
    let fire = fireBlock * block
    var posAt: [Int: Double] = [:]
    var refAt: [Int: Double] = [:]
    let marks = [0.1, 0.5, 0.9].map { fire + Int($0 * stopFrames) }
    let out = render(
      [src, ref], blocks: fireBlock + barFrames / block + 20,
      at: { b in
        if b == 2 {
          src.noteOn(84, velocity: 110)
          ref.noteOn(84, velocity: 110)
        }
        if b == fireBlock { src.fire(.vinylBrake) }
      },
      after: { b in
        for m in marks where m / block == b {
          posAt[m] = position(src)
          refAt[m] = position(ref)
        }
      })
    let f0 = crossingRate(out[1], (fire - 4000)..<fire)
    #expect(f0 > 0)
    let w = 1500
    for frac in [0.1, 0.5, 0.9] {
      let c = fire + Int(frac * stopFrames)
      let f = crossingRate(out[0], (c - w / 2)..<(c + w / 2))
      let want = 1 - frac
      #expect(abs(f / f0 - want) < 0.01, "pitch at \(frac): \(f / f0) of f0, r = \(want)")
    }
    // the clock: braked ticks since the fire = ∫ r dt (in ticks), the reference's = t
    let spt = rate * 60 / (120 * 4)
    for (i, frac) in [0.1, 0.5, 0.9].enumerated() {
      let m = marks[i]
      let t = Double((m / block + 1) * block - fire)  // frames from the fire to that block's end
      let ran = t - t * t / (2 * stopFrames)  // ∫0^t (1 − s/T) ds
      let lead = refAt[m]! - posAt[m]!  // how far the braked clock is behind
      #expect(abs(lead - (t - ran) / spt) < 0.01, "clock at \(frac): \(lead) ticks behind")
    }
    // the tick rate between 10 % and 50 %, and 50 % and 90 %: mean r over each span
    let a = posAt[marks[1]]! - posAt[marks[0]]!
    let b = refAt[marks[1]]! - refAt[marks[0]]!
    #expect(abs(a / b - 0.7) < 0.01, "ticks ran at \(a / b) of the tempo, mean r 0.7")
    let c = posAt[marks[2]]! - posAt[marks[1]]!
    let d = refAt[marks[2]]! - refAt[marks[1]]!
    #expect(abs(c / d - 0.3) < 0.01, "ticks ran at \(c / d) of the tempo, mean r 0.3")
  }

  @Test func silentWhenStoppedAndBackInTime() {
    let p = project("techno", 42, "minimal")
    let src = source(p)
    let ref = source(p)
    let fire = fireBlock * block
    let release = fire + barFrames
    var stoppedTick = -1
    var activeWhileStopped = false
    let out = render(
      [src, ref], blocks: release / block + 400,
      at: { b in if b == fireBlock { src.fire(.vinylBrake) } },
      after: { b in
        if b == (fire + Int(stopFrames)) / block + 2 {
          stoppedTick = src.tick
          activeWhileStopped = src.isActive(.vinylBrake)
        }
        if b == release / block - 2 {
          #expect(src.tick == stoppedTick, "the clock stands still while the record is stopped")
        }
      })
    #expect(activeWhileStopped, "vinyl-brake stays in activeMasterMacros while braking")
    // nothing before the fire changes
    #expect(out[0][..<fire] == out[1][..<fire])
    // the stop: exact silence from r = 0 to the release
    let silent = (fire + Int(stopFrames.rounded(.up)))..<release
    #expect(out[0][silent].allSatisfy { $0 == 0 }, "silent while stopped")
    #expect(out[0][(fire + 100)..<(fire + 2000)].contains { $0 != 0 }, "spinning down plays")
    // in time: the same tick and phase as the deck that never braked
    #expect(src.tick == ref.tick)
    #expect(src.tick % 16 == ref.tick % 16)
    #expect(abs(src.tickPhase - ref.tickPhase) < 1e-6, "\(src.tickPhase) vs \(ref.tickPhase)")
    #expect(!src.isActive(.vinylBrake))
    #expect(src.activeMasterMacros.isEmpty)
    // no click: the steps into and out of the brake are no bigger than the music's own
    let music = maxStep(out[1], fire..<out[1].count)
    #expect(maxStep(out[0], (fire - 50)..<(fire + 500)) <= music * 1.05)
    #expect(maxStep(out[0], (release - 50)..<(release + 500)) <= music * 1.05)
    // and the fade-in starts from silence
    #expect(abs(out[0][release]) < 0.01)
  }

  @Test func twoBarsTakeTwiceAsLong() {
    let p = project("techno", 42)
    let src = source(p)
    let ref = source(p)
    let fire = fireBlock * block
    var halfway = false
    _ = render(
      [src, ref], blocks: fireBlock + 2 * barFrames / block + 50,
      at: { b in if b == fireBlock { src.fire(.vinylBrake, bars: 2) } },
      after: { b in
        if b == (fire + barFrames) / block { halfway = src.isActive(.vinylBrake) }
      })
    #expect(halfway)
    #expect(!src.isActive(.vinylBrake))
    #expect(src.tick == ref.tick && abs(src.tickPhase - ref.tickPhase) < 1e-6)
  }

  @Test func panicReleasesAtOnceInTime() {
    let p = project("techno", 42, "minimal")
    let src = source(p)
    let ref = source(p)
    let panicBlock = fireBlock + 100
    let fade = Int((0.005 * rate).rounded())
    var activeAfter = true
    let out = render(
      [src, ref], blocks: panicBlock + 300,
      at: { b in
        if b == fireBlock { src.fire(.vinylBrake) }
        if b == panicBlock { src.panic() }
      },
      after: { b in
        if b == panicBlock + (fade + block - 1) / block { activeAfter = src.isActive(.vinylBrake) }
      })
    #expect(!activeAfter, "released within 5 ms (and the block it ends in)")
    #expect(src.tick == ref.tick && abs(src.tickPhase - ref.tickPhase) < 1e-6)
    let music = maxStep(out[1], 0..<out[1].count)
    let at = panicBlock * block
    #expect(maxStep(out[0], (at - 50)..<(at + 2 * fade + 200)) <= music * 1.05, "no click")
  }

  @Test func stopCancelsAndTheNextBrakeStartsAfresh() {
    let src = source(project("techno", 42))
    _ = render(
      [src], blocks: 200,
      at: { b in
        if b == 10 { src.fire(.vinylBrake) }
        if b == 60 { src.stop() }
        if b == 70 { src.play() }
        if b == 80 { src.fire(.vinylBrake) }
      })
    #expect(src.isActive(.vinylBrake), "a brake fired after a stop runs")
  }

  @Test func theParityPathIsBeatsCompound() {
    // `WaveOptions()` (what the fixtures run): an octave-down hold, the clock keeps time
    let p = project("techno", 42)
    let src = source(p, brake: false)
    let ref = source(p, brake: false)
    var during = 0.0
    let out = render(
      [src, ref], blocks: fireBlock + barFrames / block + 100,
      at: { b in if b == fireBlock { src.fire(.vinylBrake) } },
      after: { b in
        if b == fireBlock + 60 { during = position(ref) - position(src) }
      })
    #expect(during == 0, "no varispeed: the net clock keeps the tempo")
    #expect(out[0][(fireBlock * block + 2000)...] != out[1][(fireBlock * block + 2000)...])
    #expect(src.activeMasterMacros.isEmpty)
  }

  @Test func sessionsReplayTheBrakeToTheByte() {
    func once() -> [Float] {
      let src = source(project("dnb", 3, "minimal"), tempo: 174)
      return render(
        [src], blocks: 900,
        at: { b in
          switch b {
          case 20: src.fire(.vinylBrake)
          case 25: src.fire(.sweepLp, bars: 1)
          case 300: src.fire(.vinylBrake, bars: 2)
          case 420: src.panic()
          case 500: src.fire(.vinylBrake)
          default: break
          }
        })[0]
    }
    let a = once()
    #expect(a == once())
    #expect(a.allSatisfy { $0.isFinite })
  }

}

// Measured on the render thread (`make swift-rt-test`, release builds).
struct TurntableBrakeRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func turntableBrakeDoesNotAllocate() {
    // the app's path: the brake fired mid-render on an extended project with samplers, re-fired,
    // a panic mid-spin, a stop mid-brake, a full brake played through its release, big blocks
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    let p = TrackSpec(genre: "country", seed: 7, structure: "minimal").project()
    src.load(WaveRunner.prepare(p, sampleRate: sr, opts: .extended(samplers: src.samplers)))
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 4096)
    var r = [Float](repeating: 0, count: 4096)
    func run(_ n: Int, frames: Int = 256) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n {
            src.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
          }
        }
      }
    }
    run(300)
    var allocs = 0
    var frees = 0
    func measure(_ n: Int, frames: Int = 256) {
      let rep = countAllocations { run(n, frames: frames) }
      allocs += rep.allocations
      frees += rep.frees
    }
    src.fire(.vinylBrake)
    measure(40)
    #expect(src.isActive(.vinylBrake), "the app's options brake")
    src.fire(.vinylBrake)  // while braking
    measure(40)
    src.panic()
    measure(20)
    src.fire(.vinylBrake, bars: 2)
    src.fire(.sweepLp, bars: 2)
    measure(400)  // 2 bars at 480 BPM = 1 s: through the stop and the release
    src.fire(.vinylBrake)
    measure(10, frames: 4096)  // blocks bigger than a braked chunk
    src.stop()
    src.play()
    measure(50)
    src.fire(.vinylBrake)
    src.freeze()
    src.scrub(ticks: 3)
    measure(20)
    src.release()
    measure(20)
    #expect(allocs == 0, "render allocated \(allocs) times")
    #expect(frees == 0, "render freed \(frees) times")
    src.drainRetired()
  }
}
