import Foundation

// SPEC mode 23: the rolling timeline dots (lib/backend/audio-io.js `vizSpawnParticle` and
// `vizDrawTimeline`). Every audible fire leaves a dot that slides from the right edge to the
// left over an adaptive window, colour by part, fading out over the last 15 %.
//
// Numbers only: the strip view in DJViews draws what `layout` returns. The dots are the very
// fires the scope modes read: `TimelineDotsModel` takes them from a `ScopeFeed`'s fire log
// "since last look". Time is the engine's audio clock (a fire's `time`, the feed's `nowTime`),
// not `Date.now()` as in the JS, so the dots stay on the beat when the UI hitches and stop
// when the engine does.

/// One fire as the strip remembers it.
public struct TimelineDot: Equatable, Sendable {
  /// Audio seconds at which the note sounds.
  public var time: Double
  public var color: ScopeColor

  public init(time: Double, color: ScopeColor) {
    self.time = time
    self.color = color
  }
}

/// A dot as drawn: a streak behind a head, at `x`, at `alpha`.
public struct TimelineDotDraw: Equatable, Sendable {
  public var x: Double
  public var alpha: Double
  /// Length of the gradient streak that trails the head to its left.
  public var streakLength: Double
  public var color: ScopeColor

  public init(x: Double, alpha: Double, streakLength: Double, color: ScopeColor) {
    self.x = x
    self.alpha = alpha
    self.streakLength = streakLength
    self.color = color
  }
}

/// The constants of `vizDrawTimeline`.
public enum TimelineGeometry {
  /// `_vizHistory.length > 200` → `shift()`.
  public static let cap = 200
  /// `Math.max(2000, …)`: the window is never shorter than 2 s.
  public static let minWindowMs = 2000.0
  /// `elapsed + 500`.
  public static let windowPadMs = 500.0
  /// Four bars: `(240 / Math.max(60, tempo)) * 1000` ms.
  public static func maxWindowMs(tempo: Double) -> Double { 240 / max(60, tempo) * 1000 }
  /// `pct < 0.85 ? 0.7 : …`: the dot holds 0.7 until 85 % of the window, then fades linearly.
  public static let baseAlpha = 0.7
  public static let fadeStart = 0.85
  /// `Math.min(20, (w / windowMs) * 120)`.
  public static let streakMax = 20.0
  public static let streakPerWidth = 120.0
  /// In the JS the dots sit at fixed offsets in the workspace canvas, well below its top: the
  /// streak is `fillRect(x - streakLen, 27, streakLen, 6)` and the head `arc(x, 30, 4, …)`, so
  /// they occupy y 26...34. The strip is only as tall as the dots are, so those rows are counted
  /// from `stripTop`, the canvas row the strip starts at.
  public static let stripTop = 24.0
  /// Streak rectangle, from the top of the strip.
  public static let streakY = 27.0 - stripTop
  public static let streakHeight = 6.0
  /// Head circle: centre y and radius.
  public static let headY = 30.0 - stripTop
  public static let headRadius = 4.0
  /// The head's circle (2...10) with two points of air above and below.
  public static let stripHeight = 12.0
}

/// The history behind the strip: up to 200 dots, oldest first.
public struct TimelineDots: Equatable, Sendable {
  public private(set) var dots: [TimelineDot] = []

  public init() {}

  public var isEmpty: Bool { dots.isEmpty }
  public var count: Int { dots.count }

  /// `vizSpawnParticle`: push, and drop the oldest past 200.
  public mutating func add(_ dot: TimelineDot) {
    dots.append(dot)
    if dots.count > TimelineGeometry.cap { dots.removeFirst() }
  }

  public mutating func removeAll() { dots.removeAll(keepingCapacity: true) }

