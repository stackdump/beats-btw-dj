import Foundation

// A DJ set written down rather than performed: tracks alternate decks A / B / A / B, each plays
// its whole song, and each next one comes in on a bar of the one playing — load (from the
// third track on), sync to the bar, play, a linear crossfader ramp, stop the outgoing deck.
// The result is an ordinary `Session` (the same envelope `SessionRecorder` writes), so it is
// stored, exported and published like a recorded set, and `SessionPlayer` renders it.

public enum SessionMixError: Error, Equatable, CustomStringConvertible {
  case tooFewTracks
  case unknownGenre(String)
  /// A song without sections (a loop) has no end to mix out of.
  case endless(String)
  /// The track is too short for the crossfade (it must outlast it into the next, and a deck
  /// must be free again before its next track loads).
  case tooShort(String, seconds: Double)

  public var description: String {
    switch self {
    case .tooFewTracks: return "a mix needs at least two tracks"
    case .unknownGenre(let g): return "unknown genre \(g)"
    case .endless(let t): return "\(t) is an endless loop (give it a structure)"
    case .tooShort(let t, let s):
      return "\(t) is too short (\(String(format: "%.1f", s)) s) for this crossfade"
    }
  }
}

public struct SessionMix {
  /// One track of the set, as it plays (synced to the track before it).
  public struct Track: Equatable, Sendable {
    public var spec: TrackSpec
    public var title: String
    public var deck: String
    /// The song's own tempo, and what it plays at once synced.
    public var bpm: Double
    public var playedBPM: Double
    /// Sixteenth steps in the song.
    public var steps: Int
    /// Frame its deck starts playing, and frame its deck is stopped (the end of the
    /// crossfade out, or the song's end for the last track).
    public var inFrame: Int
    public var outFrame: Int
    /// Length of the song at `playedBPM`.
    public var seconds: Double { Double(steps) * 15 / playedBPM }
  }

  public let session: Session
  public let tracks: [Track]

  public static let decks = ["A", "B"]
  /// Inputs land on engine blocks; events are stamped on block boundaries (live blocks are
  /// 512 frames; the offline conductor steps 128).
  static let grain = 512
  /// Crossfader resolution: a step every quarter second.
  public static let rampStep = 0.25

  /// Plan the set. `xfade` is the crossfade length in seconds; the next track starts on the
  /// outgoing one's bar nearest `xfade` before its end.
  public init(
    _ specs: [TrackSpec], xfade: Double = 20, sampleRate: Double = 44_100
  ) throws {
    guard specs.count >= 2 else { throw SessionMixError.tooFewTracks }
    let sr = sampleRate
    func frame(_ seconds: Double) -> Int {
      Int((seconds * sr / Double(Self.grain)).rounded()) * Self.grain
    }

    var tracks: [Track] = []
    var events: [SessionEvent] = []
    func act(_ f: Int, _ a: DeckAction) { events.append(SessionEvent(frame: f, kind: .action(a))) }

    for (i, spec) in specs.enumerated() {
      guard BeatsTables.shared.genres[spec.genre] != nil else {
        throw SessionMixError.unknownGenre(spec.genre)
      }
      // What a deck would show for it: the composed project's name, tempo and song length.
      let project = spec.project()
      let steps = Deck.SectionInfo.sections(of: project).map(\.steps).reduce(0, +)
      guard steps > 0 else { throw SessionMixError.endless(project.name) }
      let bpm = project.tempo > 0 ? project.tempo : 120
      let deck = Self.decks[i % 2]
      guard let prev = tracks.last else {
        tracks.append(
          Track(
            spec: spec, title: project.name, deck: deck, bpm: bpm, playedBPM: bpm, steps: steps,
            inFrame: 0, outFrame: 0))
        act(0, .play(deck: deck, on: true))
        continue
      }
      // `sync` to the deck playing: its tempo rule, so the song's length is what it plays.
      let played = bpm * Deck.tempoMatch(base: bpm, target: prev.playedBPM).ratio
      // Come in on the outgoing track's bar nearest `xfade` before its end, so the bar sync
      // barely moves the incoming one.
      let bar = 240 / prev.playedBPM
      let start = Double(prev.inFrame) / sr
      let bars = ((prev.seconds - xfade) / bar).rounded()
      guard bars >= 1 else { throw SessionMixError.tooShort(prev.title, seconds: prev.seconds) }
      let syncFrame = frame(start + bars * bar)
      let playFrame = syncFrame + Self.grain
      let rampEnd = playFrame + frame(xfade)
      if i >= 2 {
        // The deck's previous track must be stopped (and swapped out) before this one loads.
        let freed = tracks[i - 2].outFrame
        let loadFrame = syncFrame - frame(1)
        guard loadFrame > freed else {
          throw SessionMixError.tooShort(prev.title, seconds: prev.seconds)
        }
        act(loadFrame, .load(deck: deck, source: .net(spec)))
      }
      act(syncFrame, .sync(deck: deck, align: "bar"))
      act(playFrame, .play(deck: deck, on: true))
      // Linear ramp toward the incoming deck: A is crossfader 0, B is 1.
      let n = max(1, Int((xfade / Self.rampStep).rounded()))
      for k in 1...n {
        let x = Double(k) / Double(n)
        let v = ((deck == "B" ? x : 1 - x) * 10_000).rounded() / 10_000
        act(playFrame + frame(xfade * x), .crossfader(v))
      }
      tracks[i - 1].outFrame = rampEnd + Self.grain
      act(rampEnd + Self.grain, .play(deck: prev.deck, on: false))
      tracks.append(
        Track(
          spec: spec, title: project.name, deck: deck, bpm: bpm, playedBPM: played,
          steps: steps, inFrame: playFrame, outFrame: 0))
    }
    // The last track plays to its end; a second of tail after it.
    let last = tracks.count - 1
    let end = tracks[last].inFrame + frame(tracks[last].seconds)
    tracks[last].outFrame = end
    act(end, .play(deck: tracks[last].deck, on: false))
    // (Built in frame order: each transition starts after the one before it has stopped.)

    // The decks start as a recording would find them: first two tracks loaded, at rest, with
    // default knobs; the crossfader full on A; the engine's default master (a Float volume).
    session = Session(
      sampleRate: sr, frames: end + frame(1),
      decks: ["A": .net(specs[0]), "B": .net(specs[1])],
      params: ["A": DeckParams(), "B": DeckParams()], crossfader: 0,
      master: Double(Float(0.8)), events: events)
    self.tracks = tracks
  }

  /// "<first> into <last>" — the auto title for publishing.
  public var title: String {
    "\(tracks.first!.title) into \(tracks.last!.title)"
  }
}
