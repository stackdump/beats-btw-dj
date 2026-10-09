import DJCore
import SwiftUI

// The empty stage's message (no net deck behind the source, or the first bar has not arrived).
// Part of the stage skeleton. It is NOT inside the turning container: the track spin turns the
// panels and the meta-net, and a message that turned with them would end up on its side. It is
// shown when there are no panels and no solo visualizer owns the window.

struct StageEmptyLayer: View {
  let context: StageContext

  var body: some View {
    Canvas { gc, size in
      StageEmptyPainter.draw(&gc, context: context)
    }
    .allowsHitTesting(false)
  }
}

enum StageEmptyPainter {
  static func draw(_ gc: inout GraphicsContext, context: StageContext) {
    guard context.panels.isEmpty else { return }
    let text = gc.resolve(
      Text(StageEmptyState.message(hasNet: context.hasNet, source: context.source))
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.4)))
    gc.draw(text, at: CGPoint(x: context.width / 2, y: context.height / 2), anchor: .center)
  }
}
