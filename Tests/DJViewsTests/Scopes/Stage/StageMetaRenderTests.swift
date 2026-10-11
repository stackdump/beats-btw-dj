import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

@MainActor
struct StageMetaRenderTests {
  func render(_ rig: StageViewRig, _ ctx: StageContext? = nil) throws -> Pixels {
    let view = StageScene(model: rig.model, context: ctx ?? rig.model.context)
    return try #require(renderPixels(view, width: Int(rig.width), height: Int(rig.height)))
  }

  @Test func theMetaNetIsDrawnForSixPanelsAndNotForMoreThanSixteen() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let ctx = rig.model.context
    let l = ctx.layout
    let placeR = try #require(l.placeR)
    let c = l.placeCenters[0]
    // the place circle's stroke at its top: #4a90d9 at 0.45 over the background is (39, 70, 112)
    let top = (Int(c.x.rounded()), Int((c.y - placeR).rounded()))
    let px = try render(rig)
    #expect(
      Sw.anyNear(px, top.0, top.1, r: 2, (39, 70, 112), tol: 22),
      "stroke: \(px.color(top.0, top.1))")
    // and its fill: rgba(74,144,217,0.06) over the background
    let inside = px.color(Int(c.x), Int(c.y))
    #expect(inside.b > 26 && inside.b < 40, "faint fill \(inside)")
    // the radial arcs are there too: the middle of the first arc, #4a90d9 at 0.35
    let edges = StageMetaNet.edges(layout: l)
    let mid = ((edges[0].x1 + edges[0].x2) / 2, (edges[0].y1 + edges[0].y2) / 2)
    #expect(Sw.anyNear(px, Int(mid.0), Int(mid.1), r: 2, (30, 56, 91), tol: 26))

    // expanded: 36 panels, no meta-net
    rig.model.settings.expandVariants = true
    try rig.run(seconds: 0.1)
    let big = rig.model.context
    #expect(big.panels.count == 36 && !big.layout.showsMeta)
    let px2 = try render(rig)
    let l2 = big.layout
    // where a meta circle would be at 0.35R is bare background
    let c2 = (Int(l2.center.x), Int((l2.center.y - l2.radius * 0.35).rounded()))
    #expect(px2.near(c2.0, c2.1, Sw.background, tol: 4), "no meta-net: \(px2.color(c2.0, c2.1))")
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-expanded")
  }

  // MARK: exact paint of the meta-net alone (six panels in 600 x 600, nothing else drawn)

  /// The meta-net layer over the stage background.
  func metaPixels(count: Int = 6) throws -> (Pixels, StageRingLayout) {
    let layout = StagePanelLayout.layoutRing(width: 600, height: 600, count: count)
    let ctx = StageContext(width: 600, height: 600, layout: layout)
    let view = ZStack {
      StagePalette.background.color
      StageMetaLayer(context: ctx)
    }
    return (try #require(renderPixels(view, width: 600, height: 600)), layout)
  }

  @Test func theMetaArcsAreStrokedAtOpacityPointThreeFive() throws {
    let (px, layout) = try metaPixels()
    savePNG(
      ZStack {
        StagePalette.background.color
        StageMetaLayer(context: StageContext(width: 600, height: 600, layout: layout))
      }, width: 600, height: 600, name: "stage-meta-alone")
    let want = Sw.blend(Sw.arcBlue, 0.35, over: Sw.background)
    #expect(want == (32, 57, 93))
    // every shaft has pixels of full coverage somewhere along it: the exact blend, no brighter
    for (i, e) in StageMetaNet.edges(layout: layout).enumerated() {
      let g = Sw.peak(
        px, channel: 1, from: StagePoint(x: e.x1, y: e.y1), to: StagePoint(x: e.x2, y: e.y2))
      #expect(abs(g - want.1) <= 2, "edge \(i): peak green \(g), want \(want.1)")
    }
  }

  @Test func theThreeLinesOfAnArrowOverlapAtItsTipLikeSVGLines() throws {
    // shaft and both barbs are separate <line>s at stroke-opacity 0.35, so where the three meet
    // at the tip the blend is 1 - 0.65^3 = 0.725 of the arc colour (G 107), not one stroke's
    // 0.35 (G 57). (Edges 2i end on a place circle, whose own stroke adds to it; edges 2i + 1 end
    // on a panel's square, where nothing else is drawn here.)
    let (px, layout) = try metaPixels()
    var strong = 0
    for (i, e) in StageMetaNet.edges(layout: layout).enumerated() {
      var g = 0
      for dy in -1...1 {
        for dx in -1...1 {
          let x = Int(e.x2.rounded(.down)) + dx
          let y = Int(e.y2.rounded(.down)) + dy
          g = max(g, px.color(x, y).g)
        }
      }
      if i % 2 == 1 {
        #expect(g >= 90 && g <= 108, "edge \(i): the tip is three strokes deep: G \(g)")
        if g >= 95 { strong += 1 }
      } else {
        #expect(g >= 95, "edge \(i): G \(g)")
      }
    }
    #expect(strong >= 4, "the overlap shows at the panel ends (\(strong) of 6)")
  }

  @Test func thePlaceCirclesAreFilledAtSixPercentAndStrokedAtFortyFive() throws {
    let (px, layout) = try metaPixels()
    let placeR = try #require(layout.placeR)
    let fillWant = Sw.blend(Sw.arcBlue, 0.06, over: Sw.background)
    #expect(fillWant == (14, 18, 37))
    for (i, c) in layout.placeCenters.enumerated() {
      // the pixel holding the centre is wholly inside the circle
      let inside = px.color(Int(c.x.rounded(.down)), Int(c.y.rounded(.down)))
      #expect(
        abs(inside.r - fillWant.0) <= 1 && abs(inside.g - fillWant.1) <= 1
          && abs(inside.b - fillWant.2) <= 1, "fill \(inside), want \(fillWant)")
      // The stroke at 0.45 over the (barely filled) background: the brightest pixel on the ring
      // is about 0.45 of the arc colour (G 70, 75 over the fill) and no more (0.40 would be 64). The arrows land on
      // the ring (one from the panel before, one towards the panel after): leave 30 degrees of
      // ring round both.
      let t0 = layout.panelCenters[i]
      let t1 = layout.panelCenters[(i + 1) % layout.panelCenters.count]
      let toward = [atan2(t0.y - c.y, t0.x - c.x), atan2(t1.y - c.y, t1.x - c.x)]
      var g = 0
      for k in 0..<720 {
        let a = Double(k) / 720 * 2 * Double.pi - Double.pi
        let clear = toward.allSatisfy { abs(atan2(sin(a - $0), cos(a - $0))) > 0.52 }
        guard clear else { continue }
        let x = Int((c.x + placeR * cos(a)).rounded(.down))
        let y = Int((c.y + placeR * sin(a)).rounded(.down))
        g = max(g, px.color(x, y).g)
      }
      #expect(g >= 69 && g <= 77, "place \(i): ring peak green \(g)")
    }
  }
}
