import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct SubOctaveRealTimeTests {
  /// The sub-octave's phases are allocated at prepare: a dnb song with it renders without
  /// allocating, stereo.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func subOctaveDoesNotAllocate() {
    let sr = 48_000.0
    let track = PreparedTrack(
      spec: TrackSpec(genre: "dnb", seed: 42, structure: "minimal"), sampleRate: sr)
    let r = WaveRunner(sampleRate: sr, opts: track.opts)
    r.load(prepared: track.prepared)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    var rr = l
    l.withUnsafeMutableBufferPointer { lb in
      rr.withUnsafeMutableBufferPointer { rb in
        for _ in 0..<200 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { lb in
        rr.withUnsafeMutableBufferPointer { rb in
          for _ in 0..<3000 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(track.prepared.lanes.contains { !$0.subPhase.isEmpty })
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
