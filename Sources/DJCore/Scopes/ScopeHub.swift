// ScopeHub: the one object that hands out `ScopeFeed`s and pumps them.
//
// Owned by the app model (`AppModel.scopeHub`), built over a `DJEngine`. Main thread only.
//
//   let feed = hub.feed(.deck("A"))   // one shared feed per source, created on first ask
//   feed.acquire()                    // starts the taps; the host view does this for you
//   hub.pump()                        // once per UI frame (idempotent), drains every subscribed feed
//   ... draw from feed ...
//   feed.release()                    // the last release switches the taps off
//
// Nothing is tapped while no feed is subscribed: an idle app pays nothing. `pump()` is safe to
// call from every Canvas in a frame (a second call finds at most the render cycles that ran in
// between; see the ScopeFeed header), and a hub with no subscribed feed does no work at all.
//
// `vizLevel` (0...3) is the quality level the perf monitor (a later mode) will drive; the
// frame pacer turns it into 30 / 15 / 8 / 4 draws per second (`ScopeFramePacer`).

import Foundation

@MainActor
public final class ScopeHub {
  public let engine: DJEngine
  private var feeds: [ScopeSource: ScopeFeed] = [:]
  public private(set) var pacer = ScopeFramePacer()
  /// Number of `pump()` calls that had a subscribed feed to drain.
  public private(set) var pumpCount = 0

  public init(engine: DJEngine) { self.engine = engine }

  /// The feed for a source: the same object every time.
  public func feed(_ source: ScopeSource) -> ScopeFeed {
    if let f = feeds[source] { return f }
    let f = ScopeFeed(source: source, engine: engine)
    feeds[source] = f
    return f
  }

  /// Sources a panel can offer: every deck by name, then the master.
  public var sources: [ScopeSource] {
    engine.decks.keys.sorted().map { .deck($0) } + [.master]
  }

  /// Feeds somebody has acquired.
  public var activeFeeds: [ScopeFeed] { feeds.values.filter(\.isActive) }

  /// Drain every subscribed feed. Once per UI frame; idempotent.
  public func pump() {
    let active = activeFeeds
    guard !active.isEmpty else { return }
    pumpCount += 1
    for f in active { f.pump() }
  }

  // MARK: pacing

  /// 0 = 30 fps, 1 = 15, 2 = 8, 3 = 4. Clamped.
  public var vizLevel: Int {
    get { pacer.level }
    set { pacer.level = newValue }
  }

  /// Seconds between draws at the current level: what a driver passes to
  /// `TimelineView(.animation(minimumInterval:))`.
  public var minFrameInterval: Double { pacer.minInterval }

  /// For a loop that ticks faster than `minFrameInterval`: is a draw due at `now` (seconds)?
  public func shouldDraw(now: Double) -> Bool { pacer.shouldDraw(now: now) }
}
