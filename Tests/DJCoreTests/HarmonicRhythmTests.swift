import Testing

@testable import DJCore

// `.harmonicRhythm` (ROADMAP 6.3, dj first): `SectionHarmony`'s half-bar slots filled so the
// band's chord changes at its own rate per section — intros, breakdowns and outros hold each
// chord 2 bars, a buildup's last half-bar is the V of what follows, the bar into a chorus
// plays 2 chords, and drops keep 1 per bar. Measured on the plan (`note(_:group:step:)`, what
// the runner and `NoteLog` play through) against the pad's own chord per bar.

private let genres = [
  "trance", "techno", "house", "edm", "synthwave", "lofi", "country", "funk", "metal", "reggae",
]
private let seeds: [Double] = [42, 7, 1234]
private let both: DJMusicality.Fixes = [.sectionHarmony, .harmonicRhythm]

private func played(_ genre: String, _ seed: Double, structure: String = "standard") -> Project {
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  return DJMusicality.apply(spec.project(), spec: spec)
}

/// Every played project of `genres` × `seeds` × structures with a rhythm plan, and the plan.
nonisolated(unsafe) private let songs: [(name: String, project: Project, plan: SectionHarmony)] = {
  var out: [(String, Project, SectionHarmony)] = []
  for structure in ["standard", "extended"] {
    for genre in genres {
      for seed in seeds {
        let p = played(genre, seed, structure: structure)
        if let h = SectionHarmony(project: p, fixes: both) {
          out.append(("\(genre) \(seed) \(structure)", p, h))
        }
      }
    }
  }
  return out
}()

/// The pitch class the band's chord root is on at `step`: the pad's root in that bar, moved by
/// the plan (any group: a diatonic shift moves a pitch class the same in every octave). nil
/// without a pad chord in that bar.
private func bandRoot(_ p: Project, _ h: SectionHarmony, step: Int) -> Int? {
  let (chords, bars) = DJMusicality.padChords(p)
  guard bars > 0, let r = chords[(step / 16) % bars]?.first, !h.groups.isEmpty else { return nil }
  return h.note(48 + r, group: 0, step: step) % 12
}

private func rise(_ from: Int, _ to: Int) -> Int { ((to - from) % 12 + 12) % 12 }

/// The section index `k`'s end step.
private func sectionEnd(_ h: SectionHarmony, _ k: Int) -> Int {
  k + 1 < h.start.count ? h.start[k + 1] : h.end
}

struct HarmonicRhythmTests {
  /// Neither flag: no plan. `.sectionHarmony` alone is the old plan (no tails, every cycle slot
  /// the section's shift). `.harmonicRhythm` alone moves no section (degrees all 0).
  @Test func flags() throws {
    let (_, p, _) = try #require(songs.first)
    #expect(SectionHarmony(project: p, fixes: []) == nil)
    #expect(SectionHarmony.playing(p, fixes: []) == nil)
    if let old = SectionHarmony(project: p) {
      #expect(old == SectionHarmony(project: p, fixes: [.sectionHarmony]))
      #expect(old.tail.allSatisfy { $0 == SectionHarmony.noTail })
    }
    let rhythm = try #require(SectionHarmony(project: p, fixes: [.harmonicRhythm]))
    #expect(rhythm.degrees.allSatisfy { $0 == 0 })
    #expect(rhythm.tail.count == rhythm.start.count * SectionHarmony.tailSlots)
    #expect(rhythm.slots.count == rhythm.start.count * SectionHarmony.slotsPerCycle)
    #expect(SectionHarmony.playing(p, fixes: [.harmonicRhythm]) == rhythm)
    #expect(SectionHarmony.playing(p, fixes: .all) == SectionHarmony(project: p, fixes: .all))
  }

