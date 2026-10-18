import Testing

@testable import DJCore

// StageControlTimeline: the control schedule of a real composed (and dj-played) song.

enum TimelineFixture {
  /// techno, seed 42, the standard structure, as a deck plays it (every dj fix on).
  static func played(
    genre: String = "techno", seed: Double = 42, structure: String = "standard"
  ) -> Project {
    let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
    return DJMusicality.apply(spec.project(), spec: spec, fixes: .all)
  }

  static func timeline(
    genre: String = "techno", seed: Double = 42, structure: String = "standard"
  ) -> StageControlTimeline {
    StageControlTimeline.build(played(genre: genre, seed: seed, structure: structure))
  }
}

@Suite struct StageControlTimelineTests {
  @Test func sectionsMatchTheStructure() {
    let p = TimelineFixture.played()
    let t = StageControlTimeline.build(p)
    let sections = Deck.SectionInfo.sections(of: p)
    #expect(t.sections == sections)
    #expect(t.count(.section) == sections.count)
    for (k, s) in sections.enumerated() {
      let e = t.event(.section, k)
      #expect(e.tick == s.startTick && e.length == s.steps && e.name == s.name && e.index == k)
    }
    #expect(t.totalSteps == sections.reduce(0) { $0 + $1.steps })
    #expect(t.sectionIndex(at: Double(sections[1].startTick)) == 1)
    #expect(t.sectionIndex(at: Double(sections[1].startTick) - 0.5) == 0)
  }

  @Test func phrasesTileEverySectionInChunksOfAtMostFourBars() {
    let t = TimelineFixture.timeline()
    var covered = 0
    for i in 0..<t.count(.phrase) {
      let e = t.event(.phrase, i)
      #expect(e.tick == covered, "phrases are contiguous")
      #expect(e.length > 0 && e.length <= StageControlTimeline.maxPhraseSteps)
      #expect(e.index == i)
      covered = e.end
    }
    #expect(covered == t.totalSteps)
    // every section starts a phrase
    for s in t.sections {
      #expect(t.last(.phrase, atOrBefore: Double(s.startTick))?.tick == s.startTick)
    }
  }

  @Test func everyBuildupPairsWithTheDropAfterIt() {
    let t = TimelineFixture.timeline()
    #expect(t.count(.buildup) > 0, "the standard techno song has a buildup")
    for i in 0..<t.count(.buildup) {
      let b = t.event(.buildup, i)
      let drop = t.next(.drop, after: Double(b.tick))
      #expect(drop?.tick == b.end, "the drop starts where its buildup ends")
      #expect(drop?.index == b.index)
      #expect(t.sections[b.index - 1].name == b.name)
    }
  }

  @Test func theFuseBurnsDownOverTheBuildup() {
    let t = TimelineFixture.timeline()
    let b = t.event(.buildup, 0)
    #expect(t.fuse(at: Double(b.tick) - 1) == nil)
    #expect(t.fuse(at: Double(b.tick))?.progress == 0)
    let half = t.fuse(at: Double(b.tick) + Double(b.length) / 2)?.progress ?? -1
    #expect(abs(half - 0.5) < 1e-9)
    #expect(t.fuse(at: Double(b.end)) == nil, "lit no more on the drop")
    // ticksUntil agrees
    let until = t.ticksUntil(.drop, from: Double(b.tick) + 3) ?? -1
    #expect(until == Double(b.length) - 3)
  }

  @Test func dropGapsSitAtTheEndOfEachBuildup() {
    let t = TimelineFixture.timeline()
    #expect(t.count(.dropGap) > 0)
    for i in 0..<t.count(.dropGap) {
      let g = t.event(.dropGap, i)
      #expect(g.length == DJMusicality.dropGapSteps)
      let b = t.covering(.buildup, at: Double(g.tick))
      #expect(b?.end == g.end, "the gap is the buildup's last beat")
      #expect(t.covering(.dropGap, at: Double(g.tick) + 1)?.tick == g.tick)
    }
    // the kick out (a dance buildup into a drop) is the buildup's last bar
    for i in 0..<t.count(.kickOut) {
      let k = t.event(.kickOut, i)
      #expect(t.covering(.buildup, at: Double(k.tick))?.end == k.end)
    }
  }

  @Test func fillsEndOnSectionBoundaries() {
    let t = TimelineFixture.timeline()
    #expect(t.count(.fill) > 0, "techno has drum fills")
    let starts = Set(t.sections.map(\.startTick) + [t.totalSteps])
    for i in 0..<t.count(.fill) {
      let f = t.event(.fill, i)
      #expect(starts.contains(f.end), "fill \(f.name) ends at \(f.end)")
      #expect(f.length == 4 || f.length == 8)
    }
  }

  @Test func rolesEnterAndLeaveWithTheStructure() {
    let t = TimelineFixture.timeline()
    #expect(t.roles.contains("kick") && t.roles.contains("bass"))
    #expect(t.count(.enter) + t.count(.exit) > 0)
    // isActive replays the edges
    for r in t.roles {
      var on = t.initiallyActive[t.roles.firstIndex(of: r)!]
      #expect(
        t.isActive(role: r, at: 0) == on || t.events(from: 0, to: 1).contains { $0.name == r })
      for e in t.events where (e.kind == .enter || e.kind == .exit) && e.name == r {
        #expect((e.kind == .enter) != on, "\(r) at \(e.tick): an edge changes the state")
        on = e.kind == .enter
        #expect(t.isActive(role: r, at: Double(e.tick)) == on)
      }
    }
    // a role that enters is silent on the step before
    if t.count(.enter) > 0 {
      let e = t.event(.enter, 0)
      if e.tick > 0 { #expect(!t.isActive(role: e.name, at: Double(e.tick) - 1)) }
    }
  }

  @Test func theSongStops() {
    let t = TimelineFixture.timeline()
    #expect(t.count(.stop) == 1)
    let s = t.event(.stop, 0)
    #expect(abs(s.tick - t.totalSteps) <= 1)
  }

  @Test func windowsAndLookAhead() {
    let t = TimelineFixture.timeline()
    let s1 = t.sections[1]
    let window = t.events(from: s1.startTick, to: s1.startTick + 1)
    #expect(window.contains { $0.kind == .section && $0.index == 1 })
    #expect(window.allSatisfy { $0.tick == s1.startTick })
    #expect(t.events(from: 5, to: 5).isEmpty)
    #expect(t.next(.section, after: Double(s1.startTick))?.index == 2)
    #expect(t.next(.section, after: Double(s1.startTick) - 0.5)?.index == 1)
    #expect(t.last(.section, atOrBefore: Double(s1.startTick))?.index == 1)
    #expect(t.next(.stop, after: Double(t.totalSteps + 10)) == nil)
  }

  @Test func deterministicPerConfigurationAndSeededByIt() {
    let a = TimelineFixture.timeline()
    let b = TimelineFixture.timeline()
    #expect(a == b)
    let c = TimelineFixture.timeline(seed: 43)
    #expect(a.seed != c.seed)
    #expect(StageControlTimeline.empty.events.isEmpty)
    #expect(StageControlTimeline.trailingNumber("t12") == 12)
    #expect(StageControlTimeline.trailingNumber("fill-3") == 3)
    #expect(StageControlTimeline.trailingNumber("kick") == nil)
    #expect(StageControlTimeline.trailingNumber("7") == 7)
  }
}
