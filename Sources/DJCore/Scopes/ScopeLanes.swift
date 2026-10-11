// Lanes: the parts of a track as the scopes see them. A port of scope.js `buildLanes` (with
// `durMsOf`, `sectionGroupForNet` from lib/ui/mixer.js and the colour rules of audio-io.js).
//
// A lane is one row of the event display and one "part" of the model modes: nets that share a
// riff group (kick-0, kick-1, ... variants of one part) are merged into one lane. At most 32
// lanes are kept, drums first.
//
// Two ways in, one result:
//  * `ScopeLaneSet.build(project:tempo:deck:)` is the faithful port: it walks the Project, so it
//    knows every transition's note and duration (the model modes need them).
//  * `ScopeLaneSet.build(layout:deck:)` builds the same lanes from what the engine publishes
//    about a project that is already running (`MarkingLayout.nets`). It has the same lanes,
//    keys, order, colours and note range but no per-transition durations or note sets. The feed
//    uses it only when the `Project` of a sounding generation is no longer at hand.

/// A song section as the scopes draw it: where it starts, in song steps (`tick - 1`
/// numbering, so the first section starts at step 0), and its name.
public struct ScopeSection: Equatable, Sendable {
  public var step: Int
  public var name: String

  public init(step: Int, name: String) {
    self.step = step
    self.name = name
  }
}

/// One lane (scope.js lane object).
public struct ScopeLane: Equatable, Sendable {
  /// The merge key: the riff group, else the net id without its trailing `-<digits>`.
  public var key: String
  /// Net ids merged into this lane, in project order.
  public var ids: [String]
  /// The track's MIDI channel (1 when the track names none).
  public var channel: Int
  /// `sectionGroupForNet`: the track's group, `stinger` for `hit<N>` nets, else `main`.
  public var group: String
  /// Channels 10...15: percussion, drawn as velocity spikes.
  public var drum: Bool
  /// The track's instrument name ('' if none).
  public var instrument: String
  /// Distinct notes the lane's transitions can play, in first-seen order.
  public var notes: [Int]
  /// Up to 256 note lengths in ms (`durMsOf`), in transition order. The model modes take the
  /// median.
  public var durationsMs: [Double]
  /// Lowest and highest note (48 and 72 when the lane has none).
  public var lo: Int
  public var hi: Int
  public var color: ScopeColor
  /// The deck this lane belongs to. On a `.master` feed lanes of both decks are concatenated and
  /// this says which is which; on a deck feed it is that deck.
  public var deck: String

  public init(
    key: String, ids: [String], channel: Int, group: String, drum: Bool, instrument: String,
    notes: [Int], durationsMs: [Double], lo: Int, hi: Int, color: ScopeColor, deck: String
  ) {
    self.key = key
    self.ids = ids
    self.channel = channel
    self.group = group
    self.drum = drum
    self.instrument = instrument
    self.notes = notes
    self.durationsMs = durationsMs
    self.lo = lo
    self.hi = hi
    self.color = color
    self.deck = deck
  }
}

/// The lanes of one project, plus the maps built with them (scope.js `s.lanes`, `s.laneOf`,
/// `s.channels`, `s.sections`).
public struct ScopeLaneSet: Equatable, Sendable {
  /// scope.js keeps at most this many lanes.
  public static let maxLanes = 32
  /// scope.js `GROUP_ORDER`: lanes sort by this rank after drums-first.
  public static let groupOrder = [
    "drums", "percussion", "bass", "chords", "harmony", "lead", "melody", "arp", "pad", "texture",
    "stinger",
  ]
  /// Cap on `ScopeLane.durationsMs` per lane.
  public static let maxDurations = 256

  public var lanes: [ScopeLane]
  /// Net id → lane index. Nets that are not in a lane (control nets, `macro:` nets, lanes beyond
  /// the 32nd) are absent: their fires are dropped.
  public var laneOf: [String: Int]
  /// Distinct channels of the kept lanes, in lane order.
  public var channels: [Int]
  /// Section starts and names (empty for a loop).
  public var sections: [ScopeSection]

  public init(
    lanes: [ScopeLane] = [], laneOf: [String: Int] = [:], channels: [Int] = [],
    sections: [ScopeSection] = []
  ) {
    self.lanes = lanes
    self.laneOf = laneOf
    self.channels = channels
    self.sections = sections
  }

  public var isEmpty: Bool { lanes.isEmpty }

  /// The lane a net belongs to, if it has one.
  public func lane(of netId: String) -> ScopeLane? { laneOf[netId].map { lanes[$0] } }

  // MARK: building

  /// scope.js `buildLanes` over a `Project`.
  ///
  /// Skipped, as in JS: nets whose role is `control` and ids starting `macro:`. JS also skips
  /// nets that have no `track`; a Swift `NetBundle` always has one (a net parsed without a track
  /// object gets the default track: channel 1, no instrument), so that rule cannot be applied.
  ///
  /// `tempo` is the BPM `durMsOf` converts step durations with (JS reads the UI's tempo when the
  /// lanes are built); a non-finite or non-positive value means 120, as in JS.
  ///
  /// Sort order is drums first, then `groupOrder` rank, then the lane key with Swift's `<` on
  /// strings. JS uses `localeCompare`, which orders upper/lower case and punctuation by ICU
  /// collation; the two agree on the all-lower-case alphanumeric keys the composer makes, and
  /// may differ for keys with `_`, upper case or non-ASCII characters.
  public static func build(project: Project, tempo: Double, deck: String) -> ScopeLaneSet {
    var inputs: [LaneInput] = []
    for (id, net) in project.nets.pairs {
      var inp = LaneInput(
        id: id, role: net.role, riffGroup: net.riffGroup, group: net.track.group,
        channel: net.track.channel, instrument: net.track.instrument)
      for (_, m) in net.bindings.pairs {
        inp.bindings.append((m.note, durMs(of: m, tempo: tempo)))
      }
      inputs.append(inp)
    }
    var set = assemble(inputs, deck: deck)
    set.sections = Deck.SectionInfo.sections(of: project).map {
      ScopeSection(step: $0.startTick, name: $0.name)
    }
    return set
  }

