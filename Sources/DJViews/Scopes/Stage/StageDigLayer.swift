import DJCore
import SwiftUI

// The "Dig" solo visualizer, drawn (the model is `StageDigModel`; read its header).
//
// Full window, outside the container like the other solo visualizers; nothing is drawn unless
// it is the one showing. A pure function of the model's scene: a dark fill, the voxels back to
// front (painted as the Blocks layer paints them), the hotbar's counts, then the flash. Original
// procedural pixel art; no game textures or characters.

struct StageDigLayer: View {
  let context: StageContext
  let model: StageDigModel

  var body: some View {
    let showing = context.visualizer == .dig
    let scene = model.scene
    StageCanvas { gc, size in
      guard showing, scene.width > 0 else { return }
      StageDigPainter.draw(&gc, scene: scene, size: size)
    }
    .allowsHitTesting(false)
  }
}

enum StageDigPainter {
  static func draw(_ gc: inout GraphicsContext, scene s: StageDigScene, size: CGSize) {
    let full = CGRect(origin: .zero, size: size)
    gc.fill(Path(full), with: .color(Color(.sRGB, red: 0.05, green: 0.045, blue: 0.06)))
    for v in s.voxels { StageMinecraftPainter.draw(&gc, v) }
    for (i, r) in s.slots.enumerated() where i < s.inventory.count && s.inventory[i] > 0 {
      gc.draw(
        Text("\(s.inventory[i])")
          .font(.system(size: max(9, r.h * 0.34), weight: .bold, design: .monospaced))
          .foregroundStyle(.white),
        at: CGPoint(x: r.x + r.w - 3, y: r.y + r.h - 2), anchor: .bottomTrailing)
    }
    if s.flash > 0.001 {
      gc.fill(
        Path(full), with: .color(Color(.sRGB, red: 0.92, green: 1, blue: 1, opacity: s.flash)))
    }
  }
}
