import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct FeelRealTimeTests {
  /// `.feel` reads fixed arrays and holds hits back in the groove queue's fixed arrays: a song
  /// played with its family's template renders without allocating, across a tempo change
  /// (the swing is worked out per hit at the tempo playing).
  @Test(
    .enabled(if: optimized, "allocation is only meaningful in optimized builds"),
    arguments: ["lofi", "jazz", "techno"])
  func feelDoesNotAllocate(genre: String) {
    let sr = 48_000.0
    let o = WaveOptions.extended.forGenre(genre)
    #expect(o.feel != nil)
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
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
