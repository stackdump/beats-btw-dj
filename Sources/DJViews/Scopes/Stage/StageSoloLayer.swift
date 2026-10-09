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
// into strokes.
//
// GLOWS. A canvas `shadowBlur` is defined by the HTML spec: the shape's alpha channel, blurred with
// a Gaussian of standard deviation blur/2, painted in the shadow colour with its alpha multiplied
// in, UNDER the shape. SwiftUI's `.shadow` filter is not that (measured: on a line a few points
// wide it leaves about half of the canvas glow), so the glow is drawn the way the spec says it is:
// the same path stroked in the shadow colour inside a layer with a `.blur` filter (whose kernel is
// a Gaussian of the radius given, measured), and then the shape itself over it. No fudge factor.
//
// DEVICE PIXELS. The blur is a length in DEVICE pixels that a canvas transform does not scale
// (stage.js draws on a canvas of `w * dpr` pixels under `setTransform(dpr, ...)`), so the same
// `shadowBlur` is `1 / dpr` as wide in points on a Retina screen: the Gaussian here is
// `blur / (2 * displayScale)` points. Measured against Chrome at both ratios
// (scripts/stage-solo-chrome-reference.html).

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
    case .sonar(let arcs): drawSonar(gc, arcs: arcs)
    case .petal(let petals): drawPetals(gc, petals: petals)
    }
  }

  /// How many device pixels a point is (the view's `displayScale`).
  static func deviceScale(_ gc: GraphicsContext) -> Double {
    let s = gc.environment.displayScale
    return s.isFinite && s > 0 ? Double(s) : 1
  }

  /// The standard deviation, in points, of a canvas `shadowBlur` of `blur` on this context.
  static func glowSigma(blur: Double, _ gc: GraphicsContext) -> Double {
    blur / (2 * deviceScale(gc))
  }

  /// A canvas shadow, under a shape: `body` draws the shape's path in the shadow colour (its
  /// alpha already multiplied by the shape's own, as the spec does), and this blurs it.
  static func glow(
    _ gc: GraphicsContext, blur: Double, _ body: (GraphicsContext) -> Void
  ) {
    let sigma = glowSigma(blur: blur, gc)
    guard sigma > 0 else { return }
    gc.drawLayer { layer in
      layer.addFilter(.blur(radius: sigma))
      body(layer)
    }
  }

  /// The glow of a STROKED shape: `path` in the shadow colour with the stroke's alpha in it (as
  /// the spec does), blurred. Nothing is drawn for a shadow that is invisible.
  static func strokeGlow(
    _ gc: GraphicsContext, _ path: Path, shadow: ScopeColor, blur: Double, under stroke: ScopeColor,
    style: StrokeStyle
  ) {
    let tinted = shadow.withAlpha(shadow.a * stroke.a)
    guard tinted.a > 0 else { return }
    glow(gc, blur: blur) { layer in layer.stroke(path, with: .color(tinted.color), style: style) }
  }

  // MARK: corona (mode 9)

  /// `renderCorona`: one round-capped line per bin, each with its own glow. A bin with no length
  /// (at the floor, or silent) is a zero-length line, which a canvas does not draw at all, round
  /// caps or not (measured in Chrome: no dot and no glow), so nothing is drawn for it.
  static func drawCorona(_ gc: GraphicsContext, rays: [CoronaRay]) {
    for ray in rays where !ray.isZeroLength {
      var line = Path()
      line.move(to: CGPoint(x: ray.x0, y: ray.y0))
      line.addLine(to: CGPoint(x: ray.x1, y: ray.y1))
      let style = StrokeStyle(lineWidth: ray.lineWidth, lineCap: .round)
      strokeGlow(
        gc, line, shadow: ray.shadow, blur: ray.shadowBlur, under: ray.stroke, style: style)
      gc.stroke(line, with: .color(ray.stroke.color), style: style)
    }
  }
}

extension StageSoloPainter {
  // MARK: sonar (mode 10)

  /// `renderSonar`: one stroked circle per ring, each with its own glow, oldest first.
  static func drawSonar(_ gc: GraphicsContext, arcs: [SonarArc]) {
    for arc in arcs {
      let circle = Path(
        ellipseIn: CGRect(
          x: arc.cx - arc.radius, y: arc.cy - arc.radius, width: 2 * arc.radius,
          height: 2 * arc.radius))
      let style = StrokeStyle(lineWidth: arc.lineWidth)
      strokeGlow(
        gc, circle, shadow: arc.shadow, blur: arc.shadowBlur, under: arc.stroke, style: style)
      gc.stroke(circle, with: .color(arc.stroke.color), style: style)
    }
  }
}

extension StageSoloPainter {
  // MARK: petal (mode 11)

  /// `renderPetal`: for each petal a fill (a two-circle gradient clipped to the petal) and then
  /// its outline with a glow, in panel order.
  static func drawPetals(_ gc: GraphicsContext, petals: [PetalShape]) {
    for petal in petals {
      let outline = path(of: petal)
      // The fill carries the PREVIOUS petal's glow: stage.js leaves its shadow state set (see
      // `PetalShape.fillShadow`). The shadow of a fill is the fill's own alpha, blurred.
      if let s = petal.fillShadow, s.a > 0 {
        glow(gc, blur: petal.fillShadowBlur) { layer in
          fill(
            layer, petal: petal, outline: outline,
            inner: s.withAlpha(s.a * petal.fillInner.a), outer: s.withAlpha(s.a * petal.fillOuter.a)
          )
        }
      }
      fill(gc, petal: petal, outline: outline)
      let style = StrokeStyle(lineWidth: petal.lineWidth)
      strokeGlow(
        gc, outline, shadow: petal.shadow, blur: petal.shadowBlur, under: petal.outline,
        style: style)
      gc.stroke(outline, with: .color(petal.outline.color), style: style)
    }
  }

  /// `moveTo(centre)`, `quadraticCurveTo(left, tip)`, `quadraticCurveTo(right, centre)`.
  static func path(of p: PetalShape) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: p.center.x, y: p.center.y))
    path.addQuadCurve(
      to: CGPoint(x: p.tip.x, y: p.tip.y), control: CGPoint(x: p.left.x, y: p.left.y))
    path.addQuadCurve(
      to: CGPoint(x: p.center.x, y: p.center.y), control: CGPoint(x: p.right.x, y: p.right.y))
    return path
  }

  /// `createRadialGradient(cx, cy, baseR * 0.5, tipX, tipY, len)` filled into the petal. A canvas
  /// radial gradient runs between TWO circles (here: a small one on the centre and one of radius
  /// `len` round the tip) and extends past both with its end colours, where the cone between
  /// them reaches; SwiftUI's own radial gradient has one centre, so this is Core Graphics'
  /// `drawRadialGradient`, which is the same shading, in the layer's own context.
  static func fill(
    _ gc: GraphicsContext, petal p: PetalShape, outline: Path, inner: ScopeColor? = nil,
    outer: ScopeColor? = nil
  ) {
    gc.withCGContext { cg in
      let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
      let colors = [cgColor(inner ?? p.fillInner), cgColor(outer ?? p.fillOuter)] as CFArray
      guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])
      else { return }
      cg.addPath(outline.cgPath)
      cg.clip()
      cg.drawRadialGradient(
        gradient, startCenter: CGPoint(x: p.center.x, y: p.center.y),
        startRadius: p.gradientStartRadius, endCenter: CGPoint(x: p.tip.x, y: p.tip.y),
        endRadius: p.gradientEndRadius,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
  }

  static func cgColor(_ c: ScopeColor) -> CGColor {
    CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
  }
}
