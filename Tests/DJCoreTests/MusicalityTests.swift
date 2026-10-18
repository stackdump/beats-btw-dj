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

/// Fixes that rewrite single notes by their neighbours (`.cadence`, `.approach`) or bars by
/// others (`.motif`, `.bassMotif`): a test that isolates an earlier fix by A/B leaves them out of both sides,
/// since which note they pick depends on the octave or the step that fix chose.
private let phrasing: DJMusicality.Fixes = [.cadence, .approach, .motif, .bassMotif]

/// `t` played with every fix except `without` and `phrasing`.
private func playedWithout(
  _ t: (spec: TrackSpec, composed: Project, played: Project), _ without: DJMusicality.Fixes = []
) -> Project {
  DJMusicality.apply(
    t.composed, spec: t.spec, fixes: .all.subtracting(phrasing).subtracting(without))
}

/// Genres whose B / C sections are tension variants (the ones `.key` repairs).
private let tensionGenres = BeatsTables.shared.genreIDs.filter {
  BeatsTables.shared.genres[$0]!.tensionCurve
}

struct MusicalityTests {
  /// Every flag has its own bit, a name `djctl render --fixes` takes, and is in `all`.
  @Test func fixesRegistryIsConsistent() {
    let flags = DJMusicality.Fixes.named.filter { $0.key != "none" }
    let bits = flags.values.map(\.rawValue)
    #expect(bits.allSatisfy { $0 != 0 && $0 & ($0 - 1) == 0 }, "one bit per flag")
    #expect(Set(bits).count == bits.count, "bits are unique")
    let union = flags.values.reduce(DJMusicality.Fixes()) { $0.union($1) }
    #expect(union == .all, "named and all list the same flags")
    #expect(DJMusicality.Fixes.named["none"] == [])
  }

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
        // `.color` binds a free step of the pad (a seventh), `.arpeggio` rebinds the arp's
        // steps, `.motif` a melody's second bars (bar 1's rhythm), `.buildup` / `.crash` the
        // fill chains' (a roll, a crash), `.variety` a bass pickup or every other bass hit and
        // ghost drum hits, `.backbeat` the chill family's kick and snare figures, `.bassMotif`
        // a bass bar 2 (bar 1's rhythm) (all on the net's own transitions); nothing else gains
        // or loses notes
        let unvaried = DJMusicality.apply(
          t.composed, spec: t.spec, fixes: .all.subtracting([.variety, .bassMotif])
        ).nets[id]!
        #expect(Set(b.bindings.keys).isSubset(of: Set(b.transitions.keys)), "\(genre) \(id)")
        if id.hasPrefix("fill-") {
          continue
        } else if DJMusicality.backbeatStyle(genre: genre) != nil,
          DJMusicality.backbeatRoles.contains(id)
        {
          #expect(!b.bindings.keys.isEmpty, "\(genre) \(id)")
        } else if b.track.group == "arp" || b.track.group == "melody" {
          #expect(!b.bindings.keys.isEmpty, "\(genre) \(id)")
        } else if b.track.group == "harmony" {
          #expect(Set(a.bindings.keys).isSubset(of: Set(b.bindings.keys)), "\(genre) \(id)")
        } else {
          #expect(a.bindings.count == unvaried.bindings.count, "\(genre) \(id) bound transitions")
        }
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
    let without = playedWithout(t, .register)
    #expect(
      NoteLog.capture(without).map { $0.note % 12 }
        == NoteLog.capture(playedWithout(t)).map { $0.note % 12 })
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
    // Metal, not edm: since adfc733 (instrument levels) and `.variety` the dance genres sit
    // within ~5 dB of lofi / jazz (seed 42: edm −13.3, techno −14.1, ambient −17.7, lofi
    // −18.2 dB), while metal still starts ~8 dB above lofi (−10.1).
    for genre in ["techno", "lofi", "ambient", "metal"] {
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
    // (lofi/42 is the quietest of them; `.variety` moved it a little louder, so 1.2, not 1.5)
    #expect(WaveRunner.prepare(p, sampleRate: 22_050, opts: o).gain > 1.2)
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
    // (the section crashes `.crash` puts on the same chains are not the fill)
    let fills = NoteLog.capture(t.played).filter {
      $0.net.hasPrefix("fill-") && $0.note != DJMusicality.crashNote
    }
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
    // triads either way (`.color` adds sevenths in jazz), with and without the voicing
    let blocks = DJMusicality.apply(
      t.composed, spec: t.spec, fixes: .all.subtracting([.voicing, .color]))
    let led = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.color))
    let before = try #require(report(blocks).padMotion)
    let after = try #require(report(led).padMotion)
    #expect(after < before, "\(genre): \(before) → \(after)")
    #expect(after <= 5, "\(genre): \(after) semitones per chord change")
    let pad = { (p: Project) in NoteLog.capture(p).filter { $0.group == "harmony" } }
    #expect(pad(blocks).map { $0.note % 12 } == pad(led).map { $0.note % 12 })
    #expect(try #require(report(t.played).padMotion) <= 5)
    #expect(report(t.played).harmonyInBassRange == 0)
  }

  /// Melodies step instead of stalling on one pitch: far fewer repeated notes, more steps,
  /// the notes on the beat (the motif's chord tones) unchanged, no more semitone rubs against
  /// the other parts than before, the motif still coming back.
  @Test(arguments: ["techno", "trance", "jazz", "dubstep"])
  func melodiesStepRatherThanRepeat(genre: String) throws {
    let t = played(genre, 42)
    // `.variety`'s new chords re-snap the beat notes away from their neighbours, which does
    // part of `.contour`'s work: A/B it on the track as beats composed it, then check the
    // played melody still steps
    let flat = playedWithout(t, [.contour, .variety])
    let stepped = playedWithout(t, .variety)
    #expect(try #require(report(playedWithout(t)).melodyRepeats) < 0.45, "\(genre) as played")
    let a = report(flat)
    let b = report(stepped)
    let before = try #require(a.melodyRepeats)
    let after = try #require(b.melodyRepeats)
    #expect(after < 0.7 * before && after < 0.45, "\(genre): repeats \(before) → \(after)")
    #expect(try #require(b.melodySteps) > (a.melodySteps ?? 0) + 0.1)
    #expect(b.semitoneClashes <= a.semitoneClashes + 0.1)
    #expect(try #require(b.melodyRecurrence) >= (a.melodyRecurrence ?? 0) - 0.1)
    let onBeats = { (p: Project) in
      NoteLog.capture(p).filter { $0.group == "melody" && ($0.tick - 1) % 4 == 0 }.map(\.note)
    }
    #expect(onBeats(flat) == onBeats(stepped))
  }

  /// Sevenths where the style has them (jazz, bossa, house, garage, funk): most pad chords get
  /// their scale seventh, in key, inside the pad's range and clear of the bass, without more
  /// rubs against the other parts; other genres keep beats' triads untouched.
  @Test(arguments: ["jazz", "bossa", "house", "garage", "funk"])
  func padChordsAreSeventhsWhereTheStyleIs(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let triads = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.color))
      let a = report(triads)
      let b = report(t.played)
      #expect(try #require(b.padColor) >= 0.75, "\(genre)/\(seed)")
      #expect(a.padColor == 0)
      #expect(b.inKey >= a.inKey)
      #expect(b.harmonyInBassRange == 0)
      // the rubs the sevenths add, on beats' chords (`.variety`'s progressions move where a
      // seventh lands against the tune; VarietyTests holds their rubs to beats' level)
      let plain: DJMusicality.Fixes = .all.subtracting(.variety)
      let x = report(DJMusicality.apply(t.composed, spec: t.spec, fixes: plain.subtracting(.color)))
      let y = report(DJMusicality.apply(t.composed, spec: t.spec, fixes: plain))
      #expect(y.semitoneClashes <= x.semitoneClashes + 1, "\(genre)/\(seed)")
    }
    let techno = played("techno", 42)
    let plain = DJMusicality.apply(
      techno.composed, spec: techno.spec, fixes: .all.subtracting(.color))
    #expect(plain.canonicalJSON == techno.played.canonicalJSON)
  }

  /// The arp plays the chords: every arp note a tone of the bar's pad chord, hardly ever the
  /// melody's pitch class at the same moment (beats' arp slots are the melody's motif, doubled),
  /// a steady run of notes in each bar it plays, above the pad, in key.
  @Test(arguments: ["trance", "edm", "synthwave"])
  func arpPlaysTheChords(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let motif = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.arpeggio))
      let a = report(motif)
      let b = report(t.played)
      #expect(try #require(a.arpDoublesMelody) > 0.5, "\(genre)/\(seed): composed arp doubles")
      #expect(try #require(b.arpChordTones) == 1, "\(genre)/\(seed)")
      #expect(try #require(b.arpDoublesMelody) < 0.3, "\(genre)/\(seed)")
      #expect(b.inKey >= a.inKey)
      // a steady run at the figure's own rate (`.arpDensity` varies it: ArpDensityTests)
      let steady = DJMusicality.apply(
        t.composed, spec: t.spec, fixes: .all.subtracting(.arpDensity))
      let arp = NoteLog.capture(steady).filter { $0.group == "arp" }
      for (_, bar) in Dictionary(grouping: arp, by: { ($0.tick - 1) / 16 }) {
        #expect(bar.count >= 8, "\(genre)/\(seed): \(bar.count) arp notes in a bar")
      }
      #expect(try #require(b.medianNote["arp"]) > (b.medianNote["harmony"] ?? 0))
    }
  }

  /// Every buildup builds into what follows: a snare roll over its last bars that only gets
  /// faster and louder, ending in sixteenths on the section change; songs without a buildup
  /// are untouched, and the deck voices the roll.
  @Test(arguments: ["techno", "edm", "trance", "dnb", "dubstep"])
  func buildupsRollIntoTheDrop(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      guard t.played.structure.dropLast().contains(where: { $0.name == "buildup" }) else {
        continue
      }
      #expect(try #require(report(t.played).buildupsBuild) == 1, "\(genre)/\(seed)")
      let without = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.buildup))
      #expect(try #require(report(without).buildupsBuild) == 0)
      var end = 0
      for s in t.played.structure.dropLast() {
        end += s.steps
        guard s.name == "buildup" else { continue }
        let roll = NoteLog.capture(t.played)
          .filter { $0.net.hasPrefix("fill-") && $0.tick > end - 128 && $0.tick <= end }
          .sorted { $0.tick < $1.tick }
        let v = roll.map(\.velocity)
        #expect(v == v.sorted() && v.first! + 40 < v.last!, "\(genre)/\(seed): \(v)")
        #expect(roll.last?.tick == end, "the roll lands on the change")
        #expect(roll.suffix(16).map(\.tick) == Array((end - 15)...end), "sixteenths at the end")
      }
    }
    #expect(
      WaveRunner.prepare(played("edm", 42).played, sampleRate: 22_050, opts: .extended)
        .byNet.keys.contains { $0.hasPrefix("fill-") })
  }

  /// A crash on the downbeat of every section after the first, louder into a drop, played by a
  /// crash voice (a long bright tail, not beats' 0.1 s open hat); the parity path has none.
  @Test(arguments: ["techno", "edm", "jazz", "lofi", "funk"])
  func sectionsStartWithACrash(genre: String) throws {
    let t = played(genre, 42)
    #expect(try #require(report(t.played).crashOnSections) == 1, "\(genre)")
    #expect(try #require(report(t.composed).crashOnSections) == 0)
    let crashes = NoteLog.capture(t.played).filter { $0.isDrum && $0.note == 49 }
    #expect(crashes.count == t.played.structure.count - 1, "one per section change")
    if let drop = t.played.structure.firstIndex(where: { $0.name == "drop" }), drop > 0 {
      let at = t.played.structure.prefix(drop).reduce(0) { $0 + $1.steps } + 1
      let loud = try #require(crashes.first { $0.tick == at }).velocity
      #expect(crashes.allSatisfy { $0.velocity <= loud })
    }
    let deck = WaveRunner.prepare(t.played, sampleRate: 22_050, opts: .extended)
    let crash = deck.lanes.filter { $0.voice.kind == "crash" }
    #expect(!crash.isEmpty && crash.allSatisfy { $0.netId.hasPrefix("fill-") })
    #expect(crash.allSatisfy { $0.voice.pulse.tau.max()! > 0.5 })
    let parity = WaveRunner.prepare(t.played, sampleRate: 22_050)
    #expect(!parity.lanes.contains { $0.voice.kind == "crash" })
  }

  /// The bass steps between chord roots instead of leaping: less motion at chord changes than
  /// beats' one-octave roots, no change bigger than a fifth where it had any, the same pitch
  /// classes in the same order, still on the root, still under the pad and in a bass register.
  @Test(arguments: ["techno", "house", "edm", "trance", "dnb", "synthwave", "jazz", "funk"])
  func bassStepsBetweenRoots(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let leaping = playedWithout(t, .bassLine)
      let stepping = playedWithout(t)
      let a = report(leaping)
      let b = report(stepping)
      let before = try #require(a.bassLeap)
      let after = try #require(b.bassLeap)
      #expect(after <= before, "\(genre)/\(seed): \(before) → \(after)")
      #expect(after <= 5, "\(genre)/\(seed): \(after) semitones per change")
      let bass = { (p: Project) in NoteLog.capture(p).filter { $0.group == "bass" } }
      #expect(bass(leaping).map { $0.note % 12 } == bass(stepping).map { $0.note % 12 })
      #expect(try #require(b.bassOnRoot) >= (a.bassOnRoot ?? 0))
      #expect(b.harmonyInBassRange == 0)
      let median = try #require(b.medianNote["bass"])
      #expect(median >= DJMusicality.bassFloor && median <= DJMusicality.bassCeiling + 2)
    }
  }

  /// Four-on-the-floor dance genres open the hat on every off-beat eighth it plays and nowhere
  /// else, and the deck gives those an open-hat voice; other genres' hats are untouched.
  @Test(arguments: ["techno", "house", "edm", "trance"])
  func offbeatHatsOpen(genre: String) throws {
    let t = played(genre, 42)
    let hats = NoteLog.capture(t.played).filter { $0.isDrum && $0.net.hasPrefix("hihat") }
    let offbeat = hats.filter { ($0.tick - 1) % 4 == 2 }
    try #require(!offbeat.isEmpty)
    #expect(offbeat.allSatisfy { $0.note == DJMusicality.openHatNote }, "\(genre)")
    #expect(!hats.contains { ($0.tick - 1) % 4 != 2 && $0.note == DJMusicality.openHatNote })
    let closed = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.openHats))
    let before = NoteLog.capture(closed).filter { $0.isDrum && $0.net.hasPrefix("hihat") }
    #expect(
      before.map(\.tick) == hats.map(\.tick) && before.map(\.velocity) == hats.map(\.velocity))
    let deck = WaveRunner.prepare(t.played, sampleRate: 22_050, opts: .extended)
    #expect(deck.lanes.contains { $0.voice.kind == "openhat" && $0.netId.hasPrefix("hihat") })
    for other in ["dnb", "jazz", "lofi"] {
      let o = played(other, 42)
      #expect(
        o.played.canonicalJSON
          == DJMusicality.apply(o.composed, spec: o.spec, fixes: .all.subtracting(.openHats))
          .canonicalJSON, "\(other)")
    }
  }

  /// Melody notes last until the next one (at most a beat) instead of a sixteenth each; the
  /// line's onsets, pitches and velocities are the same.
  @Test(arguments: ["techno", "trance", "funk", "lofi", "jazz", "ambient"])
  func melodiesAreHeld(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let blips = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.legato))
      let before = try #require(report(blips).melodyLegato)
      let after = try #require(report(t.played).melodyLegato)
      #expect(before < 0.9, "\(genre)/\(seed): already held (\(before))")
      #expect(after >= 0.99, "\(genre)/\(seed): \(after)")
      let melody = { (p: Project) in NoteLog.capture(p).filter { $0.group == "melody" } }
      let a = melody(blips)
      let b = melody(t.played)
      #expect(a.map(\.tick) == b.map(\.tick) && a.map(\.note) == b.map(\.note))
      #expect(a.map(\.velocity) == b.map(\.velocity))
      #expect(b.allSatisfy { $0.steps <= Double(DJMusicality.legatoMax) })
    }
  }

  /// A melody phrase (before half a bar of rest, or a 4-bar line) ends on a tone of the bar's
  /// chord; only those notes move, by a fourth at most, and stay in key.
  @Test(arguments: ["techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "funk"])
  func phrasesEndOnChordTones(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      // (`.motif` rewrites bar 2 from bar 1: left out of both sides of the A/B)
      let open = DJMusicality.apply(
        t.composed, spec: t.spec, fixes: .all.subtracting([.cadence, .motif]))
      let closed = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.motif))
      let after = try #require(report(t.played).phraseEndsOnChordTones)
      #expect(after >= 0.95, "\(genre)/\(seed): \(after)")
      #expect(try #require(report(closed).phraseEndsOnChordTones) >= 0.95)
      let melody = { (p: Project) in NoteLog.capture(p).filter { $0.group == "melody" } }
      let a = melody(open)
      let b = melody(closed)
      #expect(a.map(\.tick) == b.map(\.tick))
      #expect(zip(a, b).allSatisfy { abs($0.note - $1.note) <= 5 })
      #expect(report(closed).inKey >= report(open).inKey)
    }
    // the open endings were really there
    let t = played("techno", 42)
    let open = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.cadence))
    #expect(try #require(report(open).phraseEndsOnChordTones) < 0.8)
  }

  /// Where the bass line moves, it walks into the next chord: the arrival at a new root comes
  /// from a scale step away. Downbeats (the roots) and every onset stay; the offbeat-bass
  /// genres and jazz's walking bass are left alone.
  @Test(arguments: ["house", "dnb", "dubstep", "synthwave", "funk"])
  func bassApproachesChordChanges(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let plain = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.approach))
      let before = try #require(report(plain).bassStepwise)
      let after = try #require(report(t.played).bassStepwise)
      #expect(after >= 0.95, "\(genre)/\(seed): \(before) → \(after)")
      #expect(after >= before)
      let bass = { (p: Project) in NoteLog.capture(p).filter { $0.group == "bass" } }
      let a = bass(plain)
      let b = bass(t.played)
      #expect(a.map(\.tick) == b.map(\.tick))
      let pcs = scalePCs(t.played)
      for (x, y) in zip(a, b) where x.note != y.note {
        #expect((x.tick - 1) % 16 >= 8, "\(genre)/\(seed): moved a first-half note at \(x.tick)")
        #expect(pcs.contains(y.note % 12))
      }
      let rooted = try #require(report(plain).bassOnRoot)
      #expect(try #require(report(t.played).bassOnRoot) >= rooted)
    }
    for other in ["techno", "trance", "jazz"] {
      let o = played(other, 42)
      #expect(
        o.played.canonicalJSON
          == DJMusicality.apply(o.composed, spec: o.spec, fixes: .all.subtracting(.approach))
          .canonicalJSON, "\(other)")
    }
  }

  /// Each 4-bar melody phrase states its idea twice: bar 2 has bar 1's rhythm and shape (beats'
  /// random walk almost never repeats one), on bar 2's chord, ending open (a chord tone, not the
  /// root). Bars 1, 3 and 4 and every other part are as before; notes stay in key, beats on
  /// chord tones.
  @Test(arguments: ["techno", "house", "edm", "trance", "dnb", "synthwave", "lofi", "funk", "jazz"])
  func ideasAreStatedTwice(genre: String) throws {
    for seed in [7.0, 42] {
      let t = played(genre, seed)
      let plain = DJMusicality.apply(t.composed, spec: t.spec, fixes: .all.subtracting(.motif))
      let a = report(plain)
      let b = report(t.played)
      let before = try #require(a.melodyIdeaRepeats)
      let after = try #require(b.melodyIdeaRepeats)
      #expect(before < 0.4, "\(genre)/\(seed): already repeats (\(before))")
      #expect(after >= 0.8, "\(genre)/\(seed): \(before) → \(after)")
      #expect(b.inKey >= a.inKey - 0.005)
      #expect(try #require(b.chordTonesOnBeats) >= (a.chordTonesOnBeats ?? 0) - 0.02)
      #expect(
        try #require(b.phraseEndsOnChordTones) >= (a.phraseEndsOnChordTones ?? 0) - 0.02)
      // only melody bars 2 (mod 4) changed
      let other = { (p: Project) in
        NoteLog.capture(p).filter { $0.group != "melody" || ($0.tick - 1) % 64 / 16 != 1 }
      }
      let x = other(plain)
      let y = other(t.played)
      #expect(x.map(\.tick) == y.map(\.tick) && x.map(\.note) == y.map(\.note), "\(genre)/\(seed)")
    }
  }
}
