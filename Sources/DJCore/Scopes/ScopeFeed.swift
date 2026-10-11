// ScopeFeed: everything a scope mode reads, for one source (a deck, or the master).
//
// READ THIS FIRST (mode authors)
// ==============================
// A feed is a MAIN-THREAD aggregate (`@MainActor`) over the engine's lock-free plumbing (the
// F1 taps, fire/anchor rings and marking mirror). A mode never touches those, and never
// re-derives what the engine publishes (tempo, tick, phase, marking, fires, mutes, sections,
// roles): it reads it from here.
//
// Getting one.
//   * In a view: the host (`ScopePanelView`) already holds the subscription; a mode view is
//     handed `(feed:measured:hub:)`. Draw from `feed`, and call `hub.pump()` first thing in the
//     draw (`ScopeCanvas` does that for you).
//   * In a test: `ScopeHub(engine:)`, `hub.feed(.deck("A"))`, `feed.acquire()` BEFORE rendering,
//     render, `hub.pump()`. `ScopeTestSupport.swift` has helpers.
//
// Time base (do not drift from this).
//   * Every stamp is an ENGINE FRAME. Audio seconds = frame / `sampleRate`. A deck's frames
//     (`Deck.renderedFrames`), the master's (`DJEngine.frame`), the taps' samples, `FireEvent`s
//     and `TickAnchor`s all share that axis, so a waveform and the fires line up exactly.
//   * "now" (`nowFrame`, `nowTime`) is the right edge of every time axis. It is FREE-RUNNING:
//     the frames the engine has rendered as of the last `pump()`, not the wall clock. When the
//     engine stops, "now" stops; nothing is estimated from the clock.
//   * Everything a feed exposes is at or before `nowFrame`: samples, fires, anchors. Records the
//     audio thread wrote after "now" was read are held back to the next pump.
//   * What the listener hears is `engine.outputLatencyFrames` behind "now"; a display that wants
//     to line up with the speakers subtracts it.
//   * A master feed's "now" is the master tap's right edge once the tap delivers (it is written
//     last in a render cycle, so every deck's records below it are complete). Before that, and
//     if the tap goes silent (`masterTapSilent`), it is the frame every net deck has finished
//     (`min(engine.frame, deck.renderedFrames…)`): the engine clock is counted FIRST in a cycle
//     and can be ahead of a deck, so it is never used on its own. `nowFrame` never goes back.
//
// When data moves.
//   * `pump()` drains the rings into this feed. Call it once per UI frame (the hub's `pump()`
//     does it for every subscribed feed). A second call in the same frame finds (almost)
//     nothing new and costs a few atomic loads, so every Canvas may call it. With the engine
//     stopped, or rendered offline between pumps, a repeat pump changes nothing at all. With the
//     audio thread running it can advance "now" by at most the render cycles that happened in
//     between (one block, about 10 ms), and `marking()` is re-read per pump: two canvases of
//     one frame may differ by that much. Draw each canvas from what it reads in its own draw.
//   * A feed does nothing, and its taps stay OFF, until someone `acquire()`s it. Balance with
//     `release()`; the last release switches the tap off.
//
// Resets (`generation`).
//   * `generation` changes when a mode must forget its accumulated state: a new track, a restart
//     from the top (the step counter jumped back more than 32 steps, no loop; scope.js
//     `resetHistory`), the deck changing between sample and net, or (re)acquiring. A section
//     relaunch or a jump FORWARD of the same song is not a reset: the sample history, fire log
//     and (until the rule above trips) the anchors carry on.
//   * Generation numbers come from ONE process-wide counter: no two feeds ever report the same
//     value, and a value never repeats. So "reset when `feed.generation` changes" also covers a
//     panel that swaps to another feed (a different source): the new feed's number differs.
//     (`ScopePanelView` additionally gives the mode view a new identity per feed.)
//   * `fireLog.total` (= `fireCount`) only ever grows within a feed, also across acquire, release
//     and re-acquire; a cursor taken from another feed may be ahead of it, and
//     `fireLog.numbers(since:)` is then empty, not a trap.
//   * `trackSerial` identifies the song of the lead deck. On a deck feed, same serial = same
//     lanes; a master feed's lanes are both decks', see the last point.
//   * Lanes (`lanes`) change only together with a generation bump.
//   * On a master feed `anchors`, `sections`, `clock`, `trackSerial` and `leadProject` follow the
//     LEAD deck (`leadDeck`), while `lanes` and the fire log are both decks'. The lead changes
//     with the crossfader and play state (with hysteresis: it needs a 1.25x louder weight to
//     take over, so a crossfader at the centre does not flip it); that is NOT a generation bump.
//     A mode that caches something of the lead (the bar grid, the sections) re-reads it when
//     `leadDeck` or `trackSerial` changes.
//
// Deviations from the JS, on purpose.
//   * The JS derives its (time, step) anchors from fires. Here the engine publishes an anchor
//     for every tick with its exact frame, tempo and `.swap` / `.discontinuity` flags; the feed
//     uses those (dedup by step as `pushAnchor` does, `step = tick - 1`).
//   * The reset rule runs on those anchors rather than on fires.
//   * The anchor ring holds 128 (`ScopeAnchorRing`), not 64: there is one per tick.
//   * The fire log is cleared on a new track (lane indices mean something else), which the JS
//     does not do.
//   * A lane's note lengths (`ScopeLane.durationsMs`) are built at the tempo the deck actually
//     runs when the song is first seen (the first anchor's, else the deck's), because the engine's
//     `ScopeFire.durSec` is at that tempo too. The JS builds both at its one UI tempo. Like the
//     JS, they are not rebuilt when the tempo moves later.

