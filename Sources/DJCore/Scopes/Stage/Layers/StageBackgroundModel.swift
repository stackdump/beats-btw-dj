// STAGE LAYER PLACEHOLDER: background (SPEC mode 18: void, stars with ringed planets, aurora).
// Replaced wholesale by the backgrounds task. Contract: see StageLayerModels.swift.
//
// stage.js: `renderStars(dt)` / `renderAurora(dt)` run every frame behind the meta-diagram
// (`context.bgMode`, `context.dt`, `context.width/height`); void draws nothing (the stage's
// #0a0a1a shows). This layer is NOT inside the container transform: the background does not
// spin or tilt.

@MainActor
public final class StageBackgroundModel: StageLayerModel {
  public init() {}
}
