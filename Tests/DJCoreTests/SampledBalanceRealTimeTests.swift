import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private let sr = 48_000.0

/// `.balance` on sampled parts renders each slot with a gain through the scratch pair, with its
/// duck and room send: none of it allocates on the render thread.
struct SampledBalanceRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func slotGainsDoNotAllocate() throws {
    try measure { p in
      try #require(p.gainSlots != 0, "a sampled slot with a gain to measure")
    }
  }

  /// `.stereo`'s per-slot widths and side highpasses (`WaveProject.slotWidth`) on the same path.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func slotWidthsDoNotAllocate() throws {
    try measure { p in
      try #require(p.widthSlots != 0, "a sampled slot with a width to measure")
    }
  }

  private func measure(_ check: (WaveProject) throws -> Void) throws {
    let src = WaveDeckSource(sampleRate: sr)
    let spec = TrackSpec(genre: "country", seed: 7, structure: "minimal")
    let track = PreparedTrack(
      spec: spec, sampleRate: sr, opts: .extended(samplers: src.samplers, seed: spec.seed))
    let p = track.prepared
    try check(p)
    src.load(p)
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    func run(_ n: Int, frames: Int = 512) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n {
            src.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
          }
        }
      }
    }
    run(100)
    let report = countAllocations {
      run(1000)
      run(200, frames: 128)  // other block sizes through the same scratch
      src.noteOn(52, velocity: 100)
      run(50)
      src.allNotesOff()
      run(50)
    }
    #expect(report.allocations == 0, "render allocated \(report.allocations) times")
    #expect(report.frees == 0, "render freed \(report.frees) times")
  }
}
