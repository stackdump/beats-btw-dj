import Foundation

// StageModel: the Stage's per-frame brain (beats' stage.js session, without the DOM).
//
// It owns the panels of the ring, their drift, the track spin and the toolbar state, reads the
// engine ONLY through the scope feed (marking, fire log, mutes, tick facts: it never re-derives
// what the engine publishes), and once per drawn frame builds the `StageContext` the layers read.
//
//   let model = StageModel(hub: hub)
//   model.attach()                                  // acquires the feed of `settings.source`
//   model.advance(now: t, dt: dt, width: w, height: h)   // once per drawn frame
//   model.context                                   // what the layers draw from
//   model.detach()                                  // releases the feed (the taps go off)
//
// The host (`StageView`) does exactly that from a TimelineView. `advance` pumps the hub first, so
// a test needs no extra pump; time is passed in (`now` is the model's wall clock, `dt` is clamped
// to 0.1 as the rAF loop does) so nothing inside depends on the system clock.
//
// What it reconciles, and when (stage.js):
//   * `stageOnProjectSync`: a NEW TRACK (the sounding project of a deck has another
//     `trackSerial`) rebuilds every panel, quarter-turns the diagram (+90 on the spin target) and
//     clears the pulse, flame and bolts layers. The first build, a source switch and the expand
//     toggle rebuild WITHOUT the turn ("toggling the view is not a track change"), and so does a
//     deck that loses its net (a sample was loaded) or gains one: only a deck that was showing a
//     net and still does, with another song, is a new track. A section
//     relaunch or jump of the same song (same `trackSerial`, new generation) keeps the panels.
//     The turn is keyed on `trackSerial` rather than on `ScopeFeed.generation` because that also
//     bumps on a restart from the top, a re-acquire and a lane-set change, none of which is a
//     track change.
//   * `stageOnMuteStateChange`: panels never reflow when mutes change; a muted panel dims
//     (opacity 0.25, eased over 280 ms) and a collapsed riff-group panel flips to whichever
//     variant is unmuted.
//   * `stageOnTransitionFired`: every fire of the feed's log lights its transition (100 ms) and
//     is handed to the layers with its position in stage coordinates.

@MainActor
public final class StageModel {
  public let hub: ScopeHub
  public let settings: StageSettings
  public let layers: StageLayerModels

  /// The last frame's context (empty before the first `advance`).
  public private(set) var context: StageContext
  /// The diagram's turn (mode 20).
  public private(set) var spin = StageSpin()
  /// Bumps whenever the panels are rebuilt.
  public private(set) var epoch = 0
  /// Frames advanced (`advance` calls): how many frames the host drew, for tests and the perf
  /// monitor's pacing checks.
  public private(set) var advances = 0
  /// Extra models advanced after the registry's, and cleared on a rebuild like the pulse, flame
  /// and bolts models (tests and tools that want to watch the frames).
  public var observers: [any StageLayerModel] = []

  /// Fires older than this (audio seconds behind "now") are dropped: the window was hidden, or
  /// the app stalled, and replaying a backlog as a burst of effects would be noise.
  public static let staleFireSeconds = 2.0

  private let subscription = ScopeSubscription()
  private var attached = false

  private var random: ClosureRandom
  private var panels: [PanelState] = []
  private var builtFeed: ObjectIdentifier?
  private var builtExpand = false
  private var builtTracks: [String: Int32] = [:]
  private var builtNetIds: [String: [String]] = [:]
  private var fireCursor = 0
  private var lastNow: Double?
  private var lastSize = (w: 0.0, h: 0.0)
  private var cache: [DeckGeneration: DeckNets] = [:]
  private var cacheOrder: [DeckGeneration] = []

  public init(
    hub: ScopeHub, settings: StageSettings = StageSettings(),
    layers: StageLayerModels = StageLayerModels(),
    random: @escaping () -> Double = { Double.random(in: 0..<1) }
  ) {
    self.hub = hub
    self.settings = settings
    self.layers = layers
    self.random = ClosureRandom(generate: random)
    context = StageContext(
      width: 0, height: 0,
      layout: StagePanelLayout.layoutRing(width: 0, height: 0, count: 0),
      hasNet: false, source: settings.source)
  }

  // MARK: subscribing

  /// Start listening: acquires the feed of the selected source (the taps stay off until then).
  public func attach() {
    attached = true
    syncSubscription()
  }