import Foundation

/// Where generation numbers come from: one counter for the whole process, so that two feeds never
/// report the same value (per-feed counters collided, and a mode that was handed another feed saw
/// no change).
@MainActor
enum ScopeGenerations {
  private static var last = 0
  static func next() -> Int {
    last += 1
    return last
  }
}

/// Where a feed listens.
public enum ScopeSource: Hashable, Sendable {
  case deck(String)
  /// The master mix; lanes, fires and the bar grid of every net deck.
  case master

  public var label: String {
    switch self {
    case .deck(let n): "Deck \(n)"
    case .master: "Master"
    }
  }
}

public enum ScopeTransport: Equatable, Sendable {
  /// No net deck behind the source (a sample deck, or nothing loaded).
  case noNet
  case stopped
  case playing
  /// The net clock is frozen by a scratch.
  case scrubbing
  /// The song ended (a `stop-transport` control fired).
  case ended

  /// What a status line says when the net is not running: "stopped", "scrubbing", "ended"; nil
  /// while it plays (or there is no net).
  public var statusNote: String? {
    switch self {
    case .playing, .noNet: nil
    case .stopped: "stopped"
    case .scrubbing: "scrubbing"
    case .ended: "ended"
    }
  }
}

/// The net clock as of the last pump (the lead deck's, on a master feed).
public struct ScopeClock: Equatable, Sendable {
  /// BPM; never 0 (120 when the engine has none yet, as scope.js `tickSecOf`).
  public var tempo: Double
  /// Seconds per step: `60 / (tempo * 4)`.
  public var tickSec: Double
  /// The graph's tick counter. The step being played is `tick - 1`.
  public var tick: Int
  /// Fraction of the current tick elapsed.
  public var tickPhase: Double
  public var transport: ScopeTransport
  /// A macro is running on the lead deck: fired and not yet run out, a mute timer, a beat repeat
  /// or a tempo effect (`WaveRunner.macroActive`).
  public var macroActive: Bool

  public var playing: Bool { transport == .playing }

  public static let idle = ScopeClock(
    tempo: 120, tickSec: tickSec(forTempo: 120), tick: 0, tickPhase: 0, transport: .noNet,
    macroActive: false)

  /// scope.js `tickSecOf`: `60 / ((finite and > 0 ? tempo : 120) * 4)`.
  public static func tickSec(forTempo t: Double) -> Double {
    60 / ((t.isFinite && t > 0 ? t : 120) * 4)
  }
}

@MainActor
public final class ScopeFeed {
  public let source: ScopeSource
  public let sampleRate: Double
  /// Scope windows are 64 steps (4 bars) wide.
  public static let windowSteps = ScopeTimeAxis.windowSteps
  /// Steps per bar.
  public static let stepsPerBar = 16

  // MARK: published state (read-only for modes)

  /// Bumped whenever a mode must reset (see the header).
  public private(set) var generation = 0
  /// The fire number (`fireLog.total` at that moment) at which the current `generation` began:
  /// fires numbered below it belong to the state a mode just reset. A mode that accumulates over
  /// the fire log resets on a new `generation` and continues from here, so the fires that were
  /// logged in the same pump after the reset (a restart's first step) are not lost and the ones
  /// before it are not counted twice.
  public private(set) var generationFireStart = 0
  /// Bumped by every pump that ingested anything or changed the clock: "is there something new
  /// to draw?".
  public private(set) var revision = 0
  /// Engine frame of the right edge: the frames the engine had rendered at the last pump.
  public private(set) var nowFrame = 0
  public var nowTime: Double { Double(nowFrame) / sampleRate }

