import DJCore
import SwiftUI
import Testing

@testable import DJViews

private let bg = (5, 10, 20)  // ScopeColors.background

@MainActor
struct ScopeAppModelTests {
  func model() throws -> (AppModel, DJEngine) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    return (AppModel(engine: dj), dj)
  }

  @Test func theScopeStateStartsOffOnTheMasterScope() throws {
    let (m, dj) = try model()
    #expect(!m.showScopes && m.scopeKind == .live && m.scopeSource == .master && !m.scopeMeasured)
    #expect(m.scopeHub == nil, "the hub appears with the engine, at start()")
    m.start()
    let hub = try #require(m.scopeHub)
    #expect(hub.engine === dj)
    #expect(hub.activeFeeds.isEmpty, "nothing is tapped until a panel is on screen")
    #expect(!dj.masterTap.isEnabled && !dj["A"]!.tap.isEnabled)
    m.start()  // a second start keeps the same hub
    #expect(m.scopeHub === hub)
  }

  @Test func theTogglesAreModelState() throws {
    let (m, _) = try model()
    m.start()
    m.showScopes = true
    m.scopeKind = .spectro
    m.scopeSource = .deck("A")
    m.scopeMeasured = true
    #expect(
      m.showScopes && m.scopeKind == .spectro && m.scopeSource == .deck("A") && m.scopeMeasured)
    #expect(m.scopeWindowHeight == 800)
  }

  @Test func theContentViewShowsThePanelUnderTheDecksWhenOn() throws {
    let (m, _) = try model()
    m.start()
    m.poll()
    // The master meter in the Mixer column (SPEC mode 28) is a 38 pt box of the same colour, as
    // feed.html's flame canvas is: about 4.6 k pixels. The column is in the middle of the window
    // (about x 470...630 at this width), so the count leaves out x 400...700 and the panel, which
    // spans the window, is still counted where it is wide.
    func background(_ view: some View) throws -> Int {
      let px = try #require(renderPixels(view, width: 1100, height: 2000))
      let isBackground: (Int, Int, Int) -> Bool = { r, g, b in
        abs(r - bg.0) <= 2 && abs(g - bg.1) <= 2 && abs(b - bg.2) <= 2
      }
      return px.count(inX: 0..<400, y: 0..<2000, where: isBackground)
        + px.count(inX: 700..<1100, y: 0..<2000, where: isBackground)
    }
    let off = try background(ContentView(model: m))
    m.showScopes = true
    let live = try background(ContentView(model: m))
    m.scopeKind = .bands
    let bands = try background(ContentView(model: m))
    #expect(off < 200, "no scope background without the panel (\(off))")
    #expect(live > 200_000, "the live panel is ~440 pt of scope background (\(live))")
    #expect(bands > 50_000 && bands < live / 2, "bands is 124 pt tall (\(bands))")
    savePNG(ContentView(model: m), width: 1100, height: 2000, name: "app-scopes")
  }
}
