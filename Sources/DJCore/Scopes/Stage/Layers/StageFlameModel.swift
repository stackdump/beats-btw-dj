import Foundation

// Flame beams (SPEC mode 15): "a radial equalizer anchored at the ring centre".
//
// One beam per panel, shot from the centre toward the transition that fired last on that panel,
// brightened by an energy that every fire bumps and every frame decays. stage.js:
//
//     // stageOnTransitionFired, `vizModes.has('flame') && panel?.ringX != null`
//     flameEnergy.set(netId, min(1, prev + 0.9));  if (origin) panel.flameOrigin = origin;
//
//     // renderFlame(dt), every frame, for each panel
//     v = energy * exp(-dt * 4);  if (v < 0.01) { delete; continue }
//     halfAng = min(0.10, n > 0 ? (pi / n) * 0.15 : 0.10);  innerR = min(cx, cy) * 0.10
//     target = flameOrigin ?? (ringX, ringY);  dist = hypot(target - c) || 1;  theta = atan2
//     barLen = max(innerR + 4, dist * (0.55 + 0.4 v))
//     polygon: c + innerR at theta -+ halfAng, c + barLen at theta +- halfAng * 0.25
//     gradient c -> c + barLen at theta:  rgba(255,200,64,0.85 v) @0, rgba(233,69,96,0.7 v) @0.5,
//                                          rgba(74,144,217,0) @1
//
// Here the hook is `StageContext.fires` and the frame is `advance`: the frame's fires bump
// energies first (they arrived between two frames), then the decay and the 0.01 floor apply, and
// the stored energy is the one the beam is drawn with (the JS stores `v` back too). Pure geometry
// (`StageFlame`) takes the stored energies and the context's panel positions, so the layer
// holds no state of its own.
//
//   * Energy and origin are kept per PANEL (its stable `id`), where the JS keys energy by the
//     net's id and keeps `flameOrigin` on the panel. They differ only when a riff-group panel
//     flips to another variant: the JS then leaves the old net's energy stranded under its old
//     key (it neither decays nor draws again until the panel flips back), this keeps the beam
//     with the panel and lets it decay. Two decks with a net of the same id cannot collide either.
//   * A lone panel has no ring position (`StagePanel.ring == nil`): no beam, no energy.
//   * Toggling flame off clears the energies (the origins stay on their panels, as in the JS)
//     and nothing is drawn; a rebuild (`reset()`) clears both.
//   * The bolts (mode 17) spawn in the JS flame branch; see `StageBoltsModel`.

/// One beam, ready to fill: a polygon and the gradient that colours it.
public struct StageFlameBeam: Equatable, Sendable {
  /// The panel it belongs to.
  public var panelId: String
  /// The stored (post-decay) energy, 0.01...1.
  public var energy: Double
  /// The two base corners at `innerR` (theta -+ halfAng), then the two tip corners at `barLen`
  /// (theta +- halfAng * 0.25).
  public var base1: StagePoint
  public var base2: StagePoint
  public var tip2: StagePoint
  public var tip1: StagePoint
  /// The gradient runs from the ring centre to here (`barLen` along theta).
  public var gradientStart: StagePoint
  public var gradientEnd: StagePoint
  public var theta: Double
  public var barLength: Double

  /// The four corners in drawing order: moveTo(1), lineTo(2), lineTo(3), lineTo(4).
  public var polygon: [StagePoint] { [base1, base2, tip2, tip1] }

  /// The gradient's three stops: location and colour.
  public var stops: [(location: Double, color: ScopeColor)] { StageFlame.stops(energy: energy) }

  /// The same gradient as a SwiftUI gradient needs it to look like the canvas one (see
  /// `StageCanvasGradient`).
  public var paintStops: [(location: Double, color: ScopeColor)] {
    StageCanvasGradient.resampled(stops)
  }
}

/// The numbers of the flame, as pure functions.
public enum StageFlame {
  /// `min(1, prev + 0.9)`.
  public static let bump = 0.9
  /// `Math.exp(-dt * 4)`.
  public static let decayRate = 4.0
  /// `if (v < 0.01) delete`.
  public static let floor = 0.01
  /// `Math.min(0.10, ...)`.
  public static let maxHalfAngle = 0.10
  /// `(Math.PI / n) * 0.15`.
  public static let halfAngleOfPanel = 0.15
  /// `innerR = Math.min(cx, cy) * 0.10`.
  public static let innerRadiusOfCentre = 0.10
  /// `Math.max(innerR + 4, ...)`.
  public static let minReach = 4.0
  /// `dist * (0.55 + 0.4 * v)`.
  public static let reachBase = 0.55
  public static let reachEnergy = 0.4
  /// The tip is a quarter as wide as the base: `halfAng * 0.25`.
  public static let tipTaper = 0.25

