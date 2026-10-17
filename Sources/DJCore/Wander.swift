import Foundation

// Wander: the theme's random walk made autonomous. A net deck with wander on takes one move in
// configuration space per phrase (`WanderState.pace` bars on its own bar clock) until the
// performer grabs the browser wheel. Each move is a pure function of the deck's configuration
// (its `TrackSpec`, roles, locks) and the step index — never the wall clock — so a recorded
// session replays the same walk: the moves are derived, not recorded; only the pokes that set
// wander up (`DeckAction.wander`, `.wanderPace`, `.wanderLock`, the controller's MIDI) are.
//
// The three things a feature names (CLAUDE.md, the theme):
// 1. the poke: wander on/off, its pace, its locks; the browser wheel steers (and pauses it);
// 2. the rule: `Wander.plan` — weighted move kinds, seeded from the spec's share CID + step;
// 3. the boundary: moves are taken on entering the last bar of a phrase, so a macro lands on
//    the phrase end and a swap (a new seed, instrument, structure or genre) lands at the bar
//    after it: the next phrase's first bar, the transport still running.

/// What the walk must not change on a deck (`DeckAction.wanderLock`). Each removes move kinds
/// or constrains them; per-role keeps are `keep:<role>`.
public enum WanderLock {
  /// The dimensions, in the order the UI shows their chips.
  public static let dimensions = [
    "genre", "tempo", "key", "structure", "instruments", "arrangement", "fx", "palette",
  ]
  public static let keepPrefix = "keep:"
  /// How far (either way, as a fraction) a tempo-locked walk may move from the tempo the lock
  /// was set at: a genre hop beyond it is never taken.
  public static let tempoTolerance = 0.06

  /// The lock that keeps `role` ("keep the bass"): its instrument goes with every new seed, and
  /// no move mutes it or picks it another instrument. (Its notes still change with the seed:
  /// beats has no per-part seeds yet.)
  public static func keep(_ role: String) -> String { keepPrefix + role }

  /// The role a `keep:` lock names, nil for any other.
  public static func keptRole(_ dimension: String) -> String? {
    dimension.hasPrefix(keepPrefix) ? String(dimension.dropFirst(keepPrefix.count)) : nil
  }

  public static func isValid(_ dimension: String) -> Bool {
    dimensions.contains(dimension) || !(keptRole(dimension) ?? "").isEmpty
  }

  public static func label(_ dimension: String) -> String {
    if let r = keptRole(dimension) { return "keep \(r)" }
    return dimension.prefix(1).uppercased() + dimension.dropFirst()
  }
}

/// The kinds of move, from the small ones taken most often to the rare big ones.
public enum WanderMoveKind: String, CaseIterable, Sendable {
  /// Mute or unmute one role (never a disabled, kept or locked one).
  case role
  /// A STEMS group (music / mic) off, or back on.
  case stem
  /// A net macro over the phrase's last bar: drop, breakdown, beat repeat, solo drums, double
  /// drop.
  case macro
  /// A master-chain FX macro from the phrase end: a filter sweep, riser, wash, crush.
  case fx
  /// A ring stinger.
  case stinger
  /// The next seed nearby (±1…7): new notes, same genre and structure.
  case seed
  /// A nearby seed with another instrument on one tonal role, arriving with the swap.
  case instrument
  /// The same seed in another structure (songs only).
  case structure
  /// A neighbouring genre (`Wander.neighbours`), a new seed.
  case genre

  /// Out of 100. Tuned for a walk you can follow: about two moves in three change the mix of
  /// the track playing, one in three moves to another track, one in twenty to another genre.
  public var weight: Int {
    switch self {
    case .role: 30
    case .stem: 6
    case .macro: 13
    case .fx: 8
    case .stinger: 5
    case .seed: 20
    case .instrument: 9
    case .structure: 4
    case .genre: 5
    }
  }

  /// Moves that put another track on the deck (swapped in at the next bar).
  public var swaps: Bool { [.seed, .instrument, .structure, .genre].contains(self) }

