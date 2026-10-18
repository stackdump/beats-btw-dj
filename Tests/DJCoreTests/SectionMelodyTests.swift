import Testing

@testable import DJCore

// `.sectionHarmony`'s pass half (ROADMAP 6.3, dj first): the melody / arp nets beats moved for
// a bridge or a solo go back to the home harmony, and the runner then moves the whole band
// (`SectionTransposeTests`). Measured with `NoteLog` mapped through the plan, as `djctl render`
// reports it.

/// A track with a section the runner moves and melody nets beats moved there.
struct BridgeSong: @unchecked Sendable {
  let spec: TrackSpec
  let composed: Project

  /// The project after `fixes`.
  func played(_ fixes: DJMusicality.Fixes = .all) -> Project {
    DJMusicality.apply(composed, spec: spec, fixes: fixes)
  }

  /// The first standard / extended song (genres sorted, seeds 1…6, seed 42 first) with a
  /// bridge, a plan and at least one melody net to normalise.
  static let first: BridgeSong? = {
    for structure in ["standard", "extended"] {
      for genre in BeatsTables.shared.genres.keys.sorted() {
        for seed in [42.0] + (1...6).map(Double.init) {
          let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
          let composed = spec.project()
          guard composed.structure.contains(where: { $0.name == "bridge" }),
            composed.cohesion == "v2", SectionHarmony(project: composed) != nil
          else { continue }
          let early = DJMusicality.apply(composed, spec: spec, fixes: [.key, .phrases, .timing])
          let theme = buildTrackTheme(genre: genre, seed: seed)
          if DJMusicality.sectionMelodyShifts(early, theme: theme).contains(where: {
            $0.degrees == 5
          }) {
            return BridgeSong(spec: spec, composed: composed)
          }
        }
      }
    }
    return nil
  }()
}

/// Every bound note of a net, by transition.
func boundNotes(_ nb: NetBundle) -> [String: Int] {
  Dictionary(uniqueKeysWithValues: nb.bindings.pairs.map { ($0.key, $0.value.note) })
}

/// Every bound note of a project, by net and transition.
func boundNotes(_ p: Project) -> [String: [String: Int]] {
  Dictionary(uniqueKeysWithValues: p.nets.pairs.map { ($0.key, boundNotes($0.value)) })
}

/// The lowest agreement of the sections named `name`.
private func agreement(_ r: MusicalityReport, _ name: String) -> Double? {
  r.sectionChordAgreementBySection.filter { $0.section == name }.map(\.agreement).min()
}

