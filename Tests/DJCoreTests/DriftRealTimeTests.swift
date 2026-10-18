import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct DriftRealTimeTests {
  /// `.drift` hashes its noise per hit (no tables, no state) and holds hits back in the groove
  /// queue's fixed arrays: a song played with it, on top of `.feel` and without, renders
  /// without allocating, across a tempo change.
  @Test(
    .enabled(if: optimized, "allocation is only meaningful in optimized builds"),
    arguments: ["lofi", "house", "funk"])
  func driftDoesNotAllocate(genre: String) {
    let sr = 48_000.0
    for withFeel in [true, false] {
      var o = WaveOptions.extended.forGenre(genre)
      o.voicingSeed = 42
      if !withFeel { o.musicality.remove(.feel) }
      #expect(o.musicality.contains(.drift))
      let r = WaveRunner(sampleRate: sr, opts: o)
      r.load(TrackSpec(genre: genre, seed: 42, structure: "minimal").project())
      r.setTempo(480)
      r.play()
      var l = [Float](repeating: 0, count: 128)
      l.withUnsafeMutableBufferPointer { b in
        for _ in 0..<200 { r.process(b.baseAddress!, nil, frames: 128) }
      }
      let report = countAllocations {
        l.withUnsafeMutableBufferPointer { b in
          for i in 0..<3000 {
            if i == 1500 { r.setTempo(300) }
            r.process(b.baseAddress!, nil, frames: 128)
          }
        }
      }
      #expect(r.graph!.tick > 100)
      #expect(
        report.allocations == 0, "\(genre) feel \(withFeel): \(report.allocations) allocations")
    }
  }
}
