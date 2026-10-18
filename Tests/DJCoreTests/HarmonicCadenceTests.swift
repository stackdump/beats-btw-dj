import Testing

@testable import DJCore

// `.harmonicCadence` (HarmonicCadence.swift, ROADMAP 6.3's pass-level cadence): the pad
// cycle's last bar resolves into its first (V → I, ♭VII → i in minor dance genres), measured
// on what a deck plays and on the pass's own output.

private let genres = ["techno", "house", "trance", "edm", "dnb", "jazz", "synthwave", "funk"]
private let seeds: [Double] = [42, 7, 1234]

private func played(_ genre: String, _ seed: Double, fixes: DJMusicality.Fixes = .all)
  -> Project
{
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  return DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

/// The semitones the pad cycle's last bar's root rises into bar 0's; nil without both chords.
private func lastBarRise(_ p: Project) -> Int? {
  let (chords, bars) = DJMusicality.padChords(p)
  guard bars >= 2, let last = chords[bars - 1]?.first, let first = chords[0]?.first else {
    return nil
  }
  return DJMusicality.pc(first - last)
}

struct HarmonicCadenceTests {
  /// Every 4-bar line of the song is a harmonic cadence (or nearly: ≥ 0.9), where the
  /// baseline (HarmonyReportTests' header) had 0 for jazz, dnb, trance, funk.
  @Test(arguments: genres)
  func phraseEndsAreCadences(genre: String) throws {
    for seed in seeds {
      let r = report(played(genre, seed))
      let cad = try #require(r.harmonicCadences, "\(genre) \(seed)")
      #expect(cad >= 0.9, "\(genre) \(seed): harmonicCadences \(cad)")
    }
  }

  /// The resolved chord is voice-led like the rest (pad motion ≤ 4 semitones per change), and
  /// moving it does not add semitone rubs between parts (≤ +0.3 points against the flag off).
  @Test(arguments: genres)
  func padMotionAndRubsHold(genre: String) throws {
    for seed in seeds {
      let on = report(played(genre, seed))
      let off = report(played(genre, seed, fixes: .all.subtracting(.harmonicCadence)))
      let motion = try #require(on.padMotion, "\(genre) \(seed)")
      #expect(motion <= 4, "\(genre) \(seed): padMotion \(motion)")
      let rubs = on.semitoneClashes
      let before = off.semitoneClashes
      #expect(rubs <= before + 0.3, "\(genre) \(seed): rubs \(before) → \(rubs)")
    }
  }

  /// Pentatonic and blues genres (five- / six-note keys) keep their plan, as with `.variety`.
  @Test(arguments: ["ambient", "lofi", "blues"])
  func pentatonicGenresAreUnchanged(genre: String) {
    for seed in seeds {
      let on = played(genre, seed)
      let off = played(genre, seed, fixes: .all.subtracting(.harmonicCadence))
      #expect(on.canonicalJSON == off.canonicalJSON, "\(genre) \(seed)")
    }
  }

  /// On the pass's own output (`.variety` then the cadence, nothing after): a last bar that
  /// already resolves stays exactly as it was; one that did not now rises a fourth or a whole
  /// step into bar 0 (a whole step from a tonic bar 0 in minor dance genres), and only the
  /// line-end bars moved. Bindings only: places, transitions and arcs are the composed ones.
  @Test(arguments: genres)
  func lastBarResolvesOrStays(genre: String) throws {
    let def = try #require(BeatsTables.shared.genres[genre])
    for seed in seeds {
      let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
      let composed = spec.project()
      let before = DJMusicality.apply(composed, spec: spec, fixes: .variety)
      let after = DJMusicality.apply(composed, spec: spec, fixes: [.variety, .harmonicCadence])
      let rise = try #require(lastBarRise(before), "\(genre) \(seed)")
      if DJMusicality.cadenceRises.contains(rise) {
        #expect(after.canonicalJSON == before.canonicalJSON, "\(genre) \(seed): rise \(rise)")
        continue
      }
      let now = try #require(lastBarRise(after), "\(genre) \(seed)")
      #expect(DJMusicality.cadenceRises.contains(now), "\(genre) \(seed): rise \(rise) → \(now)")
      let (a, bars) = DJMusicality.padChords(before)
      let (b, _) = DJMusicality.padChords(after)
      // from bar 0 on the tonic a minor key always has its ♭VII a whole step below
      if DJMusicality.cadencesFromFlatSeven(def),
        a[0]?.first == DJMusicality.pc(after.rootNote ?? 60)
      {
        #expect(now == 2, "\(genre) \(seed): ♭VII → i in a minor dance genre, rose \(now)")
      }
      for bar in 0..<bars where bar % 4 != 3 {
        #expect(a[bar] == b[bar], "\(genre) \(seed) bar \(bar)")
      }
      for id in composed.nets.keys {
        let x = composed.nets[id]!
        let y = after.nets[id]!
        #expect(x.places.keys == y.places.keys, "\(genre) \(id) places")
        #expect(x.transitions.keys == y.transitions.keys, "\(genre) \(id) transitions")
        #expect(x.arcs.count == y.arcs.count, "\(genre) \(id) arcs")
      }
    }
  }

  /// The flag is in the registry: on in `.all`, and by name.
  @Test func flagIsRegistered() {
    #expect(DJMusicality.Fixes.all.contains(.harmonicCadence))
    #expect(DJMusicality.Fixes.named["harmonicCadence"] == .harmonicCadence)
  }
}
