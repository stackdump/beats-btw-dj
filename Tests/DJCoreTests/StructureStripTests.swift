import Testing

@testable import DJCore

// SPEC mode 24: the structure strip of canvas.js `renderTimeline` reconciled with the strip the
// app already had (SectionTimeline): beats' colours for its five names, phrase marks from the
// structure's phrase data, blocks sized by steps / total.
struct StructureStripTests {
  func rgb(_ c: ScopeColor) -> [Int] { [c.rgb8.r, c.rgb8.g, c.rgb8.b] }

  @Test func theFiveBeatsSectionsKeepBeatsColours() {
    let want: [String: [Int]] = [
      "intro": [0x4a, 0x90, 0xd9], "verse": [0x2e, 0xcc, 0x71], "chorus": [0xe9, 0x45, 0x60],
      "bridge": [0x9b, 0x59, 0xb6], "outro": [0xf5, 0xa6, 0x23],
    ]
    #expect(Set(SectionTimeline.beatsNames) == Set(want.keys))
    for (name, c) in want {
      #expect(rgb(SectionTimeline.color(name, isCurrent: true)) == c, "\(name)")
      // the block that is not playing is dimmed by the ratio the strip always used (.45 / .95)
      let k = 0.45 / 0.95
      let dim = c.map { Int((Double($0) * k).rounded()) }
      #expect(rgb(SectionTimeline.color(name, isCurrent: false)) == dim, "\(name) resting")
    }
    // and they agree with the shared palette the scopes use
    for name in SectionTimeline.beatsNames {
      #expect(
        SectionTimeline.color(name, isCurrent: true).rgb8 == ScopeColors.section(name).rgb8)
    }
  }

  @Test func otherNamesKeepTheirStableHueWhereBeatsWouldPaintThemGrey() {
    for name in ["drop", "breakdown", "buildup", "pre-chorus", "solo"] {
      let cur = SectionTimeline.color(name, isCurrent: true)
      #expect(cur.rgb8 != ScopeColors.defaultLaneColor.rgb8, "\(name) is not #888")
      // HSB at saturation 0.55: brightness 0.95 -> max channel 242, min 0.45 * that = 109
      let v = [cur.rgb8.r, cur.rgb8.g, cur.rgb8.b]
      #expect(v.max() == 242 && v.min() == 109, "\(name): \(v)")
      let rest = SectionTimeline.color(name, isCurrent: false)
      let r = [rest.rgb8.r, rest.rgb8.g, rest.rgb8.b]
      #expect(r.max() == 115 && r.min() == 52, "\(name) resting: \(r)")  // .45 and .45 * .45
      #expect(SectionTimeline.color(name, isCurrent: true) == cur, "stable")
    }
    #expect(
      SectionTimeline.color("drop", isCurrent: true)
        != SectionTimeline.color("breakdown", isCurrent: true))
  }

  @Test func hsbMatchesTheStandardModelAtTheSixCorners() {
    func c(_ h: Double) -> [Int] {
      let k = SectionTimeline.hsb(h, 1, 1)
      return [k.rgb8.r, k.rgb8.g, k.rgb8.b]
    }
    #expect(c(0) == [255, 0, 0] && c(1.0 / 6) == [255, 255, 0] && c(2.0 / 6) == [0, 255, 0])
    #expect(
      c(3.0 / 6) == [0, 255, 255] && c(4.0 / 6) == [0, 0, 255] && c(5.0 / 6) == [255, 0, 255])
    let half = SectionTimeline.hsb(0.1, 0, 0.5)
    #expect(half.rgb8 == (128, 128, 128), "no saturation is grey")
  }

  @Test func phraseMarksAppearOnlyForMoreThanOnePhrase() {
    func seg(_ n: Int, _ p: [String]) -> SectionTimeline.Segment {
      .init(name: "verse", start: 0, width: 1, isCurrent: false, phraseCount: n, phrasePattern: p)
    }
    let four = seg(4, ["A", "B", "A", "C"])
    #expect(four.hasPhrases && four.phraseLabel == "ABAC")
    #expect(four.dividers == [0.25, 0.5, 0.75], "pi / phraseCount for pi = 1...3")
    let two = seg(2, ["C", "C"])
    #expect(two.dividers == [0.5] && two.phraseLabel == "CC")
    let one = seg(1, ["A"])
    #expect(!one.hasPhrases && one.phraseLabel == nil && one.dividers.isEmpty)
    #expect(seg(0, []).dividers.isEmpty, "no phrase lists: Math.max(...[]) is never reached")
    // dividers without letters (the first role has none): still divided, nothing printed
    let bare = seg(3, [])
    #expect(bare.phraseLabel == nil && bare.dividers.count == 2)
    // the default segment is the one the old initialiser built
    let plain = SectionTimeline.Segment(name: "x", start: 0, width: 1, isCurrent: true)
    #expect(plain.phraseCount == 1 && plain.phrasePattern.isEmpty && plain.dividers.isEmpty)
  }

  @Test func sectionInfoTakesTheFirstRolesLettersAndTheLongestList() {
    var verse = Section(name: "verse", steps: 64)
    verse.phrases["bass"] = ["A"]  // the first role: one phrase...
    verse.phrases["lead"] = ["A", "B", "A", "C"]  // ...but another role has four
    var intro = Section(name: "intro", steps: 32)
    intro.phrases["kick"] = ["A", "A"]
    let bare = Section(name: "outro", steps: 16)  // no phrase data at all
    var project = Project()
    project.structure = [verse, intro, bare]
    let info = Deck.SectionInfo.sections(of: project)
    #expect(info.map(\.startTick) == [0, 64, 96])
    #expect(info[0].phraseCount == 4 && info[0].phrasePattern == ["A"], "JS: first role's letters")
    #expect(info[1].phraseCount == 2 && info[1].phrasePattern == ["A", "A"])
    #expect(info[2].phraseCount == 1 && info[2].phrasePattern.isEmpty)
  }

  @Test func aComposedSongCarriesItsPhrasesAndWidthsFollowTheSteps() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    await a.generate(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    let sections = a.sections
    #expect(sections.contains { $0.phraseCount > 1 }, "the composer's sections have phrases")
    let project = try #require(a.netProject)
    for (info, sec) in zip(sections, project.structure) {
      let lists = sec.phrases.values
      #expect(info.phraseCount == (lists.map(\.count).max() ?? 1))
      #expect(info.phrasePattern == (lists.first ?? []))
    }
    let t = try #require(a.sectionTimeline)
    let total = Double(sections.map(\.steps).reduce(0, +))
    for (seg, info) in zip(t.segments, sections) {
      #expect(abs(seg.width - Double(info.steps) / total) < 1e-12, "sized by steps / total")
      #expect(seg.phraseCount == info.phraseCount && seg.phrasePattern == info.phrasePattern)
    }
    #expect(abs(t.segments.map(\.width).reduce(0, +) - 1) < 1e-9)
  }
}

