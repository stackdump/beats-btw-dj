import DJCore
import SwiftUI
import Testing

@testable import DJViews

// Support for the background render tests (kept out of the `import Testing` file: it needs
// Foundation's trigonometry). The oracles below compute, on the CPU and from the DJCore
// numbers, what a pixel of each background should be; the tests compare the rendered pixels with
// them.

/// A background model and a context to drive it, no engine needed: the model is seeded, so the
/// stars and planets are the same on every run.
@MainActor
final class BackdropRig {
  let model: StageBackgroundModel
  private(set) var context: StageContext
  let width: Int
  let height: Int

  init(
    _ mode: StageBackground, seed: UInt64 = 5, width: Int = 800, height: Int = 600,
    seconds: Double = 0
  ) {
    var rng = StageSeededRandom(seed: seed)
    model = StageBackgroundModel(random: { rng.next() })
    self.width = width
    self.height = height
    context = StageContext(
      width: Double(width), height: Double(height),
      layout: StagePanelLayout.layoutRing(width: Double(width), height: Double(height), count: 0),
      bgMode: mode)
    show(mode, dt: 0)
    if seconds > 0 { show(mode, dt: seconds) }
  }

  /// A fixed scene: these stars and planets, drawn as they are (an empty `stars` would be
  /// respawned: park one far from what a test looks at).
  init(
    stars: [StageStar], planets: [StagePlanet], mode: StageBackground = .stars, width: Int = 800,
    height: Int = 600
  ) {
    model = StageBackgroundModel(stars: stars, planets: planets)
    self.width = width
    self.height = height
    context = StageContext(
      width: Double(width), height: Double(height),
      layout: StagePanelLayout.layoutRing(width: Double(width), height: Double(height), count: 0),
      bgMode: mode)
    show(mode, dt: 0)
  }

  /// One frame of `dt` seconds with `mode` selected.
  func show(_ mode: StageBackground, dt: Double) {
    context.bgMode = mode
    context.dt = dt
    model.advance(context)
  }

  /// The layer alone over the stage's own colour, as the host stacks them.
  var scene: some View {
    ZStack {
      StagePalette.background.color
      StageBackgroundLayer(context: context, model: model)
    }
  }

  func pixels() throws -> Pixels {
    try #require(renderPixels(scene, width: width, height: height))
  }

  func savePNG(_ name: String) {
    DJViewsTests.savePNG(scene, width: width, height: height, name: name)
  }

  var w: Double { Double(width) }
  var h: Double { Double(height) }

  /// Is no star within reach of (x, y)?
  func starFree(_ x: Double, _ y: Double) -> Bool {
    !model.stars.contains { hypot($0.x * w - x, $0.y * h - y) < $0.size + 3 }
  }

  /// Stars of at least `minSize` radius with no planet and no other star near them, and clear
  /// of the window's edge: the centre pixel of such a star is fully covered, so it shows
  /// exactly the star colour at the star's alpha.
  func isolatedStars(minSize: Double = 1.5) -> [StageStar] {
    model.stars.filter { s in
      let cx = s.x * w
      let cy = s.y * h
      guard s.size >= minSize, cx > 3, cy > 3, cx < w - 3, cy < h - 3 else { return false }
      let alone = model.stars.allSatisfy { o in
        o == s || hypot(o.x * w - cx, o.y * h - cy) > o.size + s.size + 2
      }
      let free = model.planets.allSatisfy { p in
        let c = p.center(width: w, height: h)
        return hypot(c.x - cx, c.y - cy) > p.ringOuter + 4
      }
      return alone && free
    }
  }
}

private func eight(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }

typealias BackdropRGB = (Int, Int, Int)

@MainActor
enum BackdropOracle {
  /// The centre of device pixel `v` in points, at `scale` pixels per point.
  private static func centre(_ v: Int, _ scale: Double) -> Double { (Double(v) + 0.5) / scale }

  /// The sky at the centre of pixel (x, y), as 8-bit channels.
  static func sky(_ x: Int, _ y: Int, w: Double, h: Double, scale: Double = 1) -> BackdropRGB {
    let c = StageBackdrop.sky(width: w, height: h).color(
      at: StagePoint(x: centre(x, scale), y: centre(y, scale)))!
    return (eight(c.r), eight(c.g), eight(c.b))
  }

  /// `fg` at `alpha` over `bg`.
  static func over(_ fg: ScopeColor, _ alpha: Double, _ bg: BackdropRGB) -> BackdropRGB {
    func mix(_ f: Double, _ b: Int) -> Int {
      Int((Double(b) + alpha * (f * 255 - Double(b))).rounded())
    }
    return (mix(fg.r, bg.0), mix(fg.g, bg.1), mix(fg.b, bg.2))
  }

  /// The aurora at the centre of pixel (x, y): the base plus every blob's premultiplied colour,
  /// 'lighter'.
  static func aurora(_ x: Int, _ y: Int, w: Double, h: Double, phase: Double) -> BackdropRGB {
    var r = StageBackdrop.auroraBase.r
    var g = StageBackdrop.auroraBase.g
    var b = StageBackdrop.auroraBase.b
    let p = StagePoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
    for blob in StageBackdrop.auroraBlobs(phase: phase) {
      guard let c = blob.gradient(width: w, height: h).color(at: p) else { continue }
      r += c.r * c.a
      g += c.g * c.a
      b += c.b * c.a
    }
    return (eight(r), eight(g), eight(b))
  }

