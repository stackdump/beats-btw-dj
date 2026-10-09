// STAGE LAYER PLACEHOLDER: the solo visualizers (SPEC modes 9-12: corona, sonar, petal, shuffle).
// Replaced wholesale by the solo task. Contract: see StageLayerModels.swift.
//
// While `context.visualizer.isSolo` the host hides the panel grid, the flame canvas and the
// constellation controls (stage.js `viz-solo`) and shows `StageSoloLayer` full window. This model
// owns the shuffle state machine: the host calls `resolveVisualizer` once per frame BEFORE it
// builds the context and shows whatever it returns (never `.shuffle`).

@MainActor
public final class StageSoloModel: StageLayerModel {
  public init() {}

  /// The visualizer to show this frame. `selection` is the toolbar's value (may be `.shuffle`);
  /// `fires` are the frame's fires (shuffle counts them: 64 per swap), `now` the wall clock.
  /// The skeleton shows the constellation for shuffle.
  public func resolveVisualizer(
    selection: StageVisualizer, fires: [StageFire], now: Double
  ) -> StageVisualizer {
    selection == .shuffle ? .constellation : selection
  }
}