  /// The lock dimension that removes this kind (nil: none removes it outright).
  var lock: String? {
    switch self {
    case .role, .stem: "arrangement"
    case .macro, .fx, .stinger: "fx"
    case .instrument: "instruments"
    case .structure: "structure"
    case .genre: "genre"
    case .seed: nil
    }
  }
}

/// The key a key-locked walk keeps: the genre's scale and the root pitch class the track played
/// in when the lock was set, and its offset from the genre's root.
public struct WanderKey: Equatable, Sendable {
  public var scale: String
  public var rootPC: Int
  /// Semitones from the genre's root (−5…+6): what the spec pins as `extra["keyOffset"]`
  /// (`TrackSpec.pinnedKeyOffset`), for a key-varying pass to honour.
  public var offset: Int
}

/// One move of the walk: the discovery trail.
public struct WanderMove: Equatable, Sendable {
  public var step: Int
  /// The bar (1-based, on the deck's clock) it was taken in: the last of a phrase.
  public var bar: Int
  public var kind: WanderMoveKind
  /// What it did: "bass off", "drop", "seed 41 → 44", "techno → house · seed 512".
  public var detail: String
  /// The configuration it put on the deck (a swap), or the one it played on (any other move):
  /// what ★ on its row keeps.
  public var spec: TrackSpec?
  /// The share CID of `spec` for a swap (nil for a move that kept the track).
  public var cid: String?

  public var json: JSONValue {
    var o = JSONObject([
      ("step", .int(step)), ("bar", .int(bar)), ("kind", .string(kind.rawValue)),
      ("move", .string(detail)),
    ])
    if let cid { o["cid"] = .string(cid) }
    if let spec {
      o["genre"] = .string(spec.genre)
      o["seed"] = .number(spec.seed)
    }
    return .object(o)
  }
}

/// A deck's walk: on or off, its pace, where it has got to, its locks.
public struct WanderState: Equatable, Sendable {
  public static let paces = [4, 8, 16, 32]
  public static let defaultPace = 16
  /// Moves the log keeps (newest last).
  public static let logLimit = 48

  public var on = false
  /// Bars per move.
  public var pace = WanderState.defaultPace
  /// Moves taken so far on this deck: with the spec, what the next one is drawn from.
  public var step = 0
  public var locks: Set<String> = []
  /// The tempo the tempo lock holds the walk to (set with the lock).
  public var anchorBPM: Double?
  /// The key the key lock holds (set with the lock).
  public var key: WanderKey?
  /// The browser wheel turned on this deck: the walk waits for a quiet phrase.
  public var paused = false
  /// Bars since the wheel last turned, while paused.
  public var quietBars = 0
  public internal(set) var log: [WanderMove] = []
  /// The bar the deck's clock was last seen in (nil: not yet).
  var lastBar: Int?

  public init() {}

  /// The part a session's starting state keeps (no log, no clock reading).
  var settings: WanderState {
    var s = self
    s.log = []
    s.lastBar = nil
    return s
  }

  public var kept: Set<String> { Set(locks.compactMap(WanderLock.keptRole)) }
  public func isLocked(_ dimension: String) -> Bool { locks.contains(dimension) }
}

/// What one tonal (or drum-kit) channel of a deck plays, for the walk: beats' own instrument
/// lists only (`BeatsTables.instrumentSets`), so a pick is the same on every Mac.
struct WanderVoice: Equatable, Sendable {
  var roles: [String]
  var channel: Int
  var instrument: String
  var options: [String]
}

/// Everything a move is chosen from: the deck's configuration and what the user fixed.
struct WanderContext: Sendable {
  var deck: String
  var spec: TrackSpec
  var isLoop: Bool
  var roles: [String]
  var rolesOn: Set<String>
  var disabledRoles: Set<String>
  var stemsMuted: Set<String>
  /// `DJEngine.lockedActions`: a move whose button is locked is not taken.
  var lockedActions: Set<String>
  var locks: Set<String>
  var voices: [WanderVoice]
  var anchorBPM: Double?
  var key: WanderKey?
  /// The sound palette and drum kit the deck plays (`Deck.palette` / `kit`): what the palette
  /// lock carries into every new track.
  var palette: String? = nil
  var kit: String? = nil