  /// Stop listening; the last release switches the taps off. Safe to repeat.
  public func detach() {
    attached = false
    layers.solo.rest()  // a lease on the feed (the corona's left channel) is not the window's own
    subscription.release()
  }

  public var isAttached: Bool { attached }

  /// Seconds between frames at the perf level (a TimelineView's `minimumInterval`).
  public var minFrameInterval: Double { StageFramePacer.minInterval(level: hub.vizLevel) }

  private func syncSubscription() {
    let feed = hub.feed(settings.source)
    if subscription.feed !== feed {
      subscription.move(to: feed)
      // A new feed: its fire log is its own, and the panels belong to the old source.
      fireCursor = feed.fireLog.total
      builtFeed = nil
    }
  }

  // MARK: keys

  /// Forward a key to the layers (top first); `.t` falls back to the card toggle when the card
  /// is available. True if something used it.
  @discardableResult
  public func handleKey(_ key: StageKey) -> Bool {
    for layer in layers.all.reversed() where layer.handleKey(key, settings: settings) {
      return true
    }
    if key == .t, layers.card.isAvailable {
      settings.cardOnChange.toggle()
      return true
    }
    return false
  }

  // MARK: the frame

  /// The host's entry: `now` in seconds on any steady clock. Draws once per distinct `now` and
  /// size (SwiftUI may evaluate a body twice for one timeline date).
  @discardableResult
  public func frame(now: Double, width: Double, height: Double) -> StageContext {
    if let last = lastNow, last == now, lastSize.w == width, lastSize.h == height {
      return context
    }
    let dt = lastNow.map { now - $0 } ?? 0
    advance(now: now, dt: dt, width: width, height: height)
    return context
  }

  /// One frame. `dt` is clamped to 0.1 s (`Math.min(100, now - lastTime)`).
  public func advance(now: Double, dt rawDt: Double, width: Double, height: Double) {
    advances += 1
    let dt = min(0.1, max(0, rawDt.isFinite ? rawDt : 0))
    lastNow = now
    lastSize = (width, height)
    if attached { syncSubscription() }
    hub.pump()
    let feed = hub.feed(settings.source)
    let views = deckViews(feed)

    // Panels follow the sounding project; a new track turns the whole diagram.
    let trackChanged = reconcile(feed: feed, views: views)
    if trackChanged { spin.bump() }
    updateMutesAndTokens(views: views, dt: dt)
    spin.advance(dt: dt)

    let flowOn = settings.isOn(.flow)
    for p in panels { p.flow.advance(dt: dt, flowOn: flowOn) }

    let layout = StagePanelLayout.layoutRing(
      width: width, height: height, count: panels.count, scale: settings.scale)
    var values = panels.enumerated().map { makePanel($1, index: $0, layout: layout) }

    // Fires: read after the flow step so an origin is where the node is drawn this frame.
    let audioNow = feed.nowTime
    let level = hub.vizLevel
    let fires = consumeFires(
      feed: feed, values: &values, now: now, audioNow: audioNow,
      effects: StageFramePacer.showsFireEffects(level: level))

    let shown = layers.solo.resolveVisualizer(
      selection: settings.visualizer, fires: fires, now: now)
    // A solo model that hands back .shuffle would show nothing: fall back to the constellation.
    let visualizer = shown == .shuffle ? StageVisualizer.constellation : shown

    let ctx = StageContext(
      width: width, height: height, layout: layout, panels: values, now: now, dt: dt,
      audioNow: audioNow, fires: fires, macroRunning: feed.clock.macroActive,
      hasNet: !views.isEmpty, source: settings.source, feed: feed, metaRotation: spin.rotation,
      selection: settings.visualizer, visualizer: visualizer, overlays: settings.overlays,
      scale: settings.scale, expandVariants: settings.expandVariants, bgMode: settings.bgMode,
      cardOnChange: settings.cardOnChange, showBacks: settings.showBacks,
      showLabels: settings.showLabels, vizLevel: level, epoch: epoch, trackChanged: trackChanged,
      stats: statsText(views: views))
    context = ctx
    for layer in layers.all { layer.advance(ctx) }
    for layer in observers { layer.advance(ctx) }
    // A frame that outlives `detach()` (or comes before `attach()`) holds nothing on the feed.
    if !attached { layers.solo.rest() }
  }

  // MARK: engine reads

  /// One net deck's marking and the static facts of the layout it belongs to.
  private struct DeckView {
    let deck: String
    let snapshot: MarkingSnapshot
    let nets: DeckNets
  }

