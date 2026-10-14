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
    // let the waveform land: it is computed in the background, so wait for it (a fixed sleep
    // lost the race under a loaded machine)
    for _ in 0..<200 where dj["B"]!.waveform == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
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
    // 1600: a net deck with its section strip and Perform open, plus pads and the map, is ~1540
    // tall; any shorter and the window scrolls, which `ImageRenderer` draws blank.
    savePNG(view, width: 1100, height: 1600, name: "app-full")
    let px = try #require(renderPixels(view, width: 1100, height: 1600))
    // Not blank, and content reaches both deck columns and the bottom bar.
    let lit = px.count(inX: 0..<1100, y: 0..<1600) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(lit > 20_000, "something is drawn (\(lit) lit pixels)")
    #expect(m.decks["A"]?.isNet == true && m.decks["B"]?.isNet == false)
    #expect(m.decks["A"]?.snapshot?.rings.count ?? 0 >= 6)
    #expect(m.decks["B"]?.overview != nil, "deck B has its waveform")
  }

  /// Net deck + Scopes is taller than a laptop screen. The decks and the panel scroll; the bottom
  /// bar (Scopes, Stage, Record, status) stays on screen at the window's foot instead of being
  /// pushed off its bottom edge.
  @Test func aShortWindowWithScopesKeepsTheBottomBarOnScreen() async throws {
    let m = try await model()
    m.showScopes = true
    let view = ContentView(model: m)
    savePNG(view, width: 1100, height: 620, name: "app-short-scopes")
    let px = try #require(renderPixels(view, width: 1100, height: 620))
    // Before, the window's foot was the middle of the scope panel (its dark background) and the
    // bar was below the edge. Offscreen, the bar's buttons are yellow placeholders.
    let foot = 540..<620
    let scope = px.count(inX: 0..<1100, y: foot) { r, g, b in r < 40 && g < 40 && b < 60 }
    let buttons = px.count(inX: 0..<1100, y: foot) { r, g, b in r > 200 && g > 160 && b < 80 }
    #expect(scope < 3_000, "no scope panel under the bottom bar (\(scope) pixels)")
    #expect(buttons > 2_000, "the bottom bar is drawn at the window's foot (\(buttons) pixels)")
  }

  @Test func theDefaultWindowSize() async throws {
    let m = try await model()
    savePNG(ContentView(model: m), width: 900, height: 760, name: "app-default")
    #expect(try renderPixels(ContentView(model: m), width: 900, height: 760) != nil)
  }
}
