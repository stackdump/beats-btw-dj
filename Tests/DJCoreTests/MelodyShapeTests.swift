import Testing

@testable import DJCore

// `.shape` (p64-shape, ROADMAP 6.4 contour by corpus): off-beat repeats and passing tones go
// to the corpus's likeliest degree, a leap is followed by a step back, an early phrase peak
// gets a higher note near two-thirds. Beats (and the chord tones on them) never move, and
// every note stays in the key.

private let genres = ["trance", "house", "synthwave", "lofi", "funk", "jazz"]
private let seeds: [Double] = [42, 7]

private func spec(_ genre: String, _ seed: Double) -> TrackSpec {
  TrackSpec(genre: genre, seed: seed, structure: "standard")
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

/// Fixes after `.shape` that rewrite melody notes by their neighbours or by other bars: an
/// A/B of `.shape` leaves them out of both sides.
private let later: DJMusicality.Fixes = [.cadence, .hook, .motif, .answer, .approach]

private func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

struct MelodyShapeTests {
  /// Pooled over the songs, the played melody meets the 6.4 contour targets: repeats ≤ 0.30,
  /// steps ≥ 0.45, leaps recovered ≥ 0.8, the peak 0.55–0.8 of the way through a phrase.
  @Test func contourMeetsTheCorpusTargets() {
    var rep: [Double] = []
    var steps: [Double] = []
    var leapR: [Double] = []
    var peak: [Double] = []
    var offLeapR: [Double] = []
    var offPeak: [Double] = []
    for genre in genres {
      for seed in seeds {
        let s = spec(genre, seed)
        let composed = s.project()
        let on = report(DJMusicality.apply(composed, spec: s))
        let off = report(DJMusicality.apply(composed, spec: s, fixes: .all.subtracting(.shape)))
        if let v = on.melodyRepeats { rep.append(v) }
        if let v = on.melodySteps { steps.append(v) }
        if let v = on.leapRecovery { leapR.append(v) }
        if let v = on.melodyPeakPosition { peak.append(v) }
        if let v = off.leapRecovery { offLeapR.append(v) }
        if let v = off.melodyPeakPosition { offPeak.append(v) }
        print(
          "shape \(genre)/\(Int(seed)): rep \(on.melodyRepeats.map(round3) ?? -1)"
            + " steps \(on.melodySteps.map(round3) ?? -1)"
            + " leapR \(off.leapRecovery.map(round3) ?? -1) → \(on.leapRecovery.map(round3) ?? -1)"
            + " peak \(off.melodyPeakPosition.map(round3) ?? -1)"
            + " → \(on.melodyPeakPosition.map(round3) ?? -1)")
      }
    }
    #expect(!rep.isEmpty && !leapR.isEmpty && !peak.isEmpty, "no melody measured")
    #expect(mean(rep) <= 0.30, "repeats \(mean(rep))")
    #expect(mean(steps) >= 0.45, "steps \(mean(steps))")
    #expect(mean(leapR) >= 0.8, "leap recovery \(mean(leapR)) (without .shape \(mean(offLeapR)))")
    #expect(
      (0.55...0.8).contains(mean(peak)), "peak \(mean(peak)) (without .shape \(mean(offPeak)))")
  }

  /// Every played note stays in the key, and the chord tones on the beats are what they were
  /// without `.shape`.
  @Test(arguments: genres)
  func keyAndChordTonesOnTheBeatHold(genre: String) {
    for seed in seeds {
      let s = spec(genre, seed)
      let composed = s.project()
      let on = report(DJMusicality.apply(composed, spec: s, fixes: .all.subtracting(later)))
      let off = report(
        DJMusicality.apply(composed, spec: s, fixes: .all.subtracting(later).subtracting(.shape)))
      #expect(on.inKey == 1, "\(genre)/\(seed): inKey \(on.inKey)")
      #expect(
        on.chordTonesOnBeats == off.chordTonesOnBeats,
        "\(genre)/\(seed): chord tones on beats \(off.chordTonesOnBeats ?? -1) → \(on.chordTonesOnBeats ?? -1)"
      )
    }
  }

  /// The pass itself: only off-beat melody notes change, onto the key; every other net and
  /// every note on a quarter is as it was. Something moves somewhere.
  @Test func onlyOffBeatMelodyNotesMove() throws {
    let before: DJMusicality.Fixes = [
      .key, .phrases, .timing, .variety, .register, .bassLine, .contour,
    ]
    var moved = 0
    for genre in genres {
      for seed in seeds {
        let s = spec(genre, seed)
        let base = DJMusicality.apply(s.project(), spec: s, fixes: before)
        var shaped = base
        let g = try #require(BeatsTables.shared.genres[genre])
        DJMusicality.shapeMelody(&shaped, genre: g, spec: s)
        let key = DJMusicality.keyPitchClasses(base)
        for (id, nb) in base.nets.pairs {
          let after = try #require(shaped.nets[id])
          for (t, b) in nb.bindings.pairs {
            let a = try #require(after.bindings[t], "\(genre)/\(seed) \(id) lost \(t)")
            guard a.note != b.note else { continue }
            moved += 1
            let step = try #require(Int(t.dropFirst()))
            #expect(DJMusicality.part(nb) == "melody", "\(genre)/\(seed): \(id) is not melody")
            #expect(step % 4 != 0, "\(genre)/\(seed): \(id) \(t) is on a beat")
            #expect(key.contains(DJMusicality.pc(a.note)), "\(genre)/\(seed): \(id) \(t) off key")
          }
          #expect(after.bindings.count == nb.bindings.count, "\(genre)/\(seed): \(id)")
        }
      }
    }
    #expect(moved > 0, "nothing moved")
  }

  /// A pure function of (project, spec): the same song plays the same notes twice.
  @Test func shapeIsDeterministic() {
    let s = spec("trance", 42)
    let composed = s.project()
    let a = NoteLog.capture(DJMusicality.apply(composed, spec: s))
    let b = NoteLog.capture(DJMusicality.apply(composed, spec: s))
    #expect(a == b)
  }
}
