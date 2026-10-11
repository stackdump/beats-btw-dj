import Foundation

// StageBackdrop: the numbers of the stage's three backgrounds (SPEC mode 18; stage.js
// `spawnStars`, `spawnPlanets`, `renderStars`, `renderPlanets`, `renderAurora`), as values with
// unit tests. `StageBackgroundModel` owns the state (stars, planets, the phase clock) and
// `StageBackgroundLayer` (DJViews) only draws what these say.
//
// void     nothing is drawn (the stage's own #0a0a1a shows).
// stars    an indigo sky (a two-circle radial gradient), two or three ringed planets, and 150
//          twinkling stars. The planets sit UNDER the stars so the twinkles are foreground.
// aurora   a solid #07061a base and four large radial blobs whose centres orbit, added together
//          ('lighter').
//
// Canvas semantics worth knowing (the layer relies on them):
//   * `createRadialGradient(x0, y0, r0, x1, y1, r1)` is a TWO-circle gradient: the sky's circles
//     do not share a centre (the glow starts at (0.5w, 0.32h) and fades out around (0.5w, 0.5h)),
//     and a planet's lit spot sits up and left of its centre. `StageTwoCircleGradient` is that
//     gradient, with the colour a given point gets.
//   * Colour stops interpolate in RGBA WITHOUT premultiplying alpha, so an aurora blob fading to
//     `rgba(7, 6, 26, 0)` also moves its colour towards (7, 6, 26) on the way.
//   * 'lighter' adds premultiplied colours and clamps; over an opaque base it is
//     `base + colour * alpha`.

// MARK: - stars

/// One twinkling star (`spawnStars`): position as a fraction of the stage, radius in points.
public struct StageStar: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var size: Double
  public var bright: Double
  public var twinkleRate: Double
  public var phase: Double

  public init(
    x: Double, y: Double, size: Double, bright: Double, twinkleRate: Double, phase: Double
  ) {
    self.x = x
    self.y = y
    self.size = size
    self.bright = bright
    self.twinkleRate = twinkleRate
    self.phase = phase
  }

  /// `0.55 + 0.45 * sin(t * twinkleRate + phase)`.
  public func twinkle(at t: Double) -> Double { 0.55 + 0.45 * sin(t * twinkleRate + phase) }

  /// The fill alpha: `(bright * twinkle).toFixed(3)`, so rounded to three decimals like the
  /// string the canvas gets.
  public func alpha(at t: Double) -> Double { ((bright * twinkle(at: t)) * 1000).rounded() / 1000 }
}

// MARK: - planets

/// One ringed planet (`spawnPlanets`): position as a fraction of the stage, sizes in points.
public struct StagePlanet: Equatable, Sendable {
  public var x: Double
  public var y: Double
  /// Body radius.
  public var r: Double
  /// The ring's outer radius over the body's.
  public var ringRatio: Double
  /// The ring's thickness as a fraction of its outer radius.
  public var ringWidth: Double
  /// The ring's rotation at phase 0, radians.
  public var tilt: Double
  /// Radians per second.
  public var tiltRate: Double
  public var body: ScopeColor
  /// The ring's colour; its alpha is set per half (`backAlpha`, `frontAlpha`).
  public var ring: ScopeColor
  /// Which of `StageBackdrop.planetSlots` it was placed in.
  public var slot: Int

  public init(
    x: Double, y: Double, r: Double, ringRatio: Double, ringWidth: Double, tilt: Double,
    tiltRate: Double, body: ScopeColor, ring: ScopeColor, slot: Int = 0
  ) {
    self.x = x
    self.y = y
    self.r = r
    self.ringRatio = ringRatio
    self.ringWidth = ringWidth
    self.tilt = tilt
    self.tiltRate = tiltRate
    self.body = body
    self.ring = ring
    self.slot = slot
  }

  /// The half of the ring behind the body (dimmer: occluded) and the half in front.
  public static let backAlpha = 0.18
  public static let frontAlpha = 0.42

  public var ringOuter: Double { r * ringRatio }
  public var ringInner: Double { ringOuter * (1 - ringWidth) }
  /// The stroked ellipse's semi-major axis: the middle of the annulus.
  public var ringMid: Double { (ringOuter + ringInner) * 0.5 }
  /// The stroke width.
  public var ringThickness: Double { ringOuter - ringInner }
  /// The stroked ellipse's semi-minor axis: the ring flattened to 22%.
  public var ringY: Double { ringMid * 0.22 }

