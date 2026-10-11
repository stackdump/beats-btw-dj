import Foundation

// Tilt (SPEC mode 16): "slow 3D perspective orbit of the whole composition".
//
// stage.js writes `grid.style.transform` once per frame from the tilt angle (an accumulator in
// degrees) and the track spin:
//
//     if (tiltOn) session.tiltAngle += dt * 12;                    // deg/sec
//     rx = 18 * sin(tiltAngle * PI / 180 * 0.6)
//     ry = 22 * cos(tiltAngle * PI / 180 * 0.4)
//     transform = `perspective(1400px) rotateX(${rx}deg) rotateY(${ry}deg) rotateZ(${metaRotation}deg)`
//     // tilt off: rotateZ(metaRotation) alone; toggling it off resets tiltAngle to 0
//
// and copies that very string onto the flame canvas (it lives outside the grid). Here this model
// is the container hook: the host asks `projection(metaRotation:)` once per frame and wraps the
// layer group (flame, bolts, meta-net, pulses, panels) in the ONE transform, so the layers move
// and tilt as one (`StageContainer`, with the matrix and its CSS composition order in
// `StageProjection`, both unit-tested).
//
// The tilt is a pure view transform. Coordinates the model hands the layers (`nodeCenterInStage`,
// `StageFire.origin`, the beams' and bolts' endpoints) are computed WITHOUT it, as stage.js
// replays the affine instead of asking the DOM for a rect (`nodeCenterInStage`'s comment: a rect
// would be post-projection and then be projected a second time on paint, the drift the JS
// calls out). Nothing here feeds a projected point back into the model.
//
//   * The angle accumulates only while the toggle is on, with the frame's clamped `dt`; it is
//     0 whenever the toggle is off, so switching it off and on again starts the orbit afresh.
//   * It keeps counting while a solo visualizer hides the container, as the JS loop does.

/// The numbers of the tilt, as pure functions of the accumulated angle.
public enum StageTilt {
  /// `session.tiltAngle += dt * 12`: degrees per second.
  public static let degreesPerSecond = 12.0
  /// `18 * Math.sin(tiltAngle * PI / 180 * 0.6)`.
  public static let rotateXAmplitude = 18.0
  public static let rotateXRate = 0.6
  /// `22 * Math.cos(tiltAngle * PI / 180 * 0.4)`.
  public static let rotateYAmplitude = 22.0
  public static let rotateYRate = 0.4

  /// `rx` in degrees for an accumulated angle in degrees.
  public static func rotateX(angle: Double) -> Double {
    rotateXAmplitude * sin(angle * Double.pi / 180 * rotateXRate)
  }

  /// `ry` in degrees for an accumulated angle in degrees.
  public static func rotateY(angle: Double) -> Double {
    rotateYAmplitude * cos(angle * Double.pi / 180 * rotateYRate)
  }

  /// The container's transform for an accumulated angle and the track spin: the full CSS string
  /// `perspective(1400px) rotateX(rx) rotateY(ry) rotateZ(rz)`.
  public static func projection(angle: Double, metaRotation: Double) -> StageProjection {
    .tilt(rotateX: rotateX(angle: angle), rotateY: rotateY(angle: angle), rotateZ: metaRotation)
  }
}

@MainActor
public final class StageTiltModel: StageLayerModel {
  /// `session.tiltAngle`: degrees accumulated while tilt is on, 0 while it is off.
  public private(set) var angle = 0.0
  /// Was tilt on at the last frame?
  public private(set) var isTilting = false

  public init() {}

  public func advance(_ context: StageContext) {
    if context.isOn(.tilt) {
      angle += context.dt * StageTilt.degreesPerSecond
      isTilting = true
    } else {
      // turning it off resets the accumulator (`session.tiltAngle = 0`)
      angle = 0
      isTilting = false
    }
  }

  /// The container's transform for the frame that was last advanced.
  public func projection(metaRotation: Double) -> StageProjection {
    isTilting
      ? StageTilt.projection(angle: angle, metaRotation: metaRotation) : .spin(metaRotation)
  }
}
