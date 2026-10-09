// The stage's solo visualizers (SPEC modes 9-12: corona, sonar, petal, shuffle).
//
// While `context.visualizer.isSolo` the host hides the panel grid, the flame canvas and the
// constellation controls (stage.js `viz-solo`) and shows `StageSoloLayer` full window. This model
// owns the state of the three visualizers and the shuffle state machine; the host calls
// `resolveVisualizer` once per frame BEFORE it builds the context and shows whatever it returns
// (never `.shuffle`), then `advance(_:)` with the finished context.
//
//   corona  StageCoronaModel.swift   the master's FFT as 128 bars (audio-driven)
//
// Everything the view draws is a value (`StageSoloPaint`) computed here from the context, so the
// view is a pure function of it and the numbers are unit-tested without a window.

/// What the solo layer draws this frame.
public enum StageSoloPaint: Equatable, Sendable {
  case none
  case corona([CoronaRay])
}

@MainActor
public final class StageSoloModel: StageLayerModel {
  public let corona = StageCoronaModel()

  public init() {}

  /// The visualizer to show this frame. `selection` is the toolbar's value (may be `.shuffle`);
  /// `fires` are the frame's fires (shuffle counts them: 64 per swap), `now` the wall clock.
  /// (The shuffle itself lands with mode 12; until then `.shuffle` shows the constellation.)
  public func resolveVisualizer(
    selection: StageVisualizer, fires: [StageFire], now: Double
  ) -> StageVisualizer {
    selection == .shuffle ? .constellation : selection
  }

  public func advance(_ context: StageContext) {
    if context.visualizer == .corona {
      corona.advance(feed: context.feed, dt: context.dt)
    } else {
      corona.rest()
    }
  }

  /// The stage is closing (`StageModel.detach()`): hand back what the solo visualizers hold on
  /// the engine. That is the corona's lease on the source's left-channel tap, which the feed
  /// only ends with its LAST release, so a Scopes window that keeps the feed open would
  /// otherwise keep the tap running after the Stage is gone. Idempotent.
  public func rest() {
    corona.rest()
  }

  /// What to draw for `context` (`.none` unless a solo visualizer shows).
  public func paint(_ context: StageContext) -> StageSoloPaint {
    switch context.visualizer {
    case .corona: .corona(corona.rays(for: context))
    case .constellation, .sonar, .petal, .shuffle: .none
    }
  }
}