  /// Mono sample history (≥ 8192, in fact 32768, samples) on the engine's frame axis.
  public private(set) var history = ScopeSampleHistory()
  /// The fires of the lanes, newest 4096. Consume with `fireLog.numbers(since:)`.
  public private(set) var fireLog = ScopeFireLog()
  public var fireCount: Int { fireLog.total }
  /// Lanes of the source: the deck's, or on a master feed both net decks' concatenated in deck
  /// name order (each `ScopeLane.deck` says whose).
  public private(set) var lanes: [ScopeLane] = []
  public private(set) var clock = ScopeClock.idle
  /// Is any net deck behind the source? False: a model mode shows "needs a net deck"; waveform
  /// and measured modes still work from `history`.
  public private(set) var hasNet = false
  /// The deck whose clock, anchors and sections this feed shows (a deck feed: that deck; master:
  /// the loudest playing net deck, ties to the first by name).
  public private(set) var leadDeck: String?
  /// The song's `trackSerial` on the lead deck (0: none).
  public private(set) var trackSerial: Int32 = 0
  /// Per-deck model weight: gain² of the strip (trim × volume × crossfader). 1 for a deck feed.
  public private(set) var deckWeights: [String: Double] = [:]
  /// Records the audio thread lost before this feed could read them (overwritten rings), and
  /// samples the tap lost.
  public private(set) var lostFires = 0
  public private(set) var lostAnchors = 0
  public var lostSamples: Int { history.lostFrames }
  /// Master feed only: the master tap has delivered nothing for half a second although the decks
  /// rendered (the output unit refused the notification, say). `history` then stands still, but
  /// fires, anchors and "now" carry on from the decks.
  public private(set) var masterTapSilent = false

  public var tickSec: Double { clock.tickSec }

  /// The lead deck's anchors (see `ScopeAnchorRing`).
  public var anchors: ScopeAnchorRing { leadChannel?.anchors ?? ScopeAnchorRing() }

  /// The lead deck's sections; empty for a loop.
  public var sections: [ScopeSection] { leadChannel?.laneSet.sections ?? [] }

  /// The lane set of a deck feed's deck (net id → lane map included); master: the lead's.
  public var laneSet: ScopeLaneSet { leadChannel?.laneSet ?? ScopeLaneSet() }

  /// The `Project` of the song being shown on the lead deck, the one `lanes` were built from:
  /// what a mode that has to walk the whole arrangement (the raster) compiles. Nil for a sample
  /// deck, or when that project is no longer the deck's (a feed acquired behind a queued project
  /// sees the sounding song through `MarkingLayout` only).
  public var leadProject: Project? { leadChannel?.project }

  /// `leadProject` of one deck (a master feed has both).
  public func project(deck: String) -> Project? {
    channels.first { $0.name == deck && $0.active }?.project
  }

  public var subscribers: Int { refs }
  public var isActive: Bool { refs > 0 }

  // MARK: private state

  private let engine: DJEngine
  private var refs = 0
  private var channels: [Channel] = []
  private var cursorSeq = 0
  private var needsCursor = true
  private var acquiredFrame = 0
  private var scratch = [Float](repeating: 0, count: 8192)
  private var stamp = 0  // pump calls, for per-pump caches
  private var leftHeld = false  // this feed holds a subscription on the source's left-channel tap
  private var leftSince = 0  // the left tap's `frames` when the lease began: nothing older is its

  private var historyTap: ScopeTap {
    switch source {
    case .master: engine.masterTap
    case .deck(let n): engine.decks[n]?.tap ?? engine.masterTap
    }
  }

  private var hasHistorySource: Bool {
    switch source {
    case .master: true
    case .deck(let n): engine.decks[n] != nil
    }
  }

  private var leadChannel: Channel? {
    guard let lead = leadDeck else { return nil }
    return channels.first { $0.name == lead }
  }

  init(source: ScopeSource, engine: DJEngine) {
    self.source = source
    self.engine = engine
    sampleRate = engine.sampleRate
    let names: [String]
    switch source {
    case .master: names = engine.decks.keys.sorted()
    case .deck(let n): names = engine.decks[n] != nil ? [n] : []
    }
    channels = names.map { Channel(deck: engine.decks[$0]!, sampleRate: engine.sampleRate) }
  }

  // MARK: subscribing

  /// A view (or test) starts reading. The first acquire switches the tap on and starts the
  /// history at "now". Balance with `release()`.
  public func acquire() {
    refs += 1
    guard refs == 1 else { return }
    if hasHistorySource { historyTap.acquire() }
    needsCursor = true
    acquiredFrame = rawNow()
    history.reset(at: acquiredFrame)
    // The fire log is emptied (rebuildLanes below), not replaced: `total` keeps counting, so a
    // consumer's remembered number can only ever be behind it.
    lostFires = 0
    lostAnchors = 0
    masterTapSilent = false
    nowFrame = acquiredFrame
    for ch in channels { ch.deactivate() }
    for ch in channels where ch.deck.mode == .net { activate(ch) }
    rebuildLanes()
    refreshComposite()
    revision += 1
  }

  /// The last release switches the tap off. Extra releases are ignored.
  public func release() {
    guard refs > 0 else { return }
    refs -= 1
    if refs == 0 {
      if hasHistorySource { historyTap.release() }
      setLeftChannelWanted(false)  // a lease: it ends with the last subscriber
    }
  }

  // MARK: left channel

