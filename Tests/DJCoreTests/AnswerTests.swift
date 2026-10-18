import Testing

@testable import DJCore

// `DJMusicality.Fixes.answer`: in each 8-bar pair of a section, bars 1–4 end open (a question)
// and bars 5–8 close on the tonic (its answer), on whichever slot nets play them.

private func ring(_ n: Int, group: String, channel: Int, _ notes: [(step: Int, note: Int)])
  -> NetBundle
{
  var nb = NetBundle.ring(n)
  for x in notes { nb.bind(x.step, note: x.note, channel: channel, velocity: 100, duration: 100) }
  nb.track.channel = channel
  nb.track.group = group
  nb.riffGroup = group
  return nb
}

/// A one-bar pad of `notes`, one net per note (a binding plays one note).
private func pad(_ p: inout Project, _ notes: [Int]) {
  for (i, n) in notes.enumerated() {
    p.nets["pad\(i)"] = ring(16, group: "harmony", channel: 4, [(0, n)])
  }
}

/// C major, a C-major pad every bar, and one 8-bar melody ring: bars 1–4 end on C (closed
/// already), bars 5–8 on E.
private func pairProject() -> Project {
  var p = Project()
  p.rootNote = 60
  p.scaleName = "Major"
  pad(&p, [48, 52, 55])
  p.nets["melody"] = ring(
    128, group: "melody", channel: 1,
    [
      (0, 72), (4, 74), (16, 72), (20, 74),  // bars 1–2: the idea
      (36, 67), (56, 72),  // question ends on the tonic
      (64, 76), (72, 74), (80, 76), (88, 74),
      (100, 71), (120, 76),  // answer ends on E
    ])
  var s = Section(name: "verse", steps: 128)
  s.phrases["melody"] = ["A"]
  p.structure = [s]
  return p
}

