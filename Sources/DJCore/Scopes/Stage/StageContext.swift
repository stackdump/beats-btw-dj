// StageContext: the one value every stage layer reads each frame.
//
// READ THIS FIRST (stage layer authors)
// =====================================
// The Stage (beats' stage.js) is a stack of layers over one window. The stage model
// (`StageModel`) owns everything they share and builds a `StageContext` once per drawn frame;
// each layer has a model in DJCore (`Stage…Model`, state + numbers, unit-tested) and a view in
// DJViews (`Stage…Layer`, `Canvas` drawing from the context). A layer author replaces ONLY the
// two files of its slot, never the registry, the host, or another layer. The full contract, and
// the z-order, are in `Sources/DJViews/Scopes/Stage/StageLayerRegistry.swift` and
// `StageLayerModels.swift`.
//
// What is in a context.
//   * Geometry in STAGE coordinates: points in the stage window, y down, the same space the
//     layers' Canvases draw in. `ringCenter`, `side`, `radius`, `darkPlanetRadius`, and per
//     panel its `center`, `angle`, and `nodeCenterInStage(...)` (the affine replay stage.js
//     documents: other layers use it for pulse, flame and bolt origins). These are the
//     coordinates BEFORE the container transform (track spin, tilt) is applied: a layer inside
//     the container draws in them and is projected with everything else; never feed projected
//     coordinates back into the model.
//   * `fires`: the audible hits since the last frame, oldest first (`StageFire`). Each carries
//     its panel (nil when its net has none), the transition's stage position at the moment it is
//     read, note, velocity, channel and whether a macro was running when it sounded.
//   * Time. `now` is wall-clock seconds of the model's clock (what `performance.now()` is in
//     the JS; animations that last N ms use it); `dt` is the frame's elapsed seconds, clamped
//     to 0.1 as the rAF loop does; `audioNow` is the feed's free-running audio time. Nothing in
//     a tested function should read the clock itself: take `now`/`dt` from here.
//   * `feed`: the scope feed of the stage's source (nil in a synthetic context). A layer that
//     needs audio reads it there, once per frame in `advance` (the corona analyses
//     `feed.window(count:)`; never from the view's draw and never from the engine).
//   * The toolbar state: `selection` (the visualizer select, may be .shuffle) and `visualizer`
//     (what is showing; never .shuffle), `overlays`, `scale`, `expandVariants`, `bgMode`,
//     `cardOnChange`, `showBacks`, `showLabels`, `showWander`.
//   * `wander`: each source deck's walk (Wander.swift), read on the main actor once per frame
//     (`StageWanderDeck`): on, paused, pace, countdown, the bar in the phrase, the last moves.
//   * `epoch` changes whenever the panels were rebuilt (a new track, the expand toggle, a
//     source switch): a layer that tracks panels or fires forgets its state then (the model
//     also calls `reset()` on the layers that stage.js clears on a rebuild). `trackChanged` is
//     true for exactly the frame a genuine track change landed.

/// Which visualizer the stage shows (the toolbar's select). `.shuffle` is a selection only: the
/// solo layer turns it into a concrete one every 64 fires.
public enum StageVisualizer: String, CaseIterable, Sendable {
  /// stage.js calls this "mandala".
  case constellation = "mandala"
  case corona
  case sonar
  case petal
  /// The "Blocks" world, orchestrated by the control track (`StageMinecraftModel`).
  case minecraft
  case shuffle

  /// The select's option text.
  public var title: String {
    switch self {
    case .constellation: "Constellation"
    case .corona: "Corona"
    case .sonar: "Sonar"
    case .petal: "Petal"
    case .minecraft: "Blocks"
    case .shuffle: "🔀 Shuffle"
    }
  }

  /// Corona, sonar, petal and blocks own the whole window: stage.js hides the panel grid and the flame
  /// canvas (`viz-solo`) while one is showing.
  public var isSolo: Bool {
    switch self {
    case .corona, .sonar, .petal, .minecraft: true
    case .constellation, .shuffle: false
    }
  }

  /// The real visualizers, in the order the arrow keys cycle through them
  /// (stage.js `['mandala', 'corona', 'sonar', 'petal']`, then dj's blocks) and shuffle picks from.
  public static let real: [StageVisualizer] = [.constellation, .corona, .sonar, .petal, .minecraft]
}

