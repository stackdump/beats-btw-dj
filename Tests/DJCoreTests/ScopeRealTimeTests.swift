@preconcurrency import AVFoundation
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

  /// The whole engine, not just the tap: two decks playing through the real AVAudioEngine
  /// graph (EQ, strips, main mixer, master tap) rendered with `renderOffline`, the malloc
  /// counter armed on the rendering thread, a second thread draining the master tap.
  /// Hosting a custom AUAudioUnit in the master path cost one malloc/free pair per cycle.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func realEngineMasterTapRenderDoesNotAllocate() throws {
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
    try dj.start()
    let out = try #require(AVAudioPCMBuffer(pcmFormat: dj.format, frameCapacity: 512))
    func cycle() { _ = try? dj.engine.renderOffline(512, to: out) }
    for _ in 0..<50 { cycle() }  // warm-up
    let before = dj.masterTap.framesWritten
    let feed = ScopeFeed.feeds(for: dj)["master"]!
    let report = countRenderWhileDraining(feed: feed) {
      for _ in 0..<500 { cycle() }
    }
    #expect(report.allocations == 0, "render path allocated \(report.allocations) times")
    #expect(report.frees == 0, "render path freed \(report.frees) times")
    #expect(dj.masterTap.framesWritten - before >= 500 * 512 - 512, "the master tap must fill")
    #expect(dj.masterTap.recent(2048).contains { abs($0) > 1e-4 }, "and carry audio")
    dj.stop()
  }
}