  var kept: Set<String> { Set(locks.compactMap(WanderLock.keptRole)) }
  func locked(_ dimension: String) -> Bool { locks.contains(dimension) }
  func locked(_ action: DJActionKind, _ param: String? = nil) -> Bool {
    lockedActions.contains(DJActionKind.lockKey(deck: deck, action, param: param))
  }
  /// Every role the deck has is kept: no move may change the track.
  var keepsEverything: Bool { !roles.isEmpty && roles.allSatisfy(kept.contains) }
}

/// A move as it is applied to the deck.
enum WanderAction: Equatable, Sendable {
  case role(String, on: Bool)
  case stem(String)
  case netMacro(NetMacro)
  case masterMacro(MasterMacro)
  case stinger(Int)
  case swap(TrackSpec)
}

struct WanderPlan: Equatable, Sendable {
  var kind: WanderMoveKind
  var action: WanderAction
  var detail: String
}

/// The deterministic draw: SplitMix64 seeded from the spec's share CID and the step.
struct WanderRandom {
  private var state: UInt64

  init(spec: TrackSpec, step: Int) { self.init(base: Self.base(spec), step: step) }

  init(base: UInt64, step: Int) {
    state = base ^ (UInt64(truncatingIfNeeded: step) &* 0x9E37_79B9_7F4A_7C15)
  }

  /// FNV-1a of the spec's share CID: what every draw on this configuration starts from.
  static func base(_ spec: TrackSpec) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in BeatsCID.shareCID(spec.payload).utf8 {
      h ^= UInt64(b)
      h = h &* 0x100_0000_01b3
    }
    return h
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// 0..<n
  mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }

  mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

public enum Wander {
  static let tonalRoles: Set<String> = ["bass", "melody", "harmony", "arp"]
  static let netMacros: [NetMacro] = [.drop, .breakdown, .beatRepeat, .soloDrums, .doubleDrop]
  static let masterMacros: [MasterMacro] = [
    .sweepLp, .sweepHp, .riser, .reverbWash, .filterRes, .buildCrush,
  ]
  /// The structures a structure move picks from (beats' blueprints).
  static let structures = ["minimal", "standard", "extended", "ab", "drop", "build", "jam"]

  /// The genres a genre move may reach from `genre`: the three nearest in tempo of its family
  /// (beats' `genreFamilies`, which share structure blueprints), then any other genre within
  /// 8 % of its tempo. Sorted, so the walk is the same whatever order the tables load in.
  public static func neighbours(of genre: String) -> [String] {
    let t = BeatsTables.shared
    guard let g = t.genres[genre] else { return [] }
    let family = t.family(of: genre)
    func distance(_ id: String) -> Double { abs(log((t.genres[id]?.bpm ?? 1) / max(g.bpm, 1))) }
    let ids = t.genreIDs.sorted().filter { $0 != genre && t.genres[$0] != nil }
    let near = ids.filter { t.family(of: $0) == family }
      .sorted { (distance($0), $0) < (distance($1), $1) }.prefix(3)
    let far = ids.filter { t.family(of: $0) != family && distance($0) <= log(1.08) }
    return (Array(near) + far).sorted()
  }

  /// A spec's tempo: its `bpm` override, else its genre's.
  public static func bpm(of spec: TrackSpec) -> Double {
    spec.extra["bpm"]?.double ?? BeatsTables.shared.genres[spec.genre]?.bpm ?? 120
  }

  /// The move kinds the locks leave (before the deck's own state rules any out).
  static func kinds(_ c: WanderContext) -> [WanderMoveKind] {
    WanderMoveKind.allCases.filter { k in
      if let l = k.lock, c.locked(l) { return false }
      if k.swaps && c.keepsEverything { return false }
      if c.isLoop && k == .structure { return false }
      return true
    }
  }

  /// A STEMS group the walk muted wants back: its weight goes up until it is.
  static func weight(_ k: WanderMoveKind, _ c: WanderContext) -> Int {
    k == .stem && !c.stemsMuted.isEmpty ? 40 : k.weight
  }

