import DJCore
import SwiftUI

// STAGE LAYER PLACEHOLDER: bolts, seeds and halo (SPEC mode 17). Replaced wholesale by the
// overlays task, together with `StageBoltsModel`. Contract: StageLayerRegistry.swift.
//
// Inside the container transform, above the flame beams (stage.js draws bolts on the flame
// canvas) and below the meta-net, pulses and panels.

struct StageBoltsLayer: View {
  let context: StageContext
  let model: StageBoltsModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
