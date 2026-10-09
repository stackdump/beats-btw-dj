import Observation

/// Where a scope's data comes from.
public enum ScopeSource: Hashable, Sendable {
  case deck(String)
  case master

  public var title: String {
    switch self {
    case .deck(let n): "Deck \(n)"
    case .master: "Master"
    }
  }

  /// The key `ScopeFeed.feeds(for:)` uses.
  public var key: String {
    switch self {
    case .deck(let n): n
    case .master: "master"
    }
  }
}

/// Everything a scope view needs from one source, in one object: the audio tap's reader
/// (blocks, raw samples, FFT), the net's firing events, the auto-gain, and the current
/// marking. Main thread only.
///
/// Nothing here is re-derived: audio is the engine's own tap, events are pushed by the
/// executor as it fires, the marking is `Deck.netSnapshot`. Views redraw when `revision`
/// changes (one bump per `update`).
@Observable
public final class ScopeFeed {
  /// scope.js `EV_CAP`: the newest events kept for drawing.
  public static let eventCapacity = 4096

  public let source: ScopeSource
  public var mode: ScopeMode = .scope
  public var overlays: ScopeOverlays = .stageDefault
  public var background: ScopeBackground = .void

  /// Bumped by every `update`; read it in a view body to redraw.
  public private(set) var revision = 0

  @ObservationIgnored public let reader: TapReader
  @ObservationIgnored public private(set) var gain = AutoGain()
  /// Fired transitions, oldest first, at most `eventCapacity`. Always empty for the master.
  @ObservationIgnored public private(set) var events: [FireEvent] = []
  @ObservationIgnored private let deck: Deck?

  public init(source: ScopeSource, tap: AudioTap, sampleRate: Double, deck: Deck? = nil) {
    self.source = source
    self.deck = deck
    reader = TapReader(tap: tap, sampleRate: sampleRate)
  }

  /// One feed per deck ("A", "B", …) and one for "master".
  public static func feeds(for engine: DJEngine) -> [String: ScopeFeed] {
    var out: [String: ScopeFeed] = [:]
    for (name, d) in engine.decks {
      out[name] = ScopeFeed(
        source: .deck(name), tap: d.tap, sampleRate: engine.sampleRate, deck: d)
    }
    out["master"] = ScopeFeed(source: .master, tap: engine.masterTap, sampleRate: engine.sampleRate)
    return out
  }

  /// Drain the tap and the event ring and step the auto-gain. `now` is wall-clock
  /// seconds (any monotonic clock): it only sets the spring's `dt`.
  public func update(now: Double) {
    reader.update()
    if reader.lastPeak > 0 { gain.observe(peak: Double(reader.lastPeak)) }
    gain.advance(now: now)
    if let ring = deck?.wave.events.ring {
      while let e = ring.pop() { events.append(e) }
      if events.count > Self.eventCapacity {
        events.removeFirst(events.count - Self.eventCapacity)
      }
    }
    revision &+= 1
  }

  /// The current marking, for net decks (nil for samples and the master).
  public var snapshot: NetSnapshot? { deck?.netSnapshot }

  /// The net id an event refers to, resolved against the deck's current project.
  public func netId(of e: FireEvent) -> String? {
    guard let g = deck?.wave.latest?.graph, Int(e.net) < g.nets.count else { return nil }
    return g.nets[Int(e.net)].id
  }

  /// Events that fired within the last `seconds` of engine time, newest last.
  public func events(lastSeconds seconds: Double) -> ArraySlice<FireEvent> {
    let cutoff = reader.tap.framesWritten - Int(seconds * reader.sampleRate)
    let i = events.firstIndex { $0.frame >= cutoff } ?? events.endIndex
    return events[i...]
  }
}