  /// The ring's rotation at phase `t` seconds: `tilt + t * tiltRate`.
  public func tilt(at t: Double) -> Double { tilt + t * tiltRate }

  public func center(width: Double, height: Double) -> StagePoint {
    StagePoint(x: x * width, y: y * height)
  }

  /// The body's shading (`createRadialGradient(cx - 0.35r, cy - 0.35r, 0.1r, cx, cy, r)`): lit
  /// from the upper left, the body colour fading to the sky's darkest.
  public func bodyGradient(width: Double, height: Double) -> StageTwoCircleGradient {
    let c = center(width: width, height: height)
    return StageTwoCircleGradient(
      start: StagePoint(x: c.x - r * 0.35, y: c.y - r * 0.35), startRadius: r * 0.1,
      end: c, endRadius: r,
      stops: [
        StageGradientStop(offset: 0, color: body),
        StageGradientStop(offset: 1, color: StageBackdrop.skyDark),
      ])
  }

  public enum RingHalf: Sendable {
    /// `ellipse(0, 0, ringMid, ringY, 0, PI, 2 PI)`: the half at negative y (before the tilt).
    case back
    /// `ellipse(0, 0, ringMid, ringY, 0, 0, PI)`: the half at positive y.
    case front
  }

  /// The outline of the half ring's STROKE, a closed polygon in the planet's own (rotated) frame
  /// to be filled (non-zero winding): the stroke of the ellipse arc with butt caps and a line
  /// `ringThickness` wide, built the way a canvas builds it.
  ///
  /// The ellipse point at angle `a` is `(ringMid cos a, ringY sin a)`; the back half runs from
  /// angle PI to 2 PI, the front half from 0 to PI. The outline goes out along the OUTER offset
  /// curve (the point plus half the thickness along the ellipse's unit normal), then back along
  /// the INNER one, and the two straight closing edges are the butt caps, each exactly square to
  /// the tangent (which is vertical at the ellipse's tips, so the caps are horizontal there).
  ///
  /// Why not hand the arc to a stroker: at the tips the stroke is wider than twice the curvature
  /// radius (`ringY^2 / ringMid`), the inner offset curve folds over itself, and what that fold
  /// looks like is the stroker's. The canvas fills the offset outline as it is (a small arrowhead
  /// where the front half's fold spills across the major axis); a polyline or Bézier handed to
  /// CoreGraphics is flattened into chords whose caps are a few degrees off the tangent and whose
  /// fold is a larger wedge. Filling the offset outline itself gives the canvas's shape.
  public func ringOutline(_ half: RingHalf, segments: Int = 192) -> [StagePoint] {
    let start = half == .back ? Double.pi : 0
    let n = max(1, segments)
    let halfWidth = ringThickness * 0.5
    var outer: [StagePoint] = []
    var inner: [StagePoint] = []
    outer.reserveCapacity(n + 1)
    inner.reserveCapacity(n + 1)
    for i in 0...n {
      let a = start + Double.pi * Double(i) / Double(n)
      let c = cos(a)
      let s = sin(a)
      // the normal of (ringMid cos a, ringY sin a) is (ringY cos a, ringMid sin a)
      let nx = ringY * c
      let ny = ringMid * s
      let len = (nx * nx + ny * ny).squareRoot()
      let ux = nx / len
      let uy = ny / len
      let px = ringMid * c
      let py = ringY * s
      outer.append(StagePoint(x: px + halfWidth * ux, y: py + halfWidth * uy))
      inner.append(StagePoint(x: px - halfWidth * ux, y: py - halfWidth * uy))
    }
    return outer + inner.reversed()
  }
}

// MARK: - the gradient canvas calls radial

public struct StageGradientStop: Equatable, Sendable {
  public var offset: Double
  public var color: ScopeColor

  public init(offset: Double, color: ScopeColor) {
    self.offset = offset
    self.color = color
  }
}

/// `createRadialGradient(x0, y0, r0, x1, y1, r1)` with its colour stops.
///
/// The circle at parameter `t` has centre `start + t (end - start)` and radius
/// `startRadius + t (endRadius - startRadius)`. A point takes the colour of the LARGEST `t` whose
/// circle (with a non-negative radius) passes through it, `t` clamped to 0...1 for the colour: a
/// gradient whose circles are nested paints the whole plane, extended past both ends.
public struct StageTwoCircleGradient: Equatable, Sendable {
  public var start: StagePoint
  public var startRadius: Double
  public var end: StagePoint
  public var endRadius: Double
  public var stops: [StageGradientStop]

