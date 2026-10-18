import Foundation

/// A per-section diatonic shift of the band (ROADMAP 6.3, "dj first"): what the runner plays
/// the pad / bass / arp / melody lanes through so the parts move together when a section changes
/// harmony.
///
/// beats' composer moves only the melody in a bridge (+5 degrees) or a solo (+4,
/// `TrackTheme.harmonic`); the pad is a single unslotted ring, so the melody leaves a pad that
/// stays put. Here each section gets a degree shift — bridge +5, solo +4, breakdown to the
/// relative minor (−2, vi) in a major-third key or the relative major (+2, III) in a minor one —
/// and every tonal group is moved by it diatonically (in key; a chromatic note keeps its offset
/// from the scale tone below it). The octave is chosen per group: the nearer of the shift and its
/// complement (+5 plays as −2, a third down), unless that takes the group under E1 or over C8
/// where it was not already.
///
/// Each section holds 8 half-bar slots per 4-bar cycle (the pad ring's 64 steps, counted from the
/// song's first step), all equal to the section's shift unless `.harmonicRhythm` fills them, and
/// 2 tail slots for its last bar that override the cycle (`tail`). Under `.harmonicRhythm` a slot
/// is the shift that makes the band play a chosen chord over the pad's own: intros, breakdowns and
/// outros hold each chord 2 bars (the odd bar of each pair plays the even bar's chord), a
/// buildup's last half-bar plays the V of the next section's first chord, and the last bar
/// before a chorus (not from a drop or a chorus) plays 2 chords, a half-bar each, the second
/// that V (or the ♭VII when the diatonic fifth isn't perfect). Drops keep 1 chord per bar.
/// Built from the played project off the audio thread; `note(_:group:step:)` is a lookup the
/// runner may call per note.
public struct SectionHarmony: Sendable, Equatable {
  /// First step of each section, ascending (the same edges as `EnergyCurve.start`).
  public var start: [Int]
  /// The step after the last section.
  public var end: Int
  /// Each section's degree shift (`.sectionHarmony`; all 0 without it).
  public var degrees: [Int]
  /// The tonal groups the maps cover (`NoteLog.groupName`), in net order.
  public var groups: [String]
  /// The distinct non-zero shifts the slots refer to (slot value k ≥ 1 is `shifts[k - 1]`).
  public var shifts: [Int]
  /// `slotsPerCycle` entries per section: 0 = home, k = `shifts[k - 1]`.
  public var slots: [UInt8]
  /// `tailSlots` entries per section, its last bar's half-bars: as `slots`, or `noTail` (the
  /// cycle's slot plays).
  public var tail: [UInt8]
  /// The degree shift each group actually plays per shift, octave chosen
  /// (`(k - 1) * groups.count + group`): `shifts[k - 1]` or it ∓ 7.
  public var groupDegrees: [Int]
  /// 128 notes per (shift, group), same index order as `groupDegrees`.
  public var maps: [UInt8]

  /// Half-bar slots in a 4-bar cycle, and their length in steps.
  public static let slotsPerCycle = 8
  public static let slotSteps = 8
  /// Half-bar slots at the end of each section that `tail` can override (its last bar).
  public static let tailSlots = 2
  /// A `tail` entry that leaves the cycle's slot to play.
  public static let noTail = UInt8.max
  /// Sections that hold each chord 2 bars under `.harmonicRhythm`.
  public static let holdingSections: Set<String> = ["intro", "breakdown", "outro"]
  /// Degree shifts by section name; a breakdown is `breakdownShift` (it depends on the key).
  public static let sectionDegrees: [String: Int] = ["bridge": 5, "solo": 4]
  /// A group is not moved under this note (E1) or over this one (C8) unless it already was.
  static let floorNote = 28
  static let ceilingNote = 108

  /// To the relative minor (vi, −2) in a key with a major third, to the relative major (III,
  /// +2) in one with a minor third.
  public static func breakdownShift(_ intervals: [Int]) -> Int {
    intervals.count > 2 && intervals[2] == 3 ? 2 : -2
  }

  /// The degree shift of a section by name in a key (`intervals`, seven notes).
  public static func degreeShift(section name: String, intervals: [Int]) -> Int {
    if name == "breakdown" { return breakdownShift(intervals) }
    return sectionDegrees[name] ?? 0
  }

  /// The `.sectionHarmony` plan for `project`, or nil: a loop (one section or none), a key that
  /// isn't seven notes (pentatonic, blues), a song with no section that moves, or no tonal part
  /// to move.
  public init?(project: Project) {
    self.init(project: project, fixes: [.sectionHarmony])
  }

