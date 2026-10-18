import Foundation

/// When which lanes of a net deck rest: the runner's arrangement gestures (the drop gap, and
/// 6.2's layer budget, band stop and kick out), built at prepare and read on the audio thread.
/// A lane rests while a step's `classMask` shares a bit with its `RestSchedule.Class`; its
/// nets keep running, only its hits are dropped.
///
/// `entries` are disjoint and ascending (`build` merges overlapping gestures into one mask per
/// stretch), so the runner reads them with a cursor that only moves forward between jumps
/// (`Cursor`): no search, no allocation.
public struct RestSchedule: Equatable, Sendable {
  /// What a lane is, for resting: one bit per kind. A lane is one class (or none: crashes,
  /// stingers, overrides and the live keys never rest; a fill chain's drums are `.fill`, which
  /// only `.bandStop` rests).
  public struct Class: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// The kick drum.
    public static let kick = Class(rawValue: 1 << 0)
    /// Every other drum of a net's own kit (snare, hats, open hat, toms…), not fills or crashes.
    public static let drums = Class(rawValue: 1 << 1)
    /// Tonal lanes by part (`Track.group`, else the net's `riffGroup`).
    public static let bass = Class(rawValue: 1 << 2)
    public static let harmony = Class(rawValue: 1 << 3)
    public static let melody = Class(rawValue: 1 << 4)
    public static let arp = Class(rawValue: 1 << 5)
    /// Any other tonal part.
    public static let tonal = Class(rawValue: 1 << 6)
    /// The drums of a fill chain (`fill-N`: fills, buildup hits), not its crashes.
    public static let fill = Class(rawValue: 1 << 7)

    /// The rhythm section `.dropGap` stops: kick, drums, bass.
    public static let rhythm: Class = [.kick, .drums, .bass]
    public static let melodic: Class = [.harmony, .melody, .arp, .tonal]

    /// The class of a lane: `kind` is its drum kind or "tonal", `group` its part, `net` the net.
    public static func of(kind: String, group: String, net: String) -> Class {
      if kind == "tonal" {
        switch group {
        case "bass": return .bass
        case "harmony": return .harmony
        case "melody": return .melody
        case "arp": return .arp
        default: return .tonal
        }
      }
      if kind == "crash" { return [] }
      if net.hasPrefix("fill-") { return .fill }
      return kind == "kick" ? .kick : .drums
    }
  }

  /// Steps `from ..< to` (sixteenths of the song from 0), during which `mask`'s lanes rest.
  public struct Entry: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var mask: Class
    public init(from: Int, to: Int, mask: Class) {
      self.from = from
      self.to = to
      self.mask = mask
    }
  }

  /// Disjoint, ascending, none empty.
  public let entries: [Entry]

  public static let empty = RestSchedule(merging: [])

  public var isEmpty: Bool { entries.isEmpty }

  /// `gestures` made disjoint: where they overlap, one entry with both masks. Empty and
  /// mask-less entries are dropped; adjacent entries with the same mask stay apart (the
  /// cursor does not care).
  public init(merging gestures: [Entry]) {
    let live = gestures.filter { $0.to > $0.from && !$0.mask.isEmpty }
    var cuts = Set<Int>()
    for e in live {
      cuts.insert(e.from)
      cuts.insert(e.to)
    }
    let points = cuts.sorted()
    var out: [Entry] = []
    for (a, b) in zip(points, points.dropFirst()) {
      var mask: Class = []
      for e in live where e.from <= a && e.to >= b { mask.formUnion(e.mask) }
      if !mask.isEmpty { out.append(Entry(from: a, to: b, mask: mask)) }
    }
    entries = out
  }

  /// The schedule `fixes` give `project` (the project the deck plays). Pure; off the audio
  /// thread. Each gesture has its own file and flag. `genre` is the track's (`WaveOptions.genre`),
  /// nil when unknown: a gesture only some genres play is off then.
  public static func build(
    _ project: Project, fixes: DJMusicality.Fixes, genre: String? = nil
  ) -> RestSchedule {
    var gestures: [Entry] = []
    if fixes.contains(.dropGap) {
      gestures += DJMusicality.dropGaps(project).map {
        Entry(from: $0, to: $0 + DJMusicality.dropGapSteps, mask: .rhythm)
      }
    }
    if fixes.contains(.layerBudget) { gestures += DJMusicality.layerBudgetRests(project) }
    if fixes.contains(.bandStop) { gestures += DJMusicality.bandStopRests(project, genre: genre) }
    if fixes.contains(.kickOut) { gestures += DJMusicality.kickOutRests(project) }
    return RestSchedule(merging: gestures)
  }

  /// What rests at `step`, for a reader that mostly moves forward one step at a time. Moving
  /// back (a stop, a jump) re-seeks from the top. Allocation-free.
  public struct Cursor: Sendable {
    var index = 0
    public init() {}

    public mutating func reset() { index = 0 }

    @inline(__always)
    public mutating func mask(at step: Int, in s: RestSchedule) -> Class {
      let e = s.entries
      if index > e.count || (index > 0 && e[index - 1].to > step) { index = 0 }
      while index < e.count && e[index].to <= step { index += 1 }
      return index < e.count && e[index].from <= step ? e[index].mask : []
    }
  }

  /// What rests at `step`, by a plain scan (tests, off the audio thread).
  public func mask(at step: Int) -> Class {
    entries.first { $0.from <= step && step < $0.to }?.mask ?? []
  }

  /// This schedule with a mix-out tail's rest on top (`MixOutTail.entry`).
  public func with(tail: MixOutTail) -> RestSchedule {
    RestSchedule(merging: entries + [tail.entry])
  }
}

/// A mix-out tail (ROADMAP 6.2, performable form; `WaveOptions.tail`): from `fromTick` the deck
/// plays only its drums-forward lanes (kick, drums, bass: the melodic classes rest) for `bars`
/// bars, plays on past the song's own `stop-transport`, and stops on `endTick`. `fromTick` is a
/// bar line (the caller picks it), so `endTick` is one too. Fills, crashes, stingers and the
/// live keys play on, as they do through every rest.
///
/// The stop is the transport's: voices already sounding release, and the room and echo ring
/// out after it (as at the end of a song), so the last bar does not cut off dry.
public struct MixOutTail: Equatable, Sendable {
  public var fromTick: Int
  public var bars: Int

  public init(fromTick: Int, bars: Int = 16) {
    self.fromTick = fromTick
    self.bars = bars
  }

  /// The tick the deck stops on: `bars` bars after `fromTick`.
  public var endTick: Int { fromTick + max(0, bars) * 16 }

  /// What rests: the melodic lanes, from `fromTick` to the stop.
  public var entry: RestSchedule.Entry {
    RestSchedule.Entry(from: fromTick, to: endTick, mask: RestSchedule.Class.melodic)
  }
}
