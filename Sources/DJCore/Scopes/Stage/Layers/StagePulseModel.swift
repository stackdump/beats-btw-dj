// STAGE LAYER PLACEHOLDER: pulse particles (SPEC mode 14). Replaced wholesale by the overlays
// task. Contract: see StageLayerModels.swift.
//
// stage.js: each fire, while `context.isOn(.pulse)` and the panel has a ring position
// (`StagePanel.ring != nil`), spawns a particle from `StageFire.origin` toward
// `context.ringCenter` (700 ms). Particles keep draining after the toggle is turned off. Drawn
// over the meta-net and under the panels, inside the container transform. Cleared by `reset()`
// on a rebuild.

@MainActor
public final class StagePulseModel: StageLayerModel {
  public init() {}
}
