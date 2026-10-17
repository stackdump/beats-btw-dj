import Testing

@testable import DJCore

// `.variety` (TrackVariety.swift) and the seeded `.arpeggio`: two seeds of a genre are two
// different songs, part by part — measured on loops (cheap: a few bars per track), 30 seeds
// spread over the Generate range.

private let seeds: [Double] = (0..<30).map { Double(($0 * 104_729 + 12_345) % 999_999 + 1) }

/// A 4-bar loop of `genre` / `seed` as the deck plays it with `fixes`.
private func loop(_ genre: String, _ seed: Double, fixes: DJMusicality.Fixes = .all) -> Project {
  let spec = TrackSpec(genre: genre, seed: seed)
  return DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
}

/// The first four bars of each part, as (tick, note) pairs; drums are one part.
private func phrases(_ p: Project) -> [String: [[Int]]] {
  var out: [String: [[Int]]] = [:]
  for e in NoteLog.capture(p, ticks: 64) where e.group != "stinger" && !e.group.hasPrefix("fill-") {
    out[e.isDrum ? "drums" : e.group, default: []].append([e.tick, e.note])
  }
  return out
}

/// How many different 4-bar patterns each part plays across `seeds`.
private func distinct(_ genre: String, fixes: DJMusicality.Fixes = .all) -> [String: Int] {
  var seen: [String: Set<[[Int]]>] = [:]
  for s in seeds {
    for (part, notes) in phrases(loop(genre, s, fixes: fixes)) {
      seen[part, default: []].insert(notes)
    }
  }
  return seen.mapValues(\.count)
}

private func jaccard(_ a: [[Int]], _ b: [[Int]]) -> Double {
  let x = Set(a)
  let y = Set(b)
  return Double(x.intersection(y).count) / Double(max(1, x.union(y).count))
}