struct SectionMelodyTests {
  /// Only melody / arp slot nets that sound only in bridge or solo sections change, each moved
  /// back by its section's shift, diatonically; places, transitions and arcs never change.
  @Test func onlyBridgeAndSoloMelodyNetsChange() throws {
    let song = try #require(BridgeSong.first)
    let before = song.played([.key, .phrases, .timing])
    let after = song.played([.key, .phrases, .timing, .sectionHarmony])
    let theme = buildTrackTheme(genre: song.spec.genre, seed: song.spec.seed)
    let moved = DJMusicality.sectionMelodyShifts(before, theme: theme)
    #expect(!moved.isEmpty)
    let ids = Dictionary(uniqueKeysWithValues: moved.map { ($0.net, $0.degrees) })
    let windows = DJMusicality.slotWindows(before, role: "melody")
      .merging(DJMusicality.slotWindows(before, role: "arp")) { a, _ in a }
    let root = ((before.rootNote ?? 60) % 12 + 12) % 12
    let intervals = scaleIntervals(
      (before.scaleName.isEmpty ? "Major" : before.scaleName) + "Scale")
    #expect(after.nets.keys == before.nets.keys)
    for id in before.nets.keys {
      let a = before.nets[id]!
      let b = after.nets[id]!
      #expect(a.places.keys == b.places.keys, "\(id) places")
      #expect(a.transitions.keys == b.transitions.keys, "\(id) transitions")
      #expect(a.arcs.count == b.arcs.count, "\(id) arcs")
      #expect(a.bindings.keys == b.bindings.keys, "\(id) bound transitions")
      guard let d = ids[id] else {
        #expect(boundNotes(a) == boundNotes(b), "\(id) is not a bridge / solo melody net")
        continue
      }
      #expect(["melody", "arp"].contains(a.riffGroup), "\(id)")
      let names = Set(windows[id]?.map(\.sectionName) ?? [])
      #expect(!names.isEmpty && names.isSubset(of: ["bridge", "solo"]), "\(id) plays in \(names)")
      for t in a.bindings.keys where !isDrumChannel(a.bindings[t]!.channel) {
        let n = a.bindings[t]!.note
        #expect(
          b.bindings[t]!.note
            == SectionHarmony.shift(n, by: -d, root: root, intervals: intervals), "\(id) \(t)")
      }
    }
    #expect(after.structure.map(\.steps) == before.structure.map(\.steps))
  }

  /// In key, moving a note back by a section's shift and on again is the note itself (the
  /// runner's move undoes the pass's, octave aside: `groupDegrees` may pick the complement).
  @Test func shiftBackAndForthIsIdentity() {
    for scale in ["Major", "Minor", "Dorian"] {
      let iv = scaleIntervals(scale + "Scale")
      for root in [0, 2, 9] {
        let key = Set(iv.map { (root + $0) % 12 })
        for n in 24...100 where key.contains(n % 12) {
          for d in [5, 4, -2, 2] {
            let back = SectionHarmony.shift(n, by: -d, root: root, intervals: iv)
            #expect(SectionHarmony.shift(back, by: d, root: root, intervals: iv) == n)
          }
        }
      }
    }
  }

  /// Nothing to do where the runner wouldn't move the band, or where beats moved nothing: a
  /// loop, a five-note key, cohesion v1, the `hook` technique.
  @Test func leavesOtherTracksAlone() throws {
    let song = try #require(BridgeSong.first)
    var pentatonic = song.played([.key, .phrases, .timing])
    pentatonic.scaleName = "Pentatonic"
    var p = pentatonic
    DJMusicality.normaliseSectionMelody(&p, genre: genre(song), spec: song.spec)
    #expect(boundNotes(p) == boundNotes(pentatonic))

    var v1 = song.played([.key, .phrases, .timing])
    v1.cohesion = nil
    p = v1
    DJMusicality.normaliseSectionMelody(&p, genre: genre(song), spec: song.spec)
    #expect(boundNotes(p) == boundNotes(v1))

    var hooked = song.spec
    hooked.extra["hook"] = .bool(true)
    p = song.played([.key, .phrases, .timing])
    let q = p
    DJMusicality.normaliseSectionMelody(&p, genre: genre(song), spec: hooked)
    #expect(boundNotes(p) == boundNotes(q))

    let loop = TrackSpec(genre: song.spec.genre, seed: song.spec.seed, structure: nil)
    let lp = DJMusicality.apply(loop.project(), spec: loop, fixes: [.key, .phrases, .timing])
    p = lp
    DJMusicality.normaliseSectionMelody(&p, genre: genre(song), spec: loop)
    #expect(boundNotes(p) == boundNotes(lp))
  }

  /// The exit numbers: with the flag (pass + the runner's plan, as `djctl render` reports it)
  /// the bridge agrees with its chords ≥ 0.9 and the song has ≥ 2 progressions; without it the
  /// bridge agrees less. Prints both for the record.
  @Test func bridgeAgreesWithItsChords() throws {
    let song = try #require(BridgeSong.first)
    let on = song.played(.all)
    let off = song.played(.all.subtracting(.sectionHarmony))
    let harmony = try #require(SectionHarmony.playing(on, fixes: .all))
    #expect(SectionHarmony.playing(off, fixes: .all.subtracting(.sectionHarmony)) == nil)
    let (onNotes, onControls) = NoteLog.captureAll(on, harmony: harmony)
    let (offNotes, offControls) = NoteLog.captureAll(off)
    let with = MusicalityReport(project: on, log: onNotes, controls: onControls)
    let without = MusicalityReport(project: off, log: offNotes, controls: offControls)
    let a = try #require(agreement(with, "bridge"))
    let b = try #require(agreement(without, "bridge"))
    print(
      "\(song.spec.genre) \(song.spec.seed) \(song.spec.structure ?? "loop"): bridge agreement "
        + "\(round3(a)) with, \(round3(b)) without; progressions \(with.progressions ?? 0) "
        + "with, \(without.progressions ?? 0) without")
    #expect(a >= 0.9)
    #expect(b < a)
    #expect((with.progressions ?? 0) >= 2)
  }
}

private func genre(_ song: BridgeSong) -> GenreDef { BeatsTables.shared.genres[song.spec.genre]! }
