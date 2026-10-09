import DJCore
import SwiftUI

// The stage's background (SPEC mode 18), under everything and OUTSIDE the container transform
// (stage.js: the bg canvas is not a child of the grid, so it neither spins nor tilts).
// Contract: StageLayerRegistry.swift. State and numbers: `StageBackgroundModel` and
// `StageBackdrop` (DJCore).
//
//   void     nothing: the stage's #0a0a1a, painted by the host, shows.
//   stars    the sky (a bitmap of its two-circle gradient, see StageBackdropImages), then each
//            planet (body, the ring's back half, the body again on top of it, the ring's front
//            half), then the stars. The planets are under the stars so the twinkles are
//            foreground.
//   aurora   the solid base, then four radial blobs added ('lighter' is `.plusLighter`).
//
// A pure function of the context and the model, drawn in stage coordinates: switching the
// select changes what the next frame paints and leaves nothing of the old background behind.

struct StageBackgroundLayer: View {
  let context: StageContext
  let model: StageBackgroundModel
  @State private var cache = StageBackdropCache()
  @Environment(\.displayScale) private var displayScale

  init(context: StageContext, model: StageBackgroundModel) {
    self.context = context
    self.model = model
  }

  var body: some View {
    Canvas { gc, _ in
      StageBackdropPainter.draw(
        &gc, context: context, model: model, scale: displayScale, cache: cache)
    }
    .allowsHitTesting(false)
  }
}

@MainActor
enum StageBackdropPainter {
  static func draw(
    _ gc: inout GraphicsContext, context: StageContext, model: StageBackgroundModel,
    scale: CGFloat, cache: StageBackdropCache
  ) {
    switch context.bgMode {
    case .void: break
    case .stars: drawStars(&gc, context: context, model: model, scale: scale, cache: cache)
    case .aurora: drawAurora(&gc, context: context, phase: model.phase)
    }
  }

  // MARK: stars

  static func drawStars(
    _ gc: inout GraphicsContext, context: StageContext, model: StageBackgroundModel,
    scale: CGFloat, cache: StageBackdropCache
  ) {
    let w = context.width
    let h = context.height
    if let sky = cache.sky(width: w, height: h) {
      // (stretched over the stage: the bitmap has at most one pixel per point, see
      // StageBackdropImages; smooth interpolation, so the gradient shows no blocks)
      gc.draw(
        Image(decorative: sky, scale: 1).interpolation(.high),
        in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    for planet in model.planets {
      drawPlanet(
        &gc, planet: planet, phase: model.phase, context: context, scale: scale, cache: cache)
    }
    for star in model.stars {
      let alpha = star.alpha(at: model.phase)
      gc.fill(
        Path(
          ellipseIn: CGRect(
            x: star.x * w - star.size, y: star.y * h - star.size, width: star.size * 2,
            height: star.size * 2)),
        with: .color(StageBackdrop.starColor.withAlpha(alpha).color))
    }
  }

  /// `renderPlanets` for one planet.
  static func drawPlanet(
    _ gc: inout GraphicsContext, planet: StagePlanet, phase: Double, context: StageContext,
    scale: CGFloat, cache: StageBackdropCache
  ) {
    let w = context.width
    let h = context.height
    let sprite = cache.body(planet, width: w, height: h, scale: scale)
    func drawBody(_ gc: inout GraphicsContext) {
      guard let sprite else { return }
      gc.draw(Image(decorative: sprite.image, scale: scale), in: sprite.rect)
    }
    drawBody(&gc)
    // the back half, dimmer, behind the body; the body again on top of it (cheap occlusion),
    // then the front half
    ring(&gc, planet: planet, half: .back, phase: phase, width: w, height: h)
    drawBody(&gc)
    ring(&gc, planet: planet, half: .front, phase: phase, width: w, height: h)
  }

  /// One half of the ring, in the planet's frame rotated by its tilt: the outline of the
  /// half-ellipse's stroke (`StagePlanet.ringOutline`), filled. Not a stroke call: see there.
  static func ring(
    _ gc: inout GraphicsContext, planet: StagePlanet, half: StagePlanet.RingHalf, phase: Double,
    width: Double, height: Double
  ) {
    let c = planet.center(width: width, height: height)
    var g = gc
    g.translateBy(x: c.x, y: c.y)
    g.rotate(by: .radians(planet.tilt(at: phase)))
    var path = Path()
    path.addLines(planet.ringOutline(half).map(\.cgPoint))
    path.closeSubpath()
    let alpha = half == .back ? StagePlanet.backAlpha : StagePlanet.frontAlpha
    g.fill(path, with: .color(planet.ring.withAlpha(alpha).color), style: FillStyle(eoFill: false))
  }

  // MARK: aurora

  static func drawAurora(_ gc: inout GraphicsContext, context: StageContext, phase: Double) {
    let w = context.width
    let h = context.height
    let full = Path(CGRect(x: 0, y: 0, width: w, height: h))
    // a solid base, so switching from stars leaves no speckle
    gc.fill(full, with: .color(StageBackdrop.auroraBase.color))
    var g = gc
    g.blendMode = .plusLighter
    for blob in StageBackdrop.auroraBlobs(phase: phase) {
      let gradient = blob.gradient(width: w, height: h)
      // (resampled: SwiftUI blends premultiplied colours, a canvas gradient blends straight ones)
      g.fill(
        full,
        with: .radialGradient(
          Gradient(
            stops: gradient.sampledStops().map {
              Gradient.Stop(color: $0.color.color, location: $0.offset)
            }),
          center: CGPoint(x: gradient.start.x, y: gradient.start.y), startRadius: 0,
          endRadius: gradient.endRadius))
    }
  }
}

extension StagePoint {
  fileprivate var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