/// The independent toolbar toggles. `flow`, `pulse`, `flame` and `tilt` are the `data-viz`
/// buttons (`session.vizModes`); `bolts` is the lightning button (`session.boltsEnabled`).
public enum StageOverlay: String, CaseIterable, Sendable {
  case flow, pulse, flame, tilt, bolts

  /// stage.js opens with flow, pulse and flame on, tilt off, bolts on.
  public static let defaults: Set<StageOverlay> = [.flow, .pulse, .flame, .bolts]
}

/// The background behind the meta-diagram (`session.bgMode`).
public enum StageBackground: String, CaseIterable, Sendable {
  case void, stars, aurora

  public var title: String {
    switch self {
    case .void: "Void"
    case .stars: "Stars"
    case .aurora: "Aurora"
    }
  }
}

/// One audible hit, as the stage layers want it (stage.js `stageOnTransitionFired`).
public struct StageFire: Sendable {
  /// Audio seconds at which it sounds (`ScopeFire.time`).
  public var time: Double
  /// The model's wall clock when it was read (`performance.now()` at the hook): `born` of a
  /// particle, a ring or a bolt.
  public var wallTime: Double
  /// Index into `StageContext.panels`; nil when the fired net has no panel (collapsed
  /// riff-group variants that are not displayed, a net that was not eligible).
  public var panel: Int?
  public var deck: String
  public var netId: String
  public var transitionId: String
  /// Index into the panel's `shape.transitionIds` (nil without a panel).
  public var transition: Int?
  /// The transition's centre in stage coordinates (`nodeCenterInStage`) at the frame it was
  /// read; nil without a panel or a fitted view.
  public var origin: StagePoint?
  public var note: Int
  public var velocity: Int
  /// The channel that played it.
  public var channel: Int
  public var durSec: Double
  /// A macro was running on the deck when it sounded (`el._runningMacro`): fired and not yet run
  /// out, a mute timer, a beat repeat or a tempo effect (`WaveRunner.markMacroRunning`).
  public var macroRunning: Bool
  public var isDrum: Bool
  public var isStinger: Bool

  public init(
    time: Double, wallTime: Double, panel: Int?, deck: String, netId: String,
    transitionId: String, transition: Int?, origin: StagePoint?, note: Int, velocity: Int,
    channel: Int, durSec: Double, macroRunning: Bool, isDrum: Bool = false,
    isStinger: Bool = false
  ) {
    self.time = time
    self.wallTime = wallTime
    self.panel = panel
    self.deck = deck
    self.netId = netId
    self.transitionId = transitionId
    self.transition = transition
    self.origin = origin
    self.note = note
    self.velocity = velocity
    self.channel = channel
    self.durSec = durSec
    self.macroRunning = macroRunning
    self.isDrum = isDrum
    self.isStinger = isStinger
  }
}

/// The geometry of one net, as a panel draws it. Immutable; built from the net's `NetInfo`
/// (the composer's ring layout travels with the project).
public final class StageNetShape: Sendable {
  public let netId: String
  public let placeIds: [String]
  public let placeX: [Double]
  public let placeY: [Double]
  public let transitionIds: [String]
  public let transitionX: [Double]
  public let transitionY: [Double]
  public let transitionHasMidi: [Bool]
  public let arcs: [NetInfo.NetArcGeometry]
  /// Nil for a net without places and transitions.
  public let bounds: StageBounds?
  private let transitionIndexById: [String: Int]