  /// Intros, breakdowns and outros change chord every 2 bars: each odd bar of a 2-bar pair
  /// (on the song's grid) plays the even bar's chord, the section's last bar aside when a tail
  /// overrides it.
  @Test func holdingSectionsChangeEveryTwoBars() throws {
    var checked = 0
    for (name, p, h) in songs {
      let (_, padBars) = DJMusicality.padChords(p)
      guard padBars >= 2, 4 % padBars == 0 else { continue }
      for (k, s) in p.structure.enumerated()
      where SectionHarmony.holdingSections.contains(s.name) {
        let end = sectionEnd(h, k)
        let tailed = h.tail[(k * 2)..<(k * 2 + 2)].contains { $0 != SectionHarmony.noTail }
        for bar in stride(from: h.start[k] / 16 + 1, to: end / 16, by: 1) where bar % 2 == 1 {
          if tailed && bar == end / 16 - 1 { continue }
          guard bar - 1 >= h.start[k] / 16,
            let a = bandRoot(p, h, step: (bar - 1) * 16), let b = bandRoot(p, h, step: bar * 16)
          else { continue }
          #expect(a == b, "\(name) \(s.name) bar \(bar): \(a) → \(b)")
          checked += 1
        }
      }
    }
    #expect(checked > 0)
  }

  /// Intro bass: its notes in each odd bar are the even bar's chord's. On the plan, the bass's
  /// own group plays the pad root of each odd bar of a holding section as the even bar's (its
  /// map is per group: the bass is moved in its own register). And where a bass plays there,
  /// as `NoteLog` captures it: the bass downbeat on the same pitch class, where both bars'
  /// bass starts on its pad root.
  ///
  /// (The composer brings the bass in after the intro: the `NoteLog` half alone, intros only,
  /// checked nothing over all of `songs`. Over every holding section it checks 32 bars (the
  /// breakdowns and outros that keep a bass), the plan half 412.)
  @Test func introBassChangesEveryTwoBars() throws {
    var checked = 0
    var played = 0
    for (name, p, h) in songs {
      let (chords, padBars) = DJMusicality.padChords(p)
      guard padBars >= 2, 4 % padBars == 0, let bass = h.groupIndex("bass") else { continue }
      let log = NoteLog.captureAll(p, harmony: h).notes
      for (k, s) in p.structure.enumerated()
      where SectionHarmony.holdingSections.contains(s.name) {
        let end = sectionEnd(h, k)
        let tailed = h.tail[(k * 2)..<(k * 2 + 2)].contains { $0 != SectionHarmony.noTail }
        // the plan: the pad's root in the bass's octave, as the bass group plays it
        for bar in stride(from: h.start[k] / 16 + 1, to: end / 16, by: 1) where bar % 2 == 1 {
          if tailed && bar == end / 16 - 1 { continue }
          guard bar - 1 >= h.start[k] / 16, let a = chords[(bar - 1) % padBars]?.first,
            let b = chords[bar % padBars]?.first
          else { continue }
          let even = h.note(36 + a, group: bass, step: (bar - 1) * 16) % 12
          let odd = h.note(36 + b, group: bass, step: bar * 16) % 12
          #expect(even == odd, "\(name) \(s.name) bass plan bar \(bar): \(even) → \(odd)")
          #expect(odd == bandRoot(p, h, step: bar * 16), "\(name) \(s.name) bar \(bar)")
          checked += 1
        }
        // what a bass there plays
        var downbeat: [Int: Int] = [:]
        for n in log
        where n.group == "bass" && !n.isDrum && (n.tick - 1) % 16 == 0
          && n.tick - 1 >= h.start[k] && n.tick - 1 < end && downbeat[(n.tick - 1) / 16] == nil
        {
          downbeat[(n.tick - 1) / 16] = n.note % 12
        }
        for (bar, pc) in downbeat where bar % 2 == 1 {
          if tailed && bar == end / 16 - 1 { continue }
          guard let prev = downbeat[bar - 1], let r0 = bandRoot(p, h, step: (bar - 1) * 16),
            let r1 = bandRoot(p, h, step: bar * 16), prev == r0
          else { continue }
          #expect(r0 == r1, "\(name) \(s.name) bar \(bar)")
          #expect(pc == prev, "\(name) \(s.name) bass bar \(bar): \(prev) → \(pc)")
          played += 1
        }
      }
    }
    print("intro bass: \(checked) planned bars, \(played) played")
    #expect(checked > 0)
  }