  public init(
    start: StagePoint, startRadius: Double, end: StagePoint, endRadius: Double,
    stops: [StageGradientStop]
  ) {
    self.start = start
    self.startRadius = startRadius
    self.end = end
    self.endRadius = endRadius
    self.stops = stops
  }

  /// The gradient parameter at `p` (unclamped), nil when no circle of the gradient reaches it.
  public func parameter(at p: StagePoint) -> Double? {
    let dx = p.x - start.x
    let dy = p.y - start.y
    let cx = end.x - start.x
    let cy = end.y - start.y
    let dr = endRadius - startRadius
    // |d - t c|^2 = (r0 + t dr)^2  ->  a t^2 - 2 b t + c0 = 0
    let a = cx * cx + cy * cy - dr * dr
    let b = dx * cx + dy * cy + startRadius * dr
    let c0 = dx * dx + dy * dy - startRadius * startRadius
    var roots: [Double] = []
    if abs(a) < 1e-12 {
      if abs(b) > 1e-12 { roots = [c0 / (2 * b)] }
    } else {
      let disc = b * b - a * c0
      if disc >= 0 {
        let s = disc.squareRoot()
        roots = [(b + s) / a, (b - s) / a]
      }
    }
    return roots.filter { startRadius + $0 * dr >= 0 }.max()
  }

  /// The colour at `t`: linear in RGBA without premultiplying, clamped to the first and last stop.
  public func color(at t: Double) -> ScopeColor {
    guard let first = stops.first, let last = stops.last else {
      return ScopeColor(r: 0, g: 0, b: 0, a: 0)
    }
    if t <= first.offset { return first.color }
    if t >= last.offset { return last.color }
    for i in 1..<stops.count where t <= stops[i].offset {
      let lo = stops[i - 1]
      let hi = stops[i]
      let f = hi.offset > lo.offset ? (t - lo.offset) / (hi.offset - lo.offset) : 1
      return ScopeColor.lerp(lo.color, hi.color, f)
    }
    return last.color
  }

  /// The colour a point is painted with; nil where the gradient paints nothing.
  public func color(at p: StagePoint) -> ScopeColor? {
    parameter(at: p).map { color(at: $0) }
  }

  /// The stops resampled at `segments + 1` evenly spaced offsets between the first and the last.
  ///
  /// For a renderer that interpolates PREMULTIPLIED colours (SwiftUI's gradients do): a premultiplied
  /// blend of two stops that differ in alpha is not the straight blend a canvas makes (a blob
  /// fading to `rgba(7, 6, 26, 0)` would stay too bright through the middle: about 5 levels of
  /// 255 at its centre-to-edge midpoint on the aurora). Sampled densely from the straight blend,
  /// the piecewise-premultiplied curve follows it to well under a level (the error of a
  /// piecewise-linear fit of the quadratic `colour * alpha` is `(step^2 / 8) * 2 * dc * da`).
  public func sampledStops(segments: Int = 16) -> [StageGradientStop] {
    guard let first = stops.first, let last = stops.last, segments > 0 else { return stops }
    return (0...segments).map { i in
      let offset = first.offset + (last.offset - first.offset) * Double(i) / Double(segments)
      return StageGradientStop(offset: offset, color: color(at: offset))
    }
  }
}

extension ScopeColor {
  /// Straight (non-premultiplied) linear interpolation of the four components.
  static func lerp(_ a: ScopeColor, _ b: ScopeColor, _ f: Double) -> ScopeColor {
    ScopeColor(
      r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f,
      a: a.a + (b.a - a.a) * f)
  }
}

// MARK: - aurora

/// One aurora blob: centre and radius as fractions of the stage (the radius of `max(w, h)`).
public struct StageAuroraBlob: Equatable, Sendable {
  public var cx: Double
  public var cy: Double
  public var r: Double
  public var color: ScopeColor

  public init(cx: Double, cy: Double, r: Double, color: ScopeColor) {
    self.cx = cx
    self.cy = cy
    self.r = r
    self.color = color
  }

