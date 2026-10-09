import DJCore
import SwiftUI

// Pulse particles (SPEC mode 14): every audible hit sends a red dot from the fired transition
// toward the centre of the ring, shrinking and fading as it goes. The numbers (the 700 ms life,
// the ease, the radius and the alpha) are `StagePulse`, with unit tests; this file only paints
// what `StagePulseModel.dots(nowMs:)` hands it.
//
// Inside the container transform, over the meta-net and under the panels (stage.js draws the
// particles into the meta SVG, below the panels: a beat appears to pass BEHIND the ring outlines
// and reappear in the composition's negative space). Each dot is `<circle fill="#e94560"
// fill-opacity=...>`.

struct StagePulseLayer: View {
  let context: StageContext
  let model: StagePulseModel

  var body: some View {
    Canvas { gc, _ in
      StagePulsePainter.draw(&gc, dots: model.dots(nowMs: context.nowMs))
    }
    .allowsHitTesting(false)
  }
}

enum StagePulsePainter {
  static func draw(_ gc: inout GraphicsContext, dots: [StagePulseDot]) {
    for d in dots {
      let circle = Path(
        ellipseIn: CGRect(
          x: d.x - d.radius, y: d.y - d.radius, width: d.radius * 2, height: d.radius * 2))
      gc.fill(circle, with: .color(StagePalette.transition.withAlpha(d.alpha).color))
    }
  }
}
