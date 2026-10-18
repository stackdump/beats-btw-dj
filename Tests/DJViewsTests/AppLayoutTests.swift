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

  /// A wide window gives each deck a column for its sections on the outer side, so the window's
  /// outer columns carry controls (deck B is a sample deck here: its strip is Favorites, Generate,
  /// Load); a narrow window stacks them under the core.
  @Test func aWideWindowUsesItsWidth() async throws {
    let m = try await model()
    let view = ContentView(model: m)
    savePNG(view, width: 1600, height: 1100, name: "app-wide")
    let px = try #require(renderPixels(view, width: 1600, height: 1100))
    let lit: (Range<Int>) -> Int = { xs in
      px.count(inX: xs, y: 0..<900) { r, g, b in r > 60 || g > 60 || b > 60 }
    }
    #expect(lit(0..<250) > 2_000, "deck A's sections column is at the left edge")
    #expect(lit(1180..<1400) > 2_000, "deck B's sections column is right of its core")
  }

  /// At 1400 pt (the wide layout's threshold is ~1380) deck B's column reaches well right of
  /// where fixed 260 + 160 + 260 pt decks, centred, would have ended, and the deck cores widen
  /// past their 260 pt floor.
  @Test func a1400WindowUsesItsRightSide() async throws {
    let m = try await model()
    let view = ContentView(model: m)
    savePNG(view, width: 1400, height: 1100, name: "app-1400")
    let px = try #require(renderPixels(view, width: 1400, height: 1100))
    let right = px.count(inX: 1000..<1400, y: 0..<900) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(right > 2_000, "the right of a 1400 pt window is used (\(right) lit pixels)")
    // the row fits: both cards' accent lines (orange, cyan) stay inside the window's 16 pt
    // padding. A row wider than the window ran off both edges (a flexible mixer took its maximum
    // before the decks their minimum).
    let top = 0..<40
    let leftEdge = px.count(inX: 0..<12, y: top) { r, g, b in r > 60 || g > 60 || b > 60 }
    let rightEdge = px.count(inX: 1388..<1400, y: top) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(leftEdge == 0 && rightEdge == 0, "inside the padding: \(leftEdge) \(rightEdge)")
    // deck B's card ends near the window's padding: its accent line is drawn out there
    let line = px.count(inX: 1250..<1386, y: top) { r, g, b in r > 60 || g > 60 || b > 60 }
    #expect(line > 100, "deck B's card reaches the right (\(line) lit pixels)")
  }

  /// With Map and Pads on, the map takes the row beside the pad grid: it spans the width the
  /// pads leave rather than a fixed strip on the left.
  @Test func theMapSharesARowWithThePads() async throws {
    let m = try await model(pads: true, map: true)
    let view = ContentView(model: m)
    savePNG(view, width: 1400, height: 1700, name: "app-map-pads")
    let px = try #require(renderPixels(view, width: 1400, height: 1700))
    // the lower row sits under the decks (~y 720…1020): lit pixels across its whole width
    let lower: (Range<Int>) -> Int = { xs in
      px.count(inX: xs, y: 700..<1050) { r, g, b in r > 60 || g > 60 || b > 60 }
    }
    #expect(lower(0..<300) > 500, "the map's left part")
    #expect(lower(600..<1000) > 500, "the map reaches across to the pads (\(lower(600..<1000)))")
    #expect(lower(1100..<1380) > 2_000, "the pad grid sits to its right")
  }

  /// A sample deck runs the master chain on its own bus, so its section strip has Master FX
  /// (not Wander, which composes nets), and the panel's sweep-lp reaches the deck. Its panel
  /// leaves out the vinyl brake (no brake on a sample deck's bus yet).
  @Test func aSampleDeckShowsMasterFx() async throws {
    typealias S = DeckSections.Section
    let sample = S.shown(isNet: false)
    #expect(sample.contains(.masterfx) && !sample.contains(.wander))
    #expect(S.shown(isNet: true) == S.allCases, "a net deck shows every section")
    #expect(!MasterFxPanel.macros("Pitch", isNet: false).contains(.vinylBrake))
    #expect(MasterFxPanel.macros("FX", isNet: false).contains(.sweepLp))
    let m = try await model()
    let b = try #require(m.engine?["B"])
    #expect(m.decks["B"]?.isNet == false)
    m.fire("B", .sweepLp)  // what the panel's button does
    #expect(b.isMasterActive(.sweepLp))
    m.poll()
    #expect(m.decks["B"]?.masterRunning.contains(.sweepLp) == true, "the section's ● lights")
  }

  @Test func theDefaultWindowSize() async throws {
    let m = try await model()
    savePNG(ContentView(model: m), width: 900, height: 760, name: "app-default")
    #expect(try renderPixels(ContentView(model: m), width: 900, height: 760) != nil)
  }
}