  /// Centre in points.
  public func center(width: Double, height: Double) -> StagePoint {
    StagePoint(x: cx * width, y: cy * height)
  }

  /// Radius in points: `r * max(w, h)`.
  public func radius(width: Double, height: Double) -> Double { r * max(width, height) }

  /// The blob's gradient: its colour at the centre, fading to `rgba(7, 6, 26, 0)` at the radius.
  public func gradient(width: Double, height: Double) -> StageTwoCircleGradient {
    let c = center(width: width, height: height)
    return StageTwoCircleGradient(
      start: c, startRadius: 0, end: c, endRadius: radius(width: width, height: height),
      stops: [
        StageGradientStop(offset: 0, color: color),
        StageGradientStop(offset: 1, color: StageBackdrop.auroraFade),
      ])
  }
}

// MARK: - the whole set

public enum StageBackdrop {
  // MARK: stars

  /// `spawnStars`: 150 stars.
  public static let starCount = 150

  /// The star colour, `rgba(210, 220, 250, alpha)`.
  public static let starColor = ScopeColor(r8: 210, g8: 220, b8: 250)

  /// `spawnStars`: 150 stars, six random numbers each, in this order: x, y, size
  /// `0.6 + r * 1.4`, brightness `0.25 + r * 0.55`, twinkle rate `0.3 + r * 1.1`, phase
  /// `r * 2 PI`. `random` is `Math.random()`: a number in [0, 1).
  public static func makeStars(random: () -> Double) -> [StageStar] {
    (0..<starCount).map { _ in
      let x = random()
      let y = random()
      let size = 0.6 + random() * 1.4
      let bright = 0.25 + random() * 0.55
      let rate = 0.3 + random() * 1.1
      let phase = random() * Double.pi * 2
      return StageStar(x: x, y: y, size: size, bright: bright, twinkleRate: rate, phase: phase)
    }
  }

  // MARK: planets

  /// Corner slots (x and y as fractions of the stage), "biased toward corners so they don't
  /// crowd the meta-ring".
  public static let planetSlots: [(x: Double, y: Double)] = [
    (0.12, 0.18), (0.88, 0.22), (0.18, 0.82), (0.84, 0.78),
  ]

  /// The muted-dark palette: dusty violet, cool slate blue, dim rust, sea-foam. The ring colour
  /// is the `rgba(r, g, b,` prefix of the JS with its alpha left to the half being drawn.
  public static let planetPalette: [(body: ScopeColor, ring: ScopeColor)] = [
    (ScopeColor(hex: "#5a3e8c")!, ScopeColor(r8: 200, g8: 180, b8: 240)),
    (ScopeColor(hex: "#3e5a8c")!, ScopeColor(r8: 170, g8: 200, b8: 240)),
    (ScopeColor(hex: "#8c5a3e")!, ScopeColor(r8: 240, g8: 200, b8: 170)),
    (ScopeColor(hex: "#3e8c6d")!, ScopeColor(r8: 170, g8: 240, b8: 210)),
  ]