  private func deckNames(_ feed: ScopeFeed) -> [String] {
    switch settings.source {
    case .deck(let n): [n]
    case .master: hub.engine.decks.keys.sorted()
    }
  }

  private func deckViews(_ feed: ScopeFeed) -> [DeckView] {
    var out: [DeckView] = []
    for name in deckNames(feed) {
      guard let snap = feed.marking(deck: name), let layout = snap.layout else { continue }
      out.append(DeckView(deck: name, snapshot: snap, nets: nets(deck: name, layout: layout)))
    }
    return out
  }

  private struct DeckGeneration: Hashable {
    let deck: String
    let generation: Int32
  }

  private func nets(deck: String, layout: MarkingLayout) -> DeckNets {
    let key = DeckGeneration(deck: deck, generation: layout.generation)
    if let known = cache[key] { return known }
    let made = DeckNets(deck: deck, layout: layout)
    cache[key] = made
    cacheOrder.append(key)
    if cacheOrder.count > 24 { cache[cacheOrder.removeFirst()] = nil }
    return made
  }

  /// The static facts of a deck's layout at a generation (for a fire that was stamped with it).
  private func nets(deck: String, generation: Int32) -> DeckNets? {
    let key = DeckGeneration(deck: deck, generation: generation)
    if let known = cache[key] { return known }
    guard let layout = hub.engine.decks[deck]?.wave.markingLayout(generation: generation) else {
      return nil
    }
    return nets(deck: deck, layout: layout)
  }

  // MARK: panels

  /// A panel's state between frames.
  private final class PanelState {
    let id: String
    let deck: String
    var netId: String
    var shape: StageNetShape
    var label: String
    var channel: Int
    let riffGroup: String
    var flow: StageFlow
    var firedAt: [Double]
    var fade: StageFade
    var muted = false
    var tokens: [Double]

    init(
      id: String, deck: String, netId: String, shape: StageNetShape, label: String,
      channel: Int, riffGroup: String, flow: StageFlow
    ) {
      self.id = id
      self.deck = deck
      self.netId = netId
      self.shape = shape
      self.label = label
      self.channel = channel
      self.riffGroup = riffGroup
      self.flow = flow
      firedAt = [Double](repeating: -.infinity, count: shape.transitionIds.count)
      fade = StageFade()
      tokens = [Double](repeating: 0, count: shape.placeIds.count)
    }
  }

  /// A layout's static facts, built once per (deck, generation).
  private final class DeckNets {
    let deck: String
    let layout: MarkingLayout
    let descs: [StagePanelLayout.NetDesc]
    let indexById: [String: Int]
    private var shapes: [StageNetShape?]
    /// Stats line inputs: non-control nets with places and transitions.
    let counted: [Bool]
    let places: Int
    let transitions: Int
    let arcs: Int
    let notes: Int

    init(deck: String, layout: MarkingLayout) {
      self.deck = deck
      self.layout = layout
      var descs: [StagePanelLayout.NetDesc] = []
      var index: [String: Int] = [:]
      var counted: [Bool] = []
      var places = 0
      var transitions = 0
      var arcs = 0
      var notes = 0
      for (i, net) in layout.nets.enumerated() {
        let pc = layout.placeIds[i].count
        let tc = net.transitionIds.count
        descs.append(
          StagePanelLayout.NetDesc(
            id: net.id, deck: deck, role: net.role, riffGroup: net.riffGroup,
            channel: net.channel, placeCount: pc, transitionCount: tc))
        index[net.id] = i
        let on = net.role != "control" && pc > 0 && tc > 0
        counted.append(on)
        if on {
          places += pc
          transitions += tc
          arcs += net.arcCount
          notes += net.transitionHasMidi.filter { $0 }.count
        }
      }
      self.descs = descs
      indexById = index
      shapes = [StageNetShape?](repeating: nil, count: layout.nets.count)
      self.counted = counted
      self.places = places
      self.transitions = transitions
      self.arcs = arcs
      self.notes = notes
    }

    func shape(at i: Int) -> StageNetShape {
      if let s = shapes[i] { return s }
      let s = StageNetShape(info: layout.nets[i], placeIds: layout.placeIds[i])
      shapes[i] = s
      return s
    }

    /// stage.js: `net.riffGroup || net.track?.instrument || netId`.
    func label(at i: Int) -> String {
      let n = layout.nets[i]
      if !n.riffGroup.isEmpty { return n.riffGroup }
      if !n.instrument.isEmpty { return n.instrument }
      return n.id
    }

