// STAGE LAYER PLACEHOLDER: tilt (SPEC mode 16). Replaced wholesale by the overlays task.
// Contract: see StageLayerModels.swift.
//
// The container hook. Once per frame the host asks `projection(metaRotation:)` for the transform
// of the layer container (flame, bolts, meta-net, pulses, panels: all of them, identically). The
// skeleton only spins (`rotateZ(metaRotation)`, mode 20). The tilt task accumulates
// `tiltAngle += dt * 12` while `context.isOn(.tilt)` (reset to 0 when it turns off) and returns
// `StageProjection.tilt(rotateX:rotateY:rotateZ:)` with stage.js' `rx = 18 sin(a * 0.6)`,
// `ry = 22 cos(a * 0.4)`; the math of the matrix and the view that applies it
// (`StageContainer`) are the skeleton's.

@MainActor
public final class StageTiltModel: StageLayerModel {
  public init() {}

  /// The container's transform for the frame that was last advanced.
  public func projection(metaRotation: Double) -> StageProjection {
    .spin(metaRotation)
  }
}