  /// The move for step `step`: a weighted kind, then its parameters, all drawn from the spec and
  /// the step. A kind with nothing it may do here is struck and the draw goes on; nil when no
  /// kind is left (every move locked).
  static func plan(_ c: WanderContext, step: Int) -> WanderPlan? {
    var rng = WanderRandom(spec: c.spec, step: step)
    var kinds = kinds(c)
    while !kinds.isEmpty {
      var r = rng.int(kinds.reduce(0) { $0 + weight($1, c) })
      var k = kinds[0]
      for x in kinds {
        r -= weight(x, c)
        if r < 0 {
          k = x
          break
        }
      }
      if let p = build(k, c, &rng) { return p }
      kinds.removeAll { $0 == k }
    }
    return nil
  }

  /// Can the walk move at all here? (False: every move is locked or impossible.)
  static func canMove(_ c: WanderContext) -> Bool {
    // trying each kind with a throwaway draw tells whether any could be built (a genre move
    // by its options alone: building one composes the new genre when instruments are pinned)
    let base = WanderRandom.base(c.spec)
    return kinds(c).contains { k in
      if k == .genre { return !genreOptions(c).isEmpty }
      var rng = WanderRandom(base: base, step: 0)
      return build(k, c, &rng) != nil
    }
  }

  private static func build(_ k: WanderMoveKind, _ c: WanderContext, _ rng: inout WanderRandom)
    -> WanderPlan?
  {
    switch k {
    case .role:
      let eligible = c.roles.filter {
        !c.disabledRoles.contains($0) && !c.kept.contains($0) && !c.locked(.roleMute, $0)
      }
      let off = eligible.filter { !c.rolesOn.contains($0) }
      let on = eligible.filter { c.rolesOn.contains($0) }
      let audible = c.roles.filter(c.rolesOn.contains).count
      // keep at least two parts playing: when down to two, only bring one back
      let pool = audible <= 2 ? off : off + off + on
      guard !pool.isEmpty else { return nil }
      let r = rng.pick(pool)
      let turnOn = !c.rolesOn.contains(r)
      return WanderPlan(
        kind: .role, action: .role(r, on: turnOn), detail: "\(r) \(turnOn ? "on" : "off")")

    case .stem:
      let stems = Deck.stems.keys.sorted().filter { s in
        let group = Deck.stems[s] ?? []
        let present = c.roles.filter(group.contains)
        return !present.isEmpty && present.allSatisfy { !c.kept.contains($0) }
          && !c.locked(.stemMute, s)
      }
      guard !stems.isEmpty else { return nil }
      if let back = stems.first(where: c.stemsMuted.contains) {
        return WanderPlan(kind: .stem, action: .stem(back), detail: "STEMS \(back) back")
      }
      let s = rng.pick(stems)
      return WanderPlan(kind: .stem, action: .stem(s), detail: "STEMS \(s) off")

    case .macro:
      let ms = netMacros.filter { !c.locked(.macro, $0.id) }
      guard !ms.isEmpty else { return nil }
      let m = rng.pick(ms)
      return WanderPlan(kind: .macro, action: .netMacro(m), detail: m.label.lowercased())

    case .fx:
      let ms = masterMacros.filter { !c.locked(.macro, $0.id) }
      guard !ms.isEmpty else { return nil }
      let m = rng.pick(ms)
      return WanderPlan(kind: .fx, action: .masterMacro(m), detail: m.label.lowercased())

    case .stinger:
      let ns = (0..<4).filter { !c.locked(.stinger, "\($0)") }
      guard !ns.isEmpty else { return nil }
      let n = rng.pick(ns)
      return WanderPlan(kind: .stinger, action: .stinger(n), detail: "hit \(n + 1)")

    case .seed:
      var s = nearbySeed(c, &rng)
      carry(c, &s, sameGenre: true)
      return WanderPlan(
        kind: .seed, action: .swap(s), detail: "seed \(seedText(c.spec.seed)) → \(seedText(s.seed))"
      )

    case .instrument:
      let voices = c.voices.filter { v in
        v.roles.contains(where: tonalRoles.contains) && !v.roles.contains(where: c.kept.contains)
          && v.options.contains { $0 != v.instrument }
      }
      guard !voices.isEmpty else { return nil }
      let v = rng.pick(voices)
      let pick = rng.pick(v.options.filter { $0 != v.instrument })
      var s = nearbySeed(c, &rng)
      carry(c, &s, sameGenre: true)
      setInstrument(&s, pick, channel: v.channel)
      let role = v.roles.first(where: tonalRoles.contains) ?? v.roles[0]
      return WanderPlan(
        kind: .instrument, action: .swap(s),
        detail: "seed \(seedText(s.seed)) · \(role): \(v.instrument) → \(pick)")

    case .structure:
      let options = structures.filter { $0 != (c.spec.structure ?? "") }
      guard !options.isEmpty else { return nil }
      var s = c.spec
      s.structure = rng.pick(options)
      carry(c, &s, sameGenre: true, keepLayers: true)
      return WanderPlan(
        kind: .structure, action: .swap(s),
        detail: "\(c.spec.structure ?? "loop") → \(s.structure ?? "loop")")

    case .genre:
      let options = genreOptions(c)
      guard !options.isEmpty else { return nil }
      let g = rng.pick(options)
      var extra = c.spec.extra
      extra["bpm"] = nil  // the tempo is the genre's
      var s = TrackSpec(
        genre: g, seed: Double(rng.int(999_999) + 1), structure: c.spec.structure,
        cohesion: c.spec.cohesion, extra: extra)
      carry(c, &s, sameGenre: false)
      return WanderPlan(
        kind: .genre, action: .swap(s),
        detail: "\(c.spec.genre) → \(g) · seed \(seedText(s.seed))")
    }
  }