    /// The descriptors with the snapshot's current mutes.
    func descs(with snapshot: MarkingSnapshot) -> [StagePanelLayout.NetDesc] {
      var out = descs
      for i in out.indices { out[i].muted = snapshot.isMuted(net: i) }
      return out
    }
  }

  /// Rebuild the panels when the song, the source or the expand toggle changed. Returns true for
  /// a genuine track change (the caller turns the diagram).
  private func reconcile(feed: ScopeFeed, views: [DeckView]) -> Bool {
    var tracks: [String: Int32] = [:]
    var netIds: [String: [String]] = [:]
    for v in views {
      tracks[v.deck] = v.nets.layout.trackSerial
      netIds[v.deck] = v.nets.layout.netIds
    }
    let feedChanged = builtFeed != ObjectIdentifier(feed)
    let expandChanged = builtExpand != settings.expandVariants
    let trackChanged = tracks != builtTracks
    let shapeChanged = netIds != builtNetIds
    guard feedChanged || expandChanged || trackChanged || shapeChanged else { return false }

    // A track change is a deck that WAS showing a net and still is, with another song. The very
    // first build, a source switch and the expand toggle are not track changes; neither is a deck
    // that loses its net (a sample was loaded) or gains one (it had none): nothing new started
    // under the viewer's eyes, and the card flash (mode 19) keys on this too.
    let swapped = tracks.contains { deck, serial in
      builtTracks[deck].map { $0 != serial } ?? false
    }
    let genuine = swapped && !feedChanged && !expandChanged
    rebuild(views: views)
    builtFeed = ObjectIdentifier(feed)
    builtExpand = settings.expandVariants
    builtTracks = tracks
    builtNetIds = netIds
    return genuine
  }

  /// stage.js `rebuildStagePanels`: new panels (new drift), the layers that hold per-panel state
  /// forget it.
  private func rebuild(views: [DeckView]) {
    var all: [StagePanelLayout.NetDesc] = []
    for v in views { all.append(contentsOf: v.nets.descs(with: v.snapshot)) }
    let keys = StagePanelLayout.eligibleKeys(all, expandVariants: settings.expandVariants)
    let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    var built: [PanelState] = []
    for key in keys {
      guard let desc = byKey[key], let view = views.first(where: { $0.deck == desc.deck }),
        let i = view.nets.indexById[desc.id]
      else { continue }
      let flow = StageFlow.random(using: &random)
      let state = PanelState(
        id: key, deck: desc.deck, netId: desc.id, shape: view.nets.shape(at: i),
        label: view.nets.label(at: i), channel: view.nets.layout.nets[i].channel,
        riffGroup: view.nets.layout.nets[i].riffGroup, flow: flow)
      state.muted = view.snapshot.isMuted(net: i)
      state.fade = StageFade(value: state.muted ? StageFade.mutedOpacity : 1)
      built.append(state)
    }
    panels = built
    epoch += 1
    for layer in layers.clearedOnRebuild { layer.reset() }
    for layer in observers { layer.reset() }
  }

  /// Mutes, riff-group slot flips and tokens, every frame (cheap).
  private func updateMutesAndTokens(views: [DeckView], dt: Double) {
    var withMutes: [String: [StagePanelLayout.NetDesc]] = [:]
    for p in panels {
      guard let view = views.first(where: { $0.deck == p.deck }) else { continue }
      if !p.riffGroup.isEmpty && !settings.expandVariants {
        if withMutes[p.deck] == nil { withMutes[p.deck] = view.nets.descs(with: view.snapshot) }
        if let to = StagePanelLayout.variantSwap(
          panelNetId: p.netId, riffGroup: p.riffGroup, deck: p.deck, nets: withMutes[p.deck]!,
          expandVariants: false), let i = view.nets.indexById[to]
        {
          // repanel: new nodes (nothing is firing), same drift and angle.
          p.netId = to
          p.shape = view.nets.shape(at: i)
          p.label = view.nets.label(at: i)
          p.channel = view.nets.layout.nets[i].channel
          p.firedAt = [Double](repeating: -.infinity, count: p.shape.transitionIds.count)
        }
      }
      guard let i = view.nets.indexById[p.netId] else { continue }
      p.muted = view.snapshot.isMuted(net: i)
      p.fade.retarget(p.muted ? StageFade.mutedOpacity : 1)
      p.fade.advance(dt: dt)
      p.tokens = tokens(of: p.shape, net: i, in: view)
    }
  }

