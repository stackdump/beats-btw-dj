import Foundation

// The Wander walk on the stage (dj's own layer; stage.js has no Wander).
//
// The stage model reads each source deck's walk on the main actor once per frame into
// `StageContext.wander` (`StageWanderDeck`: on, paused, pace, countdown, the bar in the phrase,
// the last 4 moves). This model turns that into what `StageWanderLayer` draws:
//
//   * a phrase-progress arc per wandering deck: `StageWanderDeck.phraseProgress` straight from
//     the context (dashed when paused; the view decides that);
//   * a FLASH when a deck takes a new move (its newest move's `step` goes up): 2.5 s, fading
//     linearly, carrying that move's caption;
//   * a TICKER of the last moves across the source decks, newest last, each row fading out over
//     `tickerSeconds` from when the stage saw it.
//
// What a deck had already done when the stage first saw it is NOT news: the first reading of a
// deck only records its newest step (no flash, no ticker rows), so opening the window does not
// replay the walk. A log that goes backwards (a new session, a replay) is re-read the same way.
//
// It does NOT reset on a rebuild (`epoch`): a wander swap is itself a new track, and its flash
// must outlive the rebuild it causes. So it is not in `StageLayerModels.clearedOnRebuild`, and
// `reset()` stays the protocol's no-op. Nothing here reads a clock: `now` comes from the context.

/// A move the stage is flashing.
public struct StageWanderFlash: Equatable, Sendable {
  public var deck: String
  public var move: WanderMove
  /// The model's wall clock (seconds) when the stage saw it.
  public var startedAt: Double

  public init(deck: String, move: WanderMove, startedAt: Double) {
    self.deck = deck
    self.move = move
    self.startedAt = startedAt
  }
}

/// One row of the ticker.
public struct StageWanderTickerRow: Equatable, Sendable {
  public var deck: String
  public var move: WanderMove
  /// The model's wall clock (seconds) when the stage saw it.
  public var bornAt: Double
  /// 1 when it arrived, down to 0 at `StageWanderModel.tickerSeconds` (filled in by `rows`).
  public var alpha: Double

  public init(deck: String, move: WanderMove, bornAt: Double, alpha: Double = 1) {
    self.deck = deck
    self.move = move
    self.bornAt = bornAt
    self.alpha = alpha
  }

  /// "A · seed 41 → 44".
  public var caption: String { "\(deck) · \(move.detail)" }
}

@MainActor
public final class StageWanderModel: StageLayerModel {
  /// How long a new move flashes.
  public static let flashSeconds = 2.5
  /// How long a ticker row takes to fade out.
  public static let tickerSeconds = 12.0
  /// Rows the ticker keeps.
  public static let tickerLimit = StageWanderDeck.moveLimit

  /// The last frame's walks (the context's `wander`).
  public private(set) var decks: [StageWanderDeck] = []
  /// The move each deck is flashing (or last flashed: `flash(deck:now:)` says whether it still is).
  public private(set) var flashes: [String: StageWanderFlash] = [:]
  /// The ticker, oldest first, at most `tickerLimit` rows (the dead are dropped each frame).
  public private(set) var ticker: [StageWanderTickerRow] = []
  /// The newest step seen per deck (nil: not seen yet; -1: seen with an empty log).
  private var seen: [String: Int] = [:]

  public init() {}

  // MARK: frame

  public func advance(_ context: StageContext) {
    let now = context.now
    decks = context.wander
    for d in context.wander {
      let newest = d.moves.last?.step ?? -1
      guard let last = seen[d.deck] else {
        seen[d.deck] = newest
        continue
      }
      if newest < last {
        // the log went backwards (a new session): re-read, nothing is news
        seen[d.deck] = newest
        flashes[d.deck] = nil
        ticker.removeAll { $0.deck == d.deck }
        continue
      }
      guard newest > last else { continue }
      seen[d.deck] = newest
      for move in d.moves where move.step > last {
        ticker.append(StageWanderTickerRow(deck: d.deck, move: move, bornAt: now))
      }
      if let move = d.moves.last {
        flashes[d.deck] = StageWanderFlash(deck: d.deck, move: move, startedAt: now)
      }
    }
    ticker.removeAll { now - $0.bornAt >= Self.tickerSeconds }
    if ticker.count > Self.tickerLimit { ticker.removeFirst(ticker.count - Self.tickerLimit) }
    for (deck, f) in flashes where now - f.startedAt >= Self.flashSeconds {
      flashes[deck] = nil
    }
  }

  // MARK: what is drawn

  /// 1 right as a deck's new move is seen, down to 0 after `flashSeconds`; 0 with no flash or a
  /// clock that stepped back.
  public func flash(deck: String, now: Double) -> Double {
    guard let f = flashes[deck] else { return 0 }
    return Self.fade(age: now - f.startedAt, over: Self.flashSeconds)
  }

  /// The flashes still showing at `now`, by deck name.
  public func activeFlashes(now: Double) -> [StageWanderFlash] {
    flashes.values.filter { flash(deck: $0.deck, now: now) > 0 }.sorted { $0.deck < $1.deck }
  }

  /// The ticker at `now`, oldest first, each with its `alpha`; rows that faded out are left out.
  public func rows(now: Double) -> [StageWanderTickerRow] {
    ticker.compactMap { r in
      let a = Self.fade(age: now - r.bornAt, over: Self.tickerSeconds)
      guard a > 0 else { return nil }
      var out = r
      out.alpha = a
      return out
    }
  }

  /// The walk of one deck in the last frame.
  public func deck(_ name: String) -> StageWanderDeck? { decks.first { $0.deck == name } }

  /// Linear: 1 at age 0, 0 at `over`; 0 for a negative age (the clock stepped back).
  static func fade(age: Double, over: Double) -> Double {
    guard age >= 0, age < over else { return 0 }
    return 1 - age / over
  }
}
