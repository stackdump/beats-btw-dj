import AppKit
import DJCore

// The bitmaps of the stage's backgrounds that never change from frame to frame, drawn once with
// Core Graphics and blitted every frame (the pattern of `RasterImage`).
//
// Why bitmaps: the sky and a planet's shading are canvas TWO-circle radial gradients
// (`createRadialGradient` with different centres), which SwiftUI's `Shading.radialGradient`
// (one centre) cannot express, and `CGContext.drawRadialGradient` can: it is the same
// construction, with the colour stops interpolated in straight RGBA, and both ends extended the
// way a canvas gradient extends them. Doing that once per size, rather than on every frame,
// costs nothing at 60 fps.
//
//   sky          the whole stage, one bitmap per size, at no more than ONE pixel per point and
//                no more than `skyMaxPixels` pixels whatever the display (the gradient is smooth
//                to a fraction of a level, so stretching it costs nothing visible; a window being
//                resized, or zoomed to full screen, rebuilds it every frame, and a fixed pixel
//                budget keeps that to about a millisecond at any size)
//   planet body  a small sprite per planet at the display's scale (the disc shaded, anti-aliased
//                at its true sub-pixel centre), rebuilt when the planet's radius, colour, place
//                or the display scale changes
//
// Everything geometric comes from `StageBackdrop` / `StagePlanet` / `StageTwoCircleGradient`
// (DJCore, unit-tested); this file only executes it.

enum StageBackdropImages {
  /// A bitmap of `wPx` x `hPx` device pixels whose drawing space is the stage's, in points with y
  /// down, the point (`originX`, `originY`) at its top-left corner.
  private static func context(
    wPx: Int, hPx: Int, scale: CGFloat, originX: Double = 0, originY: Double = 0
  ) -> CGContext? {
    guard wPx > 0, hPx > 0, scale > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(hPx))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: CGFloat(-originX), y: CGFloat(-originY))
    ctx.setShouldAntialias(true)
    return ctx
  }

  /// Draw `g` over everything the context's clip allows, extended past both circles.
  private static func fill(_ g: StageTwoCircleGradient, in ctx: CGContext) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let gradient = CGGradient(
        colorsSpace: space, colors: g.stops.map { $0.color.cgColor } as CFArray,
        locations: g.stops.map { CGFloat($0.offset) })
    else { return }
    ctx.drawRadialGradient(
      gradient, startCenter: CGPoint(x: g.start.x, y: g.start.y),
      startRadius: CGFloat(g.startRadius), endCenter: CGPoint(x: g.end.x, y: g.end.y),
      endRadius: CGFloat(g.endRadius), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }

  /// The most pixels the sky bitmap has (a 512 x 512 bitmap: about a millisecond to fill).
  static let skyMaxPixels = 1 << 18

  /// Pixels per point of the sky bitmap for a `width` x `height` stage: one, or fewer for a stage
  /// of more than `skyMaxPixels` points.
  static func skyScale(width: Double, height: Double) -> CGFloat {
    let area = width * height
    guard area > Double(skyMaxPixels) else { return 1 }
    return CGFloat((Double(skyMaxPixels) / area).squareRoot())
  }

  /// The stars background's sky for a `width` x `height` stage.
  static func sky(width: Double, height: Double, scale: CGFloat) -> CGImage? {
    let wPx = Int((width * Double(scale)).rounded())
    let hPx = Int((height * Double(scale)).rounded())
    guard
      let ctx = context(
        wPx: wPx, hPx: hPx, scale: scale)
    else { return nil }
    fill(StageBackdrop.sky(width: width, height: height), in: ctx)
    return ctx.makeImage()
  }

  /// A planet's shaded body, and where it goes: the sprite covers `rect` (whole points, so the
  /// bitmap lands on the pixel grid) and holds the disc of radius `r` about the planet's centre.
  struct Sprite {
    var image: CGImage
    var rect: CGRect
  }

  static func planetBody(
    _ planet: StagePlanet, width: Double, height: Double, scale: CGFloat
  ) -> Sprite? {
    let c = planet.center(width: width, height: height)
    let margin = 2.0
    let x0 = (c.x - planet.r).rounded(.down) - margin
    let y0 = (c.y - planet.r).rounded(.down) - margin
    let side = (planet.r * 2).rounded(.up) + 2 * margin + 1
    let px = Int((side * Double(scale)).rounded())
    guard let ctx = context(wPx: px, hPx: px, scale: scale, originX: x0, originY: y0)
    else { return nil }
    // the disc, then the gradient inside it (the JS's `arc` + `fill`)
    ctx.addEllipse(
      in: CGRect(
        x: c.x - planet.r, y: c.y - planet.r, width: planet.r * 2, height: planet.r * 2))
    ctx.clip()
    fill(planet.bodyGradient(width: width, height: height), in: ctx)
    guard let image = ctx.makeImage() else { return nil }
    return Sprite(image: image, rect: CGRect(x: x0, y: y0, width: side, height: side))
  }
}

/// The bitmaps for the size and planets last drawn.
@MainActor
final class StageBackdropCache {
  private struct SkyKey: Hashable {
    var width: Double
    var height: Double
  }

  private struct BodyKey: Hashable {
    var x: Double
    var y: Double
    var r: Double
    var body: ScopeColor
    var scale: Double
  }

  private var skyKey: SkyKey?
  private var skyImage: CGImage?
  private var bodies: [BodyKey: StageBackdropImages.Sprite] = [:]
  /// Bitmaps made so far (a test watches that a steady scene makes none after the first frame).
  private(set) var builds = 0

  init() {}

  /// The sky for a stage of `width` x `height` points: at most one pixel per point and at most
  /// `skyMaxPixels` pixels, to be drawn stretched over the stage's rectangle.
  func sky(width: Double, height: Double) -> CGImage? {
    let key = SkyKey(width: width, height: height)
    if key == skyKey { return skyImage }
    skyKey = key
    skyImage = StageBackdropImages.sky(
      width: width, height: height,
      scale: StageBackdropImages.skyScale(width: width, height: height))
    if skyImage != nil { builds += 1 }
    return skyImage
  }

  func body(_ planet: StagePlanet, width: Double, height: Double, scale: CGFloat)
    -> StageBackdropImages.Sprite?
  {
    let c = planet.center(width: width, height: height)
    let key = BodyKey(x: c.x, y: c.y, r: planet.r, body: planet.body, scale: Double(scale))
    if let known = bodies[key] { return known }
    // a respawn or a resize makes new keys: forget the old ones
    if bodies.count >= 12 { bodies.removeAll() }
    guard
      let sprite = StageBackdropImages.planetBody(
        planet, width: width, height: height, scale: scale)
    else { return nil }
    builds += 1
    bodies[key] = sprite
    return sprite
  }
}
