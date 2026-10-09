// STAGE LAYER PLACEHOLDER: bolts, seeds and the dark-planet halo (SPEC mode 17). Replaced
// wholesale by the overlays task. Contract: see StageLayerModels.swift.
//
// stage.js: while a macro runs (`StageFire.macroRunning`) and `context.isOn(.bolts)`, each fire
// spawns a bolt from `StageFire.origin` toward the ring centre (stopping on
// `context.darkPlanetRadius ?? 48`). Drawn above the flame beams, inside the container transform.
// Cleared by `reset()` on a rebuild.

@MainActor
public final class StageBoltsModel: StageLayerModel {
  public init() {}
}