  /// The same lanes from what the engine published about a running project. No note sets or
  /// durations (see the file header); `lo`/`hi` come from the net's note range.
  public static func build(layout: MarkingLayout, deck: String) -> ScopeLaneSet {
    var inputs: [LaneInput] = []
    for n in layout.nets {
      var inp = LaneInput(
        id: n.id, role: n.role, riffGroup: n.riffGroup, group: n.group, channel: n.channel,
        instrument: n.instrument)
      if n.noteLow >= 0 && n.noteHigh >= 0 { inp.range = (n.noteLow, n.noteHigh) }
      inputs.append(inp)
    }
    var set = assemble(inputs, deck: deck)
    set.sections = layout.sections.map { ScopeSection(step: $0.startTick, name: $0.name) }
    return set
  }

  /// scope.js `durMsOf`: a binding's length in ms. Sixteenth steps (canonical) at the given
  /// tempo, else its legacy millisecond duration, else 100.
  public static func durMs(of m: MidiBinding, tempo: Double) -> Double {
    let bpm = tempo.isFinite && tempo > 0 ? tempo : 120
    if m.durationSteps > 0 { return Double(m.durationSteps) * 60000 / bpm / 4 }
    return m.duration > 0 ? Double(m.duration) : 100
  }

  /// lib/ui/mixer.js `sectionGroupForNet`: the track's own group, `stinger` for `hit<N>` ids,
  /// else `main`.
  public static func sectionGroup(id: String, trackGroup: String?) -> String {
    if let g = trackGroup, !g.isEmpty { return g }
    let u = Array(id.utf8)
    if u.count > 3, u[0] == 0x68, u[1] == 0x69, u[2] == 0x74,
      u[3...].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
    {
      return "stinger"
    }
    return "main"
  }

  // MARK: internals

  struct LaneInput {
    var id: String
    var role: String
    var riffGroup: String
    var group: String?
    var channel: Int
    var instrument: String
    /// (note, duration ms) per transition that has a MIDI binding, in transition order.
    var bindings: [(note: Int, durMs: Double)] = []
    /// A note range known without the bindings (the layout path).
    var range: (lo: Int, hi: Int)?
  }

  static func assemble(_ inputs: [LaneInput], deck: String) -> ScopeLaneSet {
    var byKey: [String: Int] = [:]
    var building: [ScopeLane] = []
    var fallback = 0
    for inp in inputs {
      if inp.role == "control" || inp.id.hasPrefix("macro:") { continue }
      let key = inp.riffGroup.isEmpty ? ScopeColors.stripTrailingDashDigits(inp.id) : inp.riffGroup
      var index = byKey[key]
      if index == nil {
        var color = ScopeColors.laneColor(forNet: inp.id)
        if color == ScopeColors.defaultLaneColor {
          color = ScopeColors.fallbackLaneColors[fallback % ScopeColors.fallbackLaneColors.count]
          fallback += 1
        }
        building.append(
          ScopeLane(
            key: key, ids: [], channel: inp.channel,
            group: sectionGroup(id: inp.id, trackGroup: inp.group),
            drum: isDrumChannel(inp.channel), instrument: inp.instrument, notes: [],
            durationsMs: [], lo: 127, hi: 0, color: color, deck: deck))
        index = building.count - 1
        byKey[key] = index
      }
      let i = index!
      building[i].ids.append(inp.id)
      for b in inp.bindings {
        if !building[i].notes.contains(b.note) { building[i].notes.append(b.note) }
        if building[i].durationsMs.count < maxDurations { building[i].durationsMs.append(b.durMs) }
        building[i].lo = min(building[i].lo, b.note)
        building[i].hi = max(building[i].hi, b.note)
      }
      if let r = inp.range {
        building[i].lo = min(building[i].lo, r.lo)
        building[i].hi = max(building[i].hi, r.hi)
      }
    }
    func rank(_ g: String) -> Int { groupOrder.firstIndex(of: g) ?? groupOrder.count }
    var kept = building.sorted { a, b in
      if a.drum != b.drum { return a.drum }
      if rank(a.group) != rank(b.group) { return rank(a.group) < rank(b.group) }
      return a.key < b.key
    }
    if kept.count > maxLanes { kept.removeLast(kept.count - maxLanes) }
    var laneOf: [String: Int] = [:]
    var channels: [Int] = []
    for i in kept.indices {
      for id in kept[i].ids { laneOf[id] = i }
      if kept[i].lo > kept[i].hi {
        kept[i].lo = 48
        kept[i].hi = 72
      }
      if !channels.contains(kept[i].channel) { channels.append(kept[i].channel) }
    }
    return ScopeLaneSet(lanes: kept, laneOf: laneOf, channels: channels)
  }
}
