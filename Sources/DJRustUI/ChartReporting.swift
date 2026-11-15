import Foundation

// "Count my plays toward the charts": the app's half of the track charts (bitwrap storage,
// schema bitwrap-chart-signal.v1), from djandroid charts/ChartReporting.kt. The charts rank
// tracks, never people.
//
// OFF BY DEFAULT. That is the contract the charts service advertises (`/v1/charts` reporting:
// default off, opt-in), and only the app can keep it: the service cannot see this switch.
// Nothing below runs while it is off, not even in memory.
//
// While it is on, a play counts once a track has been heard for `PlayCounter.heardMs` (30 s, the
// schema's rule), once per track per UTC day. What the counter remembers is held in memory only
// and dropped when the switch goes off or the app stops: no listening history is written to this
// device.

/// One counted play: what a report would be about. Not stored anywhere.
public struct Play: Equatable, Sendable {
  public var deck: String
  /// The track as the engine names it: genre, seed and structure.
  public var genre: String
  public var seed: Int64
  public var structure: String?
  public var title: String?
  /// The UTC day (unix seconds / 86400) the play counted on: the charts' window.
  public var day: Int64

  public init(deck: String, genre: String, seed: Int64, structure: String?, title: String?, day: Int64) {
    self.deck = deck
    self.genre = genre
    self.seed = seed
    self.structure = structure
    self.title = title
    self.day = day
  }
}

/// Where a counted play goes. Sending is not built yet (on Android either): it needs the network
/// build, the charts service's address, and signatures that don't prompt on every play (the
/// wallet). Until then every build uses `NotSent`.
public protocol PlaySink: Sendable {
  func play(_ p: Play)
}

/// The sink in every build today: the play is dropped on the spot.
public struct NotSent: PlaySink {
  public init() {}
  public func play(_ p: Play) {}
}

/// Decides when a deck's track has been heard long enough to count, from the deck states the
/// screen already polls. Pure: no clock of its own, so it is unit-tested (Kotlin's
/// PlayCounterTest, same numbers).
public final class PlayCounter {
  /// A play counts after 30 s of playback (bitwrap-chart-signal.v1).
  public static let heardMs: Int64 = 30_000
  /// Longer than any poll interval; a stalled poll does not count as listening.
  public static let maxStepMs: Int64 = 1_000
  public static let dayMs: Int64 = 86_400_000

  private final class Listening {
    let key: String
    var heardMs: Int64 = 0
    var lastAt: Int64?
    init(_ key: String) { self.key = key }
  }

  private let need: Int64
  private var decks: [String: Listening] = [:]
  /// Tracks already counted, per UTC day: day → keys. Only today's survives a day change.
  private var counted: [Int64: Set<String>] = [:]

  public init(heardMs: Int64 = PlayCounter.heardMs) { need = heardMs }

  /// One look at `deck`: `key` is the track loaded (nil: none), `heard` whether it is playing
  /// and audible right now. Returns the play the moment it counts, else nil.
  public func observe(_ deck: String, _ key: String?, heard: Bool, nowMs: Int64) -> String? {
    guard let key else {
      decks[deck] = nil
      return nil
    }
    let l: Listening
    if let have = decks[deck], have.key == key { l = have } else {
      l = Listening(key)
      decks[deck] = l
    }
    // time counts between two looks that were both heard; a gap (paused, faded out) adds nothing
    if heard, let last = l.lastAt { l.heardMs += min(max(nowMs - last, 0), Self.maxStepMs) }
    l.lastAt = heard ? nowMs : nil
    guard l.heardMs >= need else { return nil }
    let day = Self.floorDiv(nowMs, Self.dayMs)
    counted = counted.filter { $0.key == day }
    guard counted[day, default: []].insert(key).inserted else { return nil }
    return key
  }

  public func clear() {
    decks = [:]
    counted = [:]
  }

  static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }
}

/// The switch's counter (the switch itself is `RustDJModel.chartsOn`, kept as `charts_on`).
public final class ChartReporting: @unchecked Sendable {
  private let lock = NSLock()
  private let counter = PlayCounter()
  private let sink: PlaySink

  private var isOn = false

  public init(sink: PlaySink = NotSent()) { self.sink = sink }

  /// The switch, mirrored here for the poll's thread. Off: the counter forgets everything.
  public var on: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return isOn
    }
    set {
      lock.lock()
      isOn = newValue
      if !newValue { counter.clear() }
      lock.unlock()
    }
  }

  /// Called by the deck poll; does nothing while the switch is off. `heard`: the deck is playing and can be
  /// heard (its volume up, the crossfader not all the way to the other deck).
  public func observe(
    _ deck: String, genre: String?, seed: Int64?, structure: String?, title: String?, heard: Bool, nowMs: Int64
  ) {
    let key = genre.flatMap { g in seed.map { "\(g):\($0):\(structure ?? "loop")" } }
    lock.lock()
    // off: nothing runs, not even in memory
    let got = isOn ? counter.observe(deck, key, heard: heard, nowMs: nowMs) : nil
    lock.unlock()
    guard got != nil, let genre, let seed else { return }
    sink.play(
      Play(
        deck: deck, genre: genre, seed: seed, structure: structure, title: title,
        day: PlayCounter.floorDiv(nowMs, PlayCounter.dayMs)))
  }

  /// Whether `deck` can be heard: playing, volume up, the crossfader not all the way over.
  public static func heard(_ deck: String, playing: Bool, volume: Double, crossfader: Double?) -> Bool {
    guard playing, volume > 0 else { return false }
    let cf = crossfader ?? 0
    return deck == "A" ? cf < 1 : cf > 0
  }
}
