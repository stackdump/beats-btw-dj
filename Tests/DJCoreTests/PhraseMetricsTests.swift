import Testing

@testable import DJCore

// ROADMAP 6.4's exit metrics on `MusicalityReport`: answered 8-bar phrases, a hook that comes
// back in later sections, chord tones in each phrase's first bar, bass ideas stated twice, where
// a phrase peaks, and leaps that recover by step. Report only: nothing here changes a note.

private func tone(
  _ tick: Int, _ group: String, _ note: Int, net: String? = nil, steps: Double = 2
) -> NoteEvent {
  NoteEvent(
    tick: tick, net: net ?? group, group: group, note: note, velocity: 100, channel: 1,
    steps: steps)
}

/// A note on bar `bar` (0-based), sixteenth `step` of it.
private func at(_ bar: Int, _ step: Int, _ group: String, _ note: Int, net: String? = nil)
  -> NoteEvent
{
  tone(16 * bar + step + 1, group, note, net: net)
}

/// One C-major triad per bar, root first, on the bar's first tick.
private func pad(bars: Int, root: Int = 60) -> [NoteEvent] {
  (0..<bars).flatMap { b in [root, root + 4, root + 7].map { tone(16 * b + 1, "harmony", $0) } }
}

private func project(_ sections: [(String, Int)]) -> Project {
  var p = Project()
  p.rootNote = 60
  p.scaleName = "Major"
  p.structure = sections.map { Section(name: $0.0, steps: $0.1) }
  return p
}

struct PhraseMetricsTests {
  /// Bars 1–8 end G then C (open, then closed: answered); bars 9–16 end C then C (closed twice:
  /// no question). A second net with only a first half has no pair.
  @Test func answerPhrasesScoreExactly() {
    let log = [
      at(0, 0, "melody", 72), at(3, 8, "melody", 67),  // question: ends on the fifth
      at(4, 0, "melody", 74), at(7, 8, "melody", 72),  // answer: ends on the tonic
      at(8, 0, "melody", 64), at(11, 8, "melody", 60),  // closed already
      at(12, 0, "melody", 62), at(15, 8, "melody", 84),
      at(0, 0, "melody", 79, net: "lead2"), at(2, 0, "melody", 77, net: "lead2"),
    ]
    let r = MusicalityReport(project: project([("song", 256)]), log: log)
    #expect(r.answerPhrases == 0.5)
    #expect(r.dictionary["answerPhrases"] as? Double == 0.5)
  }

  /// The tonic is the project's key, not C: in G (root 55) a phrase ending on G is closed.
  @Test func answerPhrasesFollowTheKey() {
    var p = project([("song", 128)])
    p.rootNote = 55
    let log = [at(3, 0, "melody", 62), at(7, 0, "melody", 79)]
    #expect(MusicalityReport(project: p, log: log).answerPhrases == 1)
    p.rootNote = 60
    #expect(MusicalityReport(project: p, log: log).answerPhrases == 0)
  }

  /// The hook (bar 2: the first with two notes) comes back transposed in the verse and inverted
  /// in the chorus, with another rhythm in the bridge; the break has no melody and is not
  /// counted.
  @Test func hookRecurrenceScoresExactly() {
    let log = [
      at(0, 0, "melody", 60),
      at(1, 0, "melody", 72), at(1, 4, "melody", 74), at(1, 8, "melody", 76),  // the hook
      at(5, 0, "melody", 67), at(5, 4, "melody", 69), at(5, 8, "melody", 71),  // verse: transposed
      at(8, 0, "melody", 76), at(8, 4, "melody", 74), at(8, 8, "melody", 72),  // chorus: inverted
      at(12, 0, "melody", 72), at(12, 4, "melody", 74), at(12, 12, "melody", 76),  // bridge: other
    ]
    let sections = [("intro", 64), ("verse", 64), ("chorus", 64), ("bridge", 64), ("break", 64)]
    let r = MusicalityReport(project: project(sections), log: log)
    #expect(r.hookRecurrence == 2.0 / 3)
    #expect(r.dictionary["hookRecurrence"] as? Double == 0.667)
    // one section: nothing comes after the hook
    let one = MusicalityReport(project: project([("song", 256)]), log: log)
    #expect(one.hookRecurrence == nil)
  }

  /// Bar 1: C (a chord tone) and D (not); bar 2 is not a phrase's first bar; bar 5: E and G.
  @Test func barOneChordTonesScoreExactly() {
    let log =
      pad(bars: 8) + [
        at(0, 0, "melody", 72), at(0, 4, "melody", 74),
        at(1, 0, "melody", 73),
        at(4, 0, "melody", 76), at(4, 8, "melody", 79),
      ]
    let r = MusicalityReport(project: project([("song", 128)]), log: log)
    #expect(r.barOneChordTones == 0.75)
    // without a pad there is no chord to be a tone of
    let bare = log.filter { $0.group != "harmony" }
    #expect(MusicalityReport(project: project([("song", 128)]), log: bare).barOneChordTones == nil)
  }