  // The stage's corona analyses the LEFT channel (Tone's Analyser is Gain -> ChannelSplitter(1) ->
  // AnalyserNode, see the header of AnalyserFFT), while `history` is the (L+R)/2 down-mix every
  // other mode wants. The left channel therefore has its own tap, per deck and for the master,
  // which costs the audio thread one atomic load per block while nobody wants it. It is a
  // LEASE, not a subscription: the stage asks for it every frame it shows the corona
  // (`setLeftChannelWanted(true)` is idempotent), hands it back when the corona stops showing
  // and when the Stage closes (`StageModel.detach()`), and it ends by itself with the feed's
  // last `release()`: a closed Stage window cannot leave a tap running, whatever else holds the
  // feed. It carries no history: `copyNewestLeftSamples` hands out the newest samples of THIS
  // lease at the moment of the call, like an AnalyserNode that is read now. A tap that was
  // switched off keeps its old samples in the ring, so a window that reached back past the
  // start of the lease would hear the audio of a previous session as if it were current: the
  // lease starts at the tap's sequence number of that moment, and nothing older is returned.

  private var leftTap: ScopeTap? {
    switch source {
    case .master: engine.masterLeftTap
    case .deck(let n): engine.decks[n]?.leftTap
    }
  }

  /// Is the left channel being collected for this feed?
  public var leftChannelWanted: Bool { leftHeld }

  /// Start or stop collecting the source's left channel (pre-EQ, pre-fader for a deck, the master
  /// pair's for the master). Only meaningful while the feed is acquired: asking before `acquire()`
  /// is ignored, and the last `release()` switches it off. Idempotent.
  public func setLeftChannelWanted(_ on: Bool) {
    if on {
      guard refs > 0, !leftHeld, let tap = leftTap else { return }
      leftSince = tap.frames  // before the tap is switched on: everything after it is the lease's
      tap.acquire()
      leftHeld = true
    } else if leftHeld {
      leftTap?.release()
      leftHeld = false
    }
  }

  /// The newest `out.count` samples of the left channel, oldest first, zero-padded at the front
  /// while fewer have been collected SINCE THE LEASE BEGAN. Returns false (and zeroes `out`)
  /// when the channel is not wanted or nothing has arrived yet. Allocation-free.
  @discardableResult
  public func copyNewestLeftSamples(into out: UnsafeMutableBufferPointer<Float>) -> Bool {
    guard !out.isEmpty else { return false }
    out.update(repeating: 0)
    guard leftHeld, let tap = leftTap else { return false }
    let end = tap.frames  // one snapshot: the window and the read agree on where "now" is
    let have = min(out.count, end - leftSince, tap.ring.capacity)
    guard have > 0 else { return false }
    let tail = UnsafeMutableBufferPointer(rebasing: out[(out.count - have)...])
    let r = tap.read(from: end - have, into: tail)
    // A lap of the reader by the producer DURING the copy shows as `count < have` (the torn prefix
    // is dropped); `lost` also covers a lap before it began. Either way the samples are not the
    // newest `have`: count them as silence.
    guard r.count == have, r.lost == 0 else {
      out.update(repeating: 0)
      return false
    }
    return true
  }

  // MARK: pumping

  /// Drain the engine's rings into this feed; see the header. No-op while nobody subscribed.
  public func pump() {
    guard refs > 0 else { return }
    stamp += 1
    let before = (fireLog.total, nowFrame, generation, clock, history.endFrame, masterTapSilent)
    let n0 = max(sourceNow(), nowFrame)
    for ch in channels { drain(ch) }
    processStaged(upTo: n0)
    for ch in channels { adoptLoadedProject(ch) }
    nowFrame = n0
    drainHistory(upTo: n0)
    refreshComposite()
    let after = (fireLog.total, nowFrame, generation, clock, history.endFrame, masterTapSilent)
    if before.0 != after.0 || before.1 != after.1 || before.2 != after.2 || before.3 != after.3
      || before.4 != after.4 || before.5 != after.5
    {
      revision += 1
    }
  }

  /// The frame count of this source that every record below is complete for, read before
  /// anything is drained. A deck: the frames its source node rendered. Master: `deckBound()`.
  private func rawNow() -> Int {
    switch source {
    case .master: deckBound()
    case .deck(let n): engine.decks[n]?.renderedFrames ?? 0
    }
  }

  /// A frame below which every net deck's records are in their rings. The engine clock counts a
  /// render cycle FIRST, so it can be ahead of a deck that has not rendered yet; a deck bumps
  /// `renderedFrames` after it wrote its records. The smaller of them is safe at any moment.
  private func deckBound() -> Int {
    var bound = engine.frame
    for ch in channels where ch.deck.mode == .net { bound = min(bound, ch.deck.renderedFrames) }
    return bound
  }

  /// "Now" for this pump (see the header). A deck: the frames its source node rendered. Master:
  /// the master tap's right edge once the tap has delivered since `acquire()` (written last in a
  /// render cycle, so complete for every deck), else `deckBound()` — before the first delivery,
  /// and when the tap has delivered nothing for half a second while the decks rendered
  /// (`masterTapSilent`).
  private func sourceNow() -> Int {
    switch source {
    case .deck: return max(rawNow(), acquiredFrame)
    case .master:
      let bound = deckBound()
      let tap = engine.masterTap
      let delivering = engine.masterTapAttached && tap.frames > 0 && tap.endFrame > acquiredFrame
      let behind = bound - (delivering ? tap.endFrame : acquiredFrame)
      masterTapSilent = behind > Int(sampleRate / 2)
      if delivering && !masterTapSilent { return tap.endFrame }
      return max(bound, acquiredFrame)
    }
  }