  /// The genres a genre move may take from here, with the locks applied: structure keeps the
  /// family (its blueprints), tempo keeps within `tempoTolerance` of the anchor, key keeps the
  /// scale and the root (the genre's root pitch class, so the key holds with or without a pass
  /// that moves keys per seed).
  static func genreOptions(_ c: WanderContext) -> [String] {
    let t = BeatsTables.shared
    guard let here = t.genres[c.spec.genre] else { return [] }
    let anchor = c.anchorBPM ?? bpm(of: c.spec)
    return neighbours(of: c.spec.genre).filter { id in
      guard let g = t.genres[id] else { return false }
      if c.locked("structure"), t.family(of: id) != t.family(of: c.spec.genre) { return false }
      if c.locked("tempo"), abs(g.bpm / anchor - 1) > WanderLock.tempoTolerance { return false }
      if c.locked("key") {
        let scale = c.key?.scale ?? here.scaleName
        let root = c.key.map { ($0.rootPC - $0.offset + 12) % 12 } ?? here.rootNote % 12
        if g.scaleName != scale || g.rootNote % 12 != root { return false }
      }
      return true
    }
  }

  /// The same song settings a few seeds on or back (±1…7), none of this seed's own overrides.
  private static func nearbySeed(_ c: WanderContext, _ rng: inout WanderRandom) -> TrackSpec {
    let delta = Double(rng.int(7) + 1) * (rng.int(2) == 0 ? 1 : -1)
    var seed = max(1, c.spec.seed + delta)
    if seed == c.spec.seed { seed += 1 }
    return TrackSpec(
      genre: c.spec.genre, seed: seed, structure: c.spec.structure, cohesion: c.spec.cohesion,
      extra: c.spec.extra)
  }

  /// What the locks carry into a new spec: the pinned key, and the instruments the user keeps
  /// (all of them under the instruments lock, else the kept roles'), so they arrive with the
  /// swap. A new genre is composed once to find which channel each kept role plays on there.
  static func carry(
    _ c: WanderContext, _ s: inout TrackSpec, sameGenre: Bool, keepLayers: Bool = false
  ) {
    if !keepLayers { s.layers = JSONObject() }
    if let key = c.key, c.locked("key") { s.extra["keyOffset"] = .number(Double(key.offset)) }
    // the palette lock: the palette and the kit go with every new track, on its own channels
    if c.locked("palette"), c.palette != nil || c.kit != nil {
      let p = TrackSpec(
        genre: s.genre, seed: s.seed, structure: s.structure, cohesion: s.cohesion, extra: s.extra
      ).project()
      var d = DeckSourceDescriptor.net(s)
      if let pal = c.palette { d = d.withPalette(pal, channels: p.channels) ?? d }
      if let kit = c.kit { d = d.withKit(kit, channels: p.drumChannels) ?? d }
      if case .net(let next) = d { s = next }
    }
    let pins = c.voices.filter { v in
      c.locked("instruments") || v.roles.contains(where: c.kept.contains)
    }
    guard !pins.isEmpty else { return }
    let target =
      sameGenre
      ? nil
      : TrackSpec(
        genre: s.genre, seed: s.seed, structure: s.structure, cohesion: s.cohesion, extra: s.extra
      ).project()
    for v in pins {
      let ch: Int? =
        if let target { v.roles.lazy.compactMap { Self.channel(of: $0, in: target) }.first } else {
          v.channel
        }
      if let ch { setInstrument(&s, v.instrument, channel: ch) }
    }
  }

