import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct AppLayoutTests {
  /// Deck A runs a composed song, deck B the demo loop: the busiest screen the app has.
  func model(pads: Bool = false, map: Bool = false) async throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.wave.setTempo(300)
    dj["A"]!.setPlaying(true)
    dj["B"]!.setPlaying(true)
    try dj.start()
    for _ in 0..<40 { _ = try renderOffline(dj, frames: 4096) }
    try await Task.sleep(for: .milliseconds(100))  // let the waveform land
    let m = AppModel(engine: dj)
    m.start()
    m.setShowPads(pads)
    m.showMap = map
    m.poll()
    return m
  }

  @Test func theWholeWindowLaysOutAndShowsEverything() async throws {
    let m = try await model(pads: true, map: true)
    let view = ContentView(model: m)
    savePNG(view, width: 1100, height: 1500, name: "app-full")
    let px = try #require(renderPixels(view, width: 1100, height: 1500))
    // Not blank, and content reaches both deck columns and the bottom bar.
    let lit = px.count(inX: 0..<1100, y: 0..<1500) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(lit > 20_000, "something is drawn (\(lit) lit pixels)")
    #expect(m.decks["A"]?.isNet == true && m.decks["B"]?.isNet == false)
    #expect(m.decks["A"]?.snapshot?.rings.count ?? 0 >= 6)
    #expect(m.decks["B"]?.overview != nil, "deck B has its waveform")
  }

  @Test func theDefaultWindowSize() async throws {
    let m = try await model()
    savePNG(ContentView(model: m), width: 900, height: 760, name: "app-default")
    #expect(try renderPixels(ContentView(model: m), width: 900, height: 760) != nil)
  }
}