  // MARK: history

  private func drainHistory(upTo n0: Int) {
    guard hasHistorySource else { return }
    let tap = historyTap
    guard tap.frames > 0 else { return }
    if needsCursor {
      guard tap.endFrame > acquiredFrame else { return }
      cursorSeq = max(0, tap.sequence(ofFrame: acquiredFrame))
      history.reset(at: tap.frame(ofSequence: cursorSeq))
      needsCursor = false
    }
    let want = min(tap.frames, tap.sequence(ofFrame: n0))
    while cursorSeq < want {
      let chunk = min(scratch.count, want - cursorSeq)
      let r = scratch.withUnsafeMutableBufferPointer { buf in
        tap.read(from: cursorSeq, into: UnsafeMutableBufferPointer(rebasing: buf[0..<chunk]))
      }
      if r.lost > 0 { history.appendLost(r.lost) }
      if r.count > 0 {
        scratch.withUnsafeBufferPointer {
          history.append(UnsafeBufferPointer(rebasing: $0[0..<r.count]))
        }
      }
      cursorSeq += r.lost + r.count
      if r.count == 0 && r.lost == 0 { break }
    }
  }

  // MARK: events

  /// What the feed keeps per net deck: its cursor into the engine's event rings, its anchors, its
  /// lanes. A deck feed has one, a master feed one per deck.
  final class Channel {
    let deck: Deck
    var name: String { deck.name }
    let sampleRate: Double
    var active = false
    var cursor = WaveDeckSource.EventCursor()
    var fireStage: [FireEvent] = []
    var anchorStage: [TickAnchor] = []
    var forceRunStart = false
    var anchors = ScopeAnchorRing()
    var lastStep = -1
    /// The song being shown (0: none yet), its lanes and the project they were built from.
    var serial: Int32 = 0
    var laneSet = ScopeLaneSet()
    var project: Project?
    var laneBase = 0
    var tracks: [Int32: TrackEntry] = [:]
    var trackOrder: [Int32] = []
    var infos: [Int32: GenInfo] = [:]
    var infoOrder: [Int32] = []
    var lastFiredGeneration: Int32 = 0
    var lastFired: [LastFire] = []
    var desiredKey: (Int32, Int32, Bool) = (-1, -1, false)
    var desiredGeneration: Int32 = 0
    var scratchMarking = MarkingSnapshot()
    var marking = MarkingSnapshot()
    var markingStamp = -1

    init(deck: Deck, sampleRate: Double) {
      self.deck = deck
      self.sampleRate = sampleRate
    }

    func deactivate() {
      active = false
      cursor = .init()
      fireStage.removeAll()
      anchorStage.removeAll()
      anchors.removeAll()
      lastStep = -1
      serial = 0
      laneSet = ScopeLaneSet()
      project = nil
      lastFired = []
      lastFiredGeneration = 0
      forceRunStart = false
      desiredKey = (-1, -1, false)
    }
  }

  /// What is known about one song (`trackSerial`) of a deck: its lanes, and the `Project` they
  /// came from when it was still the deck's.
  struct TrackEntry {
    var laneSet: ScopeLaneSet
    var project: Project?
  }

  /// What is known about one engine generation (project) of a deck.
  final class GenInfo {
    let layout: MarkingLayout
    let track: TrackEntry
    var laneSet: ScopeLaneSet { track.laneSet }
    /// Net index -> lane index in `laneSet`, -1 for a net with no lane.
    let netToLane: [Int]

    init(layout: MarkingLayout, track: TrackEntry) {
      self.layout = layout
      self.track = track
      netToLane = layout.netIds.map { track.laneSet.laneOf[$0] ?? -1 }
    }
  }

  struct LastFire {
    var frame = -1
    var transition = 0
  }

  private func activate(_ ch: Channel) {
    ch.deactivate()
    ch.active = true
    ch.cursor = ch.deck.wave.eventCursorNow()
  }

  /// Lanes of the source = the active channels' lanes in deck order; they change only here, and a
  /// change means the lane indices of everything logged so far are stale.
  private func rebuildLanes() {
    var all: [ScopeLane] = []
    for ch in channels where ch.active {
      ch.laneBase = all.count
      all.append(contentsOf: ch.laneSet.lanes)
    }
    lanes = all
    fireLog.removeAll()
    generation = ScopeGenerations.next()
    generationFireStart = fireLog.total
  }

  private func resetHistory(_ ch: Channel) {
    ch.anchors.removeAll()
    ch.lastStep = -1
    generation = ScopeGenerations.next()
    generationFireStart = fireLog.total
  }

