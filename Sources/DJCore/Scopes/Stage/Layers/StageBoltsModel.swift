import Foundation

// Macro bolts, seeds and the dark planet's halo (SPEC mode 17).
//
// While a macro runs, every hit also throws a jagged white-blue bolt from the fired transition at
// the dark planet in the middle of the ring; where it strikes it drops a spark that drifts inward
// and outlives the bolt, and the planet itself glows with how hard the bolts are landing.
// stage.js, in three places:
//
//     // stageOnTransitionFired, inside the FLAME branch (`vizModes.has('flame') && panel?.ringX != null`)
//     if (el._runningMacro && origin && session.boltsEnabled) {
//         session.bolts.push({ origin, born: performance.now(), life: 480, seed: Math.random() * 1000 });
//         if (session.bolts.length > 32) session.bolts.shift();
//     }
//     // renderBolts(now): alive = t < 1; boltEnergy += alpha (1 - t) for every alive bolt, even one
//     // that is skipped below; skip if the origin is within darkPlanetR + 2 of the centre; the end
//     // point is on the planet's surface; 12 segments, jitter along the normal;
//     // the first time a bolt is drawn it drops a seed (cap 48); then the seeds; then the halo
//     // `glow = min(1, boltEnergy * 0.55)`.
//
// The bolts and the seeds are state here (`advance`), the polylines are pure functions of the
// state and the clock (`strokes`, `seedDots`), because the jitter re-shuffles every frame:
// "crackles". The seeds are dropped in `advance` the first frame a bolt is drawable (it passes
// the planet guard), which is the JS "first time we render it".
//
// THE MACRO SIGNAL. `el._runningMacro` is beats' macro runtime's UI bookkeeping: set by
// `markMacroRunning` for the duration of any fired macro (mute, FX, pan, feel, tempo, beat repeat,
// one-shots), cleared by a wall-clock timer. This app's engine has the net-native macros only
// (`NetMacro`: mutes, beat repeat, tempo; and the stinger windows) and tells exactly when one is
// in effect: a pending mute restore or stinger window, a running beat repeat or a tempo effect. The audio
// thread stamps that on every hit it reports (`FireFlags.macro`), and the stage hands it on as
// `StageFire.macroRunning`. That is the flag a bolt keys on: per fire, per deck, so with two
// decks a macro on A throws no bolts from B's hits. (The JS flag is global.)
//
//   * Needs the bolts toggle AND the flame toggle (the JS spawns inside the flame branch; the
//     toolbar's tooltip says "(flame mode)"). Bolts that exist keep drawing with flame off.
//   * Turning the bolts toggle off clears bolts and seeds at once ("reads as off now").
//   * A rebuild (`reset()`) clears bolts and seeds.
//   * The planet's radius is `context.darkPlanetRadius`, 48 where the layout has none (the JS
//     `session.darkPlanetRadius || 48`).
//   * The random seed of a bolt is injected (`random`), the clock is the context's.

/// One bolt: where it started, when, and the phase that makes it crackle.
public struct StageBolt: Equatable, Sendable {
  public var origin: StagePoint
  public var bornMs: Double
  public var lifeMs: Double
  /// `Math.random() * 1000`.
  public var seed: Double
  /// The spark it dropped has been dropped (`b.seeded`).
  public var seeded = false

  public init(
    origin: StagePoint, bornMs: Double, lifeMs: Double = StageBolts.boltLifeMs, seed: Double
  ) {
    self.origin = origin
    self.bornMs = bornMs
    self.lifeMs = lifeMs
    self.seed = seed
  }
}

/// A spark on the planet's surface where a bolt struck.
public struct StageSeed: Equatable, Sendable {
  public var x: Double
  public var y: Double
  /// Unit vector pointing inward (toward the ring centre).
  public var ux: Double
  public var uy: Double
  public var bornMs: Double
  public var lifeMs: Double

  public init(
    x: Double, y: Double, ux: Double, uy: Double, bornMs: Double,
    lifeMs: Double = StageBolts.seedLifeMs
  ) {
    self.x = x
    self.y = y
    self.ux = ux
    self.uy = uy
    self.bornMs = bornMs
    self.lifeMs = lifeMs
  }
}

/// Where a bolt ends: the point on the planet's surface facing its origin.
public struct StageBoltStrike: Equatable, Sendable {
  public var end: StagePoint
  /// Unit vector from the origin toward the centre (inward).
  public var ux: Double
  public var uy: Double
  /// The unit normal `(-uy, ux)` the jitter runs along.
  public var nx: Double
  public var ny: Double
  /// Distance from the origin to `end`.
  public var length: Double
  /// `end - origin`.
  public var dx: Double
  public var dy: Double
}

