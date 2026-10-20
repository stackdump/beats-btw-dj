import Foundation
import Synchronization

// Auto-mix: Wander across two decks (docs/AUTOMIX.md). Wander walks one deck through
// configuration space a move per phrase; auto-mix walks the mix: the playing deck plays, a
// phrase ahead the idle deck is given a nearby configuration, and on a phrase boundary the two
// hand over — the incoming deck drums-forward (its melodic lanes resting), the outgoing deck
// mixed out, the crossfader stepping across bar by bar — and the decks swap roles.
//
// The three things a feature names (CLAUDE.md, the theme):
// 1. the poke: `DeckAction.autoMix(on:bars:every:)` (the whole setting at once) and
//    `.autoMixNow`; steering pokes on either deck pause it (`DJEngine.noteAutoMixTouch`);
// 2. the rule: `AutoMix.plan` — Wander's new-track moves (seed, instrument, genre) over the
//    playing deck's configuration, seeded from its share CID and the hand-off counter, with both
//    decks' locks, inside the mix's tempo window, pinned to a compatible key;
// 3. the boundary: a hand-off starts on a phrase boundary of the playing deck (its outro by
//    default) and lasts exactly `bars` bars; everything in it lands on bar lines.
//
// Only the pokes are recorded (and, live only, a compose that was late: `.autoMixDefer`). The
// draw, the prepare, the start, the crossfader steps, the mix-in and mix-out are derived, as
// Wander's moves are, so a replay walks the same set.

/// The poke's value (`DeckAction.autoMix`): on or off, the hand-off length, how long a track
/// plays.
public struct AutoMixSettings: Equatable, Sendable {
  /// Hand-off lengths in bars.
  public static let lengths = [4, 8, 16, 32]
  /// Phrases (8 bars) a track plays before the next hand-off; 0 = a song to its outro (a loop:
  /// `AutoMix.loopPhrases`).
  public static let everies = [0, 4, 8, 16]
  public static let defaultBars = 8

  public var on = false
  public var bars = AutoMixSettings.defaultBars
  public var every = 0

  public init(on: Bool = false, bars: Int = AutoMixSettings.defaultBars, every: Int = 0) {
    self.on = on
    self.bars = Self.lengths.contains(bars) ? bars : Self.defaultBars
    self.every = Self.everies.contains(every) ? every : 0
  }

  /// Nothing set but the defaults (off, 8 bars, to the outro): a session leaves it out.
  public var isDefault: Bool { self == AutoMixSettings() }

  /// "8 bars · to the outro", "16 bars · every 8 phrases".
  public var label: String {
    "\(bars) bars · " + (every == 0 ? "to the outro" : "every \(every) phrases")
  }
}

/// Where auto-mix is.
public enum AutoMixPhase: String, Sendable {
  case off
  /// On, but it can't act (`AutoMixState.idle` says why).
  case idle
  /// Counting down to the next hand-off.
  case playing
  /// A steering poke paused it: it resumes after a phrase with no input.
  case paused
  /// The next track is on (or on its way to) the idle deck, stopped.
  case preparing
  /// The incoming deck is started, its first bar still to come.
  case armed
  /// The hand-off is running.
  case mixing
}

/// The configuration hand-off `n` brings in.
public struct AutoMixPlan: Equatable, Sendable {
  public var n: Int
  /// What the incoming deck will play; for a cued deck, what it holds (nil: a shared net).
  public var spec: TrackSpec?
  /// seed | instrument | genre (Wander's move kinds), or cued (loaded by hand).
  public var kind: String
  /// "seed 41 → 44 · key A", "techno → house · seed 512", "cued: house #12".
  public var detail: String
  /// The outgoing configuration's share CID it was drawn from (nil for a cue).
  public var from: String?

  public var cued: Bool { kind == "cued" }

  var json: JSONValue {
    var o = JSONObject([
      ("n", .int(n)), ("kind", .string(kind)), ("move", .string(detail)),
    ])
    if let spec {
      o["genre"] = .string(spec.genre)
      o["seed"] = .number(spec.seed)
      o["cid"] = .string(BeatsCID.shareCID(spec.payload))
      o["spec"] = DeckSourceDescriptor.net(spec).json
    }
    if let from { o["from"] = .string(from) }
    return .object(o)
  }

  init(n: Int, spec: TrackSpec?, kind: String, detail: String, from: String?) {
    self.n = n
    self.spec = spec
    self.kind = kind
    self.detail = detail
    self.from = from
  }

  init?(json v: JSONValue?) {
    guard let v, let n = v["n"]?.int, let kind = v["kind"]?.string else { return nil }
    var spec: TrackSpec?
    if case .net(let s)? = v["spec"].flatMap(DeckSourceDescriptor.init(json:)) { spec = s }
    self.init(
      n: n, spec: spec, kind: kind, detail: v["move"]?.string ?? "", from: v["from"]?.string)
  }
}