  public init(info n: NetInfo, placeIds: [String]) {
    netId = n.id
    self.placeIds = placeIds
    placeX = n.placeX
    placeY = n.placeY
    transitionIds = n.transitionIds
    transitionX = n.transitionX
    transitionY = n.transitionY
    transitionHasMidi =
      n.transitionHasMidi.count == n.transitionIds.count
      ? n.transitionHasMidi : [Bool](repeating: false, count: n.transitionIds.count)
    arcs = n.arcs
    var index: [String: Int] = [:]
    for (i, id) in n.transitionIds.enumerated() { index[id] = i }
    transitionIndexById = index
    // layoutPanel: the box of places, then transitions.
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    for i in 0..<min(placeIds.count, n.placeX.count, n.placeY.count) {
      minX = min(minX, n.placeX[i])
      maxX = max(maxX, n.placeX[i])
      minY = min(minY, n.placeY[i])
      maxY = max(maxY, n.placeY[i])
    }
    for i in 0..<n.transitionIds.count {
      minX = min(minX, n.transitionX[i])
      maxX = max(maxX, n.transitionX[i])
      minY = min(minY, n.transitionY[i])
      maxY = max(maxY, n.transitionY[i])
    }
    bounds =
      minX.isFinite
      ? StageBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY) : nil
  }

  public func transitionIndex(id: String) -> Int? { transitionIndexById[id] }

  /// A shape for tests and previews: no engine needed.
  public init(
    netId: String, placeIds: [String], placeX: [Double], placeY: [Double],
    transitionIds: [String], transitionX: [Double], transitionY: [Double],
    transitionHasMidi: [Bool]? = nil, arcs: [NetInfo.NetArcGeometry] = []
  ) {
    self.netId = netId
    self.placeIds = placeIds
    self.placeX = placeX
    self.placeY = placeY
    self.transitionIds = transitionIds
    self.transitionX = transitionX
    self.transitionY = transitionY
    self.transitionHasMidi =
      transitionHasMidi ?? [Bool](repeating: false, count: transitionIds.count)
    self.arcs = arcs
    var index: [String: Int] = [:]
    for (i, id) in transitionIds.enumerated() { index[id] = i }
    transitionIndexById = index
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    for i in 0..<placeIds.count {
      minX = min(minX, placeX[i])
      maxX = max(maxX, placeX[i])
      minY = min(minY, placeY[i])
      maxY = max(maxY, placeY[i])
    }
    for i in 0..<transitionIds.count {
      minX = min(minX, transitionX[i])
      maxX = max(maxX, transitionX[i])
      minY = min(minY, transitionY[i])
      maxY = max(maxY, transitionY[i])
    }
    bounds =
      minX.isFinite
      ? StageBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY) : nil
  }
}

/// One panel of the ring: a net, where it sits, how it is turned, what it holds right now.
public struct StagePanel: Sendable {
  /// Stable for as long as the panel exists (it survives a riff-group slot flip).
  public var id: String
  public var deck: String
  /// The net shown now (changes when the panel flips to another variant of its riff group).
  public var netId: String
  /// `riffGroup || instrument || netId`.
  public var label: String
  /// The track's channel (what colours it in the solo visualizers).
  public var channel: Int
  public var riffGroup: String
  /// Panel centre in stage coordinates.
  public var center: StagePoint
  /// stage.js `ringX`/`ringY`: the centre again, but nil for a lone panel (the JS never sets it
  /// there, so pulse and flame skip it).
  public var ring: StagePoint?
  public var side: Double
  /// Degrees the net is turned by (flow), within +-360.
  public var angle: Double
  /// The net's fit into its box; nil for a net without geometry.
  public var view: StagePanelView?
  public var muted: Bool
  /// 1, easing to 0.25 while muted (`.pn-stage-panel.muted`, `transition: opacity 280ms`).
  public var opacity: Double
  public var shape: StageNetShape
  /// Tokens per place, in `shape.placeIds` order (the engine's live marking).
  public var tokens: [Double]
  /// Audio time of each transition's last fire, `-infinity` for none.
  public var firedAt: [Double]

  public init(
    id: String, deck: String, netId: String, label: String, channel: Int, riffGroup: String,
    center: StagePoint, ring: StagePoint?, side: Double, angle: Double, view: StagePanelView?,
    muted: Bool, opacity: Double, shape: StageNetShape, tokens: [Double], firedAt: [Double]
  ) {
    self.id = id
    self.deck = deck
    self.netId = netId
    self.label = label
    self.channel = channel
    self.riffGroup = riffGroup
    self.center = center
    self.ring = ring
    self.side = side
    self.angle = angle
    self.view = view
    self.muted = muted
    self.opacity = opacity
    self.shape = shape
    self.tokens = tokens
    self.firedAt = firedAt
  }

  /// Top-left corner of the panel's box in stage coordinates (`root.offsetLeft/Top`).
  public var origin: StagePoint { StagePoint(x: center.x - side / 2, y: center.y - side / 2) }

  /// How long a fired transition stays lit (`.pn-transition.firing`, removed after 100 ms).
  public static let flashDuration = 0.1

  /// 1 right at a fire down to 0 after `flashDuration` (audio time `now`); 0 when the transition
  /// has not fired, or the fire is in the future of `now`.
  public func flash(transition i: Int, now: Double) -> Double {
    guard i >= 0, i < firedAt.count else { return 0 }
    let age = now - firedAt[i]
    // (a hair of slack so the 100 ms mark is not a coin flip of floating-point error)
    guard age >= 0, age < Self.flashDuration - 1e-9 else { return 0 }
    return 1 - age / Self.flashDuration
  }