/// A bolt as it is painted this frame.
public struct StageBoltStroke: Equatable, Sendable {
  /// 13 points: the origin, 11 jittered ones, the strike.
  public var points: [StagePoint]
  /// `Math.max(0, 1 - t)`.
  public var alpha: Double

  public init(points: [StagePoint], alpha: Double) {
    self.points = points
    self.alpha = alpha
  }
}

/// A seed as it is painted this frame: a warm disc with a glow.
public struct StageSeedDot: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var radius: Double
  public var alpha: Double

  public init(x: Double, y: Double, radius: Double, alpha: Double) {
    self.x = x
    self.y = y
    self.radius = radius
    self.alpha = alpha
  }
}

/// The halo's two washes, as the numbers the layer paints.
public struct StageHalo: Equatable, Sendable {
  /// `Math.min(1, boltEnergy * 0.55)`.
  public var glow: Double
  public var centre: StagePoint
  /// The dark planet's radius.
  public var planetRadius: Double

  public init(glow: Double, centre: StagePoint, planetRadius: Double) {
    self.glow = glow
    self.centre = centre
    self.planetRadius = planetRadius
  }
}

/// The numbers of the bolts, seeds and halo, as pure functions.
public enum StageBolts {
  /// `life: 480`.
  public static let boltLifeMs = 480.0
  /// `if (session.bolts.length > 32) session.bolts.shift()` after the push.
  public static let maxBolts = 32
  /// `life: 1100`.
  public static let seedLifeMs = 1100.0
  /// `if (session.seeds.length > 48) session.seeds.shift()` after the push.
  public static let maxSeeds = 48
  /// `session.darkPlanetRadius || 48`.
  public static let fallbackPlanetRadius = 48.0
  /// `if (distOrigin <= darkPlanetR + 2) continue`.
  public static let planetMargin = 2.0
  /// `const segs = 12`.
  public static let segments = 12
  /// `const amp = 26 * taper`.
  public static let amplitude = 26.0
  /// The two sines of the jitter: `sin(seed + i * 11.3 + now * 0.035) * amp` and
  /// `sin(seed * 0.7 + i * 3.1 + now * 0.07) * amp * 0.35`.
  public static let slowStep = 11.3
  public static let slowRate = 0.035
  public static let fastSeed = 0.7
  public static let fastStep = 3.1
  public static let fastRate = 0.07
  public static let fastWeight = 0.35

  /// `lineWidth = 2.2`, shadow blur 10 then the hot core's width 1, blur 4.
  public static let outerWidth = 2.2
  public static let outerBlur = 10.0
  public static let coreWidth = 1.0
  public static let coreBlur = 4.0
  /// The standard deviation, in POINTS, of the Gaussian a canvas `shadowBlur` of `blur` draws.
  ///
  /// It is half the blur, and the blur is in DEVICE pixels: the HTML canvas does not scale
  /// `shadowBlur` by the current transform, and stage.js sizes the flame canvas at `w * dpr` with
  /// `setTransform(dpr, ...)`. So on a 2x display the glow is 5 DEVICE px across for a blur of 10,
  /// which is 2.5 points (measured in Chrome at `devicePixelRatio` 1 and 2: the glow covers the
  /// same ~12 device pixels either way). `displayScale` is the points-to-pixels factor.
  public static func sigma(ofBlur blur: Double, displayScale: Double = 1) -> Double {
    blur / 2 / (displayScale > 0 ? displayScale : 1)
  }

  /// `rgba(200,225,255, 0.85 alpha)` stroke, `rgba(120,180,255, 0.9 alpha)` shadow.
  public static let outerColor = ScopeColor(r8: 200, g8: 225, b8: 255)
  public static let outerAlpha = 0.85
  public static let shadowColor = ScopeColor(r8: 120, g8: 180, b8: 255)
  public static let shadowAlpha = 0.9
  /// The hot core: white at 0.9 alpha.
  public static let coreColor = ScopeColor(r8: 255, g8: 255, b8: 255)
  public static let coreAlpha = 0.9

  /// Seeds: `rgba(255,240,210,0.95 alpha)` with a `rgba(255,220,150,0.8 alpha)` shadow of blur 10.
  public static let seedColor = ScopeColor(r8: 255, g8: 240, b8: 210)
  public static let seedAlpha = 0.95
  public static let seedShadowColor = ScopeColor(r8: 255, g8: 220, b8: 150)
  public static let seedShadowAlpha = 0.8
  public static let seedBlur = 10.0
  /// `planetR * 0.35 * (1 - (1 - t)^2)`.
  public static let seedDrift = 0.35

