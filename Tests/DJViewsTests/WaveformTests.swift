import DJCore
import SwiftUI
import Testing

@testable import DJViews

private func buffer(_ f: (Int) -> Float, n: Int = 4000) -> SampleBuffer {
  SampleBuffer(left: (0..<n).map(f), sampleRate: 1000)
}

@MainActor
struct WaveformStripRenderTests {
  func overview() -> WaveformOverview {
    // loud first half, quiet second half
    WaveformOverview(buffer: buffer({ $0 < 2000 ? 0.9 : 0.2 }), columns: 200)
  }

  @Test func drawsPeaksPlayheadAndTheTintSplit() throws {
    let tint = Color(red: 1, green: 0.5, blue: 0)  // 255,128,0
    let overlay = WaveformOverlay(
      playhead: 0.25, loop: nil, loopActive: false, cues: [:], barLines: [])
    savePNG(
      WaveformStrip(overview: overview(), overlay: overlay, tint: tint), width: 400, height: 80,
      name: "waveform-peaks")
    let px = try #require(
      renderPixels(
        WaveformStrip(overview: overview(), overlay: overlay, tint: tint), width: 400, height: 80))
    // loud half reaches near the top & bottom edges at the centre line, quiet half does not
    #expect(px.near(60, 30, (255, 128, 0), tol: 30), "played region is the tint colour")
    let loudTop = px.count(inX: 20..<30, y: 4..<12) { r, _, _ in r > 100 }
    let quietTop = px.count(inX: 310..<320, y: 4..<12) { r, _, _ in r > 100 }
    #expect(loudTop > 20, "loud region fills toward the top (\(loudTop))")
    #expect(quietTop == 0, "quiet region leaves the top dark")
    // playhead: a white line at x = 0.25 * 400 = 100
    #expect(px.near(100, 5, (255, 255, 255), tol: 30) || px.near(99, 5, (255, 255, 255), tol: 30))
    // played (left of the playhead) is brighter than unplayed at the same height
    let played = px.color(60, 30)
    let unplayed = px.color(140, 30)
    #expect(played.r > unplayed.r + 40, "played \(played) vs unplayed \(unplayed)")
  }

  @Test func drawsLoopCuesAndBarLines() throws {
    let overlay = WaveformOverlay(
      playhead: 0.9, loop: 0.5...0.75, loopActive: true, cues: [0: 0.1], barLines: [0.3])
    let px = try #require(
      renderPixels(
        WaveformStrip(overview: nil, overlay: overlay, tint: .green), width: 400, height: 60))
    // no audio: only the overlays. loop region tinted green between x=200..300, dark outside
    #expect(px.color(250, 30).g > px.color(150, 30).g + 20)
    #expect(px.color(150, 30).g < 40)
    // cue: yellow line at x=40
    let cue = px.color(40, 30)
    #expect(cue.r > 200 && cue.g > 200 && cue.b < 80, "\(cue)")
    // bar line: faint at x=120 (brighter than neighbours)
    #expect(px.color(120, 30).r > px.color(110, 30).r + 15)
  }

  @Test func anEmptyStripStillRenders() throws {
    let px = try #require(
      renderPixels(WaveformStrip(overview: nil, overlay: nil, tint: .red), width: 100, height: 30))
    #expect(px.color(50, 15).a > 0)
  }
}