  /// Block 1: bar 2 echoes bar 1's rhythm on other notes; block 2: it does not; block 3's first
  /// bar has one note and is not a phrase.
  @Test func bassIdeaRepeatsScoreExactly() {
    let log = [
      at(0, 0, "bass", 36), at(0, 6, "bass", 36), at(0, 10, "bass", 43),
      at(1, 0, "bass", 41), at(1, 6, "bass", 41), at(1, 10, "bass", 48),
      at(4, 0, "bass", 36), at(4, 8, "bass", 36),
      at(5, 0, "bass", 36), at(5, 4, "bass", 36),
      at(8, 0, "bass", 36), at(9, 0, "bass", 36),
    ]
    let r = MusicalityReport(project: project([("song", 192)]), log: log)
    #expect(r.bassIdeaRepeats == 0.5)
    #expect(r.dictionary["bassIdeaRepeats"] as? Double == 0.5)
  }

  /// Phrase 1 peaks on its 41st sixteenth (40 / 64 = 0.625), phrase 2 on its first (0): the
  /// first sounding of the top note counts.
  @Test func melodyPeakPositionScoresExactly() {
    let log = [
      at(0, 0, "melody", 60), at(2, 0, "melody", 67), at(2, 8, "melody", 72),
      at(3, 12, "melody", 64),
      at(4, 0, "melody", 79), at(5, 0, "melody", 72), at(6, 0, "melody", 79),
      at(8, 0, "melody", 84),  // one note: not a phrase
    ]
    let r = MusicalityReport(project: project([("song", 192)]), log: log)
    #expect(r.melodyPeakPosition == 0.3125)
  }

  /// C → G (a leap up) → F (a step down: recovered); F → C (a leap up) → D (a step further up:
  /// not); D → D below has no note after it and is not counted.
  @Test func leapRecoveryScoresExactly() {
    let line = [60, 67, 65, 72, 74, 62].enumerated().map { tone(4 * $0 + 1, "melody", $1) }
    let r = MusicalityReport(project: project([("song", 64)]), log: line)
    #expect(r.leapRecovery == 0.5)
    // a leap down recovered by a step up
    let down = [72, 64, 65].enumerated().map { tone(4 * $0 + 1, "melody", $1) }
    #expect(MusicalityReport(project: project([("song", 64)]), log: down).leapRecovery == 1)
    // half a bar or more between the leap and the next note: not followed, not counted
    let late = [tone(1, "melody", 60), tone(5, "melody", 67), tone(17, "melody", 65)]
    #expect(MusicalityReport(project: project([("song", 64)]), log: late).leapRecovery == nil)
  }

  /// Without melody or bass none of the six is measured, and the dictionary leaves them out.
  @Test func noPartsNoMetrics() {
    let r = MusicalityReport(project: project([("song", 128)]), log: pad(bars: 8))
    #expect(r.answerPhrases == nil)
    #expect(r.hookRecurrence == nil)
    #expect(r.barOneChordTones == nil)
    #expect(r.bassIdeaRepeats == nil)
    #expect(r.melodyPeakPosition == nil)
    #expect(r.leapRecovery == nil)
    for k in [
      "answerPhrases", "hookRecurrence", "barOneChordTones", "bassIdeaRepeats",
      "melodyPeakPosition", "leapRecovery",
    ] {
      #expect(r.dictionary[k] == nil)
    }
  }

  /// What a deck plays (`--fixes all`, standard structure, seed 42): the six are in range where
  /// measured. Prints one line per genre, the 6.4 baseline in docs/musicality-notes.md (run it
  /// over `BeatsTables.shared.genreIDs` to redo the table).
  @Test func playedTracksReportPhraseMetrics() {
    var lines: [String] = []
    for genre in ["techno", "house", "trance", "jazz", "lofi", "synthwave"] {
      let spec = TrackSpec(genre: genre, seed: 42, structure: "standard")
      let played = DJMusicality.apply(spec.project(), spec: spec, fixes: .all)
      let (notes, controls) = NoteLog.captureAll(played)
      let r = MusicalityReport(project: played, log: notes, controls: controls)
      let values = [
        r.answerPhrases, r.hookRecurrence, r.barOneChordTones, r.bassIdeaRepeats,
        r.melodyPeakPosition, r.leapRecovery,
      ]
      for v in values.compactMap({ $0 }) { #expect((0...1).contains(v), "\(genre)") }
      #expect(r.melodyPeakPosition != nil, "\(genre) has a melody")
      lines.append(
        genre + " "
          + values.map { $0.map { String(round3($0)) } ?? "-" }.joined(separator: " "))
    }
    print("phrase baseline (ans hook b1ct bidea peak leapR):\n" + lines.joined(separator: "\n"))
  }
}