  /// The halo: inner wash `rgba(150,190,255, 0.22 glow)` -> `rgba(120,180,255,0)` over R; the
  /// rim `rgba(180,210,255, 0.18 glow)` at 0.55 of 0.6R...1.25R, transparent at both ends.
  public static let haloInnerColor = ScopeColor(r8: 150, g8: 190, b8: 255)
  public static let haloInnerAlpha = 0.22
  public static let haloEdgeColor = ScopeColor(r8: 120, g8: 180, b8: 255)
  public static let haloRimColor = ScopeColor(r8: 180, g8: 210, b8: 255)
  public static let haloRimAlpha = 0.18
  public static let haloRimStart = 0.6
  public static let haloRimEnd = 1.25
  public static let haloRimPeak = 0.55
  public static let glowPerEnergy = 0.55

  // MARK: pure

  /// `t = (now - born) / life`.
  public static func progress(bornMs: Double, lifeMs: Double, nowMs: Double) -> Double {
    (nowMs - bornMs) / lifeMs
  }

  /// `Math.max(0, 1 - t)`.
  public static func alpha(progress t: Double) -> Double { max(0, 1 - t) }

  /// `Math.min(1, boltEnergy * 0.55)`.
  public static func glow(energy: Double) -> Double { min(1, energy * glowPerEnergy) }

  /// The inner wash's stops: `rgba(150,190,255, 0.22 glow)` at the centre, `rgba(120,180,255,0)` at
  /// the planet's radius.
  public static func haloInnerStops(glow: Double) -> [StageCanvasGradient.Stop] {
    [
      (0, haloInnerColor.withAlpha(haloInnerAlpha * glow)),
      (1, haloEdgeColor.withAlpha(0)),
    ]
  }

  /// The rim's stops over `0.6 R ... 1.25 R`: transparent, `rgba(180,210,255, 0.18 glow)` at 0.55,
  /// transparent.
  public static func haloRimStops(glow: Double) -> [StageCanvasGradient.Stop] {
    [
      (0, haloEdgeColor.withAlpha(0)),
      (haloRimPeak, haloRimColor.withAlpha(haloRimAlpha * glow)),
      (1, haloEdgeColor.withAlpha(0)),
    ]
  }

  /// The strike of a bolt from `origin` at a planet of radius `planetR` centred on `centre`, or nil
  /// when the origin is inside (or within 2 of) the planet, or the bolt would be shorter than 2.
  public static func strike(origin o: StagePoint, centre c: StagePoint, planetR: Double)
    -> StageBoltStrike?
  {
    let dxAll = c.x - o.x
    let dyAll = c.y - o.y
    let distOrigin = hypot(dxAll, dyAll)
    if distOrigin <= planetR + planetMargin { return nil }
    let ux = dxAll / distOrigin
    let uy = dyAll / distOrigin
    let end = StagePoint(x: c.x - ux * planetR, y: c.y - uy * planetR)
    let dx = end.x - o.x
    let dy = end.y - o.y
    let len = hypot(dx, dy)
    if len < 2 { return nil }
    return StageBoltStrike(
      end: end, ux: ux, uy: uy, nx: -uy, ny: ux, length: len, dx: dx, dy: dy)
  }

  /// `taper = 1 - |f - 0.5| * 2` for segment `i` of 12 (0 at the ends, 1 in the middle).
  public static func taper(segment i: Int) -> Double {
    let f = Double(i) / Double(segments)
    return 1 - abs(f - 0.5) * 2
  }

  /// The perpendicular offset of interior point `i` (1...11): two sines, re-phased by the clock.
  public static func jitter(seed: Double, segment i: Int, nowMs: Double) -> Double {
    let amp = amplitude * taper(segment: i)
    let k = Double(i)
    return sin(seed + k * slowStep + nowMs * slowRate) * amp
      + sin(seed * fastSeed + k * fastStep + nowMs * fastRate) * amp * fastWeight
  }

  /// The polyline of a bolt: origin, interior points 1...11, then the strike point.
  public static func polyline(
    origin o: StagePoint, strike s: StageBoltStrike, seed: Double, nowMs: Double
  ) -> [StagePoint] {
    var pts = [o]
    pts.reserveCapacity(segments + 1)
    for i in 1..<segments {
      let f = Double(i) / Double(segments)
      let j = jitter(seed: seed, segment: i, nowMs: nowMs)
      pts.append(StagePoint(x: o.x + s.dx * f + s.nx * j, y: o.y + s.dy * f + s.ny * j))
    }
    pts.append(s.end)
    return pts
  }

