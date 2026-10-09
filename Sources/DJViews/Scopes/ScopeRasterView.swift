import DJCore
import SwiftUI

// Raster mode (SPEC mode 6; scope.js `drawRaster`): the whole arrangement's score, ticked offline.
//
// Every net of the lead deck's project is run from the top without audio (`RasterModel`, DJCore,
// on a background task; `RasterController` follows the feed and drops stale results) and each
// audible fire is a mark: a spike for a drum, a short bar at its pitch for a note. x is the song
// position over the whole arrangement (a loop project: one cycle), one row per lane, sections
// marked at the top, a white playhead from the engine's published tick and phase. The marks are
// static, so they are drawn once into a bitmap (`RasterImage`, keyed by scene and size) and
// blitted every frame; only the playhead is drawn per frame. Building the bitmap is measured
// (262144 events at 1800x640 @2x: 80 ms in release, 135 ms in debug); what a blit of it costs per
// frame in a real window has not been measured (no window is opened in the tests).
//
// Source: a deck, its project; the master, the lead deck's project (the other deck's lanes are
// not part of that arrangement). A sample deck, or a master without a net deck, has no raster.
// The status line of the panel header is spoken through `ScopeStatusLine`.

struct ScopeRasterView: View {
  let feed: ScopeFeed
  let measured: Bool
  let hub: ScopeHub

  @State private var raster: RasterController
  @State private var cache = RasterImageCache()
  @Environment(\.displayScale) private var displayScale
  @Environment(\.scopeStatusLine) private var statusLine

  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub) {
    self.init(feed: feed, measured: measured, hub: hub, raster: RasterController())
  }

  /// With a controller of the caller's (tests hand in one that has already settled).
  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub, raster: RasterController) {
    self.feed = feed
    self.measured = measured
    self.hub = hub
    _raster = State(initialValue: raster)
  }

  var body: some View {
    ScopeCanvas(hub: hub) { ctx, size in
      raster.update(feed: feed)
      statusLine?.set(raster.statusText, owner: raster)
      RasterDrawing.draw(
        into: &ctx, size: size, scale: displayScale,
        snapshot: RasterSnapshot(raster: raster, clock: feed.clock), cache: cache)
    }
    .onDisappear {
      raster.cancel()
      statusLine?.clear(owner: raster)
    }
  }
}

/// What one frame of the raster is drawn from.
struct RasterSnapshot {
  /// The finished raster, if there is one.
  var scene: RasterScene?
  /// What to say instead while there is none (`nil` once there is a scene).
  var message: String?
  /// The engine's net clock, for the playhead.
  var clock: ScopeClock

  @MainActor init(raster: RasterController, clock: ScopeClock) {
    scene = raster.scene
    message = raster.canvasMessage
    self.clock = clock
  }

  init(scene: RasterScene?, message: String?, clock: ScopeClock) {
    self.scene = scene
    self.message = message
    self.clock = clock
  }
}

@MainActor
enum RasterDrawing {
  /// The frame: the cached static layer, then the playhead; or, with no raster yet, the message
  /// at (8, 8). The background is already filled.
  static func draw(
    into ctx: inout GraphicsContext, size: CGSize, scale: CGFloat, snapshot: RasterSnapshot,
    cache: RasterImageCache
  ) {
    guard let scene = snapshot.scene else {
      if let message = snapshot.message {
        ctx.draw(
          ctx.resolve(
            Text(message).font(.system(size: 10, design: .monospaced)).foregroundColor(
              ScopeColors.text.color)),
          at: CGPoint(x: 8, y: 8), anchor: .topLeading)
      }
      return
    }
    if let image = cache.image(for: scene, size: size, scale: scale) {
      let w = CGFloat(image.width) / scale
      let h = CGFloat(image.height) / scale
      ctx.draw(
        Image(decorative: image, scale: scale), in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let layout = RasterLayout(
      width: Double(size.width), height: Double(size.height), laneCount: scene.lanes.count,
      steps: scene.result.steps)
    if let head = layout.playheadRect(
      tick: snapshot.clock.tick, phase: snapshot.clock.tickPhase, playing: snapshot.clock.playing)
    {
      ctx.fill(Path(head.cg), with: .color(.white.opacity(0.8)))
    }
  }
}
