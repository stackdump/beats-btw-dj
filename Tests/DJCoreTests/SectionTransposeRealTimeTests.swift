import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private let sr = 48_000.0

struct SectionTransposeRealTimeTests {
  /// Playing into and through a moved section under `.sectionHarmony` — with swing holding
  /// notes back through the groove queue, a scratch back over the section edge, a stop and a
  /// swap to a project starting inside the section — allocates nothing.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func sectionTransposeDoesNotAllocate() throws {
    let song = try #require(BridgeSong.first)
    var played = song.played(.all)
    played.swing = 40
    played.humanize = 20
    let h = try #require(SectionHarmony(project: played))
    let k = try #require(h.degrees.firstIndex { $0 != 0 })
    var o = WaveOptions()
    o.musicality = [.sectionHarmony, .groove]
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(
      prepared: WaveRunner.prepare(
        played, sampleRate: sr, opts: o, startTick: max(0, h.start[k] - 16)))
    let inside = WaveRunner.prepare(played, sampleRate: sr, opts: o, startTick: h.start[k] + 8)
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      for _ in 0..<100 { r.process(b.baseAddress!, nil, frames: 128) }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        for _ in 0..<1500 { r.process(b.baseAddress!, nil, frames: 128) }
        r.freeze()
        r.scrub(ticks: -24)
        for _ in 0..<400 { r.process(b.baseAddress!, nil, frames: 128) }
        r.scrub(ticks: 24)
        for _ in 0..<400 { r.process(b.baseAddress!, nil, frames: 128) }
        r.release()
        for _ in 0..<500 { r.process(b.baseAddress!, nil, frames: 128) }
        r.stop()
        r.play()
        for _ in 0..<500 { r.process(b.baseAddress!, nil, frames: 128) }
        r.load(prepared: inside)
        for _ in 0..<1500 { r.process(b.baseAddress!, nil, frames: 128) }
      }
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }

  /// `.harmonicRhythm`'s tail slots (a buildup's last half-bar, the bar into the next section)
  /// and held bars are the same lookup: playing across a section end with swing allocates
  /// nothing.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func harmonicRhythmDoesNotAllocate() throws {
    let song = try #require(BridgeSong.first)
    var played = song.played(.all)
    played.swing = 40
    let fixes: DJMusicality.Fixes = [.sectionHarmony, .harmonicRhythm, .groove]
    let h = try #require(SectionHarmony(project: played, fixes: fixes))
    let k =
      try #require(
        h.tail.indices.first {
          $0 / SectionHarmony.tailSlots + 1 < h.start.count && h.tail[$0] != SectionHarmony.noTail
        }
      ) / SectionHarmony.tailSlots
    var o = WaveOptions()
    o.musicality = fixes
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(
      prepared: WaveRunner.prepare(
        played, sampleRate: sr, opts: o, startTick: max(0, h.start[k + 1] - 40)))
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      for _ in 0..<100 { r.process(b.baseAddress!, nil, frames: 128) }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        for _ in 0..<2000 { r.process(b.baseAddress!, nil, frames: 128) }
      }
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
