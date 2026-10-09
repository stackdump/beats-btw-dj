// BandsController: the state behind the Bands view, between the feed and `BandsScene`. The shape
// of `SpectroController`:
//
//   let bands = BandsController()
//   // every drawn frame, after hub.pump():
//   bands.update(feed: feed, engine: hub.engine, measured: measured)
//   let scene = bands.scene(feed: feed, width: w, measured: measured)   // at most 4 times a second
//   bands.statusText(feed: feed)          // the line for the panel header
//
// It owns nothing that must outlive the view: the model is `ModelEngine`'s one per feed (made on
// the first frame with `ModelEngine.start`, so the bars accumulate from the moment a Bands view
// first sees the feed and, from then on, whichever mode is on screen, with the Spectro of the
// same source sharing them) and the reader is `MeasuredReaderStore`'s, created the first time
// "measured" is on. Both keep what they learned when the host swaps views and rebuilds this one.
//
// WHAT A FRAME DOES (scope.js `frame()` for the bands view)
//   * the MODEL takes in the new fires (`consume`: deposits per bar), as for every mode;
//   * the MEASURED side, only while the panel's "measured" is on and the source has a net: one
//     `MeasuredReader.update` (one FFT of the newest 4096 samples). Nothing at all when it is off.
//     This runs on EVERY drawn frame, as in the JS where `readMeasured` runs before the view's
//     rate limit;
//   * the PICTURE (`scene`) is rebuilt at most every `redrawInterval` = 250 ms of wall time
//     (scope.js: `if (now - s.bandsAt < 250) return;` in front of `draw`, "4 Hz is plenty, and its
//     per-cell text is the priciest draw here"), and in between the last scene is handed out
//     again. The JS keeps the last picture on its canvas; a SwiftUI Canvas repaints from the
//     scene each frame, so the held scene is what keeps the cost of the stats and the cells at
//     4 Hz, and the view draws the picture into a bitmap once per scene (`BandsImage`) and only
//     blits it in between. A change of width, of the panel's "measured" or of the feed's
//     generation (a new track) rebuilds at once.
//
// THE READER IS PART OF THE PICTURE ONLY WHILE IT IS READ: "measured" on and a source with a net.
// A reader that stopped (measured unticked, or the deck now plays a sample) keeps the bars it had
// until it is next enabled, and the picture must not show them: a model-only panel must not
// widen to them, and a deck that was a net deck must say "needs a net deck", not paint the old
// song's measured block.
//
// A STRETCH IN ANOTHER VIEW leaves no reads (only the drawing mode reads; see MeasuredReader's
// GAPS): after more than a second away the measured coverage window restarts, so the bars from
// before the hole keep their measured digits but lose their residual cells, and the statistics
// and the tilt line start over. scope.js reads in every view and restarts only when "measured"
// is ticked again, so there the residual survives a visit to another view (a deviation, listed in
// the mode's report).
//
// The clock is injectable (`now`, seconds, monotonic) for tests.

import Foundation

@MainActor
public final class BandsController {
  /// scope.js: the Bands view redraws at most every 250 ms.
  public static let redrawInterval = 0.25

  public private(set) var model: ModelEngine?
  public private(set) var reader: MeasuredReader?
  /// Scenes built so far (also the `revision` of the last one).
  public private(set) var builds = 0
  /// The statistics of the last scene built with "measured" on (nil when it had none).
  public private(set) var stats: BandsStats?

  private let cache: ModelKernelCache
  private let readers: MeasuredReaderStore
  private let now: @MainActor () -> Double
  private weak var feed: ScopeFeed?

  private struct Key: Equatable {
    var generation: Int
    var width: Double
    var measured: Bool
  }
  private var held: (scene: BandsScene, key: Key, at: Double)?

  /// `cache` and `readers` default to the app-wide ones; tests pass private ones.
  public init(
    cache: ModelKernelCache = .shared, readers: MeasuredReaderStore = .shared,
    now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.cache = cache
    self.readers = readers
    self.now = now
  }

  /// One drawn frame, part 1: bring the model and (when `measured`) the reader up to the feed.
  public func update(feed: ScopeFeed, engine: DJEngine, measured: Bool) {
    if self.feed !== feed {
      self.feed = feed
      model = nil
      reader = nil
      held = nil
    }
    let m = model ?? ModelEngine.start(for: feed, engine: engine, cache: cache)
    model = m
    m.consume(feed)
    if measured && feed.hasNet {
      let r = reader ?? readers.reader(for: feed)
      reader = r
      r.update(feed: feed, enabled: true)
    } else {
      reader?.update(feed: feed, enabled: false)
    }
  }

  /// One drawn frame, part 2: what to paint. At most one rebuild per `redrawInterval` (see the
  /// header); a different width, "measured" or generation rebuilds at once.
  public func scene(feed: ScopeFeed, width: Double, measured: Bool) -> BandsScene {
    let t = now()
    let key = Key(generation: feed.generation, width: width, measured: measured)
    if let h = held, h.key == key, t >= h.at, t - h.at < Self.redrawInterval { return h.scene }
    var input = BandsScene.Input(
      model: .empty, sections: feed.sections, measured: measured,
      emptyText: emptyText(feed: feed))
    if let model {
      // The reader is part of the picture only while it is being read: "measured" on and a net
      // to compare it with. Otherwise it still holds the bars of what it last read (a deck that
      // was a net deck and now plays a sample would go on showing the old song's measured block).
      input.model = BandsModel(model: model, reader: measured && feed.hasNet ? reader : nil)
      input.modelStatus = model.status
      input.fires = model.fires
    }
    var scene = BandsScene.make(width: width, input: input)
    builds += 1
    scene.revision = builds
    stats = scene.stats
    held = (scene, key, t)
    return scene
  }

  /// What the empty picture says: the source's own message without a net deck, the hint once the
  /// model has its tables, else the kernel status (scope.js `drawBands`).
  func emptyText(feed: ScopeFeed) -> String {
    if !feed.hasNet { return feed.statusText }
    guard let model else { return BandsScene.waitingText }
    return model.hasTables ? BandsScene.waitingText : model.status
  }

  /// The panel header's line, as the Spectro's: the kernel status with what the model's FX are
  /// taken at, and the transport when it is not playing. Without a net deck the feed's own text.
  public func statusText(feed: ScopeFeed) -> String {
    guard feed.hasNet, let model else { return feed.statusText }
    var text = "\(model.status) · \(model.fxPointLabel)"
    if let note = feed.clock.transport.statusNote { text += " · \(note)" }
    return text
  }
}
