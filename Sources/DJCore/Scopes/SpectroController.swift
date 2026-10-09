// SpectroController: the state behind the Spectro view, between the feed and `SpectroScene`.
//
//   let spectro = SpectroController()
//   // every drawn frame, after hub.pump():
//   spectro.update(feed: feed, engine: hub.engine)
//   let scene = spectro.scene(feed: feed, width: w, height: h)
//   spectro.statusText(feed: feed)         // the line for the panel header
//
// It owns nothing that must outlive the view: the model is `ModelEngine`'s one per feed (made here
// on the first frame with `ModelEngine.start`, so the history accumulates from the moment a
// Spectro view first sees the feed and, from then on, whichever mode is on screen) and keeps what
// it learned when the host swaps views (scope kind, source) and rebuilds this one.
//
// What a frame does (scope.js `frame()` for the spectro view): `consume` deposits the new fires
// and finalises the spectrogram columns up to (not including) the sounding step,
// `floor(anchorStep + (now - anchorTime) / tickSec) - 1` (`ModelEngine.finaliseColumns`; a step
// ahead of the last final one by 64 or more starts the columns over instead).

import Foundation

@MainActor
public final class SpectroController {
  public private(set) var model: ModelEngine?

  private let cache: ModelKernelCache
  private weak var feed: ScopeFeed?

  /// `cache` defaults to the app-wide one; tests pass a private one.
  public init(cache: ModelKernelCache = .shared) {
    self.cache = cache
  }

  /// One drawn frame, part 1: bring the model up to the feed.
  public func update(feed: ScopeFeed, engine: DJEngine) {
    if self.feed !== feed {
      self.feed = feed
      model = nil
    }
    let m = model ?? ModelEngine.start(for: feed, engine: engine, cache: cache)
    model = m
    m.consume(feed)
  }

  /// One drawn frame, part 2: everything to paint, from the state `update` left.
  public func scene(feed: ScopeFeed, width: Double, height: Double) -> SpectroScene {
    let gutter = SpectroScene.gutter
    let input = SpectroScene.Input(
      axis: feed.timeAxis(x0: gutter, w: width - gutter), sections: feed.sections,
      running: feed.clock.playing, hasNet: feed.hasNet, hasTables: model?.hasTables ?? false,
      columns: model?.spectroColumns ?? .empty, fxLabel: model?.fxPointLabel,
      noNetText: feed.hasNet ? "" : feed.statusText)  // without a net that text IS the message
    return SpectroScene.make(width: width, height: height, input: input)
  }

  /// The panel header's line (scope.js `updateStatus`: the kernel status, and "paused" while the
  /// loop is not running), with what the model's FX are taken at and the transport when it is not
  /// playing. Without a net deck there is no model to report: the feed's own text.
  public func statusText(feed: ScopeFeed) -> String {
    guard feed.hasNet, let model else { return feed.statusText }
    var text = "\(model.status) · \(model.fxPointLabel)"
    if let note = feed.clock.transport.statusNote { text += " · \(note)" }
    return text
  }
}
