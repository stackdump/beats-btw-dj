import Testing

@testable import DJCore

// The meta-net's numbers (SPEC mode 8): stage.js `edge` and `renderMetaNet`.

struct StageMetaNetTests {
  @Test func theMetaNetsAlphasAreStageJS() {
    // renderMetaNet: arcOpacity = 0.35; place circles stroke-opacity arcOpacity + 0.1, fill
    // rgba(74,144,217,0.06); edge(): headLen = 12; stroke-width 2
    #expect(StageMetaNet.arcOpacity == 0.35)
    #expect(StageMetaNet.placeStrokeOpacity == 0.45)
    #expect(StageMetaNet.placeFillAlpha == 0.06)
    #expect(StageMetaNet.headLength == 12)
    #expect(StageStyle.metaStrokeWidth == 2)
  }

  @Test func anEdgeStartsAndEndsOnTheOutlines() {
    let e = StageMetaNet.edge(
      StagePoint(x: 0, y: 0), StagePoint(x: 100, y: 0), aInset: 10, bInset: 20)
    #expect(stageNear(e.x1, 10) && stageNear(e.y1, 0) && stageNear(e.x2, 80) && stageNear(e.y2, 0))
    // head of 12 at +-30 degrees: x2 - 12 cos(-30), y2 - 12 sin(-30), and the mirror
    #expect(stageNear(e.hx1, 80 - 12 * 0.8660254037844387) && stageNear(e.hy1, 6))
    #expect(stageNear(e.hx2, 80 - 12 * 0.8660254037844387) && stageNear(e.hy2, -6))
  }

  @Test func aDegenerateEdgeDoesNotDivideByZero() {
    let p = StagePoint(x: 5, y: 5)
    let e = StageMetaNet.edge(p, p, aInset: 3, bInset: 4)
    #expect(e.x1.isFinite && e.y2.isFinite && e.hx1.isFinite)
  }

  @Test func thereAreTwoEdgesPerPlaceInStageJSOrder() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 6)
    let edges = StageMetaNet.edges(layout: l)
    #expect(edges.count == 12)
    // edge 0: transition 0 (500, 120) -> place 0 (549, 315.13), inset side/2 = 96 and placeR
    let a = StagePoint(x: 500, y: 120)
    let p = l.placeCenters[0]
    let len = stageHyp(p.x - a.x, p.y - a.y)
    #expect(stageNear(edges[0].x1, a.x + (p.x - a.x) / len * 96, 1e-9))
    #expect(stageNear(edges[0].y1, a.y + (p.y - a.y) / len * 96, 1e-9))
    #expect(stageNear(edges[0].x2, p.x - (p.x - a.x) / len * 23.04, 1e-9))
    // edge 1: place 0 -> transition 1
    let b = l.panelCenters[1]
    let len1 = stageHyp(b.x - p.x, b.y - p.y)
    #expect(stageNear(edges[1].x1, p.x + (b.x - p.x) / len1 * 23.04, 1e-9))
    #expect(stageNear(edges[1].x2, b.x - (b.x - p.x) / len1 * 96, 1e-9))
    // the last place closes the loop onto transition 0
    let last = edges[11]
    let pl = l.placeCenters[5]
    let t0 = l.panelCenters[0]
    let len5 = stageHyp(t0.x - pl.x, t0.y - pl.y)
    #expect(stageNear(last.x2, t0.x - (t0.x - pl.x) / len5 * 96, 1e-9))
  }

  @Test func noEdgesWithoutAMetaNet() {
    #expect(
      StageMetaNet.edges(layout: StagePanelLayout.layoutRing(width: 1000, height: 800, count: 17))
        .isEmpty)
    #expect(
      StageMetaNet.edges(layout: StagePanelLayout.layoutRing(width: 1000, height: 800, count: 1))
        .isEmpty)
  }
}
