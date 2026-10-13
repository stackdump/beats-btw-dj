import Testing

@testable import DJCore

// Musical invariants of what a deck plays (`PreparedTrack.played`, after `DJMusicality`),
// measured on the note log — docs/musicality-notes.md says why each one matters.

private func played(
  _ genre: String, _ seed: Double, _ structure: String? = "standard",
  fixes: DJMusicality.Fixes = .all
) -> (spec: TrackSpec, composed: Project, played: Project) {
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  let composed = spec.project()
  return (spec, composed, DJMusicality.apply(composed, spec: spec, fixes: fixes))
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

private func scalePCs(_ p: Project) -> Set<Int> {
  let root = p.rootNote ?? 60
  return Set(scaleIntervals(p.scaleName + "Scale").map { (root + $0) % 12 })
}

/// Genres whose B / C sections are tension variants (the ones `.key` repairs).
private let tensionGenres = BeatsTables.shared.genreIDs.filter {
  BeatsTables.shared.genres[$0]!.tensionCurve
}

struct MusicalityTests {
  /// The pass rewrites bindings and markings only: same nets, places, transitions and arcs as
  /// the composer built, so views, section jumps and sessions agree with what plays.
  @Test func passKeepsTheNetTopology() {
    for genre in ["techno", "edm", "jazz"] {
      let t = played(genre, 42)
      #expect(t.played.nets.keys == t.composed.nets.keys)
      for id in t.composed.nets.keys {
        let a = t.composed.nets[id]!
        let b = t.played.nets[id]!
        #expect(a.places.keys == b.places.keys, "\(genre) \(id) places")
        #expect(a.transitions.keys == b.transitions.keys, "\(genre) \(id) transitions")
        #expect(a.arcs.count == b.arcs.count, "\(genre) \(id) arcs")
        #expect(a.bindings.keys == b.bindings.keys, "\(genre) \(id) bound transitions")
      }
      #expect(t.played.structure.map(\.steps) == t.composed.structure.map(\.steps))
    }
  }

  /// `compose()` itself is not touched: the parity path still gets beats' project.
  @Test func composeIsUnchanged() {
    let spec = TrackSpec(genre: "edm", seed: 42, structure: "standard")
    let t = played("edm", 42)
    #expect(t.composed.canonicalJSON == spec.project().canonicalJSON)
    #expect(t.played.canonicalJSON != t.composed.canonicalJSON, "the pass must do something")
    #expect(
      DJMusicality.apply(t.composed, spec: spec, fixes: []).canonicalJSON
        == t.composed.canonicalJSON)
  }

  /// Every tonal note in key, in every genre with tension variants (which composed B / C
  /// sections a whole tone up / a minor third down). Walking basses may approach the next
  /// chord root chromatically: an out-of-key bass note must resolve by a semitone, or be the
  /// last note before the bass drops out (a section without it).
  @Test(arguments: tensionGenres)
  func everyNoteInKey(genre: String) {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let pcs = scalePCs(t.played)
      // A part (all its slot nets) in time order: the approach note's target may be the
      // first note of the next slot.
      let byPart = Dictionary(
        grouping: NoteLog.capture(t.played).filter(MusicalityReport.isTonal), by: \.group)
      for (_, notes) in byPart {
        for (i, n) in notes.enumerated() where !pcs.contains(n.note % 12) {
          let next = i + 1 < notes.count ? notes[i + 1] : nil
          let resolves = next.map { abs($0.note - n.note) == 1 || $0.tick - n.tick > 8 } ?? true
          let approach = n.group == "bass" && resolves
          #expect(approach, "\(genre)/\(seed) \(n.net) tick \(n.tick): \(n.note) out of key")
        }
      }
    }
  }

  /// The composed B / C sections really are out of key (else the test above proves nothing).
  @Test func composedVariantsWereOutOfKey() {
    let t = played("edm", 42)
    #expect(report(t.composed).inKey < 0.95)
    #expect(report(t.played).inKey == 1)
  }

  /// The bass starts each bar on the chord's root (the harmony's first note).
  @Test(arguments: ["techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave"])
  func bassOnTheChordRoot(genre: String) throws {
    let r = report(played(genre, 42).played)
    let onRoot = try #require(r.bassOnRoot)
    #expect(onRoot >= 0.95, "\(genre): bass on the root in \(onRoot) of bars")
  }
}