  public static let amber = ScopeColor(r8: 255, g8: 200, b8: 64)
  public static let rose = ScopeColor(r8: 233, g8: 69, b8: 96)
  public static let blue = ScopeColor(r8: 74, g8: 144, b8: 217)

  /// A fire on a panel: `Math.min(1, prev + 0.9)`.
  public static func bumped(_ energy: Double) -> Double { min(1, energy + bump) }

  /// One frame of decay: `energy * Math.exp(-dt * 4)`. The caller drops it below `floor`.
  public static func decayed(_ energy: Double, dt: Double) -> Double {
    energy * exp(-dt * decayRate)
  }

  /// `Math.min(0.10, n > 0 ? (Math.PI / n) * 0.15 : 0.10)`.
  public static func halfAngle(panelCount n: Int) -> Double {
    min(maxHalfAngle, n > 0 ? (Double.pi / Double(n)) * halfAngleOfPanel : maxHalfAngle)
  }

  /// `Math.min(cx, cy) * 0.10`, with the ring centre.
  public static func innerRadius(centre c: StagePoint) -> Double {
    min(c.x, c.y) * innerRadiusOfCentre
  }

  /// The gradient: amber at the base, rose half way, the arc blue fading to nothing at the tip.
  public static func stops(energy v: Double) -> [(location: Double, color: ScopeColor)] {
    [
      (0.0, amber.withAlpha(0.85 * v)),
      (0.5, rose.withAlpha(0.7 * v)),
      (1.0, blue.withAlpha(0)),
    ]
  }

  /// The beam of one panel. `target` is the last fired transition's stage position, else the
  /// panel's ring position.
  public static func beam(
    panelId: String, energy v: Double, target: StagePoint, centre c: StagePoint,
    halfAngle: Double, innerRadius: Double
  ) -> StageFlameBeam {
    let dx = target.x - c.x
    let dy = target.y - c.y
    // `Math.hypot(dx, dy) || 1`
    let hyp = hypot(dx, dy)
    let dist = hyp == 0 ? 1 : hyp
    let theta = atan2(dy, dx)
    let barLen = max(innerRadius + minReach, dist * (reachBase + reachEnergy * v))
    func at(_ r: Double, _ a: Double) -> StagePoint {
      StagePoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }
    return StageFlameBeam(
      panelId: panelId, energy: v,
      base1: at(innerRadius, theta - halfAngle), base2: at(innerRadius, theta + halfAngle),
      tip2: at(barLen, theta + halfAngle * tipTaper),
      tip1: at(barLen, theta - halfAngle * tipTaper),
      gradientStart: c, gradientEnd: at(barLen, theta), theta: theta, barLength: barLen)
  }
}

@MainActor
public final class StageFlameModel: StageLayerModel {
  /// Energy per panel id, 0.01...1. Panels at rest are absent.
  public private(set) var energies: [String: Double] = [:]
  /// The last fired transition's stage position per panel id (`panel.flameOrigin`).
  public private(set) var origins: [String: StagePoint] = [:]

  public init() {}

  // MARK: frame

  public func advance(_ context: StageContext) {
    guard context.isOn(.flame) else {
      // "One-shot clear when the mode is toggled off", and nothing is collected while it is off.
      energies.removeAll()
      return
    }
    for fire in context.fires {
      guard let i = fire.panel, context.panels.indices.contains(i),
        context.panels[i].ring != nil
      else { continue }
      let id = context.panels[i].id
      energies[id] = StageFlame.bumped(energies[id] ?? 0)
      if let origin = fire.origin { origins[id] = origin }
    }
    // renderFlame: decay, and forget what fell below the floor. (A panel without a ring position
    // has no energy to begin with.)
    for p in context.panels {
      guard let e = energies[p.id] else { continue }
      let v = StageFlame.decayed(e, dt: context.dt)
      if v < StageFlame.floor {
        energies[p.id] = nil
      } else {
        energies[p.id] = v
      }
    }
  }

  public func reset() {
    energies.removeAll()
    origins.removeAll()
  }

  // MARK: geometry

  /// The beams to paint for `context`, in panel order (later ones on top).
  public func beams(in context: StageContext) -> [StageFlameBeam] {
    guard context.isOn(.flame) else { return [] }
    let centre = context.ringCenter
    let half = StageFlame.halfAngle(panelCount: context.panels.count)
    let inner = StageFlame.innerRadius(centre: centre)
    var out: [StageFlameBeam] = []
    for p in context.panels {
      guard let v = energies[p.id], let ring = p.ring else { continue }
      out.append(
        StageFlame.beam(
          panelId: p.id, energy: v, target: origins[p.id] ?? ring, centre: centre,
          halfAngle: half, innerRadius: inner))
    }
    return out
  }
}