  /// A panel's tokens in its shape's place order, out of the snapshot.
  private func tokens(of shape: StageNetShape, net i: Int, in view: DeckView) -> [Double] {
    let layout = view.nets.layout
    let slice = view.snapshot.tokens(ofNet: i)
    if layout.placeIds[i] == shape.placeIds { return Array(slice) }
    var byId: [String: Double] = [:]
    for (k, id) in layout.placeIds[i].enumerated() where k < slice.count {
      byId[id] = slice[slice.startIndex + k]
    }
    return shape.placeIds.map { byId[$0] ?? 0 }
  }

  private func makePanel(_ s: PanelState, index i: Int, layout: StageRingLayout) -> StagePanel {
    let center =
      i < layout.panelCenters.count ? layout.panelCenters[i] : layout.center
    let content = StagePanelView.contentSize(side: layout.side)
    let view = s.shape.bounds.map {
      StagePanelView.fit(bounds: $0, width: content, height: content)
    }
    return StagePanel(
      id: s.id, deck: s.deck, netId: s.netId, label: s.label, channel: s.channel,
      riffGroup: s.riffGroup, center: center, ring: layout.hasRing ? center : nil,
      side: layout.side, angle: s.flow.angle, view: view, muted: s.muted,
      opacity: s.fade.value, shape: s.shape, tokens: s.tokens, firedAt: s.firedAt)
  }

  // MARK: fires

  private func consumeFires(
    feed: ScopeFeed, values: inout [StagePanel], now: Double, audioNow: Double,
    effects: Bool
  ) -> [StageFire] {
    let log = feed.fireLog
    let range = log.numbers(since: fireCursor)
    fireCursor = log.total
    guard effects else { return [] }
    var out: [StageFire] = []
    for n in range {
      guard let f = log.fire(number: n) else { continue }
      let age = audioNow - f.time
      if age > Self.staleFireSeconds { continue }
      let deck = feed.lanes.indices.contains(f.lane) ? feed.lanes[f.lane].deck : ""
      guard let nets = nets(deck: deck, generation: f.generation),
        f.net >= 0, f.net < nets.layout.nets.count
      else { continue }
      let info = nets.layout.nets[f.net]
      guard f.transition >= 0, f.transition < info.transitionIds.count else { continue }
      let transitionId = info.transitionIds[f.transition]
      let panel = values.firstIndex { $0.deck == deck && $0.netId == info.id }
      var transition: Int?
      var origin: StagePoint?
      if let p = panel {
        transition = values[p].shape.transitionIndex(id: transitionId)
        if let t = transition {
          origin = values[p].nodeCenterInStage(transition: t)
          panels[p].firedAt[t] = max(panels[p].firedAt[t], f.time)
          values[p].firedAt[t] = panels[p].firedAt[t]
        }
      }
      out.append(
        StageFire(
          time: f.time, wallTime: now - max(0, age), panel: panel, deck: deck, netId: info.id,
          transitionId: transitionId, transition: transition, origin: origin, note: f.note,
          velocity: f.velocity, channel: f.channel, durSec: f.durSec,
          macroRunning: f.flags.contains(.macro), isDrum: f.flags.contains(.drum),
          isStinger: f.flags.contains(.stinger)))
    }
    return out
  }

  // MARK: stats

  /// stage.js `renderStats`: `N bars · active/nets nets · P places · T transitions · A arcs ·
  /// K notes`, over the non-control nets that have places and transitions (all variants, muted
  /// ones counted in `nets` and not in `active`). With two decks the counts add up and the bars
  /// are the longer song's.
  private func statsText(views: [DeckView]) -> String {
    var nets = 0
    var muted = 0
    var places = 0
    var transitions = 0
    var arcs = 0
    var notes = 0
    var bars = 0
    for v in views {
      bars = max(bars, v.nets.layout.bars)
      places += v.nets.places
      transitions += v.nets.transitions
      arcs += v.nets.arcs
      notes += v.nets.notes
      for (i, on) in v.nets.counted.enumerated() where on {
        nets += 1
        if v.snapshot.isMuted(net: i) { muted += 1 }
      }
    }
    return
      "\(bars) bars · \(nets - muted)/\(nets) nets · \(places) places · \(transitions) transitions · \(arcs) arcs · \(notes) notes"
  }
}

/// Adapts a closure to `StageRandom` (the model's injectable `Math.random`).
struct ClosureRandom: StageRandom {
  let generate: () -> Double
  mutating func next() -> Double { generate() }
}
