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

  public init(
    genre: String, seed: Double, structure: String? = nil, cohesion: String = "v2",
    extra: JSONObject = JSONObject()
  ) {
    self.genre = genre
    self.seed = seed
    self.structure = structure
    self.cohesion = cohesion
    self.extra = extra
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
  public init?(share: Share) {
    guard share.nets == nil, let genre = share.genre else { return nil }
    var extra = share.params
    let seed = extra["seed"]?.double ?? 0
    let structure = extra["structure"]?.string
    let cohesion = extra["cohesion"]?.string ?? "v1"
    extra["seed"] = nil
    extra["structure"] = nil
    extra["cohesion"] = nil
    self.init(genre: genre, seed: seed, structure: structure, cohesion: cohesion, extra: extra)
  }
}

/// A track composed and compiled off the audio thread, ready to hand to a deck.
public final class PreparedTrack: @unchecked Sendable {
  public let spec: TrackSpec
  public let project: Project
  public let prepared: WaveProject

  public init(spec: TrackSpec, sampleRate: Double) {
    self.spec = spec
    project = compose(genre: spec.genre, overrides: spec.overrides)
    prepared = WaveRunner.prepare(project, sampleRate: sampleRate)
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
  func request(_ spec: TrackSpec, sampleRate: Double) {
    let token = state.withLock { s -> Int in
      s.token += 1
      s.ready = nil
      s.inFlight = spec
      return s.token
    }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let track = PreparedTrack(spec: spec, sampleRate: sampleRate)
      state.withLock { s in
        guard s.token == token else { return }  // superseded or cancelled
        s.ready = track
        s.inFlight = nil
      }
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
    let track = await Task.detached(priority: .userInitiated) {
      PreparedTrack(spec: spec, sampleRate: sr)
    }.value
    guard mine == generation else { return false }
    loadNet(track)
    return true
  }

  /// Load a track composed elsewhere.
  @MainActor
  public func loadNet(_ track: PreparedTrack) {
    currentSpec = track.spec
    loadNet(track.prepared, project: track.project)
  }

  /// Start composing the next track in the background (cancels an earlier request).
  public func queueNext(_ spec: TrackSpec) { next.request(spec, sampleRate: wave.sampleRate) }

  public var nextReady: TrackSpec? { next.readySpec }
  public var nextComposing: TrackSpec? { next.pendingSpec }
  public func cancelNext() { next.cancel() }

  /// Move the pre-composed track onto the deck. False if none is ready yet.
  @MainActor @discardableResult
  public func advanceToNext() -> Bool {
    guard let track = next.take() else { return false }
    loadNet(track)
    return true
  }

  /// Housekeeping for the main thread (the hub calls it ~100×/s): free what the audio
  /// thread let go of, notice a song that ended, and keep the next track coming.
  @MainActor
  public func service() {
    wave.drainRetired()
    guard mode == .net else { return }
    if playing && !wave.isPlaying && wave.hasEnded {
      playing = false
      if autoAdvance, advanceToNext() { setPlaying(true) }
    }
    if let provider = nextProvider, !next.isBusy { queueNext(provider()) }
  }
}
