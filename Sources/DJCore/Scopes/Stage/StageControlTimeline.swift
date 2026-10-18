import Foundation

// StageControlTimeline: what the track's control nets are going to do, as one precomputed,
// sorted schedule a stage scene can read ahead of the music.
//
// A composed song carries its arrangement as control nets (`struct-<role>` accumulators that
// mute, unmute and activate slots; `fill-N` chains; `macro-curve` / `feel-curve` chains;
// `struct-stop`) and as its `structure` (sections with phrase lists). dj adds arrangement
// gestures on top (`RestSchedule`: the drop gap, the band stop, the kick out). Everything here
// is derivable at prepare time from the PLAYED project alone, so the timeline is a pure function
// of (project, fixes, genre), built once per track off the frame path, and queried every frame
// without allocating.
//
// Ticks are STEPS of the song: sixteenths from 0, the numbering `Deck.SectionInfo.startTick` and
// `RestSchedule` use. A control stage that fires on graph tick T is reported at step T: the
// composer schedules a section's mutes on its first step that way (`struct-*` stages and the
// edges dj carries on fill chains land exactly on section starts). A reader at clock tick `t`
// with phase `f` is at step `Double(t - 1) + f` (`ScopeClock.tick` runs one ahead of the step it
// plays), so a change shows within a step of when it is heard.
//
// What it holds (one `StageControlEvent` each, `kind` says which):
//   section    a section starts: `name`, `index` (its position), `length` (its steps)
//   phrase     a phrase starts (every section start too): `index` counts phrases from 0. A
//              section's phrases are its `phraseCount` equal parts, cut further into 4-bar
//              chunks when longer than that, so no phrase is longer than 64 steps
//   enter/exit a role (`kick`, `bass`, `melody`… the riff group or the net) starts or stops
//              sounding: the structure's mutes, unmutes and slot activations
//   buildup    a rising section (buildup / pre-chorus) that runs into a payoff (drop / chorus):
//              `length` its steps, `index` the payoff's section index
//   drop       that payoff starts (and any section named "drop"): `length` its steps
//   dropGap    the rhythm section rests before a drop (`.dropGap`), `length` steps
//   bandStop   the band stops before a chorus (`.bandStop`, song genres only)
//   kickOut    the kick sits out the last bar of a buildup (`.kickOut`)
//   fill       a `fill-N` chain's drum fill: its last 4 steps before the boundary (8 when the
//              section that ends there is 128 steps or longer: `drumFillNet`'s `fillLength`)
//   macro      a control net fires a macro (`name` its id, `length` its bars in steps)
//   stop       the song's `stop-transport`
//
// Queries: `events(from:to:)` (a window), `next(_:after:)` and `ticksUntil(_:from:)` (look
// ahead: a fuse that burns down over a buildup is `fuse(at:)`), `last(_:atOrBefore:)` (what
// is current: the section, the phrase), `isActive(role:at:)`, `covering(_:at:)` (a span event
// in progress: inside a drop gap, a fill).

public struct StageControlEvent: Equatable, Sendable {
  public enum Kind: Int, CaseIterable, Sendable {
    case section, phrase, enter, exit, buildup, drop, dropGap, bandStop, kickOut, fill, macro,
      stop
  }

  public var kind: Kind
  /// First step it acts on.
  public var tick: Int
  /// Steps it spans (0 for an instant).
  public var length: Int
  /// The section, role, fill net or macro it is about ("" for none).
  public var name: String
  /// Section index (section, buildup: the payoff's, drop), phrase ordinal (phrase), fill number
  /// (fill); 0 otherwise.
  public var index: Int

  public init(kind: Kind, tick: Int, length: Int = 0, name: String = "", index: Int = 0) {
    self.kind = kind
    self.tick = tick
    self.length = length
    self.name = name
    self.index = index
  }

  /// One past the last step it spans.
  public var end: Int { tick + length }
}

public struct StageControlTimeline: Equatable, Sendable {
  /// Every event, by tick (then by kind, then name: a deterministic order).
  public let events: [StageControlEvent]
  /// The song's sections.
  public let sections: [Deck.SectionInfo]
  /// Steps in the song (0 for a loop).
  public let totalSteps: Int
  /// Roles the structure drives, sorted, with whether each sounds from the top.
  public let roles: [String]
  public let initiallyActive: [Bool]
  /// A hash of the song (its name, tempo, sections and nets): seeds a scene's world, so the same
  /// configuration always looks the same and another song looks different.
  public let seed: UInt64