  /// stage.js `nodeCenterInStage`: where transition `i` is in stage coordinates, replaying the
  /// affine the panel is drawn with (no DOM rect, so a tilted container never warps it).
  public func nodeCenterInStage(transition i: Int) -> StagePoint? {
    guard let view, i >= 0, i < shape.transitionIds.count,
      view.scale.isFinite, view.cx.isFinite, view.cy.isFinite
    else { return nil }
    let p = view.apply(x: shape.transitionX[i], y: shape.transitionY[i], angleDegrees: angle)
    return StagePoint(x: origin.x + p.x, y: origin.y + p.y)
  }

  /// Where place `i` is in stage coordinates (same affine as `nodeCenterInStage`).
  public func placeCenterInStage(place i: Int) -> StagePoint? {
    guard let view, i >= 0, i < shape.placeIds.count, i < shape.placeX.count,
      view.scale.isFinite, view.cx.isFinite, view.cy.isFinite
    else { return nil }
    let p = view.apply(x: shape.placeX[i], y: shape.placeY[i], angleDegrees: angle)
    return StagePoint(x: origin.x + p.x, y: origin.y + p.y)
  }

  public func nodeCenterInStage(transitionId: String) -> StagePoint? {
    guard let i = shape.transitionIndex(id: transitionId) else { return nil }
    return nodeCenterInStage(transition: i)
  }
}

/// One source deck's walk as the stage shows it (`Deck.wander`, read by `StageModel.advance` on
/// the main actor, never from a view or the audio thread).
public struct StageWanderDeck: Equatable, Sendable {
  public var deck: String
  public var on: Bool
  /// The browser wheel grabbed the walk: it waits for a quiet phrase.
  public var paused: Bool
  /// Bars per move (`WanderState.paces`).
  public var pace: Int
  /// Bars until the next move (paused: until it resumes); nil when off or not a net
  /// (`Deck.wanderCountdown`).
  public var countdown: Int?
  /// 0-based bar of the deck's clock within the current phrase (paused: quiet bars so far), in
  /// 0..<pace; nil whenever `countdown` is.
  public var barInPhrase: Int?
  /// Moves taken so far (`WanderState.step`).
  public var step: Int
  /// The last `StageWanderDeck.moveLimit` moves of the log, oldest first.
  public var moves: [WanderMove]

  /// Moves a context carries per deck.
  public static let moveLimit = 4

  public init(
    deck: String, on: Bool, paused: Bool = false, pace: Int = WanderState.defaultPace,
    countdown: Int? = nil, barInPhrase: Int? = nil, step: Int = 0, moves: [WanderMove] = []
  ) {
    self.deck = deck
    self.on = on
    self.paused = paused
    self.pace = pace
    self.countdown = countdown
    self.barInPhrase = barInPhrase
    self.step = step
    self.moves = Array(moves.suffix(Self.moveLimit))
  }

  /// Phrase progress 0...1 (`barInPhrase / pace`); nil when the walk has no phrase to show.
  public var phraseProgress: Double? {
    guard let barInPhrase, pace > 0 else { return nil }
    return Double(barInPhrase) / Double(pace)
  }
}

/// Everything a layer reads for one frame. See the header. (Not `Sendable`: it carries the
/// main-actor feed.)
public struct StageContext {
  // Geometry (stage coordinates, before the container transform).
  public var width: Double
  public var height: Double
  public var layout: StageRingLayout
  public var panels: [StagePanel]

  // Time.
  public var now: Double
  public var dt: Double
  public var audioNow: Double
  /// Fires since the last frame, oldest first. Empty at visual level 2 and up.
  public var fires: [StageFire]

  // Engine facts.
  /// The source decks' walks, sorted by deck (empty in a synthetic context).
  public var wander: [StageWanderDeck]
  /// A macro is running on the lead deck (`WaveRunner.macroActive`).
  public var macroRunning: Bool
  /// Is any net deck behind the source?
  public var hasNet: Bool
  public var source: ScopeSource
  /// The feed of `source` (acquired by the stage while it is on screen).
  public var feed: ScopeFeed?

  // The diagram's turn (mode 20): degrees, eased to a target that moves 90 per track change.
  public var metaRotation: Double