  /// `spawnPlanets`: two or three planets in distinct corner slots.
  ///
  /// The random numbers are drawn in this order: the slot shuffle (three, see below), the count
  /// (`2 + (r < 0.5 ? 0 : 1)`), then per planet the palette entry `floor(r * 4)`, x jitter
  /// `(r - 0.5) * 0.05`, y jitter, radius `22 + r * 26`, ring ratio `1.8 + r * 0.6`, ring width
  /// `0.18 + r * 0.12`, tilt `r * PI`, the tilt rate's sign (`r < 0.5` is negative) and its size
  /// `0.03 + r * 0.04`.
  ///
  /// The JS shuffles with `slots.sort(() => Math.random() - 0.5)`: an inconsistent comparator,
  /// whose outcome is up to the engine's sort and not uniform. Measured in node (V8, as Chrome;
  /// 400,000 runs of `[0, 1, 2, 3].sort(...)`): the first slot is slot 0, 1, 2, 3 with probability
  /// 0.36, 0.14, 0.19, 0.31 (uniform: 0.25 each), and a slot is among the first three with
  /// 0.69, 0.91, 0.72, 0.69 (uniform: 0.75), so in Chrome the top-right corner (slot 1) holds a
  /// planet in 91% of the three-planet layouts, and the top-left and bottom-right corners are
  /// favoured as the first planet. The comparator also draws 3, 5 or 6 numbers (25%, 50%, 25%)
  /// where this draws three, so even one random stream would not line up afterwards. This is a
  /// Fisher-Yates shuffle (three draws): every corner equally likely.
  public static func makePlanets(random: () -> Double) -> [StagePlanet] {
    var order = Array(planetSlots.indices)
    var i = order.count - 1
    while i > 0 {
      let j = Int((random() * Double(i + 1)).rounded(.down))
      order.swapAt(i, min(j, i))
      i -= 1
    }
    let count = 2 + (random() < 0.5 ? 0 : 1)
    var planets: [StagePlanet] = []
    for n in 0..<count {
      let slot = order[n]
      let palette = planetPalette[min(planetPalette.count - 1, Int((random() * 4).rounded(.down)))]
      let x = planetSlots[slot].x + (random() - 0.5) * 0.05
      let y = planetSlots[slot].y + (random() - 0.5) * 0.05
      let r = 22 + random() * 26
      let ringRatio = 1.8 + random() * 0.6
      let ringWidth = 0.18 + random() * 0.12
      let tilt = random() * Double.pi
      let sign: Double = random() < 0.5 ? -1 : 1
      let tiltRate = sign * (0.03 + random() * 0.04)
      planets.append(
        StagePlanet(
          x: x, y: y, r: r, ringRatio: ringRatio, ringWidth: ringWidth, tilt: tilt,
          tiltRate: tiltRate, body: palette.body, ring: palette.ring, slot: slot))
    }
    return planets
  }

  // MARK: the sky

  /// `#161530`, `#0c0b20` and `#05041a`: the sky from its glow to its edge. The last is also what
  /// a planet's body shades to.
  public static let skyGlow = ScopeColor(hex: "#161530")!
  public static let skyMid = ScopeColor(hex: "#0c0b20")!
  public static let skyDark = ScopeColor(hex: "#05041a")!

  /// The stars background's gradient: lighter toward the upper centre, fading to near black at
  /// the edges. `createRadialGradient(0.5w, 0.32h, 0, 0.5w, 0.5h, 0.85 max(w, h))`.
  public static func sky(width w: Double, height h: Double) -> StageTwoCircleGradient {
    StageTwoCircleGradient(
      start: StagePoint(x: w * 0.5, y: h * 0.32), startRadius: 0,
      end: StagePoint(x: w * 0.5, y: h * 0.5), endRadius: max(w, h) * 0.85,
      stops: [
        StageGradientStop(offset: 0, color: skyGlow),
        StageGradientStop(offset: 0.6, color: skyMid),
        StageGradientStop(offset: 1, color: skyDark),
      ])
  }

  // MARK: aurora

  /// The solid base the blobs are added to.
  public static let auroraBase = ScopeColor(hex: "#07061a")!
  /// Where every blob fades to: `rgba(7, 6, 26, 0)`.
  public static let auroraFade = ScopeColor(r8: 7, g8: 6, b8: 26, a: 0)

  /// `renderAurora`'s blob table at phase `p` seconds: the centres orbit independently, slowly
  /// (the fastest has a period of about 105 s). Literally the JS.
  public static func auroraBlobs(phase p: Double) -> [StageAuroraBlob] {
    [
      StageAuroraBlob(
        cx: 0.25 + 0.12 * sin(p * 0.09), cy: 0.30 + 0.15 * cos(p * 0.07), r: 0.55,
        color: ScopeColor(r8: 30, g8: 22, b8: 90, a: 0.18)),
      StageAuroraBlob(
        cx: 0.78 + 0.10 * sin(p * 0.11 + 1.5), cy: 0.40 + 0.12 * cos(p * 0.06 + 2), r: 0.50,
        color: ScopeColor(r8: 90, g8: 18, b8: 60, a: 0.14)),
      StageAuroraBlob(
        cx: 0.50 + 0.18 * sin(p * 0.05 + 3), cy: 0.80 + 0.10 * cos(p * 0.08 + 1), r: 0.60,
        color: ScopeColor(r8: 12, g8: 45, b8: 90, a: 0.18)),
      StageAuroraBlob(
        cx: 0.65 + 0.14 * sin(p * 0.075 + 4), cy: 0.15 + 0.10 * cos(p * 0.095), r: 0.45,
        color: ScopeColor(r8: 70, g8: 30, b8: 10, a: 0.10)),
    ]
  }
}
