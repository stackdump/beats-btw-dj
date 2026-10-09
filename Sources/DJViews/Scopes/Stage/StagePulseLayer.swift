import DJCore
import SwiftUI

// STAGE LAYER PLACEHOLDER: pulse particles (SPEC mode 14). Replaced wholesale by the overlays
// task, together with `StagePulseModel`. Contract: StageLayerRegistry.swift.
//
// Inside the container transform, over the meta-net and under the panels (stage.js draws the
// particles into the meta SVG, below the panels: a beat appears to pass BEHIND the ring outlines
// and reappear in the composition's negative space).

struct StagePulseLayer: View {
  let context: StageContext
  let model: StagePulseModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