  /// Indices into `events` per kind (`Kind.rawValue`), ascending.
  private let byKind: [[Int]]

  public static let empty = StageControlTimeline(
    events: [], sections: [], roles: [], initiallyActive: [], seed: 0)

  /// The longest phrase the timeline reports (4 bars).
  public static let maxPhraseSteps = 64

  public init(
    events: [StageControlEvent], sections: [Deck.SectionInfo], roles: [String],
    initiallyActive: [Bool], seed: UInt64
  ) {
    let sorted = events.enumerated().sorted { a, b in
      let x = a.element
      let y = b.element
      if x.tick != y.tick { return x.tick < y.tick }
      if x.kind != y.kind { return x.kind.rawValue < y.kind.rawValue }
      if x.name != y.name { return x.name < y.name }
      return a.offset < b.offset
    }.map(\.element)
    self.events = sorted
    self.sections = sections
    totalSteps = sections.reduce(0) { $0 + $1.steps }
    self.roles = roles
    self.initiallyActive = initiallyActive
    self.seed = seed
    var kinds = [[Int]](repeating: [], count: StageControlEvent.Kind.allCases.count)
    for (i, e) in sorted.enumerated() { kinds[e.kind.rawValue].append(i) }
    byKind = kinds
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.events == b.events && a.sections == b.sections && a.roles == b.roles
      && a.initiallyActive == b.initiallyActive && a.seed == b.seed
  }

  // MARK: queries (allocation-free)

  /// Events with `from <= tick < to`, in order.
  public func events(from: Int, to: Int) -> ArraySlice<StageControlEvent> {
    guard to > from else { return events[0..<0] }
    let lo = lowerBound(from)
    let hi = lowerBound(to)
    return events[lo..<max(lo, hi)]
  }

  /// All events of one kind, in order.
  public func count(_ kind: StageControlEvent.Kind) -> Int { byKind[kind.rawValue].count }

  public func event(_ kind: StageControlEvent.Kind, _ i: Int) -> StageControlEvent {
    events[byKind[kind.rawValue][i]]
  }

  /// The first event of `kind` that starts after `step` (strictly), nil if none is left.
  public func next(_ kind: StageControlEvent.Kind, after step: Double) -> StageControlEvent? {
    let list = byKind[kind.rawValue]
    var lo = 0
    var hi = list.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if Double(events[list[mid]].tick) <= step { lo = mid + 1 } else { hi = mid }
    }
    return lo < list.count ? events[list[lo]] : nil
  }

  /// Steps from `step` to the next event of `kind` (nil if none is left).
  public func ticksUntil(_ kind: StageControlEvent.Kind, from step: Double) -> Double? {
    next(kind, after: step).map { Double($0.tick) - step }
  }

  /// The last event of `kind` that started at or before `step`.
  public func last(_ kind: StageControlEvent.Kind, atOrBefore step: Double) -> StageControlEvent? {
    let i = lastIndex(kind, atOrBefore: step)
    return i.map { events[byKind[kind.rawValue][$0]] }
  }

  /// The span event of `kind` that `step` is inside (`tick <= step < end`), nil if none.
  public func covering(_ kind: StageControlEvent.Kind, at step: Double) -> StageControlEvent? {
    let list = byKind[kind.rawValue]
    guard var i = lastIndex(kind, atOrBefore: step) else { return nil }
    // spans of one kind may overlap (fills of short sections): look back a few
    var looked = 0
    while i >= 0 && looked < 4 {
      let e = events[list[i]]
      if step < Double(e.end) { return e }
      i -= 1
      looked += 1
    }
    return nil
  }

  /// The section `step` is in (the first one before the song starts, the last after it ends).
  public func sectionIndex(at step: Double) -> Int? {
    guard !sections.isEmpty else { return nil }
    var k = 0
    for (i, s) in sections.enumerated() where Double(s.startTick) <= step { k = i }
    return k
  }

  /// 0...1 through the section `step` is in.
  public func sectionProgress(at step: Double) -> Double {
    guard let k = sectionIndex(at: step) else { return 0 }
    let s = sections[k]
    guard s.steps > 0 else { return 0 }
    return min(1, max(0, (step - Double(s.startTick)) / Double(s.steps)))
  }

  /// Does `role` sound at `step`, by the structure?
  public func isActive(role: String, at step: Double) -> Bool {
    guard let r = roles.firstIndex(of: role) else { return false }
    var on = initiallyActive[r]
    // the later of the role's last enter and last exit decides
    var lastOn = -1
    var lastOff = -1
    for i in byKind[StageControlEvent.Kind.enter.rawValue] {
      let e = events[i]
      if Double(e.tick) > step { break }
      if e.name == role { lastOn = e.tick }
    }
    for i in byKind[StageControlEvent.Kind.exit.rawValue] {
      let e = events[i]
      if Double(e.tick) > step { break }
      if e.name == role { lastOff = e.tick }
    }
    if lastOn >= 0 || lastOff >= 0 { on = lastOn > lastOff }
    return on
  }

  /// The buildup `step` is in, with how far its fuse has burnt: 0 at the buildup's first step,
  /// 1 on the drop (`1 - ticksUntilDrop / buildupLength`). Nil outside a buildup.
  public func fuse(at step: Double) -> (buildup: StageControlEvent, progress: Double)? {
    guard let b = covering(.buildup, at: step), b.length > 0 else { return nil }
    let until = Double(b.end) - step
    return (b, min(1, max(0, 1 - until / Double(b.length))))
  }

  private func lowerBound(_ tick: Int) -> Int {
    var lo = 0
    var hi = events.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if events[mid].tick < tick { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  private func lastIndex(_ kind: StageControlEvent.Kind, atOrBefore step: Double) -> Int? {
    let list = byKind[kind.rawValue]
    var lo = 0
    var hi = list.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if Double(events[list[mid]].tick) <= step { lo = mid + 1 } else { hi = mid }
    }
    return lo > 0 ? lo - 1 : nil
  }
}

