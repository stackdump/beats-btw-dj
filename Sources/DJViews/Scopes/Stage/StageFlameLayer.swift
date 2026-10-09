import DJCore
import SwiftUI

// Flame beams (SPEC mode 15): a narrow radial beam per panel from the centre of the ring toward
// the transition that fired last on it, brightest right after a hit and dying away. The numbers
// (energy, decay, the polygon, the gradient stops) are `StageFlame`, with unit tests; this file
// fills what `StageFlameModel.beams(in:)` hands it.
//
// Inside the container transform, under the bolts, the meta-net and the panels. The JS draws it
// on a canvas OUTSIDE the grid and copies the grid's transform onto it every frame; here the
// container wraps all five layers in one modifier, which is the same thing by construction.
//
// The canvas blends stops as straight RGBA and SwiftUI as premultiplied, which would turn the
// fade to transparent blue into a fade to transparent rose; the gradient is handed over resampled
// (`StageCanvasGradient`) so the tail keeps the canvas' blue-ward drift.
//
// Each beam is `ctx.createLinearGradient(cx, cy, tipX, tipY)` with amber rgba(255,200,64,.85 v) at
// 0, #e94560-ish rgba(233,69,96,.7 v) at .5 and rgba(74,144,217,0) at 1, filled into the four
// corners (two on the ring of radius innerR, two at the tip, a quarter as wide).

struct StageFlameLayer: View {
  let context: StageContext
  let model: StageFlameModel

  var body: some View {
    Canvas { gc, _ in
      StageFlamePainter.draw(&gc, beams: model.beams(in: context))
    }
    .allowsHitTesting(false)
  }
}

enum StageFlamePainter {
  static func draw(_ gc: inout GraphicsContext, beams: [StageFlameBeam]) {
    for beam in beams {
      var path = Path()
      let corners = beam.polygon
      path.move(to: CGPoint(x: corners[0].x, y: corners[0].y))
      for c in corners.dropFirst() { path.addLine(to: CGPoint(x: c.x, y: c.y)) }
      path.closeSubpath()
      let gradient = Gradient(
        stops: beam.paintStops.map { Gradient.Stop(color: $0.color.color, location: $0.location) })
      gc.fill(
        path,
        with: .linearGradient(
          gradient, startPoint: CGPoint(x: beam.gradientStart.x, y: beam.gradientStart.y),
          endPoint: CGPoint(x: beam.gradientEnd.x, y: beam.gradientEnd.y)))
    }
  }
}
