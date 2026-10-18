import Testing

@testable import DJCore

// ROADMAP 6.5's exit metric: `MusicalityReport.hasBeat`, a kick and a snare in every section
// where the genre's style has one (`DJMusicality.beatStyle`).

private func drum(_ tick: Int, _ note: Int, net: String = "drums") -> NoteEvent {
  NoteEvent(tick: tick, net: net, group: "drums", note: note, velocity: 100, channel: 10, steps: 1)
}

/// Kick on 1 and 3, snare on 2 and 4, in each of `bars` bars from `start` (a tick offset).
private func beat(from start: Int, bars: Range<Int>) -> [NoteEvent] {
  bars.flatMap { b in
    [
      drum(start + 16 * b + 1, 36), drum(start + 16 * b + 5, 38), drum(start + 16 * b + 9, 36),
      drum(start + 16 * b + 13, 38),
    ]
  }
}

private func project(_ sections: [(String, Int)]) -> Project {
  var p = Project()
  p.structure = sections.map { Section(name: $0.0, steps: $0.1) }
  return p
}

private let dance = [
  "techno", "house", "edm", "trance", "dnb", "dubstep", "speedcore", "garage",
  "trap",
]
private let chill = ["lofi", "jazz", "bossa"]

/// What beats' composer plays (no pass), or the deck with every fix, as a report with the genre.
private func report(_ genre: String, fixes: DJMusicality.Fixes? = nil) -> MusicalityReport {
  let spec = TrackSpec(genre: genre, seed: 42, structure: "standard")
  var p = spec.project()
  if let fixes { p = DJMusicality.apply(p, spec: spec, fixes: fixes) }
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls, genre: genre)
}

struct BeatTests {
  /// Every catalogue genre has a style but ambient; verses and choruses always expect one,
  /// intros, outros, breakdowns and bridges never.
  @Test func styleTableCoversTheCatalogue() {
    #expect(DJMusicality.beatStyle(genre: "ambient") == nil)
    #expect(DJMusicality.beatStyle(genre: "polka") == nil)
    for g in BeatsTables.shared.genreIDs where g != "ambient" {
      let style = DJMusicality.beatStyle(genre: g)
      #expect(style != nil, "\(g) has a beat style")
      guard let style else { continue }
      #expect(style.isSuperset(of: ["verse", "chorus"]), "\(g)")
      #expect(style.isDisjoint(with: ["intro", "outro", "breakdown", "bridge"]), "\(g)")
    }
  }

  /// A section has a beat when half its bars carry a kick and a snare together; fills don't
  /// count, and hasBeat is the share of the style's sections that have one.
  @Test func sectionsScoreExactly() {
    let p = project([("intro", 64), ("verse", 64), ("chorus", 64), ("outro", 64)])
    var log = beat(from: 128, bars: 0..<4)  // the chorus
    log += [drum(64 + 49, 38, net: "fill-1"), drum(64 + 53, 38, net: "fill-1")]  // verse fill
    log += (0..<4).map { drum(64 + 16 * $0 + 1, 36) }  // verse: four on the floor, no snare
    log += beat(from: 192, bars: 0..<1)  // the outro: one bar of four

    let r = MusicalityReport(project: p, log: log, genre: "techno")
    #expect(r.beatBySection.map(\.section) == ["intro", "verse", "chorus", "outro"])
    #expect(r.beatBySection.map(\.beat) == [false, false, true, false])
    #expect(r.hasBeat == 0.5, "verse and chorus expected, the chorus has one")
    #expect(r.dictionary["hasBeat"] as? Double == 0.5)
    #expect((r.dictionary["beatBySection"] as? [[String: Any]])?.count == 4)

    #expect(MusicalityReport(project: p, log: log).hasBeat == nil, "no genre")
    #expect(MusicalityReport(project: p, log: log, genre: "ambient").hasBeat == nil)
    let introOnly = project([("intro", 64), ("outro", 64)])
    #expect(MusicalityReport(project: introOnly, log: log, genre: "techno").hasBeat == nil)

    // two bars of four is half: a beat
    let half = MusicalityReport(
      project: project([("verse", 64)]), log: beat(from: 0, bars: 0..<2), genre: "funk")
    #expect(half.hasBeat == 1)
    let quarter = MusicalityReport(
      project: project([("verse", 64)]), log: beat(from: 0, bars: 0..<1), genre: "funk")
    #expect(quarter.hasBeat == 0)
  }

  /// Survey of beats' composer at seed 42, standard structure, before any pass: the chill
  /// family's verses and choruses never play a kick and snare (the theme table activates them
  /// only in buildup / drop / pre-chorus), so they read 0; the dance genres read 1; ambient has
  /// no beat to expect. Exactly lofi, jazz and bossa fail today (ROADMAP 6.5's beats half).
  @Test func surveyEveryGenreBeforeThePass() {
    var failing: [String] = []
    for g in BeatsTables.shared.genreIDs.sorted() {
      let r = report(g)
      if g == "ambient" {
        #expect(r.hasBeat == nil, "ambient")
        continue
      }
      #expect(r.hasBeat != nil, "\(g) has a section that expects a beat")
      if dance.contains(g) { #expect(r.hasBeat == 1, "\(g): \(r.beatBySection)") }
      if chill.contains(g) { #expect(r.hasBeat == 0, "\(g): \(r.beatBySection)") }
      if (r.hasBeat ?? 1) < 1 { failing.append(g) }
    }
    #expect(failing == chill.sorted(), "genres without a beat where the style has one")
  }

  /// The pass keeps the dance genres' beat: every fix on, they still read 1.
  @Test func danceGenresKeepTheirBeatThroughThePass() {
    for g in dance {
      let r = report(g, fixes: .all)
      #expect(r.hasBeat == 1, "\(g): \(r.beatBySection)")
    }
  }
}
