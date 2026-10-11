import DJCore
import SwiftUI

// Macro bolts, seeds and the dark planet's halo (SPEC mode 17). While a macro runs, every hit
// throws a jagged white-blue bolt from the fired transition at the dark planet in the middle of
// the ring; where it strikes it leaves a spark that drifts inward and outlives the bolt; the
// planet's halo condenses out of the bolts and dissolves when they stop. The numbers (lives,
// caps, the jitter, the colours, the glow) are `StageBolts`, with unit tests; this file strokes
// and fills what `StageBoltsModel` hands it.
//
// Inside the container transform, above the flame beams (stage.js draws all of it on the flame
// canvas, bolts after the beams) and below the meta-net, pulses and panels. Drawn in the JS order:
// every bolt (a 2.2 point pass with a blue glow, then a 1 point white core with a tighter glow),
// then the seeds, then the halo on top.
//
// A canvas `shadowBlur` B is a Gaussian with a standard deviation of B / 2 DEVICE pixels (the
// canvas does not scale it by the transform, so on a 2x display it is half as wide in points:
// `StageBolts.sigma(ofBlur:displayScale:)`). The glow is drawn the way the canvas makes it: the
// shape's own alpha, blurred, in the shadow colour (times the shape's alpha), and then the shape
// on top. It is NOT SwiftUI's `.shadow` filter: that one is a true Gaussian only for large shapes
// and several times too strong for a thin line or a 1.5 point disc (measured: a 1.5 point disc
// at radius 5 peaks at 43/255 against 11/255 for the Gaussian; `.blur(radius:)` agrees with the
// Gaussian), and the bolts and the seeds are exactly those.

struct StageBoltsLayer: View {
  let context: StageContext
  let model: StageBoltsModel
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    let scale = displayScale
    StageCanvas { gc, _ in
      StageBoltsPainter.draw(
        &gc, strokes: model.strokes(in: context), seeds: model.seedDots(in: context),
        halo: model.halo(in: context), displayScale: scale)
    }
    .allowsHitTesting(false)
  }
}

enum StageBoltsPainter {
  /// `displayScale` is the canvas' device pixel ratio: it narrows the glows (see the header).
  static func draw(
    _ gc: inout GraphicsContext, strokes: [StageBoltStroke], seeds: [StageSeedDot],
    halo: StageHalo?, displayScale: Double = 1
  ) {
    for s in strokes { drawBolt(gc, s, displayScale: displayScale) }
    for d in seeds { drawSeed(gc, d, displayScale: displayScale) }
    if let halo { drawHalo(gc, halo) }
  }

  /// `ctx.strokeStyle = rgba(200,225,255,.85a)`, shadow `rgba(120,180,255,.9a)` blur 10, width
  /// 2.2, round caps and joins; then the hot core: white `.9a`, blur 4, width 1.
  static func drawBolt(_ gc: GraphicsContext, _ bolt: StageBoltStroke, displayScale: Double = 1) {
    guard let first = bolt.points.first else { return }
    var path = Path()
    path.move(to: CGPoint(x: first.x, y: first.y))
    for p in bolt.points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
    let a = bolt.alpha
    pass(
      gc, path, stroke: StageBolts.outerColor.withAlpha(StageBolts.outerAlpha * a),
      shadow: StageBolts.shadowColor.withAlpha(StageBolts.shadowAlpha * a),
      blur: StageBolts.outerBlur, width: StageBolts.outerWidth, displayScale: displayScale)
    pass(
      gc, path, stroke: StageBolts.coreColor.withAlpha(StageBolts.coreAlpha * a),
      shadow: StageBolts.shadowColor.withAlpha(StageBolts.shadowAlpha * a),
      blur: StageBolts.coreBlur, width: StageBolts.coreWidth, displayScale: displayScale)
  }

  private static func pass(
    _ gc: GraphicsContext, _ path: Path, stroke: ScopeColor, shadow: ScopeColor, blur: Double,
    width: Double, displayScale: Double
  ) {
    let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    glow(
      gc, color: shadow, shapeAlpha: stroke.a, blur: blur, displayScale: displayScale
    ) { $0.stroke(path, with: $1, style: style) }
    gc.stroke(path, with: .color(stroke.color), style: style)
  }

  /// `fillStyle = rgba(255,240,210,.95a)`, shadow `rgba(255,220,150,.8a)` blur 10.
  static func drawSeed(_ gc: GraphicsContext, _ seed: StageSeedDot, displayScale: Double = 1) {
    let disc = Path(
      ellipseIn: CGRect(
        x: seed.x - seed.radius, y: seed.y - seed.radius, width: seed.radius * 2,
        height: seed.radius * 2))
    let fill = StageBolts.seedColor.withAlpha(StageBolts.seedAlpha * seed.alpha)
    glow(
      gc, color: StageBolts.seedShadowColor.withAlpha(StageBolts.seedShadowAlpha * seed.alpha),
      shapeAlpha: fill.a, blur: StageBolts.seedBlur, displayScale: displayScale
    ) { $0.fill(disc, with: $1) }
    gc.fill(disc, with: .color(fill.color))
  }

  /// A canvas shadow: the drawn shape's alpha, Gaussian-blurred with sigma = `shadowBlur / 2`
  /// device pixels, painted in the shadow colour with the shape's alpha folded in (the canvas
  /// takes the shadow from what was drawn, so a faint shape casts a faint shadow). `draw` paints
  /// the shape in the colour it is handed, inside the blur.
  private static func glow(
    _ gc: GraphicsContext, color: ScopeColor, shapeAlpha: Double, blur: Double,
    displayScale: Double, draw: (GraphicsContext, GraphicsContext.Shading) -> Void
  ) {
    gc.drawLayer { l in
      l.addFilter(.blur(radius: StageBolts.sigma(ofBlur: blur, displayScale: displayScale)))
      draw(l, .color(color.withAlpha(color.a * shapeAlpha).color))
    }
  }

  /// Two radial washes: a warm inner glow fading to nothing over the planet's radius, and a
  /// cooler rim that peaks near its surface. The canvas blends their stops as straight RGBA and
  /// SwiftUI premultiplied; the stops are resampled (`StageCanvasGradient`) to match the canvas.
  static func drawHalo(_ gc: GraphicsContext, _ halo: StageHalo) {
    let c = CGPoint(x: halo.centre.x, y: halo.centre.y)
    let r = halo.planetRadius
    let g = halo.glow
    func gradient(_ stops: [StageCanvasGradient.Stop]) -> Gradient {
      Gradient(
        stops: StageCanvasGradient.resampled(stops).map {
          Gradient.Stop(color: $0.color.color, location: $0.location)
        })
    }
    gc.fill(
      Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
      with: .radialGradient(
        gradient(StageBolts.haloInnerStops(glow: g)), center: c, startRadius: 0, endRadius: r))
    let outer = r * StageBolts.haloRimEnd
    gc.fill(
      Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)),
      with: .radialGradient(
        gradient(StageBolts.haloRimStops(glow: g)), center: c,
        startRadius: r * StageBolts.haloRimStart, endRadius: outer))
  }
}
