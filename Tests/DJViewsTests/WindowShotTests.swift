import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The main window on a dark background, as the app shows it: deck A playing a composed song,
/// deck B the demo loop. `DJ_SHOT_DIR=… swift test --filter WindowShotTests` writes the PNGs
/// (offscreen, AppKit controls such as sliders and menus draw as placeholders).
///
/// Nothing persisted reaches the render: the decks' open sections (`fold.<deck>`, which
/// `@AppStorage` keeps in the test process's standard defaults across runs), the model's defaults,
/// and the favorites / loops / voices / notes stores are all scratch. With sections left open by
/// an earlier run the panels outgrew the 1020 pt window, `ContentView` took its ScrollView, which
/// `ImageRenderer` draws as nothing, and every probe column came back dark (card bottoms 0).
@MainActor
struct WindowShotTests {
  @Test func theWindowInTheDark() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true  // deck B's waveform is computed inline by loadDemo, not waited for
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.wave.setTempo(300)
    dj["A"]!.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    for _ in 0..<40 { _ = try renderOffline(dj, frames: 4096) }
    #expect(dj["B"]!.waveform != nil)
    let m = AppModel(
      engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary(),
      voices: temporaryVoiceVariations(), notes: temporaryNotes())
    m.defaults = scratchDefaults()
    m.start()
    m.poll()
    let view = ZStack {
      Color(white: 0.1)
      ContentView(model: m)
    }
    .environment(\.colorScheme, .dark)
    .defaultAppStorage(scratchDefaults())
    savePNG(view, width: 1100, height: 1020, name: "window-dark")
    let px = try #require(try renderPixels(view, width: 1100, height: 1020))
    // deck A, the mixer and deck B end on one row: the lowest card pixel (lighter than the
    // window's 0.1 grey) in a column through each card's middle is the same
    func bottom(_ x: Int) -> Int {
      var last = 0
      for y in 100..<920 {
        let c = px.color(x, y)
        if c.r + c.g + c.b > 3 * 31 { last = y }
      }
      return last
    }
    let edges = [297, 550, 803].map(bottom)
    #expect(edges.max()! - edges.min()! <= 2, "card bottoms \(edges)")
    #expect(
      edges.min()! > 700,
      "card bottoms \(edges): 0 is a column with no card, i.e. the panels scrolled")
  }
}
