// The stage's solo visualizers (SPEC modes 9-12: corona, sonar, petal, shuffle).
//
// While `context.visualizer.isSolo` the host hides the panel grid, the flame canvas and the
// constellation controls (stage.js `viz-solo`) and shows `StageSoloLayer` full window. This model
// owns the state of the three visualizers and the shuffle state machine; the host calls
// `resolveVisualizer` once per frame BEFORE it builds the context and shows whatever it returns
// (never `.shuffle`), then `advance(_:)` with the finished context. The arrow keys come in through
// `handleKey` and write the toolbar's selection.
//
//   corona  StageCoronaModel.swift   the master's FFT as 128 bars (audio-driven)
//   sonar   StageSonarModel.swift    an expanding ring per fire (beat-driven)
//   petal   StagePetalModel.swift    one petal per panel, breathing with its fires (beat-driven)
//   blocks  StageMinecraftModel.swift (its own slot in the registry; nothing to paint here)
//   shuffle StageShuffle.swift       every 64 fires a new one of the four; the arrow keys cycle
//
// Everything the view draws is a value (`StageSoloPaint`) computed here from the context, so the
// view is a pure function of it and the numbers are unit-tested without a window.

/// What the solo layer draws this frame.
public enum StageSoloPaint: Equatable, Sendable {
  case none
  case corona([CoronaRay])
  case sonar([SonarArc])
  case petal([PetalShape])
}

@MainActor
public final class StageSoloModel: StageLayerModel {
  public let corona = StageCoronaModel()
  /// The sonar's rings (stage.js `session.sonarRings` and its rate-limit maps).
  public private(set) var sonar = StageSonar()
  /// The petals' energies (stage.js `session.petalEnergy`).
  public private(set) var petals = StagePetals()

  /// The shuffle state: whether the toolbar's "shuffle" is on, the fire count, what shows.
  public private(set) var shuffle = StageShuffle()

  /// The random source (stage.js `Math.random`): the shuffle's choices. Tests replace it.
  public var random: () -> Double {
    get { rng.generate }
    set { rng = ClosureRandom(generate: newValue) }
  }

  private var rng: ClosureRandom
  /// The visualizer the last frame showed: a change is `setVisualizer`, which starts the
  /// beat-driven visualizers from scratch.
  private var lastShown: StageVisualizer?
  /// The toolbar value last seen (nil before the first frame).
  private var lastSelection: StageVisualizer?
  /// What `resolveVisualizer` found for the frame that `advance` is about to see: whether a
  /// visualizer switch happened inside it (state starts from scratch) and the index of the fire
  /// that made it (that fire, and the ones after, belong to the NEW visualizer, because
  /// stage.js runs the shuffle step before the sonar and petal branches of the same fire).
  private var pending = (from: 0, reset: false)

  public init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
    rng = ClosureRandom(generate: random)
  }

  // MARK: which visualizer shows

  /// The visualizer to show this frame. `selection` is the toolbar's value (may be `.shuffle`);
  /// `fires` are the frame's fires (shuffle counts them: 64 per swap), `now` the wall clock.
  public func resolveVisualizer(
    selection: StageVisualizer, fires: [StageFire], now: Double
  ) -> StageVisualizer {
    var from = 0
    var reset = false
    if selection != lastSelection {  // the toolbar changed (applyVisualizer)
      shuffle.apply(selection, using: &rng)
      lastSelection = selection
      reset = true
    }
    if shuffle.shuffling {
      for i in fires.indices {
        if shuffle.fired(using: &rng) {  // the swap: this fire starts the new visualizer
          from = i
          reset = true
        }
      }
    }
    pending = (reset ? from : pending.from, pending.reset || reset)
    return shuffle.current
  }

  /// The arrow keys: Right and Left cycle `mandala, corona, sonar, petal` from the visualizer that
  /// SHOWS (while shuffling, the one the shuffle is on) and write the selection, which also ends
  /// shuffling (`applyVisualizer` of a fixed name). Other keys are not this layer's.
  public func handleKey(_ key: StageKey, settings: StageSettings) -> Bool {
    let step: Int
    switch key {
    case .left: step = -1
    case .right: step = 1
    case .t: return false
    }
    let shown = settings.visualizer == .shuffle ? shuffle.current : settings.visualizer
    settings.visualizer = StageShuffle.cycle(from: shown, step: step)
    return true
  }

  public func advance(_ context: StageContext) {
    let shown = context.visualizer
    let (from, switched) = pending
    pending = (0, false)
    if switched || shown != lastShown {
      resetVisualizers()
      lastShown = shown
    }
    let fires = context.fires.dropFirst(from)
    switch shown {
    case .corona:
      corona.advance(feed: context.feed, dt: context.dt)
    case .sonar:
      corona.rest()
      for fire in fires {
        sonar.fire(channel: channel(of: fire, in: context), nowMs: fire.wallTime * 1000)
      }
      sonar.prune(nowMs: context.nowMs)
    case .petal:
      corona.rest()
      for fire in fires { petals.fire(PetalKey(deck: fire.deck, netId: fire.netId)) }
      petals.decay(dt: context.dt)
    case .constellation, .minecraft, .shuffle:
      corona.rest()
    }
  }

  /// The stage is closing (`StageModel.detach()`): hand back what the solo visualizers hold on
  /// the engine. That is the corona's lease on the source's left-channel tap, which the feed
  /// only ends with its LAST release, so a Scopes window that keeps the feed open would
  /// otherwise keep the tap running after the Stage is gone. Idempotent.
  public func rest() {
    corona.rest()
  }

  /// `setVisualizer`'s reset: the per-visualizer state of the beat-driven ones.
  private func resetVisualizers() {
    sonar.reset()
    petals.reset()
  }

  /// Forget the beat-driven state (the panels were rebuilt, or a test starts over).
  public func reset() {
    resetVisualizers()
  }

  /// stage.js reads the net's TRACK channel (`netChannel`); the panel carries it. A fire whose
  /// net has no panel (a collapsed riff-group variant) falls back to the channel that played it.
  func channel(of fire: StageFire, in context: StageContext) -> Int {
    if let p = fire.panel, context.panels.indices.contains(p) { return context.panels[p].channel }
    return fire.channel
  }

  /// What to draw for `context` (`.none` unless a solo visualizer shows).
  public func paint(_ context: StageContext) -> StageSoloPaint {
    switch context.visualizer {
    case .corona: .corona(corona.rays(for: context))
    case .sonar:
      .sonar(
        sonar.arcs(
          nowMs: context.nowMs, center: context.ringCenter, width: context.width,
          height: context.height))
    case .petal:
      .petal(
        petals.shapes(
          channels: context.panels.map(\.channel),
          keys: context.panels.map { PetalKey(deck: $0.deck, netId: $0.netId) },
          center: context.ringCenter, width: context.width, height: context.height))
    case .constellation, .minecraft, .shuffle: .none
    }
  }
}
