import Testing

@testable import DJCore

// ROADMAP 6.3's exit metrics on `MusicalityReport`: harmonic cadences at 4-bar lines, distinct
// progressions per song, and per-section chord agreement.
//
// Baseline, 2026-10-18 (integrate/roadmap ad884c1, before any 6.3 harmony work): seed 42,
// standard structure, `--fixes all`; cad = harmonicCadences, prog = progressions, secCT =
// sectionChordAgreement (its lowest section).
//
//   genre      cad    prog  secCT        genre      cad    prog  secCT
//   ambient    1.0    1     0.875 bridge  jazz       0.0    1     0.813 intro
//   blues      0.273  3     0.125 outro   lofi       0.0    1     0.75 intro
//   bossa      0.0    1     1.0           metal      0.0    1     1.0
//   country    1.0    1     0.813 pre-ch  reggae     1.0    1     1.0
//   dnb        0.0    1     1.0           speedcore  0.0    1     1.0
//   dubstep    1.0    1     1.0           synthwave  1.0    1     0.917 verse
//   edm        1.0    1     1.0           techno     1.0    1     1.0
//   funk       0.0    1     0.75 pre-ch   trance     0.0    1     1.0
//   garage     1.0    1     1.0           trap       1.0    1     1.0
//   house      1.0    1     1.0
//
// One 4-bar loop per song everywhere but blues (its 12 bars are three blocks), so cad is all
// or nothing: the loop's last chord into its first either is a cadence or never is. 6.3's exit
// wants prog >= 2 in song-form genres and a cadence at every phrase end.

private func tone(_ tick: Int, _ group: String, _ note: Int) -> NoteEvent {
  NoteEvent(tick: tick, net: group, group: group, note: note, velocity: 100, channel: 1, steps: 4)
}

/// One pad chord (root, third, fifth) per bar, struck on the bar's first tick, root first.
private func pad(_ roots: [Int]) -> [NoteEvent] {
  roots.enumerated().flatMap { b, r in [r, r + 4, r + 7].map { tone(16 * b + 1, "harmony", $0) } }
}

private func project(_ sections: [(String, Int)]) -> Project {
  var p = Project()
  p.rootNote = 60
  p.scaleName = "Major"
  p.structure = sections.map { Section(name: $0.0, steps: $0.1) }
  return p
}

struct HarmonyReportTests {
  /// C F G C | A F G B♭ | C F G C: the line into bar 5 rises a major sixth (no cadence), the
  /// one into bar 9 a whole step (a cadence); bar 12 has no line after it. Two distinct blocks.
  @Test func cadencesAndProgressionsScoreExactly() {
    let roots = [60, 65, 67, 60, 57, 65, 67, 58, 60, 65, 67, 60]
    let r = MusicalityReport(project: project([("song", 192)]), log: pad(roots))
    #expect(r.harmonicCadences == 0.5)
    #expect(r.progressions == 2)
  }

  /// Falls a fifth (G → C) and rises a whole step (B♭ → C) count; a plagal IV → I and an
  /// unchanged chord do not. Roots an octave apart are the same root.
  @Test func cadenceIntervals() {
    func cadence(_ last: Int, _ next: Int) -> Double? {
      MusicalityReport(project: project([("song", 128)]), log: pad([60, 60, 60, last, next]))
        .harmonicCadences
    }
    #expect(cadence(67, 60) == 1)
    #expect(cadence(55, 60) == 1)
    #expect(cadence(58, 60) == 1)
    #expect(cadence(65, 60) == 0)
    #expect(cadence(60, 60) == 0)
  }

  /// One I–V–vi–IV loop for the whole song is one progression.
  @Test func oneLoopIsOneProgression() {
    let loop = [60, 67, 69, 65]
    let r = MusicalityReport(project: project([("song", 256)]), log: pad(loop + loop + loop + loop))
    #expect(r.progressions == 1)
    #expect(r.harmonicCadences == 0, "IV → I is plagal, not a cadence here")
    // a partial block at the end is not a progression of its own
    let partial = MusicalityReport(project: project([("song", 96)]), log: pad(loop + [60, 67]))
    #expect(partial.progressions == 1)
  }

