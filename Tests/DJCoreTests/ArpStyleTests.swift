import Testing

@testable import DJCore

// `.arpStyle` (p64-arp-style): the arp's figure comes from the genre's pool — trance rolls up
// and down in sixteenths, synthwave climbs in eighths with octave jumps, edm plays up or broken
// sixteenths — and the seed still picks within it. Other genres keep `.arpeggio`'s full pool.

private let seeds: [Double] = (0..<30).map { Double(($0 * 104_729 + 12_345) % 999_999 + 1) }

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

struct ArpStyleTests {
  typealias Figure = DJMusicality.ArpFigure

  /// Trance: an up-and-down over 4–6 tones, every sixteenth: each note a ladder step from
  /// the last, the turns at the top and bottom of the ladder.
  @Test func tranceRollsUpAndDownInSixteenths() {
    for s in seeds {
      for variant in ["A", "B"] {
        let f = Figure.seeded(s, variant: variant, genre: "trance")
        #expect(f.shape == 2 && f.rate == 1 && !f.octaves, "\(s)/\(variant)")
        #expect((4...6).contains(f.span), "\(s)/\(variant): span \(f.span)")
        let tones = (0..<16).map(f.tone)
        for (a, b) in zip(tones, tones.dropFirst()) {
          #expect(abs(a - b) == 1, "\(s)/\(variant): \(tones)")
        }
        #expect(tones.allSatisfy { (0..<f.span).contains($0) })
      }
    }
    #expect(Figure.seeded(42, variant: "C", genre: "trance").rate == 2)
  }

  /// Synthwave: eighths only, each ladder tone played twice, the second an octave up.
  @Test func synthwaveClimbsInEighthsWithOctaveJumps() {
    for s in seeds {
      let f = Figure.seeded(s, variant: "A", genre: "synthwave")
      #expect(f.rate == 2 && f.octaves, "\(s)")
      for q in stride(from: 0, to: 16, by: 4) {
        #expect(f.tone(q) == f.tone(q + 2), "\(s): step \(q)")
        #expect(f.octave(q) == 0 && f.octave(q + 2) == 12, "\(s): step \(q)")
      }
    }
  }

  /// EDM: up or broken, every sixteenth.
  @Test func edmPlaysUpOrBrokenSixteenths() {
    var shapes = Set<Int>()
    for s in seeds {
      let f = Figure.seeded(s, variant: "A", genre: "edm")
      #expect([0, 3].contains(f.shape) && f.rate == 1 && !f.octaves, "\(s)")
      shapes.insert(f.shape)
    }
    #expect(shapes == [0, 3])
  }

  /// The seed still picks within each pool, and a genre without a style draws from the full
  /// pool exactly as `.arpeggio` did.
  @Test func theSeedStillPicksWithinThePool() {
    for genre in ["trance", "synthwave", "edm"] {
      let figures = Set(seeds.map { Figure.seeded($0, variant: "A", genre: genre) })
      #expect(figures.count >= 8, "\(genre): \(figures.count) figures in \(seeds.count) seeds")
    }
    for genre in ["techno", "house", "dnb", "ambient"] {
      for s in seeds.prefix(8) {
        #expect(Figure.seeded(s, variant: "A", genre: genre) == Figure.seeded(s, variant: "A"))
      }
    }
  }

  /// As played: every arp note still a tone of the bar's chord, the styled genres' arps
  /// differ from the full pool's, and synthwave's sit on the eighths, octave pairs.
  @Test(arguments: ["trance", "edm", "synthwave"])
  func playedArpsKeepTheChords(genre: String) throws {
    for seed in [7.0, 42] {
      let p = played(genre, seed)
      #expect(try #require(report(p).arpChordTones) == 1, "\(genre)/\(seed)")
      let arp = NoteLog.capture(p).filter { $0.group == "arp" }
      #expect(!arp.isEmpty, "\(genre)/\(seed)")
      let plain = NoteLog.capture(played(genre, seed, fixes: .all.subtracting(.arpStyle)))
        .filter { $0.group == "arp" }
      #expect(
        arp.map { [$0.tick, $0.note] } != plain.map { [$0.tick, $0.note] }, "\(genre)/\(seed)")
      for (_, bar) in Dictionary(grouping: arp, by: { ($0.tick - 1) / 16 }) {
        #expect(bar.count >= 8, "\(genre)/\(seed): \(bar.count) arp notes in a bar")
      }
      guard genre == "synthwave" else { continue }
      #expect(arp.allSatisfy { ($0.tick - 1) % 2 == 0 }, "\(genre)/\(seed): off the eighths")
      var at: [String: Int] = [:]
      for e in arp { at["\(e.net)/\(e.tick)"] = e.note }
      for e in arp where (e.tick - 1) % 4 == 2 {
        guard let first = at["\(e.net)/\(e.tick - 2)"] else { continue }
        #expect(e.note == first + 12, "\(genre)/\(seed): tick \(e.tick)")
      }
    }
  }

  /// Genres without a style (house has no arp role at all) play exactly what they did.
  @Test(arguments: ["house", "techno", "dnb"])
  func otherGenresAreUnchanged(genre: String) {
    let a = played(genre, 42)
    let b = played(genre, 42, fixes: .all.subtracting(.arpStyle))
    #expect(a.canonicalJSON == b.canonicalJSON, "\(genre)")
  }
}