/// One finished hand-off: the log row (newest first in `dj_state`).
public struct AutoMixHandoff: Equatable, Sendable {
  public var n: Int
  public var from: String
  public var to: String
  /// The bar of the outgoing deck it started on (0-based, its clock).
  public var bar: Int
  public var kind: String
  public var move: String
  public var spec: TrackSpec?

  public var cid: String? { spec.map { BeatsCID.shareCID($0.payload) } }

  public var json: JSONValue {
    var o = JSONObject([
      ("n", .int(n)), ("from", .string(from)), ("to", .string(to)), ("bar", .int(bar)),
      ("kind", .string(kind)), ("move", .string(move)),
    ])
    if let spec {
      o["genre"] = .string(spec.genre)
      o["seed"] = .number(spec.seed)
    }
    if let cid { o["cid"] = .string(cid) }
    return .object(o)
  }
}

/// A hand-off in flight: everything from its prep point to its end.
struct AutoMixRun: Equatable, Sendable {
  var plan: AutoMixPlan
  var out: String
  var inc: String
  /// The hand-off bar on the outgoing deck's clock, and how many bars it was prepared ahead.
  var handoffBar: Int
  var prep: Int
  var bars: Int
  /// The outgoing deck plays a net (else a sample with a beat grid: no mix-out, its clock is
  /// the grid's).
  var outIsNet: Bool
  var incomingReady = false
  /// The outgoing project's generation when the mix-out was prepared ahead (it is used only if
  /// nothing was loaded on that deck since).
  var outGeneration: Int32?
  /// Where the mix-out project starts (`Deck.mixOutPoint`); set when it is loaded.
  var mixOutTick: Int?
  /// The outgoing deck's song tick on the hand-off bar line: its tail's first tick (the mix-out
  /// jumps to an outro still ahead), else the bar's own.
  var outHandoffTick: Int?
  var mixOutLoaded = false
  var armed = false
  var corrected = false
  /// The crossfader at the hand-off bar, where it goes, and whether the user took it.
  var c0: Double?
  var xEnd: Double
  var faderTaken = false
  var lastFader: Double?
  /// The incoming deck's leader before the hand-off (restored at its end).
  var prevLeader: String?
  /// The incoming deck's tempo multiplier against the outgoing (1, or a cued deck's ½ / 2).
  var mult = 1.0

  var json: JSONValue {
    var o = JSONObject([
      ("plan", plan.json), ("out", .string(out)), ("in", .string(inc)),
      ("handoffBar", .int(handoffBar)), ("prep", .int(prep)), ("bars", .int(bars)),
      ("outIsNet", .bool(outIsNet)), ("ready", .bool(incomingReady)),
      ("mixOutLoaded", .bool(mixOutLoaded)), ("armed", .bool(armed)),
      ("corrected", .bool(corrected)), ("xEnd", .number(xEnd)), ("faderTaken", .bool(faderTaken)),
      ("mult", .number(mult)),
    ])
    if let t = mixOutTick { o["mixOutTick"] = .int(t) }
    if let t = outHandoffTick { o["outHandoffTick"] = .int(t) }
    if let c = c0 { o["c0"] = .number(c) }
    if let l = lastFader { o["lastFader"] = .number(l) }
    if let l = prevLeader { o["prevLeader"] = .string(l) }
    return .object(o)
  }

  init(
    plan: AutoMixPlan, out: String, inc: String, handoffBar: Int, prep: Int, bars: Int,
    outIsNet: Bool, xEnd: Double
  ) {
    self.plan = plan
    self.out = out
    self.inc = inc
    self.handoffBar = handoffBar
    self.prep = prep
    self.bars = bars
    self.outIsNet = outIsNet
    self.xEnd = xEnd
  }

  init?(json v: JSONValue?) {
    guard let v, let plan = AutoMixPlan(json: v["plan"]), let out = v["out"]?.string,
      let inc = v["in"]?.string, let h = v["handoffBar"]?.int
    else { return nil }
    self.init(
      plan: plan, out: out, inc: inc, handoffBar: h, prep: v["prep"]?.int ?? AutoMix.prepBars,
      bars: v["bars"]?.int ?? AutoMixSettings.defaultBars, outIsNet: v["outIsNet"]?.bool ?? true,
      xEnd: v["xEnd"]?.double ?? 1)
    incomingReady = v["ready"]?.bool ?? false
    mixOutTick = v["mixOutTick"]?.int
    outHandoffTick = v["outHandoffTick"]?.int
    mixOutLoaded = v["mixOutLoaded"]?.bool ?? false
    armed = v["armed"]?.bool ?? false
    corrected = v["corrected"]?.bool ?? false
    c0 = v["c0"]?.double
    faderTaken = v["faderTaken"]?.bool ?? false
    lastFader = v["lastFader"]?.double
    prevLeader = v["prevLeader"]?.string
    mult = v["mult"]?.double ?? 1
  }
}

