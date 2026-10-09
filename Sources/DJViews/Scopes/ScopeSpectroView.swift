import CoreGraphics
import DJCore
import SwiftUI

// Spectro (SPEC modes 2 and 3; scope.js `drawSpectro`): a log-frequency spectrogram of the last
// four bars, 30 Hz ... 16 kHz in 28 bins, low frequencies at the bottom.
//
// MODEL block (always): nothing is listened to. Every fire the nets make deposits energy into
// its part's bins (velocity^2 x the instrument's kernel x the FX response), decaying with the
// kernel's own decay time; one column per song step, MAGMA coloured over a 50 dB range below the
// loudest visible cell. The whole thing is `ModelEngine` (DJCore); a deck feed's model is taken
// at the deck's pre-fader tap, which the second line under "model" says.
// (The panel's "measured" toggle, an FFT block below this one, is not wired yet: `measured`
// means nothing to this view until it is.)
//
// All numbers come from `SpectroController` / `SpectroScene` (DJCore); this file paints them:
// the image NEAREST-neighbour (imageSmoothingEnabled = false) stretched between the times of its
// first and last column, then grid, labels and titles on top. Frames are paced and pumped by
// `ScopeCanvas`.

struct ScopeSpectroView: View {
  let feed: ScopeFeed
  let measured: Bool
  let hub: ScopeHub

  @State private var controller: SpectroController
  @Environment(\.scopeStatusLine) private var statusLine

  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub) {
    self.init(feed: feed, measured: measured, hub: hub, controller: SpectroController())
  }

  /// With a controller of the caller's (tests hand in one over a private kernel cache).
  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub, controller: SpectroController) {
    self.feed = feed
    self.measured = measured
    self.hub = hub
    _controller = State(initialValue: controller)
  }

  var body: some View {
    ScopeCanvas(hub: hub) { ctx, size in
      controller.update(feed: feed, engine: hub.engine)
      statusLine?.set(controller.statusText(feed: feed), owner: controller)
      let scene = controller.scene(feed: feed, width: size.width, height: size.height)
      SpectroPainter.paint(scene, in: &ctx)
    }
    .onDisappear { statusLine?.clear(owner: controller) }
  }
}

/// Scene -> Canvas calls.
enum SpectroPainter {
  static func paint(_ scene: SpectroScene, in ctx: inout GraphicsContext) {
    guard scene.ok else { return }
    if let block = scene.model { paint(block, in: &ctx) }
  }

  private static func paint(_ block: SpectroScene.Block, in ctx: inout GraphicsContext) {
    // the image, clipped to the plot, over the stretch the scene says
    if let bitmap = block.bitmap, let dest = block.imageRect, let image = cgImage(bitmap) {
      var layer = ctx
      layer.clip(to: Path(LiveScopePainter.rect(block.clip)))
      layer.draw(
        layer.resolve(Image(decorative: image, scale: 1).interpolation(.none)),
        in: LiveScopePainter.rect(dest))
    }
    // grid over it: beat lines, then bar lines (a bar is every fourth beat, they never overlap)
    var beats = Path()
    var bars = Path()
    for g in block.grid.lines {
      if g.bar {
        bars.addRect(LiveScopePainter.rect(g.rect))
      } else {
        beats.addRect(LiveScopePainter.rect(g.rect))
      }
    }
    ctx.fill(beats, with: .color(ScopeColors.grid.color))
    ctx.fill(bars, with: .color(ScopeColors.barLine.color))
    for l in block.grid.barLabels { text(l, ScopeColors.text, in: &ctx) }
    for m in block.grid.sections {
      ctx.fill(Path(LiveScopePainter.rect(m.rect)), with: .color(ScopeColors.sectionLine.color))
      text(m.name, ScopeColors.sectionLine, in: &ctx)
    }
    for l in block.freqLabels { text(l, ScopeColors.text, in: &ctx) }
    text(block.title, ScopeColors.text, in: &ctx)
    if let note = block.note { text(note, ScopeColors.text, in: &ctx) }
    if let message = block.message { text(message, ScopeColors.text, in: &ctx) }
  }

  private static func text(_ t: LiveScopeText, _ color: ScopeColor, in ctx: inout GraphicsContext) {
    ctx.draw(
      ctx.resolve(Text(t.text).font(LiveScopePainter.font).foregroundColor(color.color)),
      at: CGPoint(x: t.x, y: t.y), anchor: .topLeading)
  }

  /// The bitmap as an sRGB image (the LUT values are canvas values), no smoothing.
  static func cgImage(_ bitmap: SpectroBitmap) -> CGImage? {
    let rgba = bitmap.rgba()
    guard bitmap.width > 0, bitmap.height > 0, rgba.count == bitmap.width * bitmap.height * 4,
      let provider = CGDataProvider(data: Data(rgba) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bitmap.width * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