  /// A buildup's last half-bar is a cadence into the next section's first chord: its root
  /// rises a fourth (V → I) or a whole step (♭VII → I).
  @Test func buildupEndsOnTheDominant() throws {
    var checked = 0
    for (name, p, h) in songs {
      for k in 0..<(p.structure.count - 1) where p.structure[k].name == "buildup" {
        let end = sectionEnd(h, k)
        guard let last = bandRoot(p, h, step: end - 1), let next = bandRoot(p, h, step: end)
        else { continue }
        #expect([5, 2].contains(rise(last, next)), "\(name): \(last) → \(next)")
        checked += 1
      }
    }
    #expect(checked > 0)
  }

  /// The bar before a chorus (not from a drop or a chorus) changes chord twice — at the bar
  /// and at the half-bar — and its second half is a cadence into the chorus.
  @Test func chorusRunInPlaysTwoChords() throws {
    var checked = 0
    for (name, p, h) in songs {
      for k in 0..<(p.structure.count - 1)
      where p.structure[k + 1].name == "chorus"
        && !["chorus", "drop"].contains(p.structure[k].name)
      {
        let end = sectionEnd(h, k)
        guard let before = bandRoot(p, h, step: end - 17),
          let first = bandRoot(p, h, step: end - 16),
          let second = bandRoot(p, h, step: end - 8), let chorus = bandRoot(p, h, step: end)
        else { continue }
        #expect(first != second, "\(name): no change at the half-bar")
        #expect(before != first, "\(name): no change at the bar")
        #expect([5, 2].contains(rise(second, chorus)), "\(name): \(second) → \(chorus)")
        checked += 1
      }
    }
    #expect(checked > 0)
  }

  /// Drops keep 1 chord per bar: both half-bars of every bar play the same chord, and it is
  /// the one the plan without `.harmonicRhythm` plays.
  @Test func dropsKeepOneChordPerBar() throws {
    var checked = 0
    for (name, p, h) in songs {
      let old = SectionHarmony(project: p, fixes: [.sectionHarmony])
      for (k, s) in p.structure.enumerated() where s.name == "drop" {
        for bar in (h.start[k] / 16)..<(sectionEnd(h, k) / 16) {
          guard let a = bandRoot(p, h, step: bar * 16), let b = bandRoot(p, h, step: bar * 16 + 8)
          else { continue }
          #expect(a == b, "\(name) drop bar \(bar)")
          if let old {
            #expect(bandRoot(p, old, step: bar * 16) == a, "\(name) drop bar \(bar)")
          }
          checked += 1
        }
      }
    }
    #expect(checked > 0)
  }

  /// Every in-key note stays in key at every half-bar, and every mapped note is in 0…127.
  @Test func inKeyIsUnchanged() throws {
    for (name, p, h) in songs.prefix(8) {
      let root = p.rootNote ?? 60
      let key = Set(
        scaleIntervals((p.scaleName.isEmpty ? "Major" : p.scaleName) + "Scale").map {
          (root + $0) % 12
        })
      for step in stride(from: 0, to: h.end, by: SectionHarmony.slotSteps) {
        for g in h.groups.indices {
          for n in 0..<128 {
            let m = h.note(n, group: g, step: step)
            #expect((0..<128).contains(m))
            if key.contains(n % 12) && !key.contains(m % 12) {
              Issue.record("\(name) step \(step): \(n) → \(m)")
            }
          }
        }
      }
    }
  }

  /// `WaveRunner.prepare` builds the plan under either flag.
  @Test func prepareBuildsThePlanUnderEitherFlag() throws {
    let (_, p, _) = try #require(songs.first)
    #expect(WaveRunner.prepare(p, sampleRate: 22_050, opts: WaveOptions()).harmony == nil)
    var o = WaveOptions()
    o.musicality = [.harmonicRhythm]
    let rhythm = WaveRunner.prepare(p, sampleRate: 22_050, opts: o)
    #expect(rhythm.harmony == SectionHarmony(project: p, fixes: [.harmonicRhythm]))
    #expect(rhythm.harmony != nil)
    #expect(rhythm.lanes.contains { $0.harmonyGroup >= 0 })
  }
}
