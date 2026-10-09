import Foundation

// The main ring's extras from beats' workspace (SPEC mode 22): lib/ui/canvas.js `drawRing`
// (dim while playing, rotation about the centroid), lib/macros/runtime.js `autoDjSpin` /
// `autoDjSpinAnimate` (the 800 ms swing) and petri-note.css `.pn-transition.playhead` (the
// last-fired transition stays lit). Values only: no SwiftUI here, the ring view draws them.

/// How the ring's arc layer is drawn, set by the host from the deck it belongs to.
///
/// beats draws the net's arcs (and their arrowheads) on a canvas under the place/transition
/// nodes. Playing, they step back so the rolling timeline reads as primary: alpha 0.3 and a
/// 1 px line instead of full strength and 2 px (`drawRing`: `playing ? 0.3 : 1`,
/// `(playing ? 1 : 2) / scale`). The nodes are not dimmed, and the Auto-DJ rotation turns only
/// this layer ("DOM place/transition nodes stay put").
///
/// The Swift ring draws a dot per step, not arcs, so the arc layer is the chords joining the
/// dots in firing order, with a small arrowhead on each long enough to carry one. A host that
/// does not pass a `RingArcs` gets the dots-only ring it always had.
public struct RingArcs: Equatable, Sendable {
  /// The deck is playing.
  public var playing: Bool
  /// Rotation of the arc layer about the ring's centre, degrees clockwise.
  public var angleDegrees: Double
  /// Arrowheads point back along the arcs (`_autoDjReverse`): set while a swing runs the
  /// other way.
  public var reverseArrows: Bool

  public init(playing: Bool = false, angleDegrees: Double = 0, reverseArrows: Bool = false) {
    self.playing = playing
    self.angleDegrees = angleDegrees
    self.reverseArrows = reverseArrows
  }

  /// `ctx.strokeStyle = '#4a90d9'`.
  public static let strokeHex = "#4a90d9"
  /// `ctx.globalAlpha = playing ? 0.3 : 1`.
  public static let playingAlpha = 0.3

  public var alpha: Double { playing ? Self.playingAlpha : 1 }

  /// `(playing ? 1 : 2) / scale`: a 1 px or 2 px line on screen whatever the zoom.
  public func lineWidth(scale: Double = 1) -> Double { (playing ? 1 : 2) / max(scale, 1e-9) }

  /// `drawArrowhead`: the two wings leave the tip at +-30 degrees to the arc.
  public static let wingAngle = Double.pi / 6

  /// How far short of the target dot the arrowhead's tip stops (`drawArrowhead` sets it back
  /// by the node radius, `offset = 25`): 1.4 x the dot's drawn base radius.
  public static func tipSetBack(base: Double) -> Double { base * 1.4 }

  /// The wing length of an arrowhead on a chord of length `chord` between dots of radius
  /// `base`, nil where none fits. The JS head is 12 px on arcs of 100 px and more; here it is
  /// `min(0.35 chord, 4)`, and it is drawn only when it fits between the two dots: the chord
  /// must hold a tip set-back at each end and the wing length. On a ring too small for that
  /// (16 steps in a 66 pt square) a head would only smudge the dots, so the arcs go without.
  public static func headLength(chord: Double, base: Double) -> Double? {
    let length = min(chord * 0.35, 4)
    return chord >= 2 * tipSetBack(base: base) + length ? length : nil
  }
}

/// The persistent playhead: the last-fired step stays lit until the next one fires.
///
/// `.pn-transition.playhead .pn-transition-rect`: border `#ffd36a`, outer glow
/// `0 0 6px rgba(255, 211, 106, 0.7)` and inner glow `inset 0 0 4px rgba(255, 211, 106, 0.35)`
/// on the 40 px node with its 3 px border. The ring draws it over the 100 ms `.firing` flash
/// (in beats the playhead's border and glow replace the flash's and the node stays filled).
///
/// Sizes. The ring's step is a dot, so the node box is mapped onto a circle of radius
/// `radiusFactor x base` (`base` is the dot's resting-to-firing radius scale, see
/// `RingGeometry.baseRadius`; a full-velocity hit is 2 x base, so the ring clears all but the
/// loudest). That circle stands for the box's 20 px half side, so one CSS px is
/// `radius / 20` points, and the border and glows are their CSS px times that. Two
/// conventions are applied on the way: SwiftUI's `shadow(radius:)` is the Gaussian's sigma
/// where a CSS blur of B px has sigma B / 2, and the inner glow is drawn as a ramp over its
/// full blur width. Every size has a floor of one point, or the ring and its glows would
/// vanish on a 64-step ring.
public enum RingPlayhead {
  public static let hex = "#ffd36a"
  public static let rgb8 = (r: 255, g: 211, b: 106)
  public static let outerGlowAlpha = 0.7
  public static let innerGlowAlpha = 0.35