  /// The planet's shaded body at the centre of pixel (x, y).
  static func body(
    _ planet: StagePlanet, _ x: Int, _ y: Int, w: Double, h: Double, scale: Double = 1
  ) -> BackdropRGB {
    let c = planet.bodyGradient(width: w, height: h).color(
      at: StagePoint(x: centre(x, scale), y: centre(y, scale)))!
    return (eight(c.r), eight(c.g), eight(c.b))
  }

  /// A point of the planet's ring ellipse at parameter `a`, in stage coordinates, turned by the
  /// tilt it has at `phase`.
  static func ringPoint(_ planet: StagePlanet, a: Double, phase: Double, w: Double, h: Double)
    -> (x: Double, y: Double)
  {
    let lx = planet.ringMid * cos(a)
    let ly = planet.ringY * sin(a)
    let t = planet.tilt(at: phase)
    let c = planet.center(width: w, height: h)
    return (c.x + lx * cos(t) - ly * sin(t), c.y + lx * sin(t) + ly * cos(t))
  }

  /// Is (x, y) free of every star and planet (so the sky or the aurora alone is there)?
  static func isClear(_ x: Double, _ y: Double, model: StageBackgroundModel, w: Double, h: Double)
    -> Bool
  {
    for s in model.stars where hypot(s.x * w - x, s.y * h - y) < s.size + 3 { return false }
    for p in model.planets {
      let c = p.center(width: w, height: h)
      if hypot(c.x - x, c.y - y) < p.ringOuter + 4 { return false }
    }
    return true
  }

  /// A spread of sample pixels over a `width` x `height` window, `count` at most, that are clear
  /// of stars and planets and satisfy `where`.
  static func clearPoints(
    model: StageBackgroundModel, width: Int, height: Int, count: Int, step: Int = 41,
    where allowed: (Int, Int) -> Bool = { _, _ in true }
  ) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var y = 7
    while y < height {
      var x = 5
      while x < width {
        if allowed(x, y),
          isClear(
            Double(x) + 0.5, Double(y) + 0.5, model: model, w: Double(width), h: Double(height))
        {
          out.append((x, y))
        }
        x += step
      }
      y += step
    }
    return Array(out.prefix(count))
  }

  static func clearPoints(_ rig: BackdropRig, count: Int, step: Int = 41) -> [(Int, Int)] {
    clearPoints(model: rig.model, width: rig.width, height: rig.height, count: count, step: step)
  }
}

func backdropRGB(_ p: Pixels, _ x: Int, _ y: Int) -> BackdropRGB {
  let c = p.color(x, y)
  return (c.r, c.g, c.b)
}

// MARK: - fixed scenes

/// Scenes with every number chosen, so a pixel can be said to belong to a star or a ring.
enum BackdropScene {
  /// A planet at the middle of an 800 x 600 stage that does not turn: body radius 40, ring outer
  /// 80 and inner 60 (so a stroke 20 wide along an ellipse of semi-axes 70 and 15.4), tilt 0, so
  /// the ring's major axis is the row y = 300 and its front half at x = 400 is the band
  /// y = 305.4...325.4 over the body.
  static let planet = StagePlanet(
    x: 0.5, y: 0.5, r: 40, ringRatio: 2, ringWidth: 0.25, tilt: 0, tiltRate: 0,
    body: StageBackdrop.planetPalette[0].body, ring: StageBackdrop.planetPalette[0].ring)

  /// A star at stage point (x, y) that is at its brightest at phase 0 (`sin(PI/2) = 1`, so its
  /// alpha is `bright`).
  static func star(x: Double, y: Double, size: Double, bright: Double = 0.75) -> StageStar {
    StageStar(
      x: x / 800, y: y / 600, size: size, bright: bright, twinkleRate: 0.5,
      phase: Double.pi / 2)
  }

  /// A star out of the way of everything near the middle (a fixed scene needs one: the model
  /// respawns an empty field).
  static let parked = star(x: 20, y: 580, size: 0.6, bright: 0.25)
}

/// What the pixels around a star say about its size: the star's colour's share of each pixel
/// (least squares over the three channels, against `base`), divided by the star's alpha and
/// summed, is the area of the disc in pixels, `PI r^2` (anti-aliased edges included).
func backdropStarArea(
  _ px: Pixels, star: StageStar, alpha: Double, scale: Double = 1, w: Double, h: Double,
  base: (Int, Int) -> BackdropRGB
) -> Double {
  let cx = star.x * w * scale
  let cy = star.y * h * scale
  let reach = Int(((star.size + 3) * scale).rounded(.up))
  let fg = StageBackdrop.starColor.rgb8
  var area = 0.0
  for y in Int(cy) - reach...Int(cy) + reach {
    for x in Int(cx) - reach...Int(cx) + reach {
      let b = base(x, y)
      let p = backdropRGB(px, x, y)
      let d = (Double(fg.r - b.0), Double(fg.g - b.1), Double(fg.b - b.2))
      let got = (Double(p.0 - b.0), Double(p.1 - b.1), Double(p.2 - b.2))
      let norm = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
      area += (got.0 * d.0 + got.1 * d.1 + got.2 * d.2) / norm / alpha
    }
  }
  return area / (scale * scale)
}