  /// The plan for `project` under `fixes` (`.sectionHarmony`: the section shifts;
  /// `.harmonicRhythm`: the slots it fills), or nil: neither flag, a loop, a key that isn't
  /// seven notes, nothing that moves, or no tonal part to move.
  public init?(project: Project, fixes: DJMusicality.Fixes) {
    let moves = fixes.contains(.sectionHarmony)
    let rhythm = fixes.contains(.harmonicRhythm)
    guard moves || rhythm, project.structure.count > 1 else { return nil }
    let intervals = scaleIntervals(
      (project.scaleName.isEmpty ? "Major" : project.scaleName) + "Scale")
    guard intervals.count == 7 else { return nil }
    var start: [Int] = []
    var degrees: [Int] = []
    var at = 0
    for s in project.structure {
      start.append(at)
      degrees.append(moves ? Self.degreeShift(section: s.name, intervals: intervals) : 0)
      at += s.steps
    }
    let end = at

    // the shift each slot plays (any degree count; 0 = home), cycle and tail
    let n = Self.slotsPerCycle
    var cycle: [Int] = []
    for d in degrees { cycle.append(contentsOf: repeatElement(d, count: n)) }
    var tailShift = [Int?](repeating: nil, count: start.count * Self.tailSlots)
    if rhythm {
      Self.fillRhythm(
        project, start: start, end: end, degrees: degrees, cycle: &cycle, tail: &tailShift)
    }
    guard cycle.contains(where: { $0 != 0 }) || tailShift.contains(where: { ($0 ?? 0) != 0 })
    else { return nil }

    // the tonal groups and the notes each one binds
    var groups: [String] = []
    var range: [(lo: Int, hi: Int)] = []
    for (id, nb) in project.nets.pairs where nb.role != "control" {
      let notes = nb.bindings.values.filter { !isDrumChannel($0.channel) }.map(\.note)
      guard let lo = notes.min(), let hi = notes.max() else { continue }
      let name = NoteLog.groupName(nb, id: id)
      if let g = groups.firstIndex(of: name) {
        range[g] = (min(range[g].lo, lo), max(range[g].hi, hi))
      } else {
        groups.append(name)
        range.append((lo, hi))
      }
    }
    guard !groups.isEmpty else { return nil }

    // the distinct shifts: the section shifts first, as named; any other slot's shift reuses
    // one seven degrees away (the octave is chosen per group anyway), else is folded into -3…3
    var shifts: [Int] = []
    func index(_ d: Int) -> UInt8 {
      let r = (d % 7 + 7) % 7
      guard r != 0 else { return 0 }
      if let k = shifts.firstIndex(of: d) { return UInt8(k + 1) }
      if let k = shifts.firstIndex(where: { ($0 % 7 + 7) % 7 == r }) { return UInt8(k + 1) }
      shifts.append(r > 3 ? r - 7 : r)
      return UInt8(shifts.count)
    }
    for d in degrees where d != 0 && !shifts.contains(d) { shifts.append(d) }
    let slots = cycle.map(index)
    let tail = tailShift.map { $0.map(index) ?? Self.noTail }

    let root = ((project.rootNote ?? 60) % 12 + 12) % 12
    var groupDegrees: [Int] = []
    var maps: [UInt8] = []
    for d in shifts {
      for r in range {
        let pick = Self.octave(d, lo: r.lo, hi: r.hi, root: root, intervals: intervals)
        groupDegrees.append(pick)
        for n in 0..<128 {
          maps.append(UInt8(Self.shift(n, by: pick, root: root, intervals: intervals)))
        }
      }
    }
    self.start = start
    self.end = end
    self.degrees = degrees
    self.groups = groups
    self.shifts = shifts
    self.slots = slots
    self.tail = tail
    self.groupDegrees = groupDegrees
    self.maps = maps
  }

  /// `.harmonicRhythm`: the slot shifts that change the band's chord against the pad's own.
  /// A shift of a bar is the chord wanted (a degree of the key) minus the pad's root there; a
  /// bar whose pad chord is missing or off the key keeps its section's shift.
  static func fillRhythm(
    _ project: Project, start: [Int], end: Int, degrees: [Int], cycle: inout [Int],
    tail: inout [Int?]
  ) {
    guard let key = DJMusicality.sevenNoteKey(project) else { return }
    let (chords, padBars) = DJMusicality.padChords(project)
    guard padBars > 0 else { return }
    let n = slotsPerCycle
    let halves = slotsPerCycle / 4
    /// The pad's root degree in song bar `bar` (the ring loops from the song's first bar).
    func padRoot(_ bar: Int) -> Int? {
      guard let r = chords[bar % padBars]?.first else { return nil }
      return key.degrees.firstIndex(of: r)
    }
    func cycleSlot(_ k: Int, _ step: Int) -> Int { cycle[k * n + (step / slotSteps) % n] }
    /// The degree the band plays at `step` of section `k` by the cycle (no tails yet).
    func played(_ k: Int, _ step: Int) -> Int? {
      padRoot(step / 16).map { $0 + cycleSlot(k, step) }
    }
    func same(_ a: Int, _ b: Int) -> Bool { (a - b) % 7 == 0 }

    // intros, breakdowns, outros: the odd bar of each 2-bar pair plays the even bar's chord
    // (the pad ring has to fit the 4-bar cycle for the slots to say which bar is which)
    if padBars >= 2 && 4 % padBars == 0 {
      for (k, s) in project.structure.enumerated() where holdingSections.contains(s.name) {
        for bar in stride(from: 1, to: 4, by: 2) {
          guard let r0 = padRoot(bar - 1), let r1 = padRoot(bar) else { continue }
          for h in 0..<halves { cycle[k * n + bar * halves + h] = degrees[k] + r0 - r1 }
        }
      }
    }

    // section ends: a buildup's last half-bar, and the last bar into a chorus
    for k in 0..<max(0, start.count - 1) {
      let name = project.structure[k].name
      let next = project.structure[k + 1].name
      let runIn = next == "chorus" && name != "chorus" && name != "drop"
      guard name == "buildup" || runIn else { continue }
      let last = start[k + 1] - 16
      guard last >= start[k], let target = played(k + 1, start[k + 1]) else { continue }
      // V, else the ♭VII (a whole step under): whichever the key has as that interval
      let tpc = key.degrees[(target % 7 + 7) % 7]
      let candidates = [(target + 4, 5), (target + 6, 2)]
      guard
        let into = candidates.first(where: {
          DJMusicality.pc(tpc - key.degrees[($0.0 % 7 + 7) % 7]) == $0.1
        })?.0, let own = padRoot(last / 16)
      else { continue }
      tail[k * tailSlots + 1] = into - own
      guard runIn, let first = played(k, last) else { continue }
      // the first half-bar: its own chord, unless that is the V already or the chord before
      // it, then the IV (or the ii) on the way to the V, so the bar changes twice
      let before = played(k, last - 1) ?? first
      let pick = [first, into - 1, into - 3].first { !same($0, into) && !same($0, before) }
      if let pick, !same(pick, first) { tail[k * tailSlots] = pick - own }
    }
  }