  private static func setInstrument(_ s: inout TrackSpec, _ instrument: String, channel: Int) {
    var all = s.layers["tracks"]?.object ?? JSONObject()
    var entry = all["\(channel)"]?.object ?? JSONObject()
    entry["instrument"] = .string(instrument)
    all["\(channel)"] = .object(entry)
    s.layers["tracks"] = .object(all)
  }

  /// The MIDI channel `role` (a riff group or a lone net's id) plays on in `project`.
  static func channel(of role: String, in project: Project) -> Int? {
    project.nets.keys.sorted().lazy.compactMap { id in project.nets[id].map { (id, $0) } }
      .first { $0.1.role != "control" && ($0.1.riffGroup == role || $0.0 == role) }?.1.track
      .channel
  }

  static func seedText(_ s: Double) -> String {
    s == s.rounded() ? String(Int(s)) : String(s)
  }
}

extension TrackSpec {
  /// A key offset the spec pins (`extra["keyOffset"]`, semitones from the genre's root), set by a
  /// key-locked Wander. A pass that moves each seed to its own key must use this instead of its
  /// seeded pick when it is there (`DJMusicality`'s variety pass: the integrator wires it).
  public var pinnedKeyOffset: Int? { extra["keyOffset"]?.int }
}

// MARK: - the deck

extension Deck {
  /// The tonal (and drum-kit) channels of the net with beats' instrument lists, in role order.
  var wanderVoices: [WanderVoice] {
    guard mode == .net, let project = netProject else { return [] }
    let genre = currentSpec?.genre ?? ""
    let sets = BeatsTables.shared.instrumentSets
    var out: [WanderVoice] = []
    for role in roles {
      guard
        let net = project.nets.keys.sorted().lazy
          .compactMap({ id in project.nets[id].map { (id, $0) } })
          .first(where: { $0.1.role != "control" && ($0.1.riffGroup == role || $0.0 == role) })?.1
      else { continue }
      if let i = out.firstIndex(where: { $0.channel == net.track.channel }) {
        out[i].roles.append(role)
        continue
      }
      var options = sets[genre]?[role] ?? []
      for id in sets.keys.sorted() where id != genre {
        for i in sets[id]?[role] ?? [] where !options.contains(i) { options.append(i) }
      }
      out.append(
        WanderVoice(
          roles: [role], channel: net.track.channel, instrument: net.track.instrument,
          options: options))
    }
    return out
  }

  /// The key the track plays in now: the genre's scale and the played project's root (a pass
  /// that moves keys moves `rootNote`).
  var wanderKey: WanderKey? {
    guard let spec = currentSpec, let g = BeatsTables.shared.genres[spec.genre] else { return nil }
    let root = netProject?.rootNote ?? g.rootNote
    var offset = ((root - g.rootNote) % 12 + 12) % 12
    if offset > 6 { offset -= 12 }
    return WanderKey(
      scale: g.scaleName, rootPC: ((g.rootNote + offset) % 12 + 12) % 12, offset: offset)
  }

  func wanderContext(lockedActions: Set<String>) -> WanderContext? {
    guard mode == .net, let spec = currentSpec else { return nil }
    let rs = roles
    return WanderContext(
      deck: name, spec: spec, isLoop: isNetLoop, roles: rs, rolesOn: Set(rs.filter(isRoleOn)),
      disabledRoles: disabledRoles, stemsMuted: Set(stemsMuted.keys),
      lockedActions: lockedActions, locks: wander.locks, voices: wanderVoices,
      anchorBPM: wander.anchorBPM, key: wander.key, palette: palette, kit: kit)
  }

