// SpectroController: the state behind the Spectro view, between the feed and `SpectroScene`.
//
//   let spectro = SpectroController()
//   // every drawn frame, after hub.pump():
//   spectro.update(feed: feed, engine: hub.engine, measured: measured)
//   let scene = spectro.scene(feed: feed, width: w, height: h, measured: measured)
//   spectro.statusText(feed: feed)         // the line for the panel header
//
// It owns nothing that must outlive the view: the model is `ModelEngine`'s one per feed (made here
// on the first frame with `ModelEngine.start`, so the history accumulates from the moment a
// Spectro view first sees the feed and, from then on, whichever mode is on screen) and the reader
// is `MeasuredReaderStore`'s, created the first time "measured" is on. Both keep what they learned
// when the host swaps views (scope kind, source) and rebuilds this one.
//
// What a frame does (scope.js `frame()` for the spectro views):
//   * the MODEL: `consume` deposits the new fires and finalises the spectrogram columns up to
//     (not including) the sounding step, `floor(anchorStep + (now - anchorTime) / tickSec) - 1`
//     (`ModelEngine.finaliseColumns`; a step ahead of the last final one by 64 or more starts the
//     columns over instead);
//   * the MEASURED side, only when the panel's "measured" is on: one `MeasuredReader.update`
//     (one FFT of the newest 4096 samples; nothing at all when it is off).

import Foundation

@MainActor
public final class SpectroController {
  public private(set) var model: ModelEngine?
  public private(set) var reader: MeasuredReader?

  private let cache: ModelKernelCache
  private let readers: MeasuredReaderStore
  private weak var feed: ScopeFeed?

  /// `cache` and `readers` default to the app-wide ones; tests pass private ones.
  public init(cache: ModelKernelCache = .shared, readers: MeasuredReaderStore = .shared) {
    self.cache = cache
    self.readers = readers
  }

  /// One drawn frame, part 1: bring the model and (when `measured`) the reader up to the feed.
  public func update(feed: ScopeFeed, engine: DJEngine, measured: Bool) {
    if self.feed !== feed {
      self.feed = feed
      model = nil
      reader = nil
    }
    let m = model ?? ModelEngine.start(for: feed, engine: engine, cache: cache)
    model = m
    m.consume(feed)
    if measured {
      let r = reader ?? readers.reader(for: feed)
      reader = r
      r.update(feed: feed, enabled: true)
    } else {
      reader?.update(feed: feed, enabled: false)
    }
  }

  /// One drawn frame, part 2: everything to paint, from the state `update` left.
  public func scene(feed: ScopeFeed, width: Double, height: Double, measured: Bool)
    -> SpectroScene
  {
    let gutter = SpectroScene.gutter
    var input = SpectroScene.Input(
      axis: feed.timeAxis(x0: gutter, w: width - gutter), sections: feed.sections,
      running: feed.clock.playing, hasNet: feed.hasNet, hasTables: model?.hasTables ?? false,
      columns: model?.spectroColumns ?? .empty, fxLabel: model?.fxPointLabel,
      noNetText: feed.source == .master ? "no net deck" : "needs a net deck")
    if measured { input.measured = reader?.frames ?? MeasuredFrameRing() }
    return SpectroScene.make(width: width, height: height, input: input)
  }

  /// The panel header's line (scope.js `updateStatus`: the kernel status), with what the model's
  /// FX are taken at. Without a net deck there is no model to report: the feed's own text.
  public func statusText(feed: ScopeFeed) -> String {
    guard feed.hasNet, let model else { return feed.statusText }
    return "\(model.status) · \(model.fxPointLabel)"
  }
}
