// STAGE LAYER PLACEHOLDER: flame beams (SPEC mode 15). Replaced wholesale by the overlays task.
// Contract: see StageLayerModels.swift.
//
// stage.js: `session.flameEnergy` per panel (+0.9 per fire, capped at 1, decays `exp(-dt * 4)`),
// beams from the ring centre toward the fired transition's `StageFire.origin`. Active while
// `context.isOn(.flame)`. Inside the container transform. Cleared by `reset()` on a rebuild.

@MainActor
public final class StageFlameModel: StageLayerModel {
  public init() {}
}
