import DJCore
import SwiftUI

// The "Blocks" solo visualizer, drawn (the model is `StageMinecraftModel`; read its header).
//
// Full window, outside the container like the other solo visualizers; nothing is drawn unless
// it is the one showing. A pure function of the model's scene: a sky gradient, then the voxels
// back to front. All of it is original procedural pixel art (flat-shaded squares, pixel-grid
// figures); no game textures or characters.
//
//   block  a fill, a lighter top edge, darker right and bottom edges, and three texture specks
//          whose places come from the colour (so a material tiles like a texture)
//   flat   a plain fill
//   glow   a soft radial light added over what is below (`plusLighter`), with a solid core

struct StageMinecraftLayer: View {
  let context: StageContext
  let model: StageMinecraftModel

  var body: some View {
    let showing = context.visualizer == .minecraft
    let scene = model.scene
    StageCanvas { gc, size in
      guard showing, scene.width > 0 else { return }
      StageMinecraftPainter.draw(&gc, scene: scene, size: size)
    }
    .allowsHitTesting(false)
  }
}

enum StageMinecraftPainter {
  static func draw(_ gc: inout GraphicsContext, scene s: StageMinecraftScene, size: CGSize) {
    let full = CGRect(origin: .zero, size: size)
    gc.fill(
      Path(full),
      with: .linearGradient(
        Gradient(colors: [s.skyTop.color, s.skyBottom.color]), startPoint: .zero,
        endPoint: CGPoint(x: 0, y: size.height * 0.75)))
    for v in s.voxels { draw(&gc, v) }
    if s.flash > 0.001 {
      gc.fill(
        Path(full), with: .color(Color(.sRGB, red: 1, green: 1, blue: 0.96, opacity: s.flash)))
    }
  }

  static func draw(_ gc: inout GraphicsContext, _ v: StageVoxel) {
    guard v.color.a > 0.002, v.w > 0, v.h > 0 else { return }
    // whole points keep the blocks crisp and seamless
    let rect = CGRect(
      x: v.x.rounded(.down), y: v.y.rounded(.down),
      width: (v.x + v.w).rounded(.down) - v.x.rounded(.down),
      height: (v.y + v.h).rounded(.down) - v.y.rounded(.down))
    guard rect.width > 0, rect.height > 0 else { return }
    switch v.style {
    case .flat:
      gc.fill(Path(rect), with: .color(v.color.color))
    case .block:
      block(&gc, rect, v.color)
    case .glow:
      glow(&gc, rect, v.color)
    }
  }

  static func block(_ gc: inout GraphicsContext, _ r: CGRect, _ c: ScopeColor) {
    gc.fill(Path(r), with: .color(c.color))
    guard r.width >= 4 else { return }
    let edge = max(1, (r.width / 8).rounded())
    gc.fill(
      Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: edge)),
      with: .color(shade(c, 1.22).color))
    gc.fill(
      Path(CGRect(x: r.maxX - edge, y: r.minY + edge, width: edge, height: r.height - edge)),
      with: .color(shade(c, 0.74).color))
    gc.fill(
      Path(CGRect(x: r.minX, y: r.maxY - edge, width: r.width - edge, height: edge)),
      with: .color(shade(c, 0.66).color))
    guard r.width >= 10 else { return }
    // the material's texture: three specks on a 5 x 5 grid, placed by the colour
    let rgb = c.rgb8
    var h = UInt32(
      truncatingIfNeeded: rgb.r &* 73_856_093 ^ rgb.g &* 19_349_663 ^ rgb.b &* 83_492_791)
    let cell = r.width / 5
    for i in 0..<3 {
      h = h &* 1_103_515_245 &+ 12_345
      let gx = Int((h >> 8) % 4)
      let gy = Int((h >> 16) % 4)
      let dark = i != 1
      gc.fill(
        Path(
          CGRect(
            x: (r.minX + cell * CGFloat(gx) + edge).rounded(),
            y: (r.minY + cell * CGFloat(gy) + edge).rounded(),
            width: max(1, cell.rounded()), height: max(1, cell.rounded()))),
        with: .color(shade(c, dark ? 0.86 : 1.12).color))
    }
  }

  static func glow(_ gc: inout GraphicsContext, _ r: CGRect, _ c: ScopeColor) {
    var layer = gc
    layer.blendMode = .plusLighter
    let center = CGPoint(x: r.midX, y: r.midY)
    let radius = max(r.width, r.height) / 2
    layer.fill(
      Path(ellipseIn: r),
      with: .radialGradient(
        Gradient(colors: [c.color, c.withAlpha(c.a * 0.35).color, c.withAlpha(0).color]),
        center: center, startRadius: 0, endRadius: radius))
    let core = r.insetBy(dx: r.width * 0.32, dy: r.height * 0.32)
    if core.width >= 1 {
      layer.fill(Path(core), with: .color(c.withAlpha(min(1, c.a * 1.2)).color))
    }
  }

  static func shade(_ c: ScopeColor, _ f: Double) -> ScopeColor {
    ScopeColor(r: min(1, c.r * f), g: min(1, c.g * f), b: min(1, c.b * f), a: c.a)
  }
}
