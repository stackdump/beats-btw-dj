import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private let sr = 48_000.0

struct RestScheduleRealTimeTests {
  /// Rendering through overlapping rests, a stop back to the top and a swap to a project that
  /// starts mid-song (the cursor going back and seeking forward) allocates nothing.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func restsDoNotAllocate() {
    let p = restProject()
    var o = WaveOptions()
    o.musicality = [.dropGap]
    o.trackRests = RestSchedule(merging: [
      .init(from: 8, to: 24, mask: .kick), .init(from: 16, to: 40, mask: .bass),
      .init(from: 60, to: 64, mask: .rhythm), .init(from: 100, to: 120, mask: [.kick, .bass]),
    ])
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
    let late = WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: 56)
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      for _ in 0..<200 { r.process(b.baseAddress!, nil, frames: 128) }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        for _ in 0..<2000 { r.process(b.baseAddress!, nil, frames: 128) }
        r.stop()
        r.play()
        for _ in 0..<1000 { r.process(b.baseAddress!, nil, frames: 128) }
        r.load(prepared: late)
        for _ in 0..<2000 { r.process(b.baseAddress!, nil, frames: 128) }
      }
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