// MARK: - building

extension StageControlTimeline {
  /// The timeline of `project` (the PLAYED project: a deck's `netProject`). `fixes` are the dj
  /// gestures the deck plays (`WaveOptions.musicality`), `genre` the track's when known (the band
  /// stop is a song-family gesture: off without one). Pure.
  public static func build(
    _ project: Project, fixes: DJMusicality.Fixes = .all, genre: String? = nil
  ) -> StageControlTimeline {
    let sections = Deck.SectionInfo.sections(of: project)
    var out: [StageControlEvent] = []

    // Sections and phrases.
    var phrase = 0
    for (k, s) in sections.enumerated() {
      out.append(
        StageControlEvent(
          kind: .section, tick: s.startTick, length: s.steps, name: s.name, index: k))
      let parts = max(1, s.phraseCount)
      var cuts: [Int] = []
      for p in 0..<parts {
        let a = s.startTick + p * s.steps / parts
        let b = s.startTick + (p + 1) * s.steps / parts
        var t = a
        while t < b {
          cuts.append(t)
          t += maxPhraseSteps
        }
      }
      for (j, t) in cuts.enumerated() {
        let end = j + 1 < cuts.count ? cuts[j + 1] : s.startTick + s.steps
        out.append(
          StageControlEvent(kind: .phrase, tick: t, length: end - t, name: s.name, index: phrase))
        phrase += 1
      }
    }

    // Buildups and drops.
    let rising: Set<String> = ["buildup", "pre-chorus"]
    let payoff: Set<String> = ["drop", "chorus"]
    for (k, s) in sections.enumerated() {
      let afterRise = k > 0 && rising.contains(sections[k - 1].name) && payoff.contains(s.name)
      if afterRise {
        let b = sections[k - 1]
        out.append(
          StageControlEvent(
            kind: .buildup, tick: b.startTick, length: b.steps, name: b.name, index: k))
      }
      if afterRise || s.name == "drop" {
        out.append(
          StageControlEvent(kind: .drop, tick: s.startTick, length: s.steps, name: s.name, index: k)
        )
      }
    }

    // dj's arrangement gestures.
    if fixes.contains(.dropGap) {
      for t in DJMusicality.dropGaps(project) {
        out.append(StageControlEvent(kind: .dropGap, tick: t, length: DJMusicality.dropGapSteps))
      }
    }
    if fixes.contains(.bandStop) {
      for e in DJMusicality.bandStopRests(project, genre: genre) {
        out.append(StageControlEvent(kind: .bandStop, tick: e.from, length: e.to - e.from))
      }
    }
    if fixes.contains(.kickOut) {
      for e in DJMusicality.kickOutRests(project) {
        out.append(
          StageControlEvent(kind: .kickOut, tick: e.from, length: e.to - e.from, name: "kick"))
      }
    }

    // Control nets: role changes, fills, macros, the stop.
    var changes: [(step: Int, role: String, on: Bool, order: Int)] = []
    func roleOf(_ target: String) -> String {
      if let g = project.nets[target]?.riffGroup, !g.isEmpty { return g }
      return target
    }
    func control(_ c: ControlBinding, step: Int) {
      switch c.action {
      case "mute-track", "unmute-track", "activate-slot":
        guard !c.targetNet.isEmpty else { return }
        changes.append((step, roleOf(c.targetNet), c.action != "mute-track", changes.count))
      case "fire-macro":
        let bars = c.macroBars ?? 1
        out.append(
          StageControlEvent(
            kind: .macro, tick: step, length: max(1, Int((bars * 16).rounded())),
            name: c.macro ?? ""))
      case "stop-transport":
        out.append(StageControlEvent(kind: .stop, tick: step))
      default: break
      }
    }
    var fillNumber = 0
    for (id, nb) in project.nets.pairs where nb.role == "control" {
      if nb.places["p_delay_0"] != nil {
        // an accumulator (`buildAccumulatorNet`): stage i drains p_delay_i, then fires
        var tick = 0
        var i = 0
        while let gap = nb.places["p_delay_\(i)"]?.initial.first {
          tick += Int(gap) + 1
          if let c = nb.controlBindings["t_ctrl_\(i)"] { control(c, step: tick) }
          i += 1
        }
        continue
      }
      // a chain (`drumFillNet`, `buildControlBundle`): transition k fires on tick k + 1
      for (tid, c) in nb.controlBindings.pairs {
        guard let k = trailingNumber(tid) else { continue }
        control(c, step: k + 1)
      }
      if id.hasPrefix("fill-") {
        // dj binds buildup hits and crashes along the whole chain, so the fill is read from
        // where the chain ends, as the composer placed it
        let boundary = nb.transitions.count
        let ending = sections.last { $0.startTick + $0.steps == boundary }
        let length = min(boundary, (ending?.steps ?? 0) >= 128 ? 8 : 4)
        if boundary > 0 {
          out.append(
            StageControlEvent(
              kind: .fill, tick: boundary - length, length: length, name: id,
              index: trailingNumber(id) ?? fillNumber))
          fillNumber += 1
        }
      }
    }

    // Roles: who sounds from the top, then the edges of each one's state.
    var names = Set<String>()
    for (id, nb) in project.nets.pairs where nb.role != "control" {
      if nb.track.group == "stinger" { continue }
      names.insert(nb.riffGroup.isEmpty ? id : nb.riffGroup)
    }
    for c in changes { names.insert(c.role) }
    let roles = names.sorted()
    var initial: [Bool] = []
    for r in roles {
      let nets = project.nets.pairs.filter {
        $0.value.role != "control"
          && ($0.value.riffGroup.isEmpty ? $0.key : $0.value.riffGroup) == r
      }
      initial.append(nets.contains { !project.initialMutes.contains($0.key) })
    }
    let ordered = changes.sorted { $0.step != $1.step ? $0.step < $1.step : $0.order < $1.order }
    var state = Dictionary(uniqueKeysWithValues: zip(roles, initial))
    // A slot swap is a mute of the old slot and an activation of the new one on the same step:
    // settle each step's changes before deciding whether the role entered or left.
    var i = 0
    while i < ordered.count {
      let step = ordered[i].step
      var after = state
      while i < ordered.count && ordered[i].step == step {
        after[ordered[i].role] = ordered[i].on
        i += 1
      }
      for r in roles where after[r] != state[r] {
        out.append(StageControlEvent(kind: after[r]! ? .enter : .exit, tick: step, name: r))
      }
      state = after
    }

    return StageControlTimeline(
      events: out, sections: sections, roles: roles, initiallyActive: initial,
      seed: seed(of: project))
  }

  /// The digits that end `s` ("t12" → 12, "fill-3" → 3).
  static func trailingNumber(_ s: String) -> Int? {
    let digits = s.reversed().prefix { $0.isASCII && $0.isNumber }
    return digits.isEmpty ? nil : Int(String(digits.reversed()))
  }

  /// FNV-1a over what makes the song this song.
  static func seed(of p: Project) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ s: String) {
      for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01b3
      }
      h ^= 0xff
      h = h &* 0x0000_0100_0000_01b3
    }
    mix(p.name)
    mix(String(Int((p.tempo * 1000).rounded())))
    mix(p.scaleName)
    for s in p.structure { mix("\(s.name):\(s.steps)") }
    for k in p.nets.keys { mix(k) }
    return h
  }
}
