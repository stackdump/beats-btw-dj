import DJCore
import SwiftUI

// STAGE LAYER PLACEHOLDER: the share-card flash (SPEC mode 19). Replaced wholesale by the
// backgrounds/extras task, together with `StageCardModel`. Contract: StageLayerRegistry.swift.
//
// Topmost layer, outside the container transform (stage.js appends the card box to the overlay).

struct StageCardLayer: View {
  let context: StageContext
  let model: StageCardModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
