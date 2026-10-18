import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct SweepRealTimeTests {
  /// `.sweep` reads the energy curve and writes the voices' fixed per-voice arrays at note-on:
  /// a song played through its buildup and into the drop renders without allocating, live keys
  /// struck in the buildup included.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func sweepDoesNotAllocate() throws {
    let spec = TrackSpec(genre: "trance", seed: 42, structure: "minimal")
    let p = DJMusicality.apply(spec.project(), spec: spec)
    let c = try #require(EnergyCurve(project: p))
    let b = try #require(c.ramp.firstIndex(of: true))
    let o = WaveOptions.extended
    #expect(o.musicality.contains(.sweep))
    let r = WaveRunner(sampleRate: 48_000, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: 48_000, opts: o))
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    var rr = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      rr.withUnsafeMutableBufferPointer { c in
        for _ in 0..<50 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { lb in
        rr.withUnsafeMutableBufferPointer { rb in
          for i in 0..<4000 {
            if i % 200 == 0 { r.noteOn(60 + i / 200 % 12, velocity: 100) }
            if i % 200 == 100 { r.noteOff(60 + i / 200 % 12) }
            r.process(lb.baseAddress!, rb.baseAddress!, frames: 128)
          }
        }
      }
    }
    #expect(r.stopped || r.graph!.tick > c.start[b + 1], "crossed the buildup")
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
