import DJCore
import SwiftUI

// STAGE LAYER PLACEHOLDER: background (SPEC mode 18). Replaced wholesale by the backgrounds
// task, together with `StageBackgroundModel`. Contract: StageLayerRegistry.swift.
//
// Sits under everything and OUTSIDE the container transform (stage.js: the bg canvas is not a
// child of the grid, so it neither spins nor tilts). The stage's own #0a0a1a is already painted
// by the host, so a void background draws nothing.

struct StageBackgroundLayer: View {
  let context: StageContext
  let model: StageBackgroundModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
