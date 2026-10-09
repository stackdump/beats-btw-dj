import DJCore
import SwiftUI
import Testing

@testable import DJViews

private let bg = (5, 10, 20)  // ScopeColors.background

@MainActor
struct ScopeHostTests {
  func panel(
    _ rig: ScopeViewRig, kind: ScopeKind, source: ScopeSource = .master, measured: Bool = false
  ) -> some View {
    // top-aligned, so the header is at the top of the render
    VStack(spacing: 0) {
      ScopePanelView(
        hub: rig.hub, kind: .constant(kind), source: .constant(source),
        measured: .constant(measured), windowHeight: 800)
      Spacer(minLength: 0)
    }
  }

  /// The first row of the body: where the scope background starts at the left edge.
  func bodyTop(_ px: Pixels) -> Int? {
    (0..<(px.height - 6)).first { y in (0..<6).allSatisfy { px.near(10, y + $0, bg, tol: 2) } }
  }

  @Test func theKindPickerHighlightsTheSelectedView() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.feed(.master).acquire()
    try rig.run(seconds: 0.5)
    func header(_ k: ScopeKind) throws -> Pixels {
      try #require(renderPixels(panel(rig, kind: k), width: 900, height: 700))
    }
    let live = try header(.live)
    let liveAgain = try header(.live)
    let bands = try header(.bands)
    func differing(_ a: Pixels, _ b: Pixels) -> Int {
      var n = 0
      for y in 0..<26 {
        for x in 0..<900 {
          let p = a.color(x, y)
          let q = b.color(x, y)
          if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 30 { n += 1 }
        }
      }
      return n
    }
    #expect(differing(live, liveAgain) == 0, "deterministic")
    #expect(differing(live, bands) > 150, "the highlighted pill moved")
    // the accent colour is on screen in the header
    let accent = live.count(inX: 0..<900, y: 0..<26) { r, g, b in b > 180 && r < 120 && g > 80 }
    #expect(accent > 100, "the selected pill is filled with the accent colour (\(accent))")
  }

  @Test func theMeasuredToggleAppearsOnlyWhereItMeans() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.feed(.master).acquire()
    try rig.run(seconds: 0.5)
    func lit(_ k: ScopeKind, _ measured: Bool) throws -> Int {
      let px = try #require(
        renderPixels(panel(rig, kind: k, measured: measured), width: 900, height: 700))
      // the header only: the body starts at about y = 24, and a ported mode draws there
      return px.count(inX: 0..<900, y: 0..<22) { r, g, b in r + g + b > 150 }
    }
    let live = try lit(.live, false)
    let raster = try lit(.raster, false)
    let spectro = try lit(.spectro, false)
    let spectroOn = try lit(.spectro, true)
    #expect(spectro > live + 80, "spectro has the extra pill (\(spectro) vs \(live))")
    #expect(spectroOn > spectro, "and it is filled when on")
    #expect(abs(raster - live) < 60, "raster has none, like scope")
  }

  @Test func theSourcesAreTheDecksThenTheMaster() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    #expect(rig.hub.sources == [.deck("A"), .deck("B"), .master])
    #expect(ScopeSource.master.label == "Master" && ScopeSource.deck("A").label == "Deck A")
  }

  @Test func aSampleDeckSourceStillDrawsAndSaysItNeedsANet() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.feed(.deck("B")).acquire()
    try rig.run(seconds: 0.5)
    let feed = rig.hub.feed(.deck("B"))
    #expect(!feed.hasNet && feed.statusText == "needs a net deck")
    let px = try #require(
      renderPixels(panel(rig, kind: .live, source: .deck("B")), width: 900, height: 700))
    #expect(bodyTop(px) != nil)
  }

  @Test func theModeViewsTakeTheUniformInitialiser() throws {
    // the contract in ScopePanelView.swift: every mode view is `init(feed:measured:hub:)`
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    let hub = rig.hub
    let views: [any View] = [
      ScopeLiveView(feed: feed, measured: false, hub: hub),
      ScopeSpectroView(feed: feed, measured: true, hub: hub),
      ScopeBandsView(feed: feed, measured: false, hub: hub),
      ScopeRasterView(feed: feed, measured: false, hub: hub),
    ]
    #expect(views.count == ScopeKind.allCases.count)
  }

  @Test func theCanvasPumpsTheHubBeforeDrawing() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    try renderOffline(rig.dj, frames: 8192)  // rendered, not pumped
    #expect(feed.history.isEmpty)
    var pumpedAtDraw = -1
    let view = ScopeCanvas(hub: rig.hub) { _, _ in pumpedAtDraw = feed.history.count }
    _ = renderPixels(view, width: 100, height: 60)
    #expect(pumpedAtDraw == 8192, "the Canvas pumped before it drew")
    // the background is filled
    let px = try #require(renderPixels(view, width: 100, height: 60))
    #expect(px.near(50, 30, bg, tol: 2))
  }
}