  /// scope.js `resetHistory`'s trigger: the step counter went back by more than 32 steps and the
  /// deck is not looping.
  static func isRestart(step: Int, lastStep: Int, looping: Bool) -> Bool {
    lastStep >= 0 && step < lastStep - 32 && !looping
  }

  private func newTrack(_ ch: Channel, serial: Int32, track: TrackEntry) {
    ch.serial = serial
    ch.laneSet = track.laneSet
    ch.project = track.project
    ch.anchors.removeAll()
    ch.lastStep = -1
    ch.lastFired = []
    ch.lastFiredGeneration = 0
    rebuildLanes()
  }

  /// The BPM a deck's net runs at when `info` first sees a song and no anchor says: the published
  /// tempo while it plays, else what the deck is set to (base x fader x nudge: the published one
  /// lags a command until the next block), else the project's own.
  private func runningTempo(_ ch: Channel, project: Project) -> Double {
    let live = ch.deck.wave.tempo
    if ch.deck.wave.isPlaying, live.isFinite, live > 0 { return live }
    if let set = ch.deck.effectiveBPM, set.isFinite, set > 0 { return set }
    return project.tempo
  }

  /// Layout, lanes and net → lane map of one generation of a deck's projects (built once).
  /// `tempo` is the BPM the song runs at (the first anchor's); lane note lengths are built at it,
  /// because the fires' lengths are (see the header).
  private func info(_ ch: Channel, generation g: Int32, tempo: Double? = nil) -> GenInfo? {
    if let i = ch.infos[g] { return i }
    guard let layout = ch.deck.wave.markingLayout(generation: g) else { return nil }
    let track: TrackEntry
    if let known = ch.tracks[layout.trackSerial] {
      track = known
    } else {
      if let latest = ch.deck.wave.latest, latest.trackSerial == layout.trackSerial,
        let project = ch.deck.netProject
      {
        let bpm = tempo ?? runningTempo(ch, project: project)
        track = TrackEntry(
          laneSet: .build(project: project, tempo: bpm, deck: ch.name), project: project)
      } else {
        track = TrackEntry(laneSet: .build(layout: layout, deck: ch.name), project: nil)
      }
      ch.tracks[layout.trackSerial] = track
      ch.trackOrder.append(layout.trackSerial)
      if ch.trackOrder.count > 4 { ch.tracks[ch.trackOrder.removeFirst()] = nil }
    }
    let i = GenInfo(layout: layout, track: track)
    ch.infos[g] = i
    ch.infoOrder.append(g)
    if ch.infoOrder.count > 4 { ch.infos[ch.infoOrder.removeFirst()] = nil }
    return i
  }

  /// Phase 1: bring a channel in line with its deck's mode, then pull whatever the audio thread
  /// has written into the channel's staging arrays.
  private func drain(_ ch: Channel) {
    let deck = ch.deck
    guard deck.mode == .net else {
      if ch.active {
        ch.deactivate()
        rebuildLanes()
      }
      return
    }
    if !ch.active {
      activate(ch)
      rebuildLanes()
    }
    let lost = deck.wave.readEvents(&ch.cursor, fires: &ch.fireStage, anchors: &ch.anchorStage)
    lostFires += lost.firesLost
    lostAnchors += lost.anchorsLost
    if lost.anchorsLost > 0 { ch.forceRunStart = true }
  }

  /// Phase 2: apply the staged records older than `n0`, from all channels together in time
  /// order (on a tie: anchors before fires, then deck order), so a master log is time ordered and
  /// a track change on one deck lands before the fires that come after it.
  private func processStaged(upTo n0: Int) {
    var ai = [Int](repeating: 0, count: channels.count)
    var fi = [Int](repeating: 0, count: channels.count)
    while true {
      var best: (frame: Int, kind: Int, channel: Int)?
      for (c, ch) in channels.enumerated() where ch.active {
        if ai[c] < ch.anchorStage.count {
          let cand = (Int(ch.anchorStage[ai[c]].frame), 0, c)
          if cand.0 < n0, best == nil || cand < best! { best = cand }
        }
        if fi[c] < ch.fireStage.count {
          let cand = (Int(ch.fireStage[fi[c]].frame), 1, c)
          if cand.0 < n0, best == nil || cand < best! { best = cand }
        }
      }
      guard let pick = best else { break }
      let ch = channels[pick.channel]
      if pick.kind == 0 {
        process(ch, anchor: ch.anchorStage[ai[pick.channel]])
        ai[pick.channel] += 1
      } else {
        process(ch, fire: ch.fireStage[fi[pick.channel]])
        fi[pick.channel] += 1
      }
    }
    for (c, ch) in channels.enumerated() {
      if ai[c] > 0 { ch.anchorStage.removeFirst(ai[c]) }
      if fi[c] > 0 { ch.fireStage.removeFirst(fi[c]) }
    }
  }

  /// Phase 3: a stopped deck installs a loaded project at once; show its lanes before its first
  /// anchor.
  private func adoptLoadedProject(_ ch: Channel) {
    guard ch.active, !ch.deck.wave.isPlaying, ch.anchorStage.isEmpty else { return }
    let g = desiredGeneration(ch)
    if g != 0, let i = info(ch, generation: g), i.layout.trackSerial != ch.serial {
      newTrack(ch, serial: i.layout.trackSerial, track: i.track)
    }
  }