  /// A bridge whose melody moves while the pad stays: half its melody notes on beats miss, the
  /// bass stays on the root. Per section in song order, and the lowest of them.
  @Test func sectionChordAgreementPerSection() {
    var log = pad([60, 65, 67, 60, 60, 65, 67, 60, 60, 65, 67, 60])
    for b in 0..<12 {
      let root = [60, 65, 67, 60][b % 4]
      let melody = b >= 8 && b % 2 == 0 ? root + 5 : root + 12  // a fourth up: off the triad
      log.append(tone(16 * b + 1, "melody", melody))
      log.append(tone(16 * b + 3, "melody", root + 1))  // off the beat: not counted
      if b >= 8 { log.append(tone(16 * b + 5, "bass", root - 24)) }
    }
    let r = MusicalityReport(project: project([("verse", 128), ("bridge", 64)]), log: log)
    #expect(r.sectionChordAgreementBySection.map(\.section) == ["verse", "bridge"])
    #expect(r.sectionChordAgreementBySection.map(\.agreement) == [1, 0.75])
    #expect(r.sectionChordAgreement == 0.75)
    let bySection = r.dictionary["sectionChordAgreementBySection"] as? [[String: Any]]
    #expect(bySection?.compactMap { $0["section"] as? String } == ["verse", "bridge"])
  }

  /// Without a harmony part none of the three is measured, and the dictionary leaves them out.
  @Test func noHarmonyNoMetrics() {
    let log = (0..<8).map { tone(16 * $0 + 1, "melody", 72) }
    let r = MusicalityReport(project: project([("song", 128)]), log: log)
    #expect(r.harmonicCadences == nil)
    #expect(r.progressions == nil)
    #expect(r.sectionChordAgreement == nil)
    #expect(r.sectionChordAgreementBySection.isEmpty)
    for k in ["harmonicCadences", "progressions", "sectionChordAgreement"] {
      #expect(r.dictionary[k] == nil)
    }
  }

  /// What a deck plays (`--fixes all`, standard structure, seed 42): a genre with a pad has all
  /// three (the keys `djctl render` prints), in range. Prints the line the header's baseline
  /// records (run it over `BeatsTables.shared.genreIDs` to redo the table).
  @Test func playedTracksReportHarmony() {
    var lines: [String] = []
    for genre in ["techno", "house", "trance", "jazz", "lofi", "blues"] {
      let spec = TrackSpec(genre: genre, seed: 42, structure: "standard")
      let played = DJMusicality.apply(spec.project(), spec: spec, fixes: .all)
      let (notes, controls) = NoteLog.captureAll(played)
      let r = MusicalityReport(project: played, log: notes, controls: controls)
      guard r.chordTonesOnBeats != nil || r.padColor != nil else { continue }
      let d = r.dictionary
      #expect(d["harmonicCadences"] != nil, "\(genre)")
      #expect(d["progressions"] != nil, "\(genre)")
      #expect(d["sectionChordAgreement"] != nil, "\(genre)")
      #expect((0...1).contains(r.harmonicCadences ?? -1), "\(genre)")
      #expect((r.progressions ?? 0) >= 1, "\(genre)")
      #expect((0...1).contains(r.sectionChordAgreement ?? -1), "\(genre)")
      let low = r.sectionChordAgreementBySection.min { $0.agreement < $1.agreement }
      lines.append(
        "\(genre) cad \(round3(r.harmonicCadences ?? -1)) prog \(r.progressions ?? 0) "
          + "secCT \(round3(r.sectionChordAgreement ?? -1)) (\(low?.section ?? "-"))")
    }
    print("harmony baseline:\n" + lines.joined(separator: "\n"))
  }
}
