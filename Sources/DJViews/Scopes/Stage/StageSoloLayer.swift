import DJCore
import SwiftUI

// STAGE LAYER PLACEHOLDER: the solo visualizers (SPEC modes 9-12: corona, sonar, petal, shuffle).
// Replaced wholesale by the solo task, together with `StageSoloModel`. Contract:
// StageLayerRegistry.swift.
//
// Full window, above the container and OUTSIDE its transform (stage.js: the scope canvas is not a
// child of the grid). The host keeps this view in the stack at all times and hides the panel grid
// while `context.visualizer.isSolo` (`viz-solo`); draw nothing otherwise.

struct StageSoloLayer: View {
  let context: StageContext
  let model: StageSoloModel

  var body: some View {
    Canvas { gc, size in
      guard context.isSolo else { return }
      let text = gc.resolve(
        Text("\(context.visualizer.title) — not ported yet")
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.5)))
      gc.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
    }
    .allowsHitTesting(false)
  }
}
