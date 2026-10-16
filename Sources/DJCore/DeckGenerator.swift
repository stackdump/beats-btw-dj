import Foundation
import Synchronization

/// What to compose: the same inputs a beats share envelope carries.
public struct TrackSpec: Sendable, Equatable {
  public var genre: String
  public var seed: Double
  /// "minimal" | "standard" | "extended" | … ; nil = an endless loop. (Not the string
  /// "loop": compose treats any non-empty structure as song mode, and an envelope that
  /// literally says "loop" gets the fallback blueprint — that must round-trip.)
  public var structure: String?
  /// "v1" | "v2".
  public var cohesion: String
  /// Extra `compose` overrides (traits, bpm, …), merged under the fields above.
  public var extra: JSONObject
  /// Share-envelope fields beyond the compose params, under their envelope names
  /// (`TrackSpec.layerKeys`): the overrides (`tracks`, `initialMutes`, `fx`, …) and the arrange
  /// overlay directives (`fadeIn`, `drumBreak`, `feelCurve`, `counterMelody`). Applied to the
  /// composed project by `finish` — the same `Share` code the envelope path uses — so a deck
  /// plays, and a recorded session replays, the project the envelope describes. Empty for a
  /// plain genre + seed spec.
  public var layers: JSONObject

  /// The envelope fields `layers` holds: what `shareFromPayload` puts in `overrides`, and
  /// the overlay directives. (`macroCurve` is a compose param, in `extra`.)
  public static let layerKeys: Set<String> = [
    "tracks", "fx", "feel", "autoDj", "macrosDisabled", "initialMutes", "tempo", "swing",
    "humanize", "note", "fadeIn", "drumBreak", "feelCurve", "counterMelody",
  ]

  public init(
    genre: String, seed: Double, structure: String? = nil, cohesion: String = "v2",
    extra: JSONObject = JSONObject(), layers: JSONObject = JSONObject()
  ) {
    self.genre = genre
    self.seed = seed
    self.structure = structure
    self.cohesion = cohesion
    self.extra = extra
    self.layers = layers
  }

  /// `compose`'s overrides for this spec.
  var overrides: JSONValue {
    var o = extra
    o["seed"] = .number(seed)
    o["cohesion"] = .string(cohesion)
    if let s = structure, !s.isEmpty { o["structure"] = .string(s) }
    return .object(o)
  }

  /// The spec a share envelope describes (nil for raw-`nets` envelopes and genre-less ones).
  /// Keeps the envelope's overrides and overlay directives in `layers`.
  public init?(share: Share) {
    guard share.nets == nil, let genre = share.genre else { return nil }
    var extra = share.params
    let seed = extra["seed"]?.double ?? 0
    let structure = extra["structure"]?.string
    let cohesion = extra["cohesion"]?.string ?? "v1"
    extra["seed"] = nil
    extra["structure"] = nil
    extra["cohesion"] = nil
    // `shareFromPayload` copied these from the payload as they were, so writing them back
    // under the same names gives an envelope that reads back to the same overrides / overlay.
    var layers = share.overrides ?? JSONObject()
    if let v = share.fadeIn { layers["fadeIn"] = .array(v) }
    if let v = share.drumBreak { layers["drumBreak"] = .number(v) }
    if let v = share.feelCurve { layers["feelCurve"] = .array(v) }
    if let v = share.counterMelody { layers["counterMelody"] = .array(v) }
    self.init(
      genre: genre, seed: seed, structure: structure, cohesion: cohesion, extra: extra,
      layers: layers)
  }

  /// The browser's layers on a composed project: the model-level overrides, then the arrange
  /// overlay (`Share.finishComposed`). A no-op without `layers`.
  public func finish(_ project: inout Project) {
    guard !layers.entries.isEmpty else { return }
    var p = layers
    p["genre"] = .string(genre)
    Share(payload: .object(p)).finishComposed(&project)
  }

  /// `compose` plus `finish`: the project this spec plays.
  public func project() -> Project {
    var p = compose(genre: genre, overrides: overrides)
    finish(&p)
    return p
  }
}

/// A track composed (or, for a raw-`nets` share, built) and compiled off the audio thread,
/// ready to hand to a deck.
public final class PreparedTrack: @unchecked Sendable {
  /// What a session names it by: `.net(spec)` or `.rawNets(payload:)`.
  public let source: DeckSourceDescriptor
  public let project: Project
  /// What the deck plays: `project` after dj's musicality fixes (`DJMusicality`, as
  /// `opts.musicality` asks), or `project` itself for a raw-`nets` share or without fixes.
  public let played: Project
  public let prepared: WaveProject

