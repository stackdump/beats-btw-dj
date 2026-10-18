import Testing

@testable import DJCore

// `.bassMotif` (BassMotif.swift, ROADMAP 6.4): a bass phrase's bar 2 restates bar 1's rhythm
// from its own root, in key and in the bass's room; walking and bossa basses stay as composed.

private func played(
  _ genre: String, _ seed: Double, fixes: DJMusicality.Fixes = .all
) -> Project {
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  return DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

/// The genres whose bass the pass rewrites (every groove but walking and bossa).
private let figureGenres = [
  "techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "funk", "reggae", "garage",
  "metal",
]

struct BassMotifTests {
  /// Bar 2 of each 4-bar bass phrase plays bar 1's rhythm (`bassIdeaRepeats`), still starting
  /// on the chord's root as often as without the pass, every note in key.
  @Test(arguments: figureGenres)
  func barTwoEchoesBarOne(genre: String) throws {
    for seed in [7.0, 42] {
      let plain = report(played(genre, seed, fixes: .all.subtracting(.bassMotif)))
      let p = played(genre, seed)
      let r = report(p)
      if let bidea = r.bassIdeaRepeats {
        #expect(bidea >= 0.95, "\(genre)/\(seed): bidea \(plain.bassIdeaRepeats ?? -1) → \(bidea)")
      }
      if let before = plain.bassOnRoot {
        let after = try #require(r.bassOnRoot)
        #expect(after >= before, "\(genre)/\(seed): bass on root \(before) → \(after)")
      }
      let key = DJMusicality.keyPitchClasses(p)
      let bass = NoteLog.capture(p).filter { $0.group == "bass" }
      #expect(bass.allSatisfy { key.contains(DJMusicality.pc($0.note)) }, "\(genre)/\(seed)")
      #expect(r.inKey >= plain.inKey - 0.001, "\(genre)/\(seed): in key")
      #expect(r.harmonyInBassRange == 0, "\(genre)/\(seed)")
    }
  }

  /// Walking and bossa basses are the genre's figure: the pass leaves the song as it was.
  @Test(arguments: ["jazz", "blues", "lofi", "bossa"])
  func walkingAndBossaBassesStay(genre: String) {
    for seed in [7.0, 42] {
      #expect(
        played(genre, seed).canonicalJSON
          == played(genre, seed, fixes: .all.subtracting(.bassMotif)).canonicalJSON,
        "\(genre)/\(seed)")
    }
  }

  /// On a hand-set ring: bar 1 plays root / root / fifth on 0, 6, 10; bar 2 plays its root on
  /// 0 and 8 with a pickup on 14. Bar 2 becomes bar 1's figure from its own root and keeps the
  /// pickup; bar 1 takes the pickup too; bars 3 and 4 are untouched.
  @Test func barTwoTakesBarOnesFigureAndKeepsThePickup() throws {
    let spec = TrackSpec(genre: "techno", seed: 42)
    var p = DJMusicality.apply(
      spec.project(), spec: spec, fixes: .all.subtracting([.bassMotif, .approach]))
    let genre = try #require(BeatsTables.shared.genres["techno"])
    let id = try #require(
      p.nets.keys.first { id in
        let nb = p.nets[id]!
        return DJMusicality.isBarRing(nb) && DJMusicality.part(nb) == "bass"
          && nb.transitions.count % 64 == 0 && !DJMusicality.ringNotes(nb).isEmpty
      })
    var nb = try #require(p.nets[id])
    let template = try #require(nb.bindings[DJMusicality.ringNotes(nb)[0].key])
    let (chords, padBars) = DJMusicality.padChords(p)
    try #require(padBars > 0)
    let scale = try #require(DJMusicality.sevenNoteKey(p)).scale
    // each bar's chord root, in the bass's room
    func root(_ bar: Int) throws -> Int {
      let r = try #require(chords[bar % padBars]?.first)
      return try #require(
        (DJMusicality.bassFloor...(DJMusicality.bassFloor + 11)).first {
          DJMusicality.pc($0) == r
        })
    }
    let r1 = try root(0)
    let r2 = try root(1)
    let fifth = try #require(DJMusicality.diatonic(r1, 4, scale))
    for k in Array(nb.bindings.keys) { nb.bindings[k] = nil }
    func put(_ step: Int, _ note: Int) {
      var b = template
      b.note = note
      nb.bindings["t\(step)"] = b
    }
    put(0, r1)
    put(6, r1)
    put(10, fifth)
    put(16, r2)
    put(24, r2)
    put(30, r2)
    put(32, try root(2))
    put(48, try root(3))
    p.nets[id] = nb
    DJMusicality.restateBassRhythm(&p, genre: genre, spec: spec)
    let out = DJMusicality.ringNotes(try #require(p.nets[id]))
    let bar = { (b: Int) in out.filter { $0.step / 16 == b } }
    #expect(bar(0).map { $0.step % 16 } == [0, 6, 10, 14])
    try #require(bar(1).map { $0.step % 16 } == [0, 6, 10, 14])
    // bar 2 from its root, the same scale steps as bar 1 (the fifth may fold an octave down)
    #expect(bar(1)[0].note == r2)
    #expect(bar(1)[1].note == r2)
    let up = try #require(DJMusicality.diatonic(r2, 4, scale))
    #expect([up, up - 12].contains(bar(1)[2].note))
    // the pickup stays; bar 1's is the same steps from its root
    #expect(bar(1)[3].note == r2)
    #expect(bar(0)[3].note == r1)
    #expect(bar(2).map(\.step) == [32])
    #expect(bar(3).map(\.step) == [48])
  }

  /// Bar 2 already on bar 1's rhythm (a root-per-bar ring as composed): nothing to restate.
  /// (A ring's first phrase, where it repeats.)
  @Test func aRepeatedRhythmStaysAsComposed() {
    let spec = TrackSpec(genre: "techno", seed: 42)
    let composed = DJMusicality.apply(
      spec.project(), spec: spec, fixes: .all.subtracting([.bassMotif, .variety]))
    var p = composed
    DJMusicality.restateBassRhythm(&p, genre: BeatsTables.shared.genres["techno"]!, spec: spec)
    for (id, nb) in composed.nets.pairs where DJMusicality.part(nb) == "bass" {
      let before = DJMusicality.ringNotes(nb)
      let rhythm = { (bar: Int) in Set(before.filter { $0.step / 16 == bar }.map { $0.step % 16 }) }
      guard DJMusicality.isBarRing(nb), rhythm(0) == rhythm(1) else { continue }
      let after = DJMusicality.ringNotes(p.nets[id]!)
      let phrase = { (x: [(key: String, step: Int, note: Int)]) in
        x.filter { $0.step < 32 }.map { [$0.step, $0.note] }
      }
      #expect(phrase(after) == phrase(before), "\(id)")
    }
  }

  /// A pure function of (project, spec).
  @Test func deterministic() {
    for genre in ["techno", "dnb", "house"] {
      #expect(played(genre, 4242).canonicalJSON == played(genre, 4242).canonicalJSON)
    }
  }
}
