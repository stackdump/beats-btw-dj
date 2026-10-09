import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

/// The scope taps and the event ring live on the render path, so they get the same
/// measured contract as `WaveDeckSource`: zero malloc/free on the render thread, here
/// with every tap attached and a second thread draining them the whole time.
@MainActor
struct ScopeTapRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func renderWithTapsAttachedAndDrainedDoesNotAllocate() throws {
    let sr = 22_050.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    a.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, extra: JSONObject([("bpm", .number(600))])),
        sampleRate: sr))
    b.loadDemo()
    a.setPlaying(true)
    b.setPlaying(true)
    let feeds = ScopeFeed.feeds(for: dj)
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    func block() {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for d in [a, b] {
            Deck.renderBlock(
              wave: d.wave, turntable: d.turntable, tap: d.tap, frames: 128, left: lp.baseAddress!,
              right: rp.baseAddress!)
          }
          // what the master tap node does with the mix
          dj.masterTap.write(lp.baseAddress!, rp.baseAddress!, frames: 128)
        }
      }
    }
    for _ in 0..<200 { block() }  // warm-up
    let report = countRenderWhileDraining(feed: feeds["A"]!) {
      for _ in 0..<4000 { block() }
    }
    #expect(a.wave.tick > 100, "the net must cross many ticks (fires pushed to the ring)")
    #expect(a.tap.framesWritten == 4200 * 128 && dj.masterTap.framesWritten == 4200 * 128)
    #expect(report.allocations == 0, "render path allocated \(report.allocations) times")
    #expect(report.frees == 0, "render path freed \(report.frees) times")
    // and the drain really saw it
    feeds["A"]!.update(now: 1e6)
    #expect(feeds["A"]!.events.count > 100)
  }
}