  /// Wander on or off (`DeckAction.wander`). On, it waits for the next phrase end; the bar it
  /// is in now does not count as a fresh one.
  public func setWander(_ on: Bool) {
    wander.on = on
    wander.paused = false
    wander.quietBars = 0
    wander.lastBar = mode == .net ? wave.tick / 16 : nil
  }

  /// Bars per move (4, 8, 16 or 32; anything else is ignored).
  public func setWanderPace(_ bars: Int) {
    guard WanderState.paces.contains(bars) else { return }
    wander.pace = bars
  }

  /// SHIFT + the browser wheel: one pace longer (clockwise) or shorter per click, stopping at
  /// 4 and 32.
  public func stepWanderPace(_ delta: Int) {
    let paces = WanderState.paces
    let i = paces.firstIndex(of: wander.pace) ?? 2
    wander.pace = paces[min(paces.count - 1, max(0, i + delta.signum()))]
  }

  /// Lock a dimension of the walk, or free it (`DeckAction.wanderLock`). The tempo and key
  /// locks hold the tempo and key the deck plays now.
  public func setWanderLock(_ dimension: String, _ on: Bool) {
    guard WanderLock.isValid(dimension) else { return }
    if on { wander.locks.insert(dimension) } else { wander.locks.remove(dimension) }
    switch dimension {
    case "tempo": wander.anchorBPM = on ? currentSpec.map(Wander.bpm(of:)) : nil
    case "key": wander.key = on ? wanderKey : nil
    default: break
    }
  }

  /// The browser wheel turned on this deck: a wandering deck pauses until a phrase passes with
  /// no turn.
  public func grabWander() {
    guard wander.on else { return }
    wander.paused = true
    wander.quietBars = 0
  }

  /// Bars until the walk's next move (or, paused, until it resumes); nil when it is off, the
  /// deck is not a net, or it cannot move.
  public var wanderCountdown: Int? {
    guard wander.on, mode == .net else { return nil }
    if wander.paused { return max(1, wander.pace - wander.quietBars) }
    let into = (wave.tick / 16) % wander.pace
    let n = wander.pace - 1 - into
    return n == 0 ? wander.pace : n
  }

  /// Why the walk is standing still, if it is: "sample deck", "every move is locked".
  public func wanderIdleReason(lockedActions: Set<String>) -> String? {
    guard wander.on else { return nil }
    guard mode == .net else { return "a sample deck: wander walks live nets" }
    guard let c = wanderContext(lockedActions: lockedActions) else {
      return "nothing composed to walk from"
    }
    return Wander.canMove(c) ? nil : "every move is locked: nothing left to change"
  }

  /// The walk's housekeeping (`DJEngine.serviceWander`, ~100×/s): on each new bar, count a
  /// quiet bar while paused, and on entering the last bar of a phrase take one move. Sample
  /// decks do nothing (see CLAUDE.md, Wander).
  func serviceWander(lockedActions: Set<String>) {
    guard wander.on, mode == .net, playing else { return }
    advanceWander(toBar: wave.tick / 16, lockedActions: lockedActions)
  }

  /// The deck's clock is in bar `bar` (0-based): what `serviceWander` does with a reading.
  func advanceWander(toBar bar: Int, lockedActions: Set<String>) {
    guard wander.on, mode == .net, currentSpec != nil, bar != wander.lastBar else { return }
    wander.lastBar = bar
    if wander.paused {
      wander.quietBars += 1
      if wander.quietBars >= wander.pace {
        wander.paused = false
        wander.quietBars = 0
      }
      return
    }
    guard (bar + 1) % wander.pace == 0 else { return }
    // a tempo or key lock restored at launch (no track then) holds what plays at its first move
    if wander.isLocked("tempo"), wander.anchorBPM == nil {
      wander.anchorBPM = currentSpec.map(Wander.bpm(of:))
    }
    if wander.isLocked("key"), wander.key == nil { wander.key = wanderKey }
    takeWanderMove(bar: bar, lockedActions: lockedActions)
  }

