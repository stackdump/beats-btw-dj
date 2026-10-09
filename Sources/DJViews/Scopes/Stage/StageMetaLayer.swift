import DJCore
import SwiftUI

// The meta-net (SPEC mode 8): the whole Stage read as one Petri net. N transitions (the panels,
// squares of `side`) on the outer ring alternate with N place circles on an inner ring at 0.35 of
// it, closed by 2N arcs `t_i -> p_i -> t_(i+1)` (stage.js `renderMetaNet` / `edge`; the numbers
// are `StageMetaNet`). Skipped for one panel and for more than 16, where the circles overlap into
// a thick band and the arrows drown the panels. Part of the stage skeleton; it sits inside the
// container, under the pulses and the panels.
//
//   arcs          #4a90d9 at opacity 0.35, 2 points wide, heads 12 long at +-30 degrees; every
//                 line of an edge (shaft and the two barbs) is its own `<line>` in the SVG and is
//                 stroked on its own here, so the three overlap at the tip as they do there
//   place circle  fill rgba(74,144,217,0.06), stroke #4a90d9 at opacity 0.45, 2 points wide

struct StageMetaLayer: View {
  let context: StageContext

  var body: some View {
    Canvas { gc, _ in
      StageMetaPainter.draw(&gc, layout: context.layout)
    }
    .allowsHitTesting(false)
  }
}

enum StageMetaPainter {
  static func draw(_ gc: inout GraphicsContext, layout: StageRingLayout) {
    guard layout.showsMeta, let placeR = layout.placeR else { return }
    let arcShading = GraphicsContext.Shading.color(
      StagePalette.arc.withAlpha(StageMetaNet.arcOpacity).color)
    let width = StageStyle.metaStrokeWidth
    for e in StageMetaNet.edges(layout: layout) {
      // stage.js `edge`: <line> shaft, <line> barb, <line> barb, each at stroke-opacity 0.35.
      for (a, b) in [
        (CGPoint(x: e.x1, y: e.y1), CGPoint(x: e.x2, y: e.y2)),
        (CGPoint(x: e.x2, y: e.y2), CGPoint(x: e.hx1, y: e.hy1)),
        (CGPoint(x: e.x2, y: e.y2), CGPoint(x: e.hx2, y: e.hy2)),
      ] {
        var line = Path()
        line.move(to: a)
        line.addLine(to: b)
        gc.stroke(line, with: arcShading, lineWidth: width)
      }
    }
    for c in layout.placeCenters {
      let circle = Path(
        ellipseIn: CGRect(x: c.x - placeR, y: c.y - placeR, width: placeR * 2, height: placeR * 2)
      )
      gc.fill(
        circle, with: .color(StagePalette.arc.withAlpha(StageMetaNet.placeFillAlpha).color))
      gc.stroke(
        circle,
        with: .color(StagePalette.arc.withAlpha(StageMetaNet.placeStrokeOpacity).color),
        lineWidth: width)
    }
  }
}