  /// The window in ms: `max(2000, min(maxWindowMs, elapsed + 500))`, `elapsed` being the age of
  /// the oldest dot (0 for none). Nil when the tempo is not a finite number: the JS bails out
  /// there ("a transiently non-finite `_tempo` makes every x NaN").
  public func windowMs(now: Double, tempo: Double) -> Double? {
    // JS `Math.max(60, NaN)` is NaN; Swift's `max` would answer 60, so say it outright
    if tempo.isNaN { return nil }
    let elapsed = dots.first.map { (now - $0.time) * 1000 } ?? 0
    let w = max(
      TimelineGeometry.minWindowMs,
      min(TimelineGeometry.maxWindowMs(tempo: tempo), elapsed + TimelineGeometry.windowPadMs))
    return w.isFinite && w > 0 ? w : nil
  }

  /// `alpha` of a dot at `pct = age / window`.
  public static func alpha(atFraction pct: Double) -> Double {
    pct < TimelineGeometry.fadeStart
      ? TimelineGeometry.baseAlpha
      : TimelineGeometry.baseAlpha
        * (1 - (pct - TimelineGeometry.fadeStart) / (1 - TimelineGeometry.fadeStart))
  }

  /// The dots of one frame, oldest first, for a strip `width` wide at audio time `now`. A dot
  /// older than the window is skipped; so is one whose position is not finite.
  public func layout(now: Double, width: Double, tempo: Double) -> [TimelineDotDraw] {
    guard let window = windowMs(now: now, tempo: tempo) else { return [] }
    let streak = min(TimelineGeometry.streakMax, width / window * TimelineGeometry.streakPerWidth)
    var out: [TimelineDotDraw] = []
    out.reserveCapacity(dots.count)
    for d in dots {
      let age = (now - d.time) * 1000
      if age > window { continue }
      let x = width - age / window * width
      if !x.isFinite { continue }
      out.append(
        TimelineDotDraw(
          x: x, alpha: Self.alpha(atFraction: age / window), streakLength: streak, color: d.color))
    }
    return out
  }

  /// Drop the dots older than the window (after a draw, as `vizDrawTimeline` does).
  public mutating func prune(now: Double, tempo: Double) {
    guard let window = windowMs(now: now, tempo: tempo) else { return }
    var n = 0
    while n < dots.count, (now - dots[n].time) * 1000 > window { n += 1 }
    if n > 0 { dots.removeFirst(n) }
  }
}

/// Fills a `TimelineDots` from a scope feed: every fire the feed logs becomes a dot, once.
///
/// The cursor is the feed's own fire count ("since last look"): nothing is replayed, and a
/// feed that was cleared (a new track, a restart: `generation` moved) empties the strip, since
/// the lane colours of the old song no longer mean anything.
@MainActor
public final class TimelineDotsModel {
  public private(set) var history = TimelineDots()
  private var cursor: Int
  private var generation: Int

  /// Starts at the feed's present: the fires logged before the strip existed are not dots.
  public init(feed: ScopeFeed) {
    cursor = feed.fireCount
    generation = feed.generation
  }

  /// Drop the dots older than the window (`vizDrawTimeline` prunes after it draws).
  public func prune(now: Double, tempo: Double) { history.prune(now: now, tempo: tempo) }

  /// Take the fires the feed has logged since the last call.
  public func update(from feed: ScopeFeed) {
    if feed.generation != generation {
      generation = feed.generation
      history.removeAll()
      cursor = feed.fireLog.firstNumber  // everything held belongs to the new song
    }
    let lanes = feed.lanes
    for n in feed.fireLog.numbers(since: cursor) {
      guard let f = feed.fireLog.fire(number: n), lanes.indices.contains(f.lane) else { continue }
      let lane = lanes[f.lane]
      // vizColorForNet by the net's id; `#888` for a part the table does not know
      history.add(
        TimelineDot(time: f.time, color: ScopeColors.laneColor(forNet: lane.ids.first ?? lane.key))
      )
    }
    cursor = feed.fireCount
  }
}

extension ScopeSubscription {
  /// Hold `feed` while `active`, nothing otherwise: the strip listens to a deck only while the
  /// deck's transport runs, so a stopped deck on screen costs no deck tap, no pump and no
  /// redraws (`move(to:)` acquires first, then releases, and does nothing for the same feed
  /// again). Call it on appear and whenever `active` changes; `release()` on disappear.
  public func follow(_ feed: ScopeFeed, while active: Bool) {
    move(to: active ? feed : nil)
  }
}