  /// Take the walk's next move now, as if a phrase had just reached its last bar (`bar`).
  @discardableResult
  func takeWanderMove(bar: Int, lockedActions: Set<String>) -> WanderMove? {
    guard let c = wanderContext(lockedActions: lockedActions),
      let plan = Wander.plan(c, step: wander.step)
    else { return nil }
    var move = WanderMove(
      step: wander.step, bar: bar + 1, kind: plan.kind, detail: plan.detail, spec: c.spec,
      cid: nil)
    wander.step += 1
    switch plan.action {
    case .role(let r, let on): setRole(r, on: on)
    case .stem(let s): toggleStem(s)
    case .netMacro(let m): fire(m, duration: 1)  // over the phrase's last bar
    case .masterMacro(let m): fire(m)
    case .stinger(let n): stinger(n)
    case .swap(let spec):
      move.spec = spec
      move.cid = BeatsCID.shareCID(spec.payload)
      // the next phrase's first bar, the transport still running (a loop starts at its top)
      swap(to: spec, start: isNetLoop ? .top : .tick((bar + 1) * 16))
    }
    wander.log.append(move)
    if wander.log.count > WanderState.logLimit {
      wander.log.removeFirst(wander.log.count - WanderState.logLimit)
    }
    return move
  }

  /// The JSON `dj_state` shows for the walk.
  public func wanderJSON(lockedActions: Set<String>) -> JSONValue {
    var o = JSONObject([
      ("on", .bool(wander.on)), ("pace", .int(wander.pace)), ("paused", .bool(wander.paused)),
      ("step", .int(wander.step)),
      ("locks", .array(wander.locks.sorted().map { .string($0) })),
      ("log", .array(wander.log.reversed().prefix(12).map(\.json))),
    ])
    if let n = wanderCountdown { o[wander.paused ? "resumesInBars" : "nextMoveInBars"] = .int(n) }
    if let why = wanderIdleReason(lockedActions: lockedActions) { o["idle"] = .string(why) }
    if let a = wander.anchorBPM { o["tempoAnchor"] = .number(a) }
    return .object(o)
  }
}

extension DJEngine {
  /// Every deck's walk, in name order (the hub and `OfflineConductor` call it after the decks'
  /// own service, so a replay walks the same path at the same frames).
  public func serviceWander() {
    for d in decks.values.sorted(by: { $0.name < $1.name }) {
      d.serviceWander(lockedActions: lockedActions)
    }
  }
}

// MARK: - session encoding

extension WanderKey {
  var json: JSONValue {
    .object(
      JSONObject([
        ("scale", .string(scale)), ("rootPC", .int(rootPC)), ("offset", .int(offset)),
      ]))
  }
  init?(json v: JSONValue?) {
    guard let v, let scale = v["scale"]?.string, let pc = v["rootPC"]?.int else { return nil }
    self.init(scale: scale, rootPC: pc, offset: v["offset"]?.int ?? 0)
  }
}

extension WanderState {
  /// A session's starting wander settings (what the walk continues from).
  var json: JSONValue {
    var o = JSONObject([
      ("on", .bool(on)), ("pace", .int(pace)), ("step", .int(step)),
      ("locks", .array(locks.sorted().map { .string($0) })),
    ])
    if let anchorBPM { o["anchorBPM"] = .number(anchorBPM) }
    if let key { o["key"] = key.json }
    if paused {
      o["paused"] = .bool(true)
      o["quietBars"] = .int(quietBars)
    }
    return .object(o)
  }

  init(json v: JSONValue) {
    self.init()
    on = v["on"]?.bool ?? false
    pace = v["pace"]?.int.flatMap { Self.paces.contains($0) ? $0 : nil } ?? Self.defaultPace
    step = v["step"]?.int ?? 0
    locks = Set((v["locks"]?.array ?? []).compactMap(\.string).filter(WanderLock.isValid))
    anchorBPM = v["anchorBPM"]?.double
    key = WanderKey(json: v["key"])
    paused = v["paused"]?.bool ?? false
    quietBars = v["quietBars"]?.int ?? 0
  }
}