  /// `.pn-transition-rect`: a 40 px box, 3 px border; glows of 6 px (outer) and 4 px (inner).
  public static let nodePx = 40.0
  public static let borderPx = 3.0
  public static let outerBlurPx = 6.0
  public static let innerBlurPx = 4.0
  /// The one free choice: the ring's radius as a multiple of `base`.
  public static let radiusFactor = 1.9
  /// The smallest any of the ring's sizes is drawn, in points.
  public static let floorPoints = 1.0

  public static func radius(base: Double) -> Double { base * radiusFactor }
  /// Points per CSS px.
  public static func pointsPerPx(base: Double) -> Double { radius(base: base) / (nodePx / 2) }
  public static func lineWidth(base: Double) -> Double {
    max(floorPoints, borderPx * pointsPerPx(base: base))
  }
  /// The radius to hand SwiftUI's `shadow` (its sigma): half the 6 px blur.
  public static func outerGlowRadius(base: Double) -> Double {
    max(floorPoints, outerBlurPx / 2 * pointsPerPx(base: base))
  }
  /// The width of the ramp inside the ring: the 4 px blur.
  public static func innerGlowRadius(base: Double) -> Double {
    max(floorPoints, innerBlurPx * pointsPerPx(base: base))
  }
}

/// The Auto-DJ ring swing (`autoDjSpin` + `autoDjSpinAnimate`), driven by an injected clock.
///
/// Each call to `spin` nudges the target by +-90 degrees per step, alternating direction
/// between calls, and tweens to it over 800 ms with a cubic ease-out. The tween starts from
/// wherever the last one had got to, so a spin during a swing carries on smoothly. Pure
/// arithmetic: `angle(at:)` takes a time in seconds and has no clock of its own.
///
/// Hook (the app): a deck hands over to its next track (`Deck.advances` moves); `observe`
/// turns that into a spin. beats spins on its Auto-DJ cadence (the macro fire boundary and a
/// regen); the Swift app has no such cadence, and a track change is the closest event it has.
public struct RingSpin: Equatable, Sendable {
  /// `autoDjSpinAnimate`: `DURATION = 800` ms.
  public static let duration = 0.8
  /// `dir * 90 * steps`.
  public static let degreesPerStep = 90.0

  public private(set) var targetAngle = 0.0
  private var fromAngle = 0.0
  private var startTime = -Double.infinity
  private var direction = 1.0
  /// `_autoDjReverse`: the arrowheads follow the direction of the last spin.
  public private(set) var reverseArrows = false
  /// `Deck.advances` as last observed (nil before the first look).
  public private(set) var advancesSeen: Int?

  public init() {}

  /// `1 - (1 - t)^3`, with `t` clamped to 0...1.
  public static func eased(_ t: Double) -> Double {
    let c = min(max(t, 0), 1)
    return 1 - pow(1 - c, 3)
  }

  /// The angle at `now`: `from + (to - from) * eased`.
  public func angle(at now: Double) -> Double {
    let t = (now - startTime) / Self.duration  // +infinity before the first spin
    return fromAngle + (targetAngle - fromAngle) * Self.eased(t)
  }

  /// Is a swing still running at `now`?
  public func isSpinning(at now: Double) -> Bool { now - startTime < Self.duration }

  /// `autoDjSpin(el, steps)`: a no-op for `steps <= 0`.
  public mutating func spin(steps: Int = 1, at now: Double) {
    guard steps > 0 else { return }
    let current = angle(at: now)
    targetAngle += direction * Self.degreesPerStep * Double(steps)
    reverseArrows = direction < 0
    direction = -direction
    startTime = now
    fromAngle = current
  }

  /// Spin once when `advances` has moved since the last look. The first look only records
  /// the count (a deck that was already on its tenth track does not swing when the window
  /// opens).
  public mutating func observe(advances: Int, at now: Double) {
    defer { advancesSeen = advances }
    guard let seen = advancesSeen, advances != seen else { return }
    spin(steps: 1, at: now)
  }

  /// The arc layer's state for a frame.
  public func arcs(playing: Bool, at now: Double) -> RingArcs {
    RingArcs(playing: playing, angleDegrees: angle(at: now), reverseArrows: reverseArrows)
  }
}