/// Auto-mix's state on the engine (`DJEngine.autoMix`): the settings (the poke's value), the
/// hand-off counter, and where the walk is.
public struct AutoMixState: Equatable, Sendable {
  /// Rows the log keeps (newest last).
  public static let logLimit = 48

  public internal(set) var settings = AutoMixSettings()
  /// Hand-offs drawn so far: hand-off n draws from (the outgoing spec's CID, n).
  public internal(set) var handoffs = 0
  public internal(set) var phase: AutoMixPhase = .off
  /// The deck playing (the next hand-off's outgoing deck), once one is.
  public internal(set) var playing: String?
  /// Why it can't act, when it can't.
  public internal(set) var idle: String?
  /// A steering poke paused it; `quietBars` of the playing deck pass with no input to resume.
  public internal(set) var paused = false
  var quietBars = 0
  /// The playing deck's bar when last seen (nil: not yet).
  var lastBar: Int?
  /// The bar (playing deck's clock) `every` counts from: where the deck came fully in, or where
  /// auto-mix was turned on or resumed.
  var startBar: Int?
  /// The next hand-off bar, while counting down.
  public internal(set) var handoffBar: Int?
  /// Mix now: the next phrase boundary at least `AutoMix.nowPrepBars` away.
  var nowRequested = false
  /// The idle deck the user loaded by hand since the last hand-off: the next incoming, as-is.
  var cued: String?
  /// A start cancelled by a steering poke: its plan, kept (the incoming still holds it) unless
  /// the outgoing configuration changes.
  var kept: AutoMixPlan?
  var run: AutoMixRun?
  public internal(set) var log: [AutoMixHandoff] = []

  public init() {}

  /// The next hand-off's plan, from its prep point (or a kept one).
  public var next: AutoMixPlan? { run?.plan ?? kept }
  /// The deck coming in during a hand-off.
  public var incoming: String? { run?.inc }
  /// Who moves the crossfader in this hand-off: "auto", or "user" once taken.
  public var fader: String { run?.faderTaken == true ? "user" : "auto" }

  /// The session's starting value (`Session.mixer.autoMix`): settings and counter.
  var sessionJSON: JSONValue {
    .object(
      JSONObject([
        ("on", .bool(settings.on)), ("bars", .int(settings.bars)), ("every", .int(settings.every)),
        ("handoffs", .int(handoffs)),
      ]))
  }

  /// A session leaves it out when it is the default (older sessions keep their text and CID).
  var isSessionDefault: Bool { settings.isDefault && handoffs == 0 }

  /// A journal checkpoint's value: the session's, plus a hand-off in flight and the countdown.
  var checkpointJSON: JSONValue {
    var o = sessionJSON.object ?? JSONObject()
    if let p = playing { o["playing"] = .string(p) }
    if paused {
      o["paused"] = .bool(true)
      o["quietBars"] = .int(quietBars)
    }
    if let b = startBar { o["startBar"] = .int(b) }
    if nowRequested { o["now"] = .bool(true) }
    if let c = cued { o["cued"] = .string(c) }
    if let k = kept { o["kept"] = k.json }
    if let r = run { o["run"] = r.json }
    return .object(o)
  }

  /// A session's starting value: settings and counter only.
  init(settings: AutoMixSettings, handoffs: Int) {
    self.init()
    self.settings = settings
    self.handoffs = max(0, handoffs)
  }

  /// A session's `mixer.autoMix` read back (missing: the default).
  init(start v: JSONValue?) {
    let full = AutoMixState(json: v)
    self.init(settings: full.settings, handoffs: full.handoffs)
  }

  /// The part a session starts from (`Session.autoMix`).
  var start: AutoMixState { AutoMixState(settings: settings, handoffs: handoffs) }

  /// Read either form back (unknown or missing fields: the defaults).
  init(json v: JSONValue?) {
    self.init()
    guard let v else { return }
    settings = AutoMixSettings(
      on: v["on"]?.bool ?? false, bars: v["bars"]?.int ?? AutoMixSettings.defaultBars,
      every: v["every"]?.int ?? 0)
    handoffs = max(0, v["handoffs"]?.int ?? 0)
    playing = v["playing"]?.string
    paused = v["paused"]?.bool ?? false
    quietBars = v["quietBars"]?.int ?? 0
    startBar = v["startBar"]?.int
    nowRequested = v["now"]?.bool ?? false
    cued = v["cued"]?.string
    kept = AutoMixPlan(json: v["kept"])
    run = AutoMixRun(json: v["run"])
  }
}

