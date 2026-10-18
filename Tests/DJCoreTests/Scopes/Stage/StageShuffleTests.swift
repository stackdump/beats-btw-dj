import Testing

@testable import DJCore

// SPEC mode 12, shuffle and the arrow keys: the state machine (the 64th fire switches, never to
// the visualizer that shows, a fixed selection cancels shuffling), the arrow cycle both ways with
// its wrap, and the model and stage around it (the toolbar keeps showing "shuffle", the swap
// starts the new visualizer from scratch, the fire that makes the swap belongs to the new one).

/// A scripted random source: hands out `values` in order, then the last one forever.
private struct Script: StageRandom {
  var values: [Double]
  var taken = 0
  init(_ values: [Double]) { self.values = values }
  mutating func next() -> Double {
    defer { taken += 1 }
    return values[min(taken, values.count - 1)]
  }
}

private let real: [StageVisualizer] = [.constellation, .corona, .sonar, .petal, .minecraft]

private func pick(_ values: [Double], excluding current: StageVisualizer) -> StageVisualizer {
  var rng = Script(values)
  return StageShuffle.pickNext(excluding: current, using: &rng)
}

/// A shuffle machine and its random source behind a reference, so calls to the mutating methods
/// can sit inside `#expect`.
private final class Machine {
  var shuffle: StageShuffle
  var rng: Script

  init(_ shuffle: StageShuffle = StageShuffle(), draws: [Double] = [0]) {
    self.shuffle = shuffle
    rng = Script(draws)
  }

  var current: StageVisualizer { shuffle.current }
  var shuffling: Bool { shuffle.shuffling }
  var fireCount: Int { shuffle.fireCount }
  var drawn: Int { rng.taken }

  func fired() -> Bool { shuffle.fired(using: &rng) }

  @discardableResult
  func apply(_ v: StageVisualizer) -> StageVisualizer { shuffle.apply(v, using: &rng) }
}

struct StageShuffleStateTests {
  @Test func theSwapEveryNFiresIs64AndTheOrderIsTheCycleOrder() {
    #expect(StageShuffle.firesPerSwap == 64)
    #expect(StageVisualizer.real == [.constellation, .corona, .sonar, .petal, .minecraft])
    #expect(StageVisualizer.constellation.rawValue == "mandala")
  }

  @Test func pickNextChoosesFloorOfRandomTimesTheRemainingFour() {
    // excluding the constellation: [corona, sonar, petal, minecraft]
    let cases: [(Double, StageVisualizer)] = [
      (0, .corona), (0.2499, .corona), (0.25, .sonar), (0.4999, .sonar), (0.5, .petal),
      (0.7499, .petal), (0.75, .minecraft), (0.999999, .minecraft),
    ]
    for (r, want) in cases {
      #expect(pick([r], excluding: .constellation) == want, "r = \(r)")
    }
    // excluding the sonar: [constellation, corona, petal, minecraft]
    #expect(pick([0.1], excluding: .sonar) == .constellation)
    #expect(pick([0.3], excluding: .sonar) == .corona)
    #expect(pick([0.6], excluding: .sonar) == .petal)
    #expect(pick([0.9], excluding: .sonar) == .minecraft)
    // a random source that returns exactly 1 (it must not) cannot index past the end
    #expect(pick([1], excluding: .petal) == .minecraft)
  }

  @Test func pickNextNeverReturnsTheVisualizerThatShowsOrShuffle() {
    var rng = StageSeededRandom(seed: 99)
    for current in real {
      var seen = Set<StageVisualizer>()
      for _ in 0..<400 {
        let next = StageShuffle.pickNext(excluding: current, using: &rng)
        #expect(next != current && next != .shuffle)
        seen.insert(next)
      }
      #expect(seen.count == 4, "every other one turns up: \(seen)")
    }
  }