private func played(_ genre: String, _ seed: Double, fixes: DJMusicality.Fixes) -> Project {
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  return DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

/// The section 8-bar pairs whose halves both end in bars 3–4 on the melody's slot nets, and of
/// them the share that end open (not the tonic) then closed (the tonic): `answerPhrases` across
/// nets, on each section's grid.
private func sectionAnswers(_ p: Project) -> (pairs: Int, answered: Double) {
  let nets = Set(DJMusicality.slotWindows(p, role: "melody").keys)
  let log = NoteLog.capture(p).filter { nets.contains($0.net) && MusicalityReport.isTonal($0) }
  let tonic = DJMusicality.pc(p.rootNote ?? 60)
  var pairs = 0
  var answered = 0
  var start = 0
  for s in p.structure {
    defer { start += s.steps }
    for pair in stride(from: start, through: start + s.steps - 128, by: 128) {
      func last(_ a: Int) -> NoteEvent? {
        log.filter { $0.tick - 1 >= a && $0.tick - 1 < a + 64 }.max { $0.tick < $1.tick }
      }
      guard let q = last(pair), let a = last(pair + 64), q.tick - 1 - pair >= 32,
        a.tick - 1 - pair - 64 >= 32
      else { continue }
      pairs += 1
      if DJMusicality.pc(q.note) != tonic && DJMusicality.pc(a.note) == tonic { answered += 1 }
    }
  }
  return (pairs, pairs > 0 ? Double(answered) / Double(pairs) : 0)
}

struct AnswerTests {
  /// The question's last note goes to the chord's fifth (G, the nearest in range), the answer's
  /// to the tonic; every other binding (bars 1–2 among them) stays.
  @Test func questionEndsOpenAnswerCloses() {
    let p = pairProject()
    let spec = TrackSpec(genre: "techno", seed: 42)
    let q = DJMusicality.apply(p, spec: spec, fixes: .answer)
    #expect(q.nets["melody"]!.bindings["t56"]!.note == 67)
    #expect(q.nets["melody"]!.bindings["t120"]!.note == 72)
    for (k, b) in p.nets["melody"]!.bindings.pairs where k != "t56" && k != "t120" {
      #expect(q.nets["melody"]!.bindings[k]!.note == b.note, "\(k) moved")
    }
    #expect((0..<3).map { q.nets["pad\($0)"]!.bindings["t0"]!.note } == [48, 52, 55])
    // the report's per-net pair agrees
    let before = report(p).answerPhrases
    let after = report(q).answerPhrases
    #expect(before == 0)
    #expect(after == 1)
  }

  /// Where the fifth is the tonic (an F chord in C), the question takes the chord's third.
  @Test func questionAvoidsTheTonic() {
    var p = pairProject()
    pad(&p, [53, 57, 60])
    p.nets["melody"]!.bindings["t56"]!.note = 74  // D: neither third nor fifth
    let q = DJMusicality.apply(p, spec: TrackSpec(genre: "techno", seed: 42), fixes: .answer)
    #expect(q.nets["melody"]!.bindings["t56"]!.note == 69)
  }

  /// A section shorter than 8 bars, or a pair whose half ends in bars 1–2, is left alone.
  @Test func shortSectionsAndEarlyEndsStay() {
    var p = pairProject()
    p.structure[0].steps = 112
    let spec = TrackSpec(genre: "techno", seed: 42)
    #expect(
      DJMusicality.apply(p, spec: spec, fixes: .answer).nets["melody"]!.bindings.pairs
        .map(\.value.note) == p.nets["melody"]!.bindings.pairs.map(\.value.note))
    p = pairProject()
    p.nets["melody"]!.bindings["t36"] = nil
    p.nets["melody"]!.bindings["t56"] = nil
    #expect(
      DJMusicality.apply(p, spec: spec, fixes: .answer).nets["melody"]!.bindings.pairs
        .map(\.value.note) == p.nets["melody"]!.bindings.pairs.map(\.value.note))
  }

  /// On what decks play: ≥ 0.9 of a section's 8-bar pairs answer with the flag, < 0.5 without;
  /// the idea (bar 2 restating bar 1) stays, and so do the key and the clashes.
  @Test(arguments: ["techno", "house", "edm", "trance", "dnb", "synthwave", "lofi", "funk", "jazz"])
  func playedTracksAnswer(genre: String) throws {
    for seed in [7.0, 42] {
      let with = played(genre, seed, fixes: .all)
      let without = played(genre, seed, fixes: .all.subtracting(.answer))
      let a = sectionAnswers(with)
      let b = sectionAnswers(without)
      print("answer \(genre)/\(seed): pairs \(a.pairs), \(b.answered) → \(a.answered)")
      guard a.pairs > 0 else { continue }
      #expect(a.answered >= 0.9, "\(genre)/\(seed): \(b.answered) → \(a.answered)")
      #expect(b.answered < 0.5, "\(genre)/\(seed): already answers (\(b.answered))")
      let rw = report(with)
      let ro = report(without)
      if let x = rw.answerPhrases { #expect(x >= (ro.answerPhrases ?? 0), "\(genre)/\(seed)") }
      #expect(rw.melodyIdeaRepeats == ro.melodyIdeaRepeats, "\(genre)/\(seed): idea moved")
      #expect(rw.inKey >= ro.inKey - 0.005, "\(genre)/\(seed)")
      #expect(rw.semitoneClashes <= ro.semitoneClashes + 0.5, "\(genre)/\(seed)")
    }
  }

  /// The pass rewrites bindings only: the same nets, places, transitions and arcs.
  @Test func bindingsOnly() {
    let with = played("trance", 42, fixes: .all)
    let without = played("trance", 42, fixes: .all.subtracting(.answer))
    #expect(Array(with.nets.keys) == Array(without.nets.keys))
    for (id, nb) in with.nets.pairs {
      let o = without.nets[id]!
      #expect(nb.places.count == o.places.count && nb.transitions.count == o.transitions.count)
      #expect(nb.arcs.count == o.arcs.count)
    }
  }
}
