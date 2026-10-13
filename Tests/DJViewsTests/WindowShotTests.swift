import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The main window on a dark background, as the app shows it: deck A playing a composed song,
/// deck B the demo loop. `DJ_SHOT_DIR=… swift test --filter WindowShotTests` writes the PNGs
/// (offscreen, AppKit controls such as sliders and menus draw as placeholders).
@MainActor
struct WindowShotTests {
  @Test func theWindowInTheDark() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.wave.setTempo(300)
    dj["A"]!.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    for _ in 0..<40 { _ = try renderOffline(dj, frames: 4096) }
    for _ in 0..<200 where dj["B"]!.waveform == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let m = AppModel(engine: dj)
    m.start()
    m.poll()
    let view = ZStack {
      Color(white: 0.1)
      ContentView(model: m)
    }.environment(\.colorScheme, .dark)
    savePNG(view, width: 1100, height: 980, name: "window-dark")
    #expect(try renderPixels(view, width: 1100, height: 980) != nil)
  }
}
