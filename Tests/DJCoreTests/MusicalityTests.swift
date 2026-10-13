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
        #expect(a.bindings.count == b.bindings.count, "\(genre) \(id) bound transitions")
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

  /// Structure changes take effect at bar lines, and a part that enters a section plays its
  /// downbeat: a kick or pad net that plays the downbeat of a section's second bar also plays
  /// its first (their patterns repeat every bar).
  @Test(arguments: ["techno", "edm", "jazz", "lofi"])
  func sectionsStartOnTheDownbeat(genre: String) {
    let t = played(genre, 42)
    let (notes, controls) = NoteLog.captureAll(t.played)
    #expect(!controls.isEmpty)
    for c in controls { #expect(c.tick % 16 == 0, "\(genre): \(c.net) changes at tick \(c.tick)") }
    var start = 0
    var checked = 0
    for s in t.played.structure.dropLast() {
      start += s.steps
      let parts = notes.filter {
        ($0.net.hasPrefix("kick") || $0.group == "harmony") && $0.tick == start + 17
      }
      for n in parts {
        checked += 1
        #expect(
          notes.contains { $0.net == n.net && $0.tick == start + 1 },
          "\(genre): \(n.net) misses the downbeat at step \(start)")
      }
    }
    #expect(checked > 0)
    // The composed project does lose them (else this proves nothing).
    let before = NoteLog.captureAll(t.composed).controls
    #expect(before.filter { $0.tick % 16 == 0 }.count < before.count / 2)
  }

  /// Bass, pad and melody each in their own register: the bass's median at most A2, no pad
  /// note at or below the bass's highest, the melody's median above the pad's.
  @Test(arguments: [
    "techno", "house", "edm", "trance", "synthwave", "dubstep", "dnb", "lofi", "jazz", "bossa",
  ])
  func partsInTheirOwnRegister(genre: String) throws {
    let t = played(genre, 42)
    let r = report(t.played)
    let bass = try #require(r.medianNote["bass"])
    #expect(
      bass <= DJMusicality.bassCeiling && bass >= DJMusicality.bassFloor, "\(genre) bass \(bass)")
    if let overlap = r.harmonyInBassRange {
      #expect(overlap == 0, "\(genre): pad in the bass range")
    }
    if let pad = r.medianNote["harmony"] {
      #expect(pad >= DJMusicality.padFloor, "\(genre) pad \(pad)")
    }
    if let pad = r.medianNote["harmony"], let lead = r.medianNote["melody"] {
      #expect(lead > pad, "\(genre): melody \(lead) under the pad \(pad)")
    }
    // Octaves only: the same notes in the same order, pitch classes unchanged.
    let without = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.register))
    #expect(
      NoteLog.capture(without).map { $0.note % 12 }
        == NoteLog.capture(t.played).map { $0.note % 12 })
  }

  /// Melodic parts accented by meter: downbeats louder than off-beat sixteenths, velocities
  /// that vary (beats plays every note of a part at one velocity).
  @Test(arguments: ["techno", "edm", "house", "lofi"])
  func melodicPartsHaveMetricAccents(genre: String) throws {
    let t = played(genre, 42)
    let notes = NoteLog.capture(t.played).filter { $0.group == "melody" || $0.group == "bass" }
    let down = notes.filter { ($0.tick - 1) % 16 == 0 }.map(\.velocity)
    let offs = notes.filter { ($0.tick - 1) % 2 == 1 }.map(\.velocity)
    try #require(!down.isEmpty && !offs.isEmpty)
    let mean = { (v: [Int]) in Double(v.reduce(0, +)) / Double(v.count) }
    #expect(mean(down) >= mean(offs) + 10, "\(genre): downbeats \(mean(down)) vs off \(mean(offs))")
    #expect((report(t.played).velocitySpread["melody"] ?? 0) > 4)
    // The composed track had none (the test must be able to fail).
    #expect((report(t.composed).velocitySpread["melody"] ?? 0) < 1 || genre == "edm")
  }

  /// Every genre's busiest section at about one loudness: the gain `Loudness` picks brings
  /// genres that were 10 dB apart to within 1.5 dB of the target, and the deck applies it.
  @Test func tracksPlayAtOneLoudness() {
    var raw: [Double] = []
    for genre in ["techno", "lofi", "ambient", "edm"] {
      let p = played(genre, 42).played
      guard let db = Loudness.measure(p) else {
        Issue.record("\(genre) measured silent")
        continue
      }
      raw.append(db)
      let g = Loudness.gain(for: p)
      let after = db + ampDB(g)
      #expect(abs(after - Loudness.targetDB) < 1.5, "\(genre): \(db) dB × \(g) → \(after)")
    }
    #expect((raw.max() ?? 0) - (raw.min() ?? 0) > 6, "the genres must start apart: \(raw)")
    // The deck plays with the gain: prepared with .loudness the project carries it.
    let p = played("lofi", 42).played
    var o = WaveOptions.extended
    #expect(WaveRunner.prepare(p, sampleRate: 22_050, opts: o).gain > 1.5)
    o.musicality = []
    #expect(WaveRunner.prepare(p, sampleRate: 22_050, opts: o).gain == 1)
  }

  /// In four-on-the-floor dance genres the bass leaves the kick's steps (it was on every
  /// kick), and still starts each bar on the chord's root.
  @Test(arguments: ["techno", "edm", "trance"])
  func bassOffTheKickInFourOnTheFloor(genre: String) throws {
    let t = played(genre, 42)
    #expect(try #require(report(t.composed).bassOnKick) > 0.7)
    let r = report(t.played)
    #expect(try #require(r.bassOnKick) < 0.1, "\(genre)")  // a rotated kick variant may meet it
    #expect(try #require(r.bassOnRoot) >= 0.95)
    // House (its own groove), dnb, dubstep keep their bass lines.
    let h = played("house", 42)
    #expect(
      NoteLog.capture(h.played).filter { $0.group == "bass" }.map(\.tick)
        == NoteLog.capture(
          DJMusicality.apply(h.composed, spec: h.spec, fixes: .all.subtracting(.offbeatBass))
        ).filter { $0.group == "bass" }.map(\.tick))
  }

  /// Phrase changes on the 2-bar grid from their section's start (the composer's even split
  /// gives 3-bar phrases in 12-bar sections), and the phrase lengths that make it.
  @Test func phraseChangesOnTheTwoBarGrid() throws {
    #expect(DJMusicality.phraseLengths(steps: 192, count: 4) == [64, 64, 32, 32])
    #expect(DJMusicality.phraseLengths(steps: 192, count: 2) == [128, 64])
    #expect(DJMusicality.phraseLengths(steps: 128, count: 4) == [32, 32, 32, 32])
    #expect(DJMusicality.phraseLengths(steps: 64, count: 2) == [32, 32])
    for genre in ["techno", "edm", "jazz"] {
      let t = played(genre, 42)
      #expect(try #require(report(t.played).changesOnPhrases) == 1, "\(genre)")
      #expect(try #require(report(t.composed).changesOnPhrases) < 0.8, "\(genre) composed")
    }
  }

  /// A drum fill in the bar before every section change, swelling into it, and a voice for it
  /// on the deck (beats builds the fills, mutes them and gives them none).
  @Test(arguments: ["techno", "edm", "jazz", "lofi"])
  func drumFillsBeforeSectionChanges(genre: String) throws {
    let t = played(genre, 42)
    #expect(try #require(report(t.played).fillsBeforeSections) == 1, "\(genre)")
    #expect(try #require(report(t.composed).fillsBeforeSections) == 0)
    let fills = NoteLog.capture(t.played).filter { $0.net.hasPrefix("fill-") }
    for (_, roll) in Dictionary(grouping: fills, by: \.net) {
      let v = roll.sorted { $0.tick < $1.tick }.map(\.velocity)
      #expect(v == v.sorted() && v.first! < v.last!, "\(genre): a fill swells: \(v)")
    }
    let deck = WaveRunner.prepare(t.played, sampleRate: 22_050, opts: .extended)
    #expect(deck.byNet["fill-0"] != nil)
    #expect(WaveRunner.prepare(t.played, sampleRate: 22_050).byNet["fill-0"] == nil)
  }

  /// The pad's chords lead into each other: less motion than beats' root-position blocks,
  /// the same pitch classes in the same order, still clear of the bass and in the pad's range.
  @Test(arguments: ["techno", "trance", "dubstep", "synthwave", "ambient", "jazz"])
  func padChordsLeadIntoEachOther(genre: String) throws {
    let t = played(genre, 42)
    let blocks = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.voicing))
    let before = try #require(report(blocks).padMotion)
    let after = try #require(report(t.played).padMotion)
    #expect(after < before, "\(genre): \(before) → \(after)")
    #expect(after <= 5, "\(genre): \(after) semitones per chord change")
    let pad = { (p: Project) in NoteLog.capture(p).filter { $0.group == "harmony" } }
    #expect(pad(blocks).map { $0.note % 12 } == pad(t.played).map { $0.note % 12 })
    #expect(report(t.played).harmonyInBassRange == 0)
  }
}
