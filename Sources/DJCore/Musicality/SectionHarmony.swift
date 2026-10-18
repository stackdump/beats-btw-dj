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
/// song's first step), all equal to the section's shift until harmonic rhythm fills them. Built
/// from the played project off the audio thread; `note(_:group:step:)` is a lookup the runner
/// may call per note.
public struct SectionHarmony: Sendable, Equatable {
  /// First step of each section, ascending (the same edges as `EnergyCurve.start`).
  public var start: [Int]
  /// Each section's degree shift.
  public var degrees: [Int]
  /// The tonal groups the maps cover (`NoteLog.groupName`), in net order.
  public var groups: [String]
  /// The distinct non-zero shifts the slots refer to (slot value k ≥ 1 is `shifts[k - 1]`).
  public var shifts: [Int]
  /// `slotsPerCycle` entries per section: 0 = home, k = `shifts[k - 1]`.
  public var slots: [UInt8]
  /// The degree shift each group actually plays per shift, octave chosen
  /// (`(k - 1) * groups.count + group`): `shifts[k - 1]` or it ∓ 7.
  public var groupDegrees: [Int]
  /// 128 notes per (shift, group), same index order as `groupDegrees`.
  public var maps: [UInt8]

  /// Half-bar slots in a 4-bar cycle, and their length in steps.
  public static let slotsPerCycle = 8
  public static let slotSteps = 8
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

  /// The plan for `project`, or nil: a loop (one section or none), a key that isn't seven notes
  /// (pentatonic, blues), a song with no section that moves, or no tonal part to move.
  public init?(project: Project) {
    guard project.structure.count > 1 else { return nil }
    let intervals = scaleIntervals(
      (project.scaleName.isEmpty ? "Major" : project.scaleName) + "Scale")
    guard intervals.count == 7 else { return nil }
    var start: [Int] = []
    var degrees: [Int] = []
    var at = 0
    for s in project.structure {
      start.append(at)
      degrees.append(Self.degreeShift(section: s.name, intervals: intervals))
      at += s.steps
    }
    guard degrees.contains(where: { $0 != 0 }) else { return nil }

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

    let root = ((project.rootNote ?? 60) % 12 + 12) % 12
    var shifts: [Int] = []
    for d in degrees where d != 0 && !shifts.contains(d) { shifts.append(d) }
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
    var slots: [UInt8] = []
    for d in degrees {
      let k = d == 0 ? 0 : UInt8(shifts.firstIndex(of: d)! + 1)
      slots.append(contentsOf: repeatElement(k, count: Self.slotsPerCycle))
    }
    self.start = start
    self.degrees = degrees
    self.groups = groups
    self.shifts = shifts
    self.slots = slots
    self.groupDegrees = groupDegrees
    self.maps = maps
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
    let slot = (max(0, step) / Self.slotSteps) % Self.slotsPerCycle
    let k = Int(slots[section(at: step) * Self.slotsPerCycle + slot])
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
