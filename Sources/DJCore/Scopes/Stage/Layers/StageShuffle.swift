// StageShuffle: SPEC mode 12, the shuffle state machine and the arrow-key cycle (stage.js
// `applyVisualizer`, `setVisualizer`, `pickShuffleNext`, `SHUFFLE_FIRES`, and the arrow-key branch
// of `session.onKey`). Pure: the random source is injected and nothing reads a clock.
//
//   * Choosing "shuffle" in the toolbar starts shuffling at once: a random visualizer other than
//     the one showing, so the swap is seen immediately, and the fire counter at 0. The toolbar
//     keeps showing "shuffle" (its value is the selection, not what shows).
//   * While shuffling, every audible fire counts. The 64th resets the counter and switches to
//     another random one of the four real visualizers (constellation, corona, sonar, petal),
//     never the one showing. The swap follows the song's own pulse, not a timer.
//   * Choosing any fixed visualizer, or pressing an arrow key, ends shuffling.
//   * Arrow Right / Left cycle `['mandala', 'corona', 'sonar', 'petal']` from the visualizer that
//     is SHOWING (also while shuffling), wrapping at both ends.

public struct StageShuffle: Equatable, Sendable {
  /// `SHUFFLE_FIRES`: swap every this many fires while shuffling.
  public static let firesPerSwap = 64

  /// `session.shuffling`.
  public private(set) var shuffling = false
  /// `session.shuffleFireCount`.
  public private(set) var fireCount = 0
  /// `session.visualizer`: what shows now. Never `.shuffle`.
  public private(set) var current: StageVisualizer = .constellation

  public init() {}

  public init(current: StageVisualizer, shuffling: Bool = false, fireCount: Int = 0) {
    precondition(current != .shuffle, "what shows is a real visualizer")
    self.current = current
    self.shuffling = shuffling
    self.fireCount = fireCount
  }

  /// `pickShuffleNext`: `choices[floor(random * choices.length)]` over the real visualizers
  /// without `current`, in their cycle order.
  public static func pickNext<R: StageRandom>(
    excluding current: StageVisualizer, using rng: inout R
  ) -> StageVisualizer {
    let choices = StageVisualizer.real.filter { $0 != current }
    let i = Int((rng.next() * Double(choices.count)).rounded(.down))
    return choices[min(max(i, 0), choices.count - 1)]
  }

  /// `applyVisualizer(name)` for the toolbar's value. Returns what shows afterwards.
  @discardableResult
  public mutating func apply<R: StageRandom>(
    _ selection: StageVisualizer, using rng: inout R
  ) -> StageVisualizer {
    if selection == .shuffle {
      shuffling = true
      fireCount = 0
      // a random first visualizer so the swap is seen at once
      current = Self.pickNext(excluding: current, using: &rng)
    } else {
      shuffling = false
      current = selection
    }
    return current
  }

  /// The shuffle step of `stageOnTransitionFired`, for one fire. Returns true when this fire made
  /// the swap (`setVisualizer(next)`): the caller starts the new visualizer's state from scratch.
  @discardableResult
  public mutating func fired<R: StageRandom>(using rng: inout R) -> Bool {
    guard shuffling else { return false }
    fireCount += 1
    guard fireCount >= Self.firesPerSwap else { return false }
    fireCount = 0
    current = Self.pickNext(excluding: current, using: &rng)
    return true
  }

  /// The arrow keys: `order[(index(shown) + step) mod 4]` over `StageVisualizer.real`, `step` +1
  /// for Right and -1 for Left. A visualizer that is not in the order counts as the first.
  public static func cycle(from shown: StageVisualizer, step: Int) -> StageVisualizer {
    let order = StageVisualizer.real
    let i = max(0, order.firstIndex(of: shown) ?? 0)
    return order[((i + step) % order.count + order.count) % order.count]
  }
}
