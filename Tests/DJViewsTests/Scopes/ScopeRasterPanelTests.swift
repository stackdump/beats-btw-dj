import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The raster inside the scope panel (the host picks the body by ScopeKind). A single rendered
// frame cannot wait for the background compute, so the panel is either shown while the raster is
// "computing", or handed a controller that has already settled (the panel's test seam) to see the
// finished raster, the header's status line and the height rule in place.

private let bg = (5, 10, 20)
private let textGrey = (136, 153, 170)

@MainActor
struct ScopeRasterPanelTests {
  func panel(
    _ hub: ScopeHub, kind: ScopeKind = .raster, source: ScopeSource, line: ScopeStatusLine? = nil,
    raster: RasterController? = nil
  ) -> some View {
    VStack(spacing: 0) {
      ScopePanelView(
        hub: hub, kind: .constant(kind), source: .constant(source), measured: .constant(false),
        windowHeight: 800, statusLine: line, rasterController: raster)
      Spacer(minLength: 0)
    }
  }

  func panel(_ rig: ScopeViewRig, source: ScopeSource) -> some View {
    panel(rig.hub, source: source)
  }

  @Test(arguments: [ScopeSource.master, ScopeSource.deck("A")])
  func theRasterKindShowsTheRasterBodyNotThePlaceholder(source: ScopeSource) throws {
    let rig = try ScopeViewRig(genre: "techno", seed: 42, structure: "minimal")
    defer { rig.stop() }
    rig.hub.feed(source).acquire()
    try rig.run(seconds: 0.5)
    let view = panel(rig, source: source)
    savePNG(view, width: 900, height: 700, name: "raster-panel-\(source.label)")
    let px = try #require(renderPixels(view, width: 900, height: 700))
    // the body: scope background under the header
    let top = try #require(
      (0..<(px.height - 6)).first { y in (0..<6).allSatisfy { px.near(880, y + $0, bg, tol: 2) } })
    #expect(top > 15 && top < 60)
    // the height rule is the host's (scope.js viewHeight for the raster)
    var rows = 0
    while top + rows < px.height, px.near(880, top + rows, bg, tol: 2) { rows += 1 }
    let feed = rig.hub.feed(source)
    let want = Int(
      ScopeKind.raster.height(
        measured: false, laneCount: feed.laneSet.lanes.count, windowHeight: 800))
    #expect(abs(rows - want) <= 2, "body \(rows) rows, viewHeight \(want)")
    // while the arrangement is computed the raster says so, in the text grey, top left
    let grey = px.count(inX: 6..<220, y: (top + 6)..<(top + 22)) { r, g, b in
      abs(r - textGrey.0) < 50 && abs(g - textGrey.1) < 50 && abs(b - textGrey.2) < 50
    }
    #expect(grey > 30, "computing the arrangement… (\(grey) grey pixels)")
    // and it is not the placeholder: no section-red title, no centred status lines
    let red = px.count(inX: 100..<800, y: top..<(top + rows)) { r, g, b in
      abs(r - 233) < 60 && abs(g - 69) < 50 && abs(b - 96) < 50
    }
    #expect(red == 0, "the placeholder's 'not yet ported' title is gone")
    #expect(px.near(450, top + rows / 2, bg, tol: 2))
  }

  @Test func aSampleDeckSourceSaysThereIsNoNetInTheBody() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.feed(.deck("B")).acquire()
    try rig.run(seconds: 0.5)
    let px = try #require(renderPixels(panel(rig, source: .deck("B")), width: 900, height: 700))
    let top = try #require(
      (0..<(px.height - 6)).first { y in (0..<6).allSatisfy { px.near(880, y + $0, bg, tol: 2) } })
    let grey = px.count(inX: 6..<220, y: (top + 6)..<(top + 22)) { r, g, b in
      abs(r - textGrey.0) < 50 && abs(g - textGrey.1) < 50 && abs(b - textGrey.2) < 50
    }
    #expect(grey > 30, "no net on this deck")
  }

  // MARK: the header's status line

  /// The ink (pixels that differ from the empty header at `fromX`, 0) from column `fromX` on in the
  /// top `rows` rows (the header, above the body): (minX, maxX, minY, maxY).
  private func inkBox(_ px: Pixels, fromX: Int, rows: Int) -> (Int, Int, Int, Int)? {
    let empty = px.color(fromX, 0)
    var box: (Int, Int, Int, Int)?
    for y in 0..<rows {
      for x in fromX..<px.width {
        let c = px.color(x, y)
        guard abs(c.r - empty.r) + abs(c.g - empty.g) + abs(c.b - empty.b) > 40 else { continue }
        let b = box ?? (x, x, y, y)
        box = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y))
      }
    }
    return box
  }

  /// The right-aligned 10 px monospaced secondary-colour text the header shows, alone.
  private func headerText(_ text: String) -> some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
  }

  @Test func aModesStatusLineReplacesTheHeadersOwnText() throws {
    // `live` (no measured pill) does not speak here; the line is set by hand before the frame,
    // as a mode would have, so a mode that speaks later changes nothing in the header it reads
    let rig = try ScopeViewRig(genre: "techno", seed: 42, structure: "minimal")
    defer { rig.stop() }
    rig.hub.feed(.deck("A")).acquire()
    try rig.run(seconds: 0.5)
    let shown = "raster · loop cycle · 340 events · 12 bars · 8 ms"
    let line = ScopeStatusLine()
    final class Speaker {}
    let speaker = Speaker()
    line.set(shown, owner: speaker)
    let feed = rig.hub.feed(.deck("A"))
    #expect(feed.statusText != shown)

    let spoken = try #require(
      renderPixels(
        panel(rig.hub, kind: .live, source: .deck("A"), line: line), width: 900, height: 700))
    let own = try #require(
      renderPixels(panel(rig.hub, kind: .live, source: .deck("A")), width: 900, height: 700))
    let alone = try #require(renderPixels(headerText(shown), width: 900, height: 200))
    let ownAlone = try #require(renderPixels(headerText(feed.statusText), width: 900, height: 200))

    let a = try #require(inkBox(spoken, fromX: 560, rows: 20), "the header shows the line's text")
    let b = try #require(inkBox(alone, fromX: 560, rows: 20))
    #expect(abs(a.0 - b.0) <= 1 && abs(a.1 - b.1) <= 1, "spoken \(a) / alone \(b)")
    #expect(abs((a.3 - a.2) - (b.3 - b.2)) <= 1, "the same height of ink")
    // and with nothing said it is the feed's own text
    let c = try #require(inkBox(own, fromX: 560, rows: 20))
    let d = try #require(inkBox(ownAlone, fromX: 560, rows: 20))
    #expect(abs(c.0 - d.0) <= 1 && abs(c.1 - d.1) <= 1, "own \(c) / alone \(d)")
    #expect(c.0 > a.0 + 40, "the feed's own text is much shorter than the raster's line")
  }

  @Test func theFinishedRasterAndItsStatusLineAreShownInThePanel() async throws {
    let rig = try ScopeViewRig(genre: "techno", seed: 42, structure: "minimal")
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 0.5)
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let scene = try #require(raster.scene)
    #expect(raster.phase == .ready && scene.result.count > 100)
    let line = ScopeStatusLine()
    let view = panel(rig.hub, source: .deck("A"), line: line, raster: raster)
    let px = try #require(renderPixels(view, width: 900, height: 700))
    // the panel's line now carries the raster's own text (the mode reached it through the
    // environment), and the raster did not recompute for the panel
    #expect(line.text == RasterLayout.statusText(scene.result), "\(line.text ?? "nil")")
    #expect(line.text?.hasPrefix("raster · ") == true && line.text?.hasSuffix(" ms") == true)
    #expect(raster.computeCount == 1 && raster.phase == .ready)
    // the body is the finished raster: lane names in their colours down the gutter, a section
    // marker in the section colour, no "computing" message
    let top = try #require(
      (0..<(px.height - 6)).first { y in (0..<6).allSatisfy { px.near(61, y + $0, bg, tol: 2) } })
    let lh =
      (Double(
        ScopeKind.raster.height(
          measured: false, laneCount: scene.lanes.count, windowHeight: 800)) - 28)
      / Double(scene.lanes.count)
    var colored = 0
    for (l, lane) in scene.lanes.enumerated() {
      let c = lane.color.rgb8
      let y0 = top + 14 + Int(Double(l) * lh)
      let n = px.count(inX: 0..<62, y: y0..<(y0 + max(1, Int(lh)))) { r, g, b in
        abs(r - c.r) < 60 && abs(g - c.g) < 60 && abs(b - c.b) < 60
      }
      if n > 4 { colored += 1 }
    }
    #expect(colored >= scene.lanes.count - 1, "\(colored) of \(scene.lanes.count) lane names")
    let red = px.count(inX: 60..<70, y: top..<(top + 40)) { r, g, b in
      abs(r - 233) < 40 && abs(g - 69) < 40 && abs(b - 96) < 40
    }
    #expect(red > 5, "the section marker at the left edge of the plot")
    // (the line was spoken during the frame above, so this picture's header carries it)
    savePNG(view, width: 900, height: 700, name: "raster-panel-finished")
  }

  // MARK: the height rule

  @Test func aMasterOfTwoNetDecksIsSizedFromTheLeadDecksLanesOnly() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    defer { dj.stop() }
    for (i, name) in ["A", "B"].enumerated() {
      dj[name]!.loadNet(
        PreparedTrack(
          spec: TrackSpec(genre: "techno", seed: 42 + Double(i), structure: "minimal"),
          sampleRate: 22_050))
      dj[name]!.wave.setTempo(300)
      dj[name]!.setPlaying(true)
    }
    let hub = ScopeHub(engine: dj)
    try dj.start()
    let feed = hub.feed(.master)
    feed.acquire()
    for _ in 0..<2 {
      try renderOffline(dj, frames: 11_025)
      hub.pump()
    }
    let lead = feed.laneSet.lanes.count
    #expect(
      lead > 4 && feed.lanes.count > lead,
      "the master has both decks' lanes: \(feed.lanes.count) / \(lead)")
    let ofLead = Int(ScopeKind.raster.height(measured: false, laneCount: lead, windowHeight: 800))
    let ofBoth = Int(
      ScopeKind.raster.height(measured: false, laneCount: feed.lanes.count, windowHeight: 800))
    #expect(ofLead + 40 < ofBoth, "the two rules differ: \(ofLead) / \(ofBoth)")

    let px = try #require(renderPixels(panel(hub, source: .master), width: 900, height: 700))
    let top = try #require(
      (0..<(px.height - 6)).first { y in (0..<6).allSatisfy { px.near(880, y + $0, bg, tol: 2) } })
    var rows = 0
    while top + rows < px.height, px.near(880, top + rows, bg, tol: 2) { rows += 1 }
    #expect(
      abs(rows - ofLead) <= 2, "body \(rows) rows, lead deck's rule \(ofLead), both \(ofBoth)")
  }
}