  /// A seed at `nowMs`: drifting inward, shrinking, fading; nil once dead.
  public static func dot(of seed: StageSeed, planetR: Double, nowMs: Double) -> StageSeedDot? {
    let t = progress(bornMs: seed.bornMs, lifeMs: seed.lifeMs, nowMs: nowMs)
    if t >= 1 { return nil }
    let inward = planetR * seedDrift * (1 - (1 - t) * (1 - t))
    return StageSeedDot(
      x: seed.x + seed.ux * inward, y: seed.y + seed.uy * inward,
      radius: max(0.8, 2.2 * (1 - t) + 0.5), alpha: max(0, 1 - t))
  }
}

@MainActor
public final class StageBoltsModel: StageLayerModel {
  /// Live bolts, oldest first.
  public private(set) var bolts: [StageBolt] = []
  /// Live seeds, oldest first.
  public private(set) var seeds: [StageSeed] = []
  /// `boltEnergy` of the last frame: the sum of the alive bolts' alphas.
  public private(set) var energy = 0.0

  private let random: () -> Double

  /// `random` plays `Math.random()` (tests inject their own).
  public init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
    self.random = random
  }

  // MARK: frame

  public func advance(_ context: StageContext) {
    let nowMs = context.nowMs
    guard context.isOn(.bolts) else {
      // "Drain any in-flight bolts/seeds so disabling reads as 'off now'."
      bolts.removeAll()
      seeds.removeAll()
      energy = 0
      return
    }
    if context.isOn(.flame) {
      for fire in context.fires where fire.macroRunning { spawn(fire, context: context) }
    }

    // renderBolts: the alive ones, their energy, and a seed for each one drawn for the first time.
    let centre = context.ringCenter
    let planetR = context.darkPlanetRadius ?? StageBolts.fallbackPlanetRadius
    var alive: [StageBolt] = []
    var sum = 0.0
    for var b in bolts {
      let t = StageBolts.progress(bornMs: b.bornMs, lifeMs: b.lifeMs, nowMs: nowMs)
      if t >= 1 { continue }
      sum += StageBolts.alpha(progress: t)
      if !b.seeded, let s = StageBolts.strike(origin: b.origin, centre: centre, planetR: planetR) {
        b.seeded = true
        seeds.append(
          StageSeed(x: s.end.x, y: s.end.y, ux: s.ux, uy: s.uy, bornMs: nowMs))
        if seeds.count > StageBolts.maxSeeds { seeds.removeFirst() }
      }
      alive.append(b)
    }
    bolts = alive
    energy = sum
    // renderSeeds: the dead are dropped
    seeds.removeAll {
      StageBolts.progress(bornMs: $0.bornMs, lifeMs: $0.lifeMs, nowMs: nowMs) >= 1
    }
  }

  public func reset() {
    bolts.removeAll()
    seeds.removeAll()
    energy = 0
  }

  private func spawn(_ fire: StageFire, context: StageContext) {
    guard let i = fire.panel, context.panels.indices.contains(i),
      context.panels[i].ring != nil, let origin = fire.origin
    else { return }
    bolts.append(
      StageBolt(origin: origin, bornMs: fire.wallTime * 1000, seed: random() * 1000))
    if bolts.count > StageBolts.maxBolts { bolts.removeFirst() }
  }

  // MARK: what is painted

  /// The bolts to stroke at `nowMs`: the alive ones that clear the planet.
  public func strokes(in context: StageContext) -> [StageBoltStroke] {
    let nowMs = context.nowMs
    let planetR = context.darkPlanetRadius ?? StageBolts.fallbackPlanetRadius
    var out: [StageBoltStroke] = []
    for b in bolts {
      let t = StageBolts.progress(bornMs: b.bornMs, lifeMs: b.lifeMs, nowMs: nowMs)
      if t >= 1 { continue }
      guard
        let s = StageBolts.strike(origin: b.origin, centre: context.ringCenter, planetR: planetR)
      else { continue }
      out.append(
        StageBoltStroke(
          points: StageBolts.polyline(origin: b.origin, strike: s, seed: b.seed, nowMs: nowMs),
          alpha: StageBolts.alpha(progress: t)))
    }
    return out
  }

  /// The sparks to paint at `nowMs`.
  public func seedDots(in context: StageContext) -> [StageSeedDot] {
    let planetR = context.darkPlanetRadius ?? StageBolts.fallbackPlanetRadius
    return seeds.compactMap { StageBolts.dot(of: $0, planetR: planetR, nowMs: context.nowMs) }
  }

  /// The halo, while any bolt is alive.
  public func halo(in context: StageContext) -> StageHalo? {
    guard energy > 0 else { return nil }
    return StageHalo(
      glow: StageBolts.glow(energy: energy), centre: context.ringCenter,
      planetRadius: context.darkPlanetRadius ?? StageBolts.fallbackPlanetRadius)
  }
}
