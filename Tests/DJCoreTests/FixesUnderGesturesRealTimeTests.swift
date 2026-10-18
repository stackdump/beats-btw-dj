import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

// ROADMAP 6.7: the gestures of FixesUnderGesturesTests on the render thread of an app deck
// (sampled instruments, room, echo, duck, energy, the brake), measured in release builds.

struct FixesUnderGesturesRealTimeTests {
  /// Role mutes, net macros (drop, breakdown, tape stop), a master sweep on the energy curve, a
  /// hand on the platter, a stop under the brake (`WaveRunner.silence`) and a dry song between
  /// two echo songs (the lines run empty): no allocation, no free.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func gesturesDoNotAllocate() {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr, opts: .extended(samplers: nil))
    let echoOpts = WaveOptions.extended(samplers: src.samplers, seed: 7).forGenre("trance")
    let dryOpts = WaveOptions.extended(samplers: src.samplers, seed: 7).forGenre("techno")
    let trance = TrackSpec(genre: "trance", seed: 7, structure: "standard").project()
    let techno = TrackSpec(genre: "techno", seed: 7, structure: "minimal").project()
    let first = WaveRunner.prepare(trance, sampleRate: sr, opts: echoOpts)
    src.load(first)
    src.setTempo(480)
    src.play()
    let roles = Set(first.lanes.map(\.netId)).filter { !$0.isEmpty }.sorted()
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
    for role in roles.prefix(4) { src.setRoleMuted(role, true) }
    measure(60)
    for role in roles.prefix(4) { src.setRoleMuted(role, false) }
    measure(20)
    src.fire(.drop, ticks: 16)
    measure(40)
    src.fire(.breakdown, ticks: 16)
    src.fire(.sweepLp, bars: 1)
    measure(80)
    src.fire(.tapeStop, ticks: 16)
    measure(80)
    src.freeze()
    measure(20)
    src.scrub(ticks: -6)
    measure(20)
    src.scrub(ticks: 10)
    measure(20)
    src.release()
    measure(20)
    src.fire(.vinylBrake)
    measure(60)  // a bar at 480 BPM is 0.5 s: into the stopped quarter
    src.stop()
    measure(20)
    src.play()
    measure(20)
    src.stop()
    src.load(WaveRunner.prepare(techno, sampleRate: sr, opts: dryOpts))  // installed when stopped
    src.play()
    measure(200)  // the echo and shimmer lines run empty
    src.stop()
    src.load(WaveRunner.prepare(trance, sampleRate: sr, opts: echoOpts))
    src.play()
    measure(100)
    #expect(allocs == 0, "render allocated \(allocs) times")
    #expect(frees == 0, "render freed \(frees) times")
    src.drainRetired()
  }
}