public enum AutoMix {
  /// A phrase: hand-offs start on a multiple of 8 bars of the playing deck (or a section start).
  public static let phraseBars = 8
  /// How far ahead of the hand-off the next track is drawn and composed.
  public static let prepBars = 8
  /// Mix now: the next phrase boundary at least this many bars away.
  public static let nowPrepBars = 4
  /// Quiet bars (a phrase) after a steering poke before it resumes.
  public static let quietBars = 8
  /// A loop (no outro) plays this many phrases when `every` is 0 (64 bars).
  public static let loopPhrases = 8
  /// Keeps hand-off n from drawing what Wander's step n draws on the same configuration.
  static let salt: UInt64 = 0xA17C_0DE5_1A7E_F00D
  /// The move kinds that bring a new track.
  static let kinds: [WanderMoveKind] = [.seed, .instrument, .genre]
  /// The largest dip (LU) of the short-term loudness during a hand-off below the quieter of the
  /// two tracks alone, from `djctl automix` (see `maxDipSource`). The full hand-off's drums-
  /// forward overlap is a planned dip: this is the worst measured, rounded up to 0.5 LU.
  public static let maxDipLU = 24.0
  public static let maxDipSource =
    "djctl automix matrix 2026-10-19 (techno house trance dnb lofi jazz × seeds 42, 7; bars 8, "
    + "every 4; 48 kHz synth voices), n=12, worst lofi 7 −23.64 LU (lofi's drums and bass alone "
    + "are near silent: −39 LUFS short-term); the worst outside lofi trance 42 −9.40"

  /// Hand-off `n`'s incoming configuration over the outgoing deck's (`c`, with both decks'
  /// locks and `c.mixBPM`): Wander's seed / instrument / genre moves drawn from (the spec's CID
  /// ^ `salt`, n), then the key pinned compatible (`pinKey`) from the same stream. A pure
  /// function; nil when every new-track move is locked.
  static func plan(_ c: WanderContext, n: Int, key: WanderKey?) -> AutoMixPlan? {
    var rng = WanderRandom(base: WanderRandom.base(c.spec) ^ salt, step: n)
    let allowed = Wander.kinds(c).filter(kinds.contains)
    guard let p = Wander.plan(c, random: &rng, kinds: allowed), case .swap(var spec) = p.action
    else { return nil }
    var detail = p.detail
    if !c.locked("key"), let k = pinKey(&spec, to: key, &rng) { detail += " · \(k)" }
    return AutoMixPlan(
      n: n, spec: spec, kind: p.kind.rawValue, detail: detail,
      from: BeatsCID.shareCID(c.spec.payload))
  }

  /// Can a hand-off be drawn here at all (some new-track move left)?
  static func canDraw(_ c: WanderContext) -> Bool {
    Wander.kinds(c).contains { k in
      kinds.contains(k) && (k != .genre || !Wander.genreOptions(c).isEmpty)
    }
  }

  static let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

  /// The incoming key, compatible with the outgoing `key`: when the incoming genre plays the
  /// same scale, its root is pinned (`extra["keyOffset"]`, `TrackSpec.pinnedKeyOffset`, as the
  /// key lock pins it) to the outgoing root or a fifth either way, drawn 2 : 1 : 1. Another scale
  /// keeps `.variety`'s own key (an offset carried from the outgoing spec is dropped). Returns
  /// the key's label when it pinned one.
  static func pinKey(_ spec: inout TrackSpec, to key: WanderKey?, _ rng: inout WanderRandom)
    -> String?
  {
    guard let key, let g = BeatsTables.shared.genres[spec.genre], g.scaleName == key.scale else {
      spec.extra["keyOffset"] = nil
      return nil
    }
    let shift = [0, 0, 7, 5][rng.int(4)]  // same root, same root, a fifth up, a fifth down
    let pc = (key.rootPC + shift) % 12
    var offset = ((pc - g.rootNote % 12) % 12 + 12) % 12
    if offset > 6 { offset -= 12 }
    spec.extra["keyOffset"] = .number(Double(offset))
    return "key \(pitchNames[pc])"
  }
}

/// The mix-out a hand-off prepares at its prep point (live only): handed to the outgoing deck
/// in bar H − 1, when nothing was loaded on it since. One per engine.
final class MixOutAhead: Sendable {
  private struct State {
    var ready: WaveProject?
    var token = 0
  }
  private let state = Mutex(State())

  func request(_ move: Deck.MoveRequest) {
    let token = state.withLock { s -> Int in
      s.token += 1
      s.ready = nil
      return s.token
    }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let p = move.prepare()
      state.withLock { s in if s.token == token { s.ready = p } }
    }
  }

  /// The prepared project, off the slot (nil when it is still preparing or was dropped).
  func take() -> WaveProject? {
    state.withLock { s in
      defer {
        s.ready = nil
        s.token += 1
      }
      return s.ready
    }
  }

  func drop() { _ = take() }
}