// The label's place in its block: the name and the phrase letters are one centred run with the
// CSS 4 px margin between them; the letters give way when the run does not fit.
struct SectionLabelLayoutTests {
  typealias L = SectionTimeline.LabelLayout

  @Test func aNameAloneIsCentred() {
    let r = L.run(blockWidth: 100, nameWidth: 40, lettersWidth: nil)
    #expect(r.nameX == 30 && r.lettersX == nil)
  }

  @Test func nameAndLettersAreOneRunWithTheCSSMarginBetween() {
    // block 100, name 40, letters 20: the run is 40 + 4 + 20 = 64, so it starts at 18
    let r = L.run(blockWidth: 100, nameWidth: 40, lettersWidth: 20)
    #expect(r.nameX == 18)
    #expect(r.lettersX == 62, "18 + 40 + 4")
    #expect(L.phraseGap == 4)
  }

  @Test func theLettersAreDroppedWhenTheRunDoesNotFitWithAirOnBothSides() {
    // run 64 fits a block of 68 (2 pt each side) and not one of 67
    #expect(L.run(blockWidth: 68, nameWidth: 40, lettersWidth: 20).lettersX != nil)
    let tight = L.run(blockWidth: 67, nameWidth: 40, lettersWidth: 20)
    #expect(tight.lettersX == nil, "dropped")
    #expect(tight.nameX == 13.5, "and the name is centred on its own")
  }

  @Test func aNameWiderThanItsBlockOverflowsBothSidesEqually() {
    let r = L.run(blockWidth: 30, nameWidth: 40, lettersWidth: 20)
    #expect(r.nameX == -5 && r.lettersX == nil, "cut at both edges by the view's clip")
  }
}
