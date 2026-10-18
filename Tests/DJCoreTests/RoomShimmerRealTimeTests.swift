import Testing

@testable import DJCore

// ROADMAP 6.6: the pad shimmer runs on the audio thread inside the room's send; its delay line
// is allocated at init, so a song with it running renders without allocating.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private let sr = 48_000.0

struct RoomShimmerRealTimeTests {
  /// A whole song (trance: a pad, dance family's shimmer level) with the room and the shimmer
  /// running, in stereo, then a second track installed (`tune` on the audio thread).
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theShimmerDoesNotAllocate() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: sr)
    let next = PreparedTrack(
      spec: TrackSpec(genre: "ambient", seed: 7, structure: "minimal"), sampleRate: sr)
    let r = WaveRunner(sampleRate: sr, opts: .extended)
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
    #expect((track.prepared.space?.shimmer ?? 0) > 0)
    #expect(track.prepared.lanes.contains { $0.shimmerSend > 0 })
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
    r.load(prepared: next.prepared)
    let swap = countAllocations {
      l.withUnsafeMutableBufferPointer { lb in
        rr.withUnsafeMutableBufferPointer { rb in
          for _ in 0..<3000 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(swap.allocations == 0, "process allocated \(swap.allocations) times after a swap")
  }
}