  /// The index of a group in `groups`, else nil (a drum group, or one the project doesn't have).
  public func groupIndex(_ name: String) -> Int? { groups.firstIndex(of: name) }

  /// The section `step` falls in.
  @inline(__always)
  public func section(at step: Int) -> Int {
    var k = 0
    while k + 1 < start.count && start[k + 1] <= step { k += 1 }
    return k
  }

  /// `n` as group `group` plays it at `step` (the song's sixteenth, 0-based). Allocation-free;
  /// a note outside 0…127 or a group outside `groups` comes back unchanged.
  @inline(__always)
  public func note(_ n: Int, group: Int, step: Int) -> Int {
    guard n >= 0, n < 128, group >= 0, group < groups.count else { return n }
    let s = section(at: step)
    var k = Int(
      slots[s * Self.slotsPerCycle + (max(0, step) / Self.slotSteps) % Self.slotsPerCycle])
    let back = (s + 1 < start.count ? start[s + 1] : end) - step
    if back > 0 && back <= Self.tailSlots * Self.slotSteps {
      let t = tail[(s + 1) * Self.tailSlots - (back + Self.slotSteps - 1) / Self.slotSteps]
      if t != Self.noTail { k = Int(t) }
    }
    guard k > 0 else { return n }
    return Int(maps[((k - 1) * groups.count + group) * 128 + n])
  }

  /// `n` moved `d` scale degrees in the key (`root` a pitch class); a note off the scale keeps
  /// its distance from the scale tone below it. Folded back into 0…127 by octaves.
  static func shift(_ n: Int, by d: Int, root: Int, intervals: [Int]) -> Int {
    let rel = n - root
    let octave = Int((Double(rel) / 12).rounded(.down))
    let pc = rel - octave * 12
    var i = 0
    while i + 1 < intervals.count && intervals[i + 1] <= pc { i += 1 }
    let chroma = pc - intervals[i]
    let j = i + d
    let o = Int((Double(j) / 7).rounded(.down))
    var out = root + (octave + o) * 12 + intervals[j - o * 7] + chroma
    while out > 127 { out -= 12 }
    while out < 0 { out += 12 }
    return out
  }

  /// The octave a group plays shift `d` in: `d` or its complement (`d ∓ 7`), whichever moves the
  /// middle of the group's range less, unless it leaves [E1, C8] (widened to the group's own
  /// range) and the other doesn't. A tie goes down for a group centred under middle C.
  static func octave(_ d: Int, lo: Int, hi: Int, root: Int, intervals: [Int]) -> Int {
    let other = d > 0 ? d - 7 : d + 7
    let mid = (lo + hi) / 2
    let floor = min(lo, floorNote)
    let ceiling = max(hi, ceilingNote)
    func fits(_ c: Int) -> Bool {
      let a = shift(lo, by: c, root: root, intervals: intervals)
      let b = shift(hi, by: c, root: root, intervals: intervals)
      // `shift` folds into 0…127; a fold means it didn't fit
      return a >= floor && b <= ceiling && (a - lo) * c >= 0 && (b - hi) * c >= 0
    }
    func move(_ c: Int) -> Int { abs(shift(mid, by: c, root: root, intervals: intervals) - mid) }
    var ranked = [d, other].sorted { a, b in
      let ma = move(a)
      let mb = move(b)
      if ma != mb { return ma < mb }
      return mid < 60 ? a < b : a > b
    }
    if !fits(ranked[0]) && fits(ranked[1]) { ranked.swapAt(0, 1) }
    return ranked[0]
  }
}