  /// The generation F1 reports as current for the deck (`readMarking`), re-asked only when the
  /// things it depends on change.
  private func desiredGeneration(_ ch: Channel) -> Int32 {
    let w = ch.deck.wave
    let key = (w.activeGeneration, w.latest?.generation ?? 0, w.isPlaying)
    if key != ch.desiredKey {
      ch.desiredKey = key
      ch.desiredGeneration =
        w.readMarking(into: &ch.scratchMarking) ? ch.scratchMarking.generation : 0
    }
    return ch.desiredGeneration
  }

  /// `lastFired` belongs to the generation that is running: it starts afresh when the engine's
  /// generation changes. The first anchor of a generation comes before its first fire, so doing
  /// it there (as well as at a fire whose anchor was lost) means nothing from the generation
  /// before is reported once the new one has begun.
  private func rollLastFired(_ ch: Channel, generation g: Int32, layout: MarkingLayout) {
    guard g != ch.lastFiredGeneration else { return }
    ch.lastFiredGeneration = g
    ch.lastFired = [LastFire](repeating: LastFire(), count: layout.netCount)
  }

  private func process(_ ch: Channel, anchor a: TickAnchor) {
    if let i = info(ch, generation: a.generation, tempo: Double(a.tempo)) {
      if i.layout.trackSerial != ch.serial {
        newTrack(ch, serial: i.layout.trackSerial, track: i.track)
      }
      rollLastFired(ch, generation: a.generation, layout: i.layout)
    }
    let step = Int(a.tick) - 1
    if Self.isRestart(step: step, lastStep: ch.lastStep, looping: ch.deck.looping) {
      resetHistory(ch)
    }
    ch.lastStep = step
    let anchor = ScopeAnchor(
      time: Double(a.frame) / sampleRate, frame: Int(a.frame), step: step, tempo: Double(a.tempo),
      generation: a.generation,
      discontinuity: a.flags.contains(.discontinuity) || ch.forceRunStart,
      swap: a.flags.contains(.swap))
    ch.forceRunStart = false
    ch.anchors.push(anchor)
  }

  private func process(_ ch: Channel, fire f: FireEvent) {
    guard let i = info(ch, generation: f.generation), i.layout.trackSerial == ch.serial else {
      return
    }
    let net = Int(f.net)
    rollLastFired(ch, generation: f.generation, layout: i.layout)
    if net >= 0, net < ch.lastFired.count {
      ch.lastFired[net] = LastFire(frame: Int(f.frame), transition: Int(f.transition))
    }
    guard net >= 0, net < i.netToLane.count, i.netToLane[net] >= 0 else { return }
    let v = Int(f.velocity)
    // scope.js `durMsOf`: a length that is not positive is 100 ms.
    let durMs = Double(f.durMs)
    fireLog.append(
      ScopeFire(
        time: Double(f.frame) / sampleRate, frame: Int(f.frame),
        lane: ch.laneBase + i.netToLane[net],
        net: net, transition: Int(f.transition), note: Int(f.note) & 127,
        velocity: max(1, min(127, v == 0 ? 100 : v)),
        durSec: (durMs.isFinite && durMs > 0 ? durMs : 100) / 1000,
        channel: Int(f.channel), step: Int(f.tick) - 1, generation: f.generation, flags: f.flags))
  }

  // MARK: clock, lead deck, weights

  private func refreshComposite() {
    let netChannels = channels.filter { $0.active }
    hasNet = !netChannels.isEmpty
    var weights: [String: Double] = [:]
    for ch in channels {
      let d = ch.deck
      let gain = source == .master ? d.trim * d.volume * engine.crossfadeGain(d.name) : 1
      weights[d.name] = gain * gain
    }
    deckWeights = weights
    let lead = chooseLead(netChannels, weights: weights)
    let previous = leadDeck
    leadDeck = lead?.name
    trackSerial = lead?.serial ?? 0
    var c = ScopeClock.idle
    if let lead {
      let w = lead.deck.wave
      var tempo = w.tempo
      if !(tempo.isFinite && tempo > 0) { tempo = lead.deck.effectiveBPM ?? 120 }
      if !(tempo.isFinite && tempo > 0) { tempo = 120 }
      c.tempo = tempo
      c.tickSec = ScopeClock.tickSec(forTempo: tempo)
      c.tick = w.tick
      c.tickPhase = w.tickPhase
      c.macroActive = w.isMacroActive
      c.transport =
        w.isScrubbing ? .scrubbing : (w.isPlaying ? .playing : (w.hasEnded ? .ended : .stopped))
    }
    clock = c
    if previous != leadDeck { revision += 1 }
  }