struct VarietyTests {
  /// Every part changes with the seed: beats' generator gave every seed of a genre the same
  /// bass, chords and drums (one to three patterns in 30 seeds) and dj's first `.arpeggio`
  /// the same arp; the melody was already the seed's own, and stays so.
  @Test(arguments: ["techno", "house", "trance", "lofi", "jazz", "dnb"])
  func everyPartVariesWithTheSeed(genre: String) throws {
    let n = distinct(genre)
    #expect(try #require(n["bass"]) >= 8, "\(genre): \(n)")
    #expect(try #require(n["harmony"]) >= 6, "\(genre): \(n)")
    #expect(try #require(n["drums"]) >= 4, "\(genre): \(n)")
    #expect(try #require(n["melody"]) == seeds.count, "\(genre): \(n)")
    if let arp = n["arp"] { #expect(arp >= 10, "\(genre): \(n)") }
    // A/B: without the flag the backing is the genre's, whatever the seed
    let plain = distinct(genre, fixes: .all.subtracting(.variety))
    for part in ["bass", "harmony", "drums"] {
      #expect(n[part]! > plain[part] ?? 0, "\(genre) \(part): \(plain) → \(n)")
    }
    #expect(try #require(plain["bass"]) <= 3, "\(genre): the backing was the genre's")
  }

  /// The melodies of two seeds share few notes (pitch at a tick).
  @Test(arguments: ["techno", "house", "trance", "lofi", "jazz", "dnb"])
  func melodiesShareFewNotes(genre: String) {
    let tunes = seeds.prefix(12).map { phrases(loop(genre, $0))["melody"] ?? [] }
    var sum = 0.0
    var pairs = 0
    for i in tunes.indices {
      for j in tunes.indices where j > i {
        sum += jaccard(tunes[i], tunes[j])
        pairs += 1
      }
    }
    #expect(sum / Double(pairs) <= 0.25, "\(genre): mean pitch Jaccard \(sum / Double(pairs))")
  }

  /// Not only another key: in the seven-note genres the chords themselves change (the pad's
  /// pattern relative to the track's root differs between seeds).
  @Test(arguments: ["techno", "house", "trance", "jazz", "dnb"])
  func progressionsChangeNotJustTheKey(genre: String) {
    var shapes = Set<[[Int]]>()
    for s in seeds {
      let p = loop(genre, s)
      let root = p.rootNote ?? 0
      shapes.insert((phrases(p)["harmony"] ?? []).map { [$0[0], (($0[1] - root) % 12 + 12) % 12] })
    }
    #expect(shapes.count >= 3, "\(genre): \(shapes.count) progressions in \(seeds.count) seeds")
  }

  /// The arp's figure is the seed's (and the slot's): with `.variety` off, a song's arp still
  /// differs from seed to seed (dj's first `.arpeggio` played one figure on beats' chords, so
  /// every trance song had the same arp). Songs, not loops: a loop's arp ring is shorter than
  /// the pad's cycle, so `.arpeggio` leaves it as beats composed it.
  @Test func arpFiguresVaryWithTheSeed() {
    var songs = Set<[[Int]]>()
    for s in seeds.prefix(12) {
      let spec = TrackSpec(genre: "trance", seed: s, structure: "minimal")
      let p = DJMusicality.apply(spec.project(), spec: spec, fixes: .all.subtracting(.variety))
      songs.insert(NoteLog.capture(p).filter { $0.group == "arp" }.map { [$0.tick, $0.note] })
    }
    #expect(songs.count >= 10, "\(songs.count) arps in 12 seeds")
    var figures = Set<DJMusicality.ArpFigure>()
    for s in seeds { figures.insert(.seeded(s, variant: "A")) }
    #expect(figures.count >= 10)
    #expect(DJMusicality.ArpFigure.seeded(42, variant: "C").rate == 2)
  }

  /// A pure function of the spec (the theme's derivation rule): the same seed lands on the
  /// same track, a section jump's recompile included.
  @Test func deterministicFromTheSeed() {
    for genre in ["techno", "jazz", "trance"] {
      let spec = TrackSpec(genre: genre, seed: 4242, structure: "standard")
      let a = DJMusicality.apply(spec.project(), spec: spec)
      let b = DJMusicality.apply(spec.project(), spec: spec)
      #expect(a.canonicalJSON == b.canonicalJSON, "\(genre)")
    }
  }

  /// The key moves with the root: every tonal note in the new key, the project's root
  /// moved by the same offset as the notes (so `.kickTune` tunes the kick to it), the
  /// melody's beat notes still chord tones, and no more semitone rubs than beats' own key.
  @Test(arguments: ["techno", "house", "trance", "jazz", "dnb", "lofi", "edm"])
  func stillInKeyAndOnTheChords(genre: String) throws {
    var moved = 0
    var retuned = 0
    var clashes = (with: 0.0, without: 0.0)
    for s in seeds.prefix(10) {
      let spec = TrackSpec(genre: genre, seed: s, structure: "standard")
      let composed = spec.project()
      let a = DJMusicality.apply(composed, spec: spec, fixes: .all.subtracting(.variety))
      let b = DJMusicality.apply(composed, spec: spec)
      let ra = MusicalityReport(project: a, log: NoteLog.capture(a))
      let rb = MusicalityReport(project: b, log: NoteLog.capture(b))
      #expect(rb.inKey >= ra.inKey - 0.01, "\(genre)/\(s): in key \(ra.inKey) → \(rb.inKey)")
      if let x = ra.chordTonesOnBeats, let y = rb.chordTonesOnBeats {
        #expect(y >= x - 0.1, "\(genre)/\(s): chord tones on beats \(x) → \(y)")
      }
      clashes.with += rb.semitoneClashes
      clashes.without += ra.semitoneClashes
      if b.rootNote != a.rootNote { moved += 1 }
      if KickTuning.hz(root: b.rootNote) != KickTuning.hz(root: a.rootNote) { retuned += 1 }
    }
    #expect(moved >= 5, "\(genre): \(moved) of 10 seeds in another key")
    #expect(retuned >= 3, "\(genre): the kick follows the key in \(retuned) of 10")
    #expect(
      clashes.with <= clashes.without + 10, "\(genre): rubs per 100 pairs, ×10 seeds \(clashes)")
  }
}
