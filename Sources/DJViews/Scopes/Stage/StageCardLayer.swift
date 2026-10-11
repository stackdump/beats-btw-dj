import DJCore
import SwiftUI

// The share-card flash's layer (SPEC mode 19), topmost and outside the container transform
// (stage.js appends the card box to the overlay). NOT PORTED: this app has no share card, so
// there is nothing to flash and the layer draws nothing, whatever `cardOnChange` or
// `trackChanged` say. See `StageCardModel` for the decision and what a future card would need.
// Contract: StageLayerRegistry.swift.

struct StageCardLayer: View {
  let context: StageContext
  let model: StageCardModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
