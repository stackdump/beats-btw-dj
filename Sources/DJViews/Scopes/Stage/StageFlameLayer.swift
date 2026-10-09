import DJCore
import SwiftUI

// STAGE LAYER PLACEHOLDER: flame beams (SPEC mode 15). Replaced wholesale by the overlays task,
// together with `StageFlameModel`. Contract: StageLayerRegistry.swift.
//
// Inside the container transform, under the meta-net and the panels. Draw in stage coordinates
// (`context.ringCenter`, `StageFire.origin`); the container projects it with everything else.

struct StageFlameLayer: View {
  let context: StageContext
  let model: StageFlameModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