  /// The composed track's spec; nil for a raw-`nets` share.
  public var spec: TrackSpec? {
    if case .net(let s) = source { return s }
    return nil
  }

  /// `opts`: the deck's (`Deck.waveOptions`), so its sampled instruments load into that
  /// deck's bank. `.extended` alone plays every instrument on a synth voice.
  public convenience init(spec: TrackSpec, sampleRate: Double, opts: WaveOptions = .extended) {
    self.init(
      source: .net(spec), project: spec.project(), seed: spec.seed, sampleRate: sampleRate,
      opts: opts)
  }

  /// A raw-`nets` share envelope's project (`Share.rawNetsProject()`, named by the payload's
  /// share CID as a link to it would be). The payload is read in canonical key order, the
  /// order a share link's payload decodes in (the URL carries canonical JSON), so a payload
  /// handed over in any order — or replayed from a session's canonical text — builds the
  /// same project. nil when the payload has no `nets`.
  public convenience init?(rawNets payload: JSONValue, sampleRate: Double, opts: WaveOptions) {
    let canonical = payload.canonicalJS
    let ordered = (try? JSONValue.parse(canonical)) ?? payload
    let share = Share(payload: ordered, cid: BeatsCID.shareCID(canonical: canonical))
    guard let project = share.rawNetsProject() else { return nil }
    self.init(
      source: .rawNets(payload: payload), project: project,
      seed: DeckSourceDescriptor.voicingSeed(rawNets: payload), sampleRate: sampleRate, opts: opts)
  }

  /// Either kind of net source; nil for `.none` / `.sample` (or nets-less payloads).
  public convenience init?(source: DeckSourceDescriptor, sampleRate: Double, opts: WaveOptions) {
    switch source {
    case .net(let spec): self.init(spec: spec, sampleRate: sampleRate, opts: opts)
    case .rawNets(let payload): self.init(rawNets: payload, sampleRate: sampleRate, opts: opts)
    case .none, .sample: return nil
    }
  }

  private init(
    source: DeckSourceDescriptor, project: Project, seed: Double, sampleRate: Double,
    opts: WaveOptions
  ) {
    self.source = source
    self.project = project
    if case .net(let spec) = source, !opts.musicality.isEmpty {
      played = DJMusicality.apply(project, spec: spec, fixes: opts.musicality)
    } else {
      played = project
    }
    var o = opts
    o.voicingSeed = seed
    if case .net(let spec) = source { o = o.forGenre(spec.genre) }
    prepared = WaveRunner.prepare(played, sampleRate: sampleRate, opts: o)
  }
}

extension WaveOptions {
  /// These options with the settings a track of `genre` plays with, for the fixes they hold:
  /// the duck depth, the room, the echo.
  public func forGenre(_ genre: String) -> WaveOptions {
    var o = self
    if musicality.contains(.duck) { o.duckDepth = DJMusicality.duckDepth(genre: genre) }
    if musicality.contains(.space) { o.space = SpaceSpec.forGenre(genre) }
    if musicality.contains(.echo) { o.echo = EchoSpec.forGenre(genre) }
    return o
  }
}

/// Holds the next track for a deck: composing in the background, then ready.
final class NextTrackSlot: Sendable {
  private struct State {
    var ready: PreparedTrack?
    var inFlight: TrackSpec?
    var token = 0
  }
  private let state = Mutex(State())

  var readySpec: TrackSpec? { state.withLock { $0.ready?.spec } }
  var pendingSpec: TrackSpec? { state.withLock { $0.inFlight } }
  var isBusy: Bool { state.withLock { $0.ready != nil || $0.inFlight != nil } }