  /// A deck must be this much louder (weight, gain squared) than the current lead to take over.
  /// Near the crossfader's centre the two weights differ by rounding noise (cos²(π/4) against
  /// sin²(π/4)), and a lead that flipped on that would move the bar grid every frame.
  static let leadHysteresis = 1.25

  /// The lead deck: playing decks first, then the loudest, then by name. The current lead stays
  /// unless another deck is playing when it is not, or is louder by `leadHysteresis`.
  private func chooseLead(_ candidates: [Channel], weights: [String: Double]) -> Channel? {
    let best = candidates.sorted { a, b in
      let pa = a.deck.wave.isPlaying
      let pb = b.deck.wave.isPlaying
      if pa != pb { return pa }
      let wa = weights[a.name] ?? 0
      let wb = weights[b.name] ?? 0
      if wa != wb { return wa > wb }
      return a.name < b.name
    }.first
    guard let best, let current = candidates.first(where: { $0.name == leadDeck }),
      current !== best
    else { return best }
    if current.deck.wave.isPlaying == best.deck.wave.isPlaying {
      let wc = weights[current.name] ?? 0
      let wb = weights[best.name] ?? 0
      if wb <= wc * Self.leadHysteresis { return current }
    }
    return best
  }

  // MARK: reading helpers

  /// scope.js `anchorAt(t)` on the lead deck's anchors: the latest anchor at or before audio time
  /// `t`, else the oldest.
  public func anchorAt(_ t: Double) -> ScopeAnchor? { leadChannel?.anchors.anchor(at: t) }

  /// Song step (fractional) at audio time `t`, through the engine's anchors. Nil without any.
  public func stepAt(_ t: Double) -> Double? {
    leadChannel?.anchors.step(at: t, tickSec: clock.tickSec)
  }

  /// Audio time at which song step `s` begins, in the newest run of anchors.
  public func timeAt(step s: Double) -> Double? {
    leadChannel?.anchors.time(ofStep: s, tickSec: clock.tickSec)
  }

  /// scope.js `timeAxis`: the 64-step window ending at "now", mapped onto `x0 ..< x0 + w`.
  public func timeAxis(x0: Double, w: Double) -> ScopeTimeAxis {
    ScopeTimeAxis(
      tickSec: clock.tickSec, tNow: nowTime, anchor: anchorAt(nowTime), x0: x0, w: w)
  }

  /// The newest samples since `frame` (a mode remembers `history.endFrame` from its last look).
  public func newSamples(since frame: Int) -> ScopeSamples { history.newSamples(since: frame) }

  /// The `count` newest samples ending at `endingAt` (default: now), zero-padded at the front.
  public func window(count: Int, endingAt: Int? = nil) -> [Float] {
    history.window(count: count, endingAt: endingAt)
  }

  /// The lane index of net `netId` of deck `deck` in `lanes` (nil if it has no lane).
  public func lane(forNet netId: String, deck: String) -> Int? {
    guard let ch = channels.first(where: { $0.name == deck && $0.active }),
      let i = ch.laneSet.laneOf[netId]
    else { return nil }
    return ch.laneBase + i
  }

  /// The model weight of a lane: its deck's gain² (see `deckWeights`).
  public func weight(ofLane i: Int) -> Double {
    guard lanes.indices.contains(i) else { return 0 }
    return deckWeights[lanes[i].deck] ?? 1
  }

  /// The marking of a net deck (every net's place tokens and mute flags, consistent), read
  /// from the engine's mirror at most once per pump. Nil for a sample deck or when nothing is
  /// loaded. For a deck feed the argument can be left out.
  public func marking(deck: String? = nil) -> MarkingSnapshot? {
    let name: String?
    switch source {
    case .deck(let n): name = deck ?? n
    case .master: name = deck ?? leadDeck
    }
    guard let ch = channels.first(where: { $0.name == name }), ch.deck.mode == .net else {
      return nil
    }
    if ch.markingStamp != stamp {
      guard ch.deck.wave.readMarking(into: &ch.marking) else { return nil }
      ch.markingStamp = stamp
    }
    return ch.marking
  }

  /// When net `net` (an index into the marking's layout) last fired and which transition, in the
  /// generation the deck is running. Every fire counts, including nets that have no lane. Nil if
  /// it has not fired since the feed was acquired.
  public func lastFired(net: Int, deck: String? = nil) -> (frame: Int, transition: Int)? {
    let name: String?
    switch source {
    case .deck(let n): name = deck ?? n
    case .master: name = deck ?? leadDeck
    }
    guard let ch = channels.first(where: { $0.name == name }), net >= 0, net < ch.lastFired.count,
      ch.lastFired[net].frame >= 0
    else { return nil }
    return (ch.lastFired[net].frame, ch.lastFired[net].transition)
  }

  /// A short line for the panel header.
  public var statusText: String {
    if !hasNet { return source == .master ? "no net deck" : "needs a net deck" }
    var text = "\(lanes.count) lanes · \(Int(clock.tempo.rounded())) bpm"
    if let note = clock.transport.statusNote { text += " · \(note)" }
    if masterTapSilent { text += " · master tap silent" }
    return text
  }
}
