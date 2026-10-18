import Testing

@testable import DJCore

// `SectionHarmony` (ROADMAP 6.3, dj first): the per-section diatonic shift plan the runner will
// play the tonal lanes through. Pure; not wired into playback yet.

private func played(_ genre: String, _ seed: Double = 42, structure: String? = "standard")
  -> Project
{
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  return DJMusicality.apply(spec.project(), spec: spec)
}

/// The first played project in `genres` × `structures` × seeds 1…6 with a section named `name`.
private func withSection(_ name: String) -> Project? {
  for structure in ["extended", "standard", "jam", "ab", "build", "drop"] {
    for genre in BeatsTables.shared.genres.keys.sorted() {
      for seed in 1...6 {
        let p = played(genre, Double(seed), structure: structure)
        if p.structure.contains(where: { $0.name == name }), SectionHarmony(project: p) != nil {
          return p
        }
      }
    }
  }
  return nil
}

private func pitchClasses(_ p: Project) -> Set<Int> {
  let root = p.rootNote ?? 60
  let name = p.scaleName.isEmpty ? "Major" : p.scaleName
  return Set(scaleIntervals(name + "Scale").map { (root + $0) % 12 })
}

struct SectionHarmonyTests {
  /// Loops, keys that aren't seven notes and songs with nothing to move get no plan.
  @Test func nilCases() throws {
    #expect(SectionHarmony(project: played("techno", structure: nil)) == nil)
    var p = played("trance")
    #expect(p.structure.count > 1)
    for scale in ["Pentatonic", "MinPentatonic", "Blues"] {
      p.scaleName = scale
      #expect(SectionHarmony(project: p) == nil, "\(scale)")
    }
    var flat = played("trance")
    flat.structure = flat.structure.map {
      var s = $0
      if SectionHarmony.degreeShift(section: s.name, intervals: [0, 2, 4, 5, 7, 9, 11]) != 0 {
        s.name = "verse"
      }
      return s
    }
    #expect(flat.structure.count > 1)
    #expect(SectionHarmony(project: flat) == nil)
  }

