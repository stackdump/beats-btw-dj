import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private let sr = 48_000.0

struct MixOutRealTimeTests {
  /// Rendering into a mix-out tail, past the song's ignored stop-transport, through the stop on
  /// the tail's bar line, playing again from the top, and a swap to a project that starts
  /// inside the tail allocates nothing.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func mixOutTailDoesNotAllocate() {
    let p = tailProject()
    let o = tailOptions(MixOutTail(fromTick: 64, bars: 8), fixes: [.space])
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
    let late = WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: 160)
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      for _ in 0..<200 { r.process(b.baseAddress!, nil, frames: 128) }
    }
    var stoppedOnce = false
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        // 192 ticks at 600 BPM is about 3600 blocks: through the song's end and the tail's
        for _ in 0..<5000 {
          r.process(b.baseAddress!, nil, frames: 128)
          if r.stopped { stoppedOnce = true }
        }
        r.play()
        for _ in 0..<1000 { r.process(b.baseAddress!, nil, frames: 128) }
        r.load(prepared: late)
        for _ in 0..<2000 { r.process(b.baseAddress!, nil, frames: 128) }
      }
    }
    #expect(stoppedOnce, "the tail stopped the deck")
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
