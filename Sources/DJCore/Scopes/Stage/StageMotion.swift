import Foundation

// The diagram's motion: the per-panel drift (SPEC mode 13) and the quarter-turn on a track change
// (SPEC mode 20). Pure numbers; `StageModel` steps them once per frame.

// MARK: - track spin (mode 20)

/// The quarter-turn the whole meta-diagram makes on a genuine track change, so the viewer feels
/// that something new started without a text cue (stage.js `metaRotation` /
/// `metaRotationTarget` and the easing block at the top of the rAF loop).
public struct StageSpin: Equatable, Sendable {
  /// Degrees the whole diagram is turned by now.
  public private(set) var rotation = 0.0
  /// Where it is heading: +90 per track change.
  public private(set) var target = 0.0

  /// Degrees added per track change.
  public static let step = 90.0
  /// Below this distance to the target the diagram snaps to it.
  public static let snap = 0.05
  /// Exponential approach rate (1/s): about half a second to settle.
  public static let rate = 4.0

  public init() {}

  public init(rotation: Double, target: Double) {
    self.rotation = rotation
    self.target = target
  }

  /// `stageOnProjectSync`: `metaRotationTarget += 90`.
  public mutating func bump() { target += Self.step }

  /// One frame. `dt` in seconds.
  public mutating func advance(dt: Double) {
    let delta = target - rotation
    if abs(delta) > Self.snap {
      rotation += delta * min(1, dt * Self.rate)
    } else if rotation != target {
      rotation = target
    }
    // Once caught up, wrap both so they never drift to big numbers after many track changes:
    // normalised to [0, 360).
    if rotation == target && (rotation >= 360 || rotation < 0) {
      var wrapped = rotation.truncatingRemainder(dividingBy: 360)
      wrapped = (wrapped + 360).truncatingRemainder(dividingBy: 360)
      rotation = wrapped
      target = wrapped
    }
  }
}

// MARK: - flow (mode 13)

/// Where randomness comes from, so a test can pin the drift velocities.
public protocol StageRandom {
  /// A number in [0, 1), like `Math.random()`.
  mutating func next() -> Double
}

/// The default source: the system generator.
public struct StageSystemRandom: StageRandom {
  public init() {}
  public mutating func next() -> Double { Double.random(in: 0..<1) }
}

/// A small deterministic generator (splitmix64), for tests and for seeded scenes.
public struct StageSeededRandom: StageRandom {
  private var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(1 << 53)
  }
}

/// A panel's drift (stage.js `buildOnePanel` + the loop's `p.angle += p.angleVelDps * dt`).
public struct StageFlow: Equatable, Sendable {
  /// Degrees the panel is turned by now, kept within +-360.
  public var angle = 0.0
  /// Signed drift in degrees per second: 3...9 clockwise or counter-clockwise.
  public var velocity: Double

  public init(angle: Double = 0, velocity: Double) {
    self.angle = angle
    self.velocity = velocity
  }

  /// A new panel's drift: `sign = random < 0.5 ? -1 : 1`, `vel = sign * (3 + random * 6)`. Two
  /// draws, in that order.
  public static func random<R: StageRandom>(using rng: inout R) -> StageFlow {
    let sign: Double = rng.next() < 0.5 ? -1 : 1
    return StageFlow(velocity: sign * (3 + rng.next() * 6))
  }

  /// One frame: drift when `flowOn`, and wrap at +-360 either way (a single subtraction, as the
  /// JS does: the angle never gets that far in one frame).
  public mutating func advance(dt: Double, flowOn: Bool) {
    if flowOn { angle += velocity * dt }
    if angle > 360 { angle -= 360 }
    if angle < -360 { angle += 360 }
  }
}