  /// The degree table: bridge +5, solo +4, breakdown to vi in a major-third key and to III in a
  /// minor-third one, everything else home.
  @Test func degreeTable() {
    let major = scaleIntervals("MajorScale")
    let minor = scaleIntervals("MinorScale")
    #expect(SectionHarmony.degreeShift(section: "bridge", intervals: major) == 5)
    #expect(SectionHarmony.degreeShift(section: "solo", intervals: minor) == 4)
    #expect(SectionHarmony.degreeShift(section: "breakdown", intervals: major) == -2)
    #expect(SectionHarmony.degreeShift(section: "breakdown", intervals: minor) == 2)
    #expect(
      SectionHarmony.degreeShift(section: "breakdown", intervals: scaleIntervals("DorianScale"))
        == 2)
    #expect(
      SectionHarmony.degreeShift(section: "breakdown", intervals: scaleIntervals("MixolydianScale"))
        == -2)
    for name in ["intro", "verse", "chorus", "drop", "buildup", "outro"] {
      #expect(SectionHarmony.degreeShift(section: name, intervals: major) == 0)
    }
  }

  /// The diatonic shift itself: C major, C4 up five degrees is A4, a third down is A3, E → C,
  /// a chromatic note keeps its offset, and nothing leaves 0…127.
  @Test func diatonicShift() {
    let major = scaleIntervals("MajorScale")
    #expect(SectionHarmony.shift(60, by: 5, root: 0, intervals: major) == 69)
    #expect(SectionHarmony.shift(60, by: -2, root: 0, intervals: major) == 57)
    #expect(SectionHarmony.shift(64, by: -2, root: 0, intervals: major) == 60)
    #expect(SectionHarmony.shift(61, by: 1, root: 0, intervals: major) == 63)
    #expect(SectionHarmony.shift(71, by: 1, root: 0, intervals: major) == 72)
    #expect(SectionHarmony.shift(48, by: 4, root: 9, intervals: scaleIntervals("MinorScale")) == 55)
    for n in 0..<128 {
      for d in -6...6 {
        let m = SectionHarmony.shift(n, by: d, root: 2, intervals: major)
        #expect((0..<128).contains(m))
      }
    }
  }

  /// The octave per group: the nearer way round, unless that takes a bass under E1.
  @Test func octavePerGroup() {
    let major = scaleIntervals("MajorScale")
    #expect(SectionHarmony.octave(5, lo: 60, hi: 72, root: 0, intervals: major) == -2)
    #expect(SectionHarmony.octave(4, lo: 60, hi: 72, root: 0, intervals: major) == -3)
    #expect(SectionHarmony.octave(-2, lo: 60, hi: 72, root: 0, intervals: major) == -2)
    // a bass from E1: a fourth down would leave the floor, so it goes up a fifth
    #expect(SectionHarmony.octave(4, lo: 28, hi: 40, root: 0, intervals: major) == 4)
    // a lead at the top goes down even when up is nearer
    #expect(SectionHarmony.octave(2, lo: 100, hi: 107, root: 0, intervals: major) == -5)
  }

  /// Every mapped note of every group and section is in key (for an in-key note), in 0…127,
  /// and moved by the section's degree in the octave the group chose; home sections are
  /// untouched; a note's group outside the plan comes back as it was.
  @Test func mappedNotesAreInKeyAndInRange() throws {
    for genre in ["trance", "techno", "house", "pop", "jazz", "lofi"] {
      let p = played(genre)
      guard let h = SectionHarmony(project: p) else { continue }
      let key = pitchClasses(p)
      #expect(!h.groups.isEmpty)
      #expect(h.slots.count == h.start.count * SectionHarmony.slotsPerCycle)
      #expect(h.maps.count == h.shifts.count * h.groups.count * 128)
      for (k, s) in h.start.enumerated() {
        for g in h.groups.indices {
          for n in 0..<128 {
            let m = h.note(n, group: g, step: s)
            #expect((0..<128).contains(m))
            if h.degrees[k] == 0 { #expect(m == n) }
            if key.contains(n % 12) { #expect(key.contains(m % 12), "\(genre) \(n)→\(m)") }
          }
        }
      }
      #expect(h.note(60, group: h.groups.count, step: 0) == 60)
      #expect(h.note(-1, group: 0, step: 0) == -1)
      // the bound notes of each group stay within [E1, C8] or where they already were
      for (id, nb) in p.nets.pairs where nb.role != "control" {
        guard let g = h.groupIndex(NoteLog.groupName(nb, id: id)) else { continue }
        for b in nb.bindings.values where !isDrumChannel(b.channel) {
          for s in h.start {
            let m = h.note(b.note, group: g, step: s)
            #expect(m >= min(b.note, 28) - 12 && m <= max(b.note, 108) + 12, "\(genre) \(id)")
          }
        }
      }
    }
  }

  /// A breakdown in a major key moves to the relative minor, in a minor key to the relative
  /// major: the group's root lands on vi / III.
  @Test func breakdownGoesRelative() throws {
    let p = played("trance")
    let h = try #require(SectionHarmony(project: p))
    let k = try #require(p.structure.firstIndex { $0.name == "breakdown" })
    let intervals = scaleIntervals((p.scaleName.isEmpty ? "Major" : p.scaleName) + "Scale")
    let expected = SectionHarmony.breakdownShift(intervals)
    #expect(h.degrees[k] == expected)
    let root = 48 + (p.rootNote ?? 60) % 12
    let target = (root + intervals[(expected + 7) % 7]) % 12
    for g in h.groups.indices {
      #expect(h.note(root, group: g, step: h.start[k]) % 12 == target)
    }
  }

  /// A bridge plays +5 degrees and a solo +4 (octave aside), when a song has one.
  @Test func bridgeAndSolo() throws {
    for (name, d) in [("bridge", 5), ("solo", 4)] {
      guard let p = withSection(name) else {
        Issue.record("no project with a \(name)")
        continue
      }
      let h = try #require(SectionHarmony(project: p))
      let k = try #require(p.structure.firstIndex { $0.name == name })
      #expect(h.degrees[k] == d)
      let shift = try #require(h.shifts.firstIndex(of: d))
      for g in h.groups.indices {
        let pick = h.groupDegrees[shift * h.groups.count + g]
        #expect(pick == d || pick == d - 7)
      }
    }
  }

  /// The section edges are `EnergyCurve`'s, and every slot of a section holds its shift.
  @Test func edgesMatchEnergyCurve() throws {
    var checked = 0
    for genre in ["trance", "techno", "pop"] {
      let p = played(genre)
      guard let h = SectionHarmony(project: p), let c = EnergyCurve(project: p) else { continue }
      #expect(h.start == c.start, "\(genre)")
      for k in h.start.indices {
        #expect(h.section(at: h.start[k]) == k)
        if k > 0 { #expect(h.section(at: h.start[k] - 1) == k - 1) }
        let row = h.slots[
          (k * SectionHarmony.slotsPerCycle)..<((k + 1) * SectionHarmony.slotsPerCycle)]
        #expect(Set(row).count == 1)
        #expect((row.first! == 0) == (h.degrees[k] == 0))
      }
      checked += 1
    }
    #expect(checked > 0)
  }

  /// `harmony: nil` is the old capture; with a plan, home sections and drums are unchanged and
  /// the moved sections' tonal notes are the plan's.
  @Test func noteLogHarmony() throws {
    let p = played("trance")
    let h = try #require(SectionHarmony(project: p))
    let home = NoteLog.captureAll(p, harmony: nil)
    let plain = home.notes
    #expect(NoteLog.capture(p) == plain)
    let all = NoteLog.captureAll(p, harmony: h)
    let moved = all.notes
    #expect(moved.count == plain.count)
    var changed = 0
    for (a, b) in zip(plain, moved) {
      #expect(a.tick == b.tick && a.net == b.net && a.velocity == b.velocity)
      let k = h.section(at: a.tick - 1)
      if a.isDrum || h.degrees[k] == 0 || h.groupIndex(a.group) == nil {
        #expect(a.note == b.note)
      } else {
        #expect(b.note == h.note(a.note, group: h.groupIndex(a.group)!, step: a.tick - 1))
        if a.note != b.note { changed += 1 }
      }
    }
    #expect(changed > 0)
    #expect(all.controls == home.controls)
  }
}
