import DJCore
import SwiftUI

// The stage's solo visualizers (SPEC modes 9-12: corona, sonar, petal, shuffle), drawn.
//
// Full window, above the container and OUTSIDE its transform (stage.js: the scope canvas is not a
// child of the grid). The host keeps this view in the stack at all times and hides the panel grid
// while `context.visualizer.isSolo` (`viz-solo`); draw nothing otherwise. The canvas is cleared
// every frame (stage.js `scopeCtx.clearRect`), which here means it starts transparent over the
// stage's background layer.
//
// The model computes what to draw as values (`StageSoloPaint`); `StageSoloPainter` turns them
// into strokes. A canvas `shadowBlur` of B is a Gaussian of standard deviation B/2, and
// SwiftUI's shadow filter takes the standard deviation itself, so every glow below passes
// `blur / 2` (the same conversion `StageStyle.glowSigma` documents for CSS).

struct StageSoloLayer: View {
  let context: StageContext
  let model: StageSoloModel

  var body: some View {
    let paint = context.isSolo ? model.paint(context) : .none
    Canvas { gc, _ in
      StageSoloPainter.draw(&gc, paint: paint)
    }
    .allowsHitTesting(false)
  }
}

enum StageSoloPainter {
  static func draw(_ gc: inout GraphicsContext, paint: StageSoloPaint) {
    switch paint {
    case .none: break
    case .corona(let rays): drawCorona(gc, rays: rays)
    }
  }

  /// A canvas shadow: the shape's own alpha through the shadow colour, blurred.
  static func glow(
    _ gc: GraphicsContext, color: ScopeColor, blur: Double, _ body: (GraphicsContext) -> Void
  ) {
    gc.drawLayer { layer in
      layer.addFilter(
        .shadow(
          color: color.color, radius: blur / 2, x: 0, y: 0, blendMode: .normal, options: []))
      body(layer)
    }
  }

  // MARK: corona (mode 9)

  /// `renderCorona`: one round-capped line per bin, each with its own glow.
  static func drawCorona(_ gc: GraphicsContext, rays: [CoronaRay]) {
    for ray in rays {
      glow(gc, color: ray.shadow, blur: ray.shadowBlur) { layer in
        if ray.isDot {
          // a zero-length line with round caps is a dot as wide as the line
          let r = ray.lineWidth / 2
          layer.fill(
            Path(ellipseIn: CGRect(x: ray.x0 - r, y: ray.y0 - r, width: 2 * r, height: 2 * r)),
            with: .color(ray.stroke.color))
        } else {
          var line = Path()
          line.move(to: CGPoint(x: ray.x0, y: ray.y0))
          line.addLine(to: CGPoint(x: ray.x1, y: ray.y1))
          layer.stroke(
            line, with: .color(ray.stroke.color),
            style: StrokeStyle(lineWidth: ray.lineWidth, lineCap: .round))
        }
      }
    }
  }
}