  /// Begin a background compose; a newer request supersedes an older one.
  func request(
    _ spec: TrackSpec, sampleRate: Double, samplers: SamplerBank?, roleFilter: RoleFilter?
  ) {
    let token = state.withLock { s -> Int in
      s.token += 1
      s.ready = nil
      s.inFlight = spec
      return s.token
    }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let track = PreparedTrack(
        spec: spec, sampleRate: sampleRate,
        opts: .extended(samplers: samplers, roleFilter: roleFilter))
      state.withLock { s in
        guard s.token == token else { return }  // superseded or cancelled
        s.ready = track
        s.inFlight = nil
      }
    }
  }

  /// Compose on the calling thread (replay mode).
  func requestSync(
    _ spec: TrackSpec, sampleRate: Double, samplers: SamplerBank?, roleFilter: RoleFilter?
  ) {
    let track = PreparedTrack(
      spec: spec, sampleRate: sampleRate,
      opts: .extended(samplers: samplers, roleFilter: roleFilter))
    state.withLock { s in
      s.token += 1
      s.ready = track
      s.inFlight = nil
    }
  }

  func take() -> PreparedTrack? {
    state.withLock { s in
      defer { s.ready = nil }
      return s.ready
    }
  }

  func cancel() {
    state.withLock { s in
      s.token += 1
      s.ready = nil
      s.inFlight = nil
    }
  }
}

extension Deck {
  /// Compose `spec` on a background thread, then load it (at the next bar if the deck is
  /// playing). Returns false if a newer `generate` superseded this one meanwhile.
  @MainActor @discardableResult
  public func generate(_ spec: TrackSpec) async -> Bool {
    generation += 1
    let mine = generation
    let sr = wave.sampleRate
    let bank = wave.samplers
    let filter = roleFilter
    let track = await Task.detached(priority: .userInitiated) {
      PreparedTrack(
        spec: spec, sampleRate: sr, opts: .extended(samplers: bank, roleFilter: filter))
    }.value
    guard mine == generation else { return false }
    loadNet(track)
    return true
  }

  /// Load a track composed elsewhere.
  public func loadNet(_ track: PreparedTrack) {
    loadNet(track.prepared, project: track.played)
    currentSpec = track.spec
    if case .rawNets(let payload) = track.source { currentRawNets = payload }
  }

  /// A composed net loop (a spec with no structure: it plays until stopped).
  public var isNetLoop: Bool {
    guard mode == .net, let spec = currentSpec else { return false }
    return spec.structure?.isEmpty ?? true
  }

  /// The browser wheel on a playing loop: the same genre, `delta` seeds on, composed in the
  /// background and swapped in at the next bar (inline in `deterministic` replay). Clicks that
  /// land while one composes count from the seed it is heading to; the latest wins. Nil (and
  /// nothing happens) unless the deck holds a composed loop.
  @discardableResult
  public func stepSeed(_ delta: Int) -> TrackSpec? {
    guard delta != 0, isNetLoop, var spec = seedTarget ?? currentSpec else { return nil }
    spec.seed += Double(delta)
    if deterministic {
      loadNet(PreparedTrack(spec: spec, sampleRate: wave.sampleRate, opts: waveOptions))
    } else {
      seedTarget = spec
      Task { @MainActor in await self.generate(spec) }
    }
    return spec
  }

  /// Start composing the next track in the background (cancels an earlier request).
  public func queueNext(_ spec: TrackSpec) {
    if deterministic {
      next.requestSync(
        spec, sampleRate: wave.sampleRate, samplers: wave.samplers, roleFilter: roleFilter)
    } else {
      next.request(
        spec, sampleRate: wave.sampleRate, samplers: wave.samplers, roleFilter: roleFilter)
    }
  }

  public var nextReady: TrackSpec? { next.readySpec }
  public var nextComposing: TrackSpec? { next.pendingSpec }
  public func cancelNext() { next.cancel() }

  /// Move the pre-composed track onto the deck. False if none is ready yet.
  @discardableResult
  public func advanceToNext() -> Bool {
    guard let track = next.take() else { return false }
    loadNet(track)
    advances += 1
    return true
  }

  /// Housekeeping for the main thread (the hub calls it ~100×/s): free what the audio
  /// thread let go of, notice a song that ended, and keep the next track coming.
  public func service() {
    wave.drainRetired()
    if let leader, let target = leader.effectiveBPM, let base = baseBPM {
      // Follow tempo changes of the deck we are locked to (same multiplier rule as sync).
      let p = (Self.tempoMatch(base: base, target: target).ratio - 1) / Self.pitchRange
      if abs(p - pitch) > 1e-6 { pitch = p }
    }
    guard mode == .net else { return }
    if playing && !wave.isPlaying && wave.hasEnded {
      playing = false
      if autoAdvance, advanceToNext() { setPlaying(true) }
    }
    if let provider = nextProvider, !next.isBusy { queueNext(provider()) }
  }
}
