import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private let sr = 48_000.0

struct RiserRealTimeTests {
  /// Rendering through riser windows (wide, into the room), a stop back to the top, a pause
  /// and a swap to a project that starts inside a window allocates nothing.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func riserDoesNotAllocate() {
    var p = restProject()
    p.structure = [
      Section(name: "buildup", steps: 64), Section(name: "drop", steps: 32),
      Section(name: "buildup", steps: 32), Section(name: "chorus", steps: 64),
    ]
    var o = WaveOptions()
    o.musicality = [.riser, .stereo, .space, .dropGap]
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
    let late = WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: 40)
    #expect(late.riser != nil)
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    var rr = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      rr.withUnsafeMutableBufferPointer { c in
        for _ in 0..<200 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        rr.withUnsafeMutableBufferPointer { c in
          for _ in 0..<2000 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
          r.stop()
          r.play()
          for _ in 0..<500 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
          r.pause()
          for _ in 0..<50 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
          r.play()
          r.load(prepared: late)
          for _ in 0..<2000 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