  @Test func choosingShuffleStartsAtOnceOnARandomOtherVisualizer() {
    let m = Machine(draws: [0.3])  // from the constellation: [corona, sonar, petal, mc] -> sonar
    let shown = m.apply(.shuffle)
    #expect(shown == .sonar && m.current == .sonar && m.shuffling && m.fireCount == 0)
    #expect(m.drawn == 1)
    // from the sonar the next first pick cannot be the sonar
    let again = Machine(StageShuffle(current: .sonar), draws: [0.3])
    again.apply(.shuffle)
    #expect(again.current == .corona && again.fireCount == 0)
  }

  @Test func the64thFireSwapsAndEveryOtherFireDoesNot() {
    // excluding the corona: [constellation, sonar, petal, minecraft] -> petal
    let m = Machine(StageShuffle(current: .corona, shuffling: true), draws: [0.6])
    for n in 1...63 {
      #expect(!m.fired(), "fire \(n)")
      #expect(m.current == .corona && m.fireCount == n)
    }
    #expect(m.drawn == 0, "no random number is drawn before the swap")
    #expect(m.fired(), "the 64th")
    #expect(m.current == .petal && m.fireCount == 0, "counter reset, switched")
    for n in 1...63 { #expect(!m.fired(), "fire \(n) again") }
    #expect(m.fired() && m.current != .petal)
  }

  @Test func neverTheSameVisualizerTwiceInARowOverManySwaps() {
    var s = StageShuffle(current: .constellation, shuffling: true)
    var rng = StageSeededRandom(seed: 5)
    var last = s.current
    var swaps = 0
    for _ in 0..<(64 * 300) where s.fired(using: &rng) {
      swaps += 1
      #expect(s.current != last && s.current != .shuffle)
      last = s.current
    }
    #expect(swaps == 300)
  }

  @Test func firesAreNotCountedWhileNotShuffling() {
    let m = Machine(StageShuffle(current: .corona))
    for _ in 0..<500 { #expect(!m.fired()) }
    #expect(m.fireCount == 0 && m.current == .corona && m.drawn == 0)
  }

  @Test func aFixedSelectionCancelsShufflingAndShowsThatVisualizer() {
    let m = Machine(StageShuffle(current: .sonar, shuffling: true, fireCount: 40))
    #expect(m.apply(.petal) == .petal)
    #expect(!m.shuffling && m.current == .petal)
    for _ in 0..<100 { #expect(!m.fired()) }
    #expect(m.current == .petal, "stays put however many fires")
    // and shuffle again starts a fresh count
    m.apply(.shuffle)
    #expect(m.shuffling && m.fireCount == 0)
  }

  @Test func theArrowCycleWrapsBothWays() {
    var right: [StageVisualizer] = []
    var v = StageVisualizer.constellation
    for _ in 0..<5 {
      v = StageShuffle.cycle(from: v, step: 1)
      right.append(v)
    }
    #expect(right == [.corona, .sonar, .petal, .minecraft, .constellation], "right, wrapping")
    var left: [StageVisualizer] = []
    v = .constellation
    for _ in 0..<5 {
      v = StageShuffle.cycle(from: v, step: -1)
      left.append(v)
    }
    #expect(left == [.minecraft, .petal, .sonar, .corona, .constellation], "left, wrapping")
    // a name outside the order counts as the first (indexOf = -1 -> 0)
    #expect(StageShuffle.cycle(from: .shuffle, step: 1) == .corona)
    #expect(StageShuffle.cycle(from: .shuffle, step: -1) == .minecraft)
  }
}

@MainActor
struct StageShuffleModelTests {
  private func fire(_ net: String = "n", channel: Int = 1, wall: Double = 0) -> StageFire {
    StageFire(
      time: 0, wallTime: wall, panel: nil, deck: "A", netId: net, transitionId: "t",
      transition: nil, origin: nil, note: 60, velocity: 100, channel: channel, durSec: 0.1,
      macroRunning: false)
  }

  private func fires(_ n: Int, wall: (Int) -> Double = { _ in 0 }) -> [StageFire] {
    (0..<n).map { fire("n\($0)", channel: 1 + $0 % 5, wall: wall($0)) }
  }

  private func context(
    _ shown: StageVisualizer, selection: StageVisualizer? = nil, fires: [StageFire] = [],
    now: Double = 100, dt: Double = 1.0 / 60
  ) -> StageContext {
    StageContext(
      width: 800, height: 600,
      layout: StagePanelLayout.layoutRing(width: 800, height: 600, count: 0),
      now: now, dt: dt, fires: fires, selection: selection ?? shown, visualizer: shown)
  }

  /// A model whose shuffle draws from `values`, one per pick.
  private func model(_ values: [Double]) -> StageSoloModel {
    var s = Script(values)
    return StageSoloModel(random: { s.next() })
  }

  @Test func aFixedSelectionIsShownAsIsAndNeverShuffles() {
    let m = model([0])
    #expect(m.resolveVisualizer(selection: .corona, fires: fires(200), now: 1) == .corona)
    #expect(m.resolveVisualizer(selection: .corona, fires: fires(200), now: 2) == .corona)
    #expect(!m.shuffle.shuffling)
    #expect(m.resolveVisualizer(selection: .constellation, fires: [], now: 3) == .constellation)
  }

  @Test func shuffleShowsARandomOtherOneAtOnceThenSwapsOnTheSixtyFourthFire() {
    // picks: 0.4 -> from the constellation [corona, sonar, petal, minecraft] -> sonar;
    //        0.6 -> excluding the sonar [constellation, corona, petal, minecraft] -> petal
    let m = model([0.4, 0.6])
    #expect(m.resolveVisualizer(selection: .shuffle, fires: [], now: 1) == .sonar)
    #expect(m.shuffle.shuffling)
    // 63 fires over two frames: still the sonar
    #expect(m.resolveVisualizer(selection: .shuffle, fires: fires(30), now: 2) == .sonar)
    #expect(m.resolveVisualizer(selection: .shuffle, fires: fires(33), now: 3) == .sonar)
    #expect(m.shuffle.fireCount == 63)
    // the 64th is the first fire of the next frame
    #expect(m.resolveVisualizer(selection: .shuffle, fires: fires(5), now: 4) == .petal)
    #expect(m.shuffle.fireCount == 4, "the other four fires of that frame already count again")
  }

  @Test func theSwapIsDecidedInsideAFrameAndNeverReturnsShuffle() {
    let m = model([0.1])  // excluding anything: the first of the others
    var shown: [StageVisualizer] = []
    for frame in 0..<12 {
      shown.append(m.resolveVisualizer(selection: .shuffle, fires: fires(32), now: Double(frame)))
    }
    #expect(!shown.contains(.shuffle))
    // 12 frames * 32 fires = 384 fires = 6 swaps, on the frames that hold fire 64, 128, ...
    let changes = zip(shown, shown.dropFirst()).enumerated().filter { $1.0 != $1.1 }.map(\.offset)
    #expect(changes.map { $0 + 1 } == [1, 3, 5, 7, 9, 11], "swap frames: \(shown)")
  }

  @Test func theFireThatMakesTheSwapBelongsToTheNewVisualizer() {
    // sonar first, then the 64th fire swaps to the petal: the sonar rings of fires 1...63 are
    // thrown away by setVisualizer, the petal gets the 64th fire only
    let m = model([0.4, 0.6])
    let first = m.resolveVisualizer(selection: .shuffle, fires: [], now: 1)
    m.advance(context(first, selection: .shuffle, fires: []))
    #expect(first == .sonar)
    // 100 ms apart
    let batch = fires(70, wall: { 99.0 + Double($0) * 0.1 })
    let shown = m.resolveVisualizer(selection: .shuffle, fires: Array(batch[0..<64]), now: 2)
    #expect(shown == .petal, "fire 64 swapped")
    m.advance(context(shown, selection: .shuffle, fires: Array(batch[0..<64]), now: 2))
    #expect(m.sonar.rings.isEmpty, "the sonar's state went with the swap")
    #expect(m.petals.energy.count == 1, "only the 64th fire is the petal's: \(m.petals.energy)")
    #expect(m.petals.energy.keys.first?.netId == "n63")
  }

  @Test func aSwapToTheSonarLetsTheSwappingFireRingAndTheEarlierOnesNot() {
    // petal first (0.6 -> [corona, sonar, petal, minecraft] -> petal), then 0.6 excluding the
    // petal [constellation, corona, sonar, minecraft] -> sonar
    let m = model([0.6, 0.6])
    let first = m.resolveVisualizer(selection: .shuffle, fires: [], now: 1)
    #expect(first == .petal)
    m.advance(context(first, selection: .shuffle))
    let batch = fires(66, wall: { 98.0 + Double($0) * 0.1 })
    let shown = m.resolveVisualizer(selection: .shuffle, fires: batch, now: 2)
    #expect(shown == .sonar)
    m.advance(context(shown, selection: .shuffle, fires: batch, now: 105))
    // fires 64, 65 and 66 (indices 63...65) are the sonar's: the first rings at 63*100 ms
    #expect(m.petals.energy.isEmpty, "petal energies are gone")
    #expect(!m.sonar.rings.isEmpty && m.sonar.rings.count <= 3)
    #expect(m.sonar.rings.first?.born == (98.0 + 63 * 0.1) * 1000)
  }

  @Test func theToolbarSelectionKeepsSayingShuffleWhileTheVisualizerChanges() {
    let m = model([0.4, 0.6])
    let shown = m.resolveVisualizer(selection: .shuffle, fires: [], now: 1)
    let ctx = context(shown, selection: .shuffle)
    #expect(ctx.selection == .shuffle && ctx.visualizer == .sonar && ctx.isSolo)
    let swapped = m.resolveVisualizer(selection: .shuffle, fires: fires(64), now: 2)
    let ctx2 = context(swapped, selection: .shuffle)
    #expect(ctx2.selection == .shuffle && ctx2.visualizer == .petal)
    #expect(StageVisualizer.shuffle.title == "🔀 Shuffle")
  }

  @Test func choosingAFixedVisualizerWhileShufflingStopsTheSwaps() {
    let m = model([0.4])
    _ = m.resolveVisualizer(selection: .shuffle, fires: fires(10), now: 1)
    #expect(m.shuffle.shuffling)
    #expect(m.resolveVisualizer(selection: .corona, fires: fires(500), now: 2) == .corona)
    #expect(!m.shuffle.shuffling)
    #expect(m.resolveVisualizer(selection: .corona, fires: fires(500), now: 3) == .corona)
  }

  // MARK: arrows

  @Test func theArrowKeysWriteTheSelectionAndWrapBothWays() {
    let m = model([0])
    let settings = StageSettings()
    settings.visualizer = .constellation
    _ = m.resolveVisualizer(selection: settings.visualizer, fires: [], now: 0)
    var seen: [StageVisualizer] = []
    for _ in 0..<5 {
      #expect(m.handleKey(.right, settings: settings))
      seen.append(settings.visualizer)
      _ = m.resolveVisualizer(selection: settings.visualizer, fires: [], now: 0)
    }
    #expect(seen == [.corona, .sonar, .petal, .minecraft, .constellation])
    seen = []
    for _ in 0..<5 {
      #expect(m.handleKey(.left, settings: settings))
      seen.append(settings.visualizer)
      _ = m.resolveVisualizer(selection: settings.visualizer, fires: [], now: 0)
    }
    #expect(seen == [.minecraft, .petal, .sonar, .corona, .constellation])
    #expect(!m.handleKey(.t, settings: settings), "T is the card's")
  }

  @Test func anArrowWhileShufflingCyclesFromWhatShowsAndEndsTheShuffle() {
    let m = model([0.4])  // sonar first
    let settings = StageSettings()
    settings.visualizer = .shuffle
    let shown = m.resolveVisualizer(selection: .shuffle, fires: [], now: 0)
    #expect(shown == .sonar)
    #expect(m.handleKey(.right, settings: settings))
    #expect(settings.visualizer == .petal, "from the sonar, not from `shuffle`")
    #expect(
      m.resolveVisualizer(selection: settings.visualizer, fires: fires(200), now: 1) == .petal)
    #expect(!m.shuffle.shuffling)
    // and left from the shuffle's visualizer goes the other way
    settings.visualizer = .shuffle
    let again = m.resolveVisualizer(selection: .shuffle, fires: [], now: 2)
    #expect(m.handleKey(.left, settings: settings))
    #expect(settings.visualizer == StageShuffle.cycle(from: again, step: -1))
  }

  @Test func twoArrowPressesBeforeAFrameStillCycleTwice() {
    let m = model([0])
    let settings = StageSettings()
    settings.visualizer = .constellation
    _ = m.resolveVisualizer(selection: .constellation, fires: [], now: 0)
    _ = m.handleKey(.right, settings: settings)
    _ = m.handleKey(.right, settings: settings)
    #expect(settings.visualizer == .sonar)
  }
}

@MainActor
struct StageShuffleEngineTests {
  @Test func theStageSwapsEvery64RealFiresAndTheToolbarKeepsSayingShuffle() throws {
    let h = try StageHarness()
    defer { h.stop() }
    var seq = StageSeededRandom(seed: 3)
    h.model.layers.solo.random = { seq.next() }
    h.model.settings.visualizer = .shuffle
    var shownRuns: [StageVisualizer] = []
    var firesSeen = 0
    var firesAtSwap: [Int] = []
    var last: StageVisualizer?
    for _ in 0..<400 {  // 20 s
      h.step()
      let ctx = h.ctx
      #expect(ctx.selection == .shuffle && ctx.visualizer != .shuffle)
      #expect(h.model.settings.visualizer == .shuffle, "the select is never rewritten")
      firesSeen += ctx.fires.count
      if ctx.visualizer != last {
        if last != nil { firesAtSwap.append(firesSeen) }
        shownRuns.append(ctx.visualizer)
        last = ctx.visualizer
      }
    }
    #expect(shownRuns.count >= 4, "20 s of a dense song is several swaps: \(shownRuns)")
    #expect(zip(shownRuns, shownRuns.dropFirst()).allSatisfy { $0 != $1 }, "never twice in a row")
    // between two swaps the stage saw (about) 64 fires: the swap lands on the frame that holds the
    // 64th, so the count at the swap frames is within a frame's worth of a multiple of 64
    for (i, n) in firesAtSwap.enumerated() {
      let expected = 64 * (i + 1)
      #expect(
        n >= expected && n < expected + 12, "swap \(i + 1) after \(n) fires (want \(expected))")
    }
  }

  @Test func arrowsGoThroughTheStageModelsKeyHandlingAndCancelTheShuffle() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.model.layers.solo.random = { 0.0 }
    h.model.settings.visualizer = .shuffle
    h.step()
    let shown = h.ctx.visualizer
    #expect(h.ctx.selection == .shuffle && shown != .shuffle)
    #expect(h.model.handleKey(.right))
    #expect(h.model.settings.visualizer == StageShuffle.cycle(from: shown, step: 1))
    h.step()
    #expect(h.ctx.selection != .shuffle && h.ctx.visualizer == h.ctx.selection)
    h.run(8)  // a lot of fires: a fixed selection never swaps
    #expect(h.ctx.visualizer == h.model.settings.visualizer)
    #expect(h.model.handleKey(.left))
  }
}
