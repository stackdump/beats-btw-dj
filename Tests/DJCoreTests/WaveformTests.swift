import Testing

@testable import DJCore

private func buffer(_ f: (Int) -> Float, n: Int = 4000) -> SampleBuffer {
  SampleBuffer(left: (0..<n).map(f), sampleRate: 1000)
}

struct WaveformModelTests {
  @Test func peaksOfKnownSignals() {
    // 4 columns over 4000 samples: loud, silent, quiet-negative, loud-both-signs
    let b = buffer { i in
      switch i / 1000 {
      case 0: return 0.8
      case 1: return 0
      case 2: return -0.3
      default: return i % 2 == 0 ? 1 : -1
      }
    }
    let w = WaveformOverview(buffer: b, columns: 4)
    #expect(w.columns == 4 && w.peaks.count == 8)
    #expect(w.peak(0) == (0.8, 0.8))
    #expect(w.peak(1) == (0, 0))
    #expect(w.peak(2) == (-0.3, -0.3))
    #expect(w.peak(3) == (-1, 1))
  }

  @Test func stereoIsMixedToMono() {
    let b = SampleBuffer(
      left: [Float](repeating: 1, count: 100), right: [Float](repeating: -1, count: 100),
      sampleRate: 1000)
    #expect(WaveformOverview(buffer: b, columns: 2).peak(0) == (0, 0))
  }

  @Test func moreColumnsThanSamplesStillCoversTheTrack() {
    let b = buffer({ Float($0) / 10 }, n: 10)
    let w = WaveformOverview(buffer: b, columns: 40)
    #expect(w.peaks.count == 80)
    #expect(w.peak(39).max == 0.9)
    #expect((0..<40).allSatisfy { w.peak($0).min <= w.peak($0).max })
  }

  @Test func windowsZoomIntoTheSamples() {
    let b = buffer { Float($0 % 1000) / 1000 }
    let win = WaveformOverview.window(buffer: b, start: 1000, end: 2000, columns: 2)
    #expect(win[0] == 0 && abs(win[1] - 0.499) < 1e-6)
    #expect(abs(win[3] - 0.999) < 1e-6)
    // out of range clamps instead of crashing
    let edge = WaveformOverview.window(buffer: b, start: -500, end: 99_999, columns: 4)
    #expect(edge.count == 8)
    #expect(
      WaveformOverview.window(buffer: b, start: 10, end: 10, columns: 3)
        == [Float](repeating: 0, count: 6))
  }
}

@MainActor
struct DeckOverlayTests {
  @Test func overlayPlacesPlayheadBarsCuesAndLoop() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    let a = try #require(dj["A"])
    #expect(a.waveformOverlay == nil)
    a.loadDemo()  // 8 beats at 120 bpm: two bars, offset 0
    let w = try #require(a.waveform)
    #expect(w.columns == 1200 && w.length == a.loaded!.length)
    try dj.start()
    defer { dj.stop() }
    a.turntable.send(.seek(sample: Double(a.loaded!.length) * 0.25))
    _ = try renderOffline(dj, frames: 128)
    a.hotCue(1)
    a.loopIn()
    a.turntable.send(.seek(sample: Double(a.loaded!.length) * 0.75))
    _ = try renderOffline(dj, frames: 128)
    a.loopOut()
    let o = try #require(a.waveformOverlay)
    #expect(abs(o.playhead - 0.75) < 1e-3)
    #expect(o.barLines == [0, 0.5])
    #expect(abs(o.cues[1]! - 0.25) < 1e-3)
    #expect(
      o.loop.map { abs($0.lowerBound - 0.25) < 1e-3 && abs($0.upperBound - 0.75) < 1e-3 } == true)
    #expect(o.loopActive)
  }

  @Test func netDecksHaveNoWaveform() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    a.loadNet(PreparedTrack(spec: TrackSpec(genre: "techno", seed: 1), sampleRate: 22_050))
    #expect(a.waveformOverlay == nil)
  }
}
