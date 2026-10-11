import CoreGraphics
import DJCore
import SwiftUI

// Bands (SPEC mode 5; scope.js `drawBands`): per-bar energy in the five analysis bands plus
// their sum E, one column per bar, as the digits 0-9 of an infra-red camera: 9 is each row's own
// loudest bar and every digit is 4 dB below the next (VIRIDIS). The newest bars fill the width.
//
// MODEL block (always): nothing is listened to. Every fire the nets make deposits energy into its
// bar's bands (velocity^2 x the instrument's kernel x the FX response); `ModelEngine`.
// MEASURED block + RESIDUAL block (the panel's "measured" toggle): the same rows from the mean
// analyser power of each bar, and below them measured - model in dB with each row's mean removed
// (red: louder than the model says, blue: quieter), then the spectral tilt of the five offsets.
//
// All numbers come from `BandsController` / `BandsScene` / `BandsModel` (DJCore); this file paints
// them. The scene is rebuilt at most four times a second (the 250 ms redraw limit) and the picture
// is drawn into a bitmap once per scene (`BandsImage`), as scope.js keeps it on its canvas; every
// frame in between is one blit.

struct ScopeBandsView: View {
  let feed: ScopeFeed
  let measured: Bool
  let hub: ScopeHub

  @State private var controller: BandsController
  @State private var imageCache = BandsImageCache()
  @Environment(\.scopeStatusLine) private var statusLine
  @Environment(\.displayScale) private var displayScale

  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub) {
    self.init(feed: feed, measured: measured, hub: hub, controller: BandsController())
  }

  /// With a controller of the caller's (tests hand in one over a private kernel cache).
  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub, controller: BandsController) {
    self.feed = feed
    self.measured = measured
    self.hub = hub
    _controller = State(initialValue: controller)
  }

  var body: some View {
    ScopeCanvas(hub: hub) { ctx, size in
      controller.update(feed: feed, engine: hub.engine, measured: measured)
      statusLine?.set(controller.statusText(feed: feed), owner: controller)
      let scene = controller.scene(feed: feed, width: size.width, measured: measured)
      BandsPainter.paint(scene, in: &ctx, size: size, scale: displayScale, cache: imageCache)
    }
    .onDisappear { statusLine?.clear(owner: controller) }
  }
}

/// Scene -> Canvas calls: the scene's bitmap, blitted.
enum BandsPainter {
  @MainActor
  static func paint(
    _ scene: BandsScene, in ctx: inout GraphicsContext, size: CGSize, scale: CGFloat,
    cache: BandsImageCache
  ) {
    guard let image = cache.image(for: scene, size: size, scale: scale) else { return }
    let w = CGFloat(image.width) / scale
    let h = CGFloat(image.height) / scale
    ctx.draw(Image(decorative: image, scale: scale), in: CGRect(x: 0, y: 0, width: w, height: h))
  }
}