  // Toolbar state.
  public var selection: StageVisualizer
  public var visualizer: StageVisualizer
  public var overlays: Set<StageOverlay>
  public var scale: StageScale
  public var expandVariants: Bool
  public var bgMode: StageBackground
  public var cardOnChange: Bool
  public var showBacks: Bool
  public var showLabels: Bool
  /// The ∿ button (`StageSettings.showWander`): the wander layer draws only while it is on.
  public var showWander: Bool
  /// The perf monitor's level, 0...3.
  public var vizLevel: Int

  // Discrete events.
  public var epoch: Int
  public var trackChanged: Bool

  /// The stats line (`renderStats`).
  public var stats: String

  // MARK: conveniences

  public var ringCenter: StagePoint { layout.center }
  public var side: Double { layout.side }
  public var radius: Double { layout.radius }
  /// Nil for fewer than two panels; consumers keep stage.js's own fallbacks.
  public var darkPlanetRadius: Double? { layout.darkPlanetRadius }
  public var isSolo: Bool { visualizer.isSolo }
  public var nowMs: Double { now * 1000 }

  public func isOn(_ overlay: StageOverlay) -> Bool { overlays.contains(overlay) }

  public init(
    width: Double, height: Double, layout: StageRingLayout, panels: [StagePanel] = [],
    now: Double = 0, dt: Double = 0, audioNow: Double = 0, fires: [StageFire] = [],
    macroRunning: Bool = false, hasNet: Bool = true, source: ScopeSource = .master,
    feed: ScopeFeed? = nil,
    metaRotation: Double = 0, selection: StageVisualizer = .constellation,
    visualizer: StageVisualizer = .constellation,
    overlays: Set<StageOverlay> = StageOverlay.defaults, scale: StageScale = .loop,
    expandVariants: Bool = false, bgMode: StageBackground = .void, cardOnChange: Bool = false,
    showBacks: Bool = false, showLabels: Bool = false, showWander: Bool = true, vizLevel: Int = 0,
    epoch: Int = 0, trackChanged: Bool = false, stats: String = "",
    wander: [StageWanderDeck] = []
  ) {
    self.width = width
    self.height = height
    self.layout = layout
    self.panels = panels
    self.now = now
    self.dt = dt
    self.audioNow = audioNow
    self.fires = fires
    self.macroRunning = macroRunning
    self.hasNet = hasNet
    self.source = source
    self.feed = feed
    self.metaRotation = metaRotation
    self.selection = selection
    self.visualizer = visualizer
    self.overlays = overlays
    self.scale = scale
    self.expandVariants = expandVariants
    self.bgMode = bgMode
    self.cardOnChange = cardOnChange
    self.showBacks = showBacks
    self.showLabels = showLabels
    self.showWander = showWander
    self.vizLevel = vizLevel
    self.epoch = epoch
    self.trackChanged = trackChanged
    self.stats = stats
    self.wander = wander
  }
}

/// The stage's palette (petri-note.css, canvas.js).
public enum StagePalette {
  /// `.pn-stage-overlay` background.
  public static let background = ScopeColor(hex: "#0a0a1a")!
  /// Arcs, place borders, meta-net.
  public static let arc = ScopeColor(hex: "#4a90d9")!
  /// Place and transition fill (`.pn-place-circle`, `.pn-transition-rect`).
  public static let nodeFill = ScopeColor(hex: "#1a1a2e")!
  /// Transition border and the fired fill.
  public static let transition = ScopeColor(hex: "#e94560")!
  /// The lower-right half of a transition that carries a note
  /// (`linear-gradient(135deg, #1a1a2e 50%, #2d1f3d 50%)`).
  public static let transitionMidi = ScopeColor(hex: "#2d1f3d")!
  /// `radial-gradient(circle at center, #131a33 0%, #070712 100%)` of a panel's back.
  public static let backInner = ScopeColor(hex: "#131a33")!
  public static let backOuter = ScopeColor(hex: "#070712")!
  /// `1px solid rgba(74,144,217,0.18)`.
  public static let backBorder = ScopeColor(r8: 74, g8: 144, b8: 217, a: 0.18)
  /// `.pn-stage-label`: rgba(255,255,255,0.55).
  public static let label = ScopeColor(r: 1, g: 1, b: 1, a: 0.55)
  /// Arcs are drawn at this alpha (`ctx.globalAlpha = 0.6`).
  public static let arcAlpha = 0.6
}
