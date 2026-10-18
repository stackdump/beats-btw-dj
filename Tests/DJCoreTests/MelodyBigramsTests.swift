import Testing

@testable import DJCore

// Melody bigrams (ROADMAP 6.4): Resources/beats/melody-bigrams.json, counted from the RS200
// vocal transcriptions by scripts/melody-bigrams.py. These hold the checked-in table to its
// contract; `make melody-bigrams && git diff --exit-code` holds it to the corpus.

@Suite struct MelodyBigramsTests {
  @Test func tableLoadsAndRowsSumToOne() {
    let t = MelodyBigrams.default
    #expect(MelodyBigrams.all.keys.contains("default"))
    #expect(t.songs >= 190 && t.bigrams > 50_000)
    #expect(t.next.count == 7 && t.moves.count == 7 && t.counts.count == 7)
    for i in 0..<7 {
      #expect(abs(t.next[i].reduce(0, +) - 1) < 1e-3, "next[\(i)]")
      #expect(abs(t.moves[i].reduce(0, +) - 1) < 1e-3, "moves[\(i)]")
      #expect(t.moves[i][i] == 0)
      #expect(t.next[i].allSatisfy { $0 >= 0 })
    }
    #expect(abs(t.unigram.reduce(0, +) - 1) < 1e-3)
    // The tonic is the most sung degree, then 3, then 5.
    let byUse = (0..<7).sorted { t.unigram[$0] > t.unigram[$1] }
    #expect(Array(byUse.prefix(3)) == [0, 2, 4])
  }

  @Test func intervalSharesMatchTheCorpus() {
    let t = MelodyBigrams.default
    // The shares the table implies are the ones the script recorded.
    #expect(abs(t.stepShare - t.stats.steps) < 2e-3)
    #expect(abs(t.repeatShare - t.stats.repeats) < 2e-3)
    #expect(t.repeatShare <= 0.35)
    // Once the melody moves, steps dominate (≥ 0.45 is ROADMAP 6.4's target for the pass).
    #expect(t.stats.stepsOfMoves >= 0.45)
    #expect(abs(t.stats.stepsOfMoves - t.stepShare / (1 - t.repeatShare)) < 2e-3)
    // With repeats in, RS200's singers step 0.40 of the time (pitch: 0.41), not 0.45: the
    // pass gets to 0.45 by moving repeats (`moves`), not by copying `next`.
    #expect(t.stepShare >= 0.38)
    #expect(t.stats.pitchSteps >= 0.38 && t.stats.pitchRepeats <= 0.35)
    #expect(abs(t.stats.pitchRepeats + t.stats.pitchSteps + t.stats.pitchLeaps - 1) < 1e-3)
  }

  @Test func likelyNextDegrees() {
    let t = MelodyBigrams.default
    #expect(t.mostLikely(after: 1) == 0)  // 2 falls to the tonic
    #expect(t.mostLikely(after: 3) == 2)  // 4 falls to 3
    #expect(t.mostLikely(after: 6, moving: true) == 0)  // the leading tone resolves
    #expect(t.mostLikely(after: 0, moving: true) != 0)
    for d in 0..<7 { #expect(t.mostLikely(after: d, moving: true) != d) }
    // Degrees wrap: 7 is the tonic an octave up, −1 the 7th below.
    #expect(t.probability(from: 7, to: -1) == t.next[0][6])
    #expect(t.mostLikely(after: 8) == t.mostLikely(after: 1))
  }

  @Test func provenanceMatchesTheScriptsPin() throws {
    let parsed = try melodyBigramsFile()
    #expect(parsed.provenance.license.hasPrefix("CC BY 4.0"))
    #expect(parsed.provenance.source.contains("RS200"))
    let script = try repoText("scripts/melody-bigrams.py")
    #expect(script.contains("RS200_SHA256 = \"\(parsed.provenance.sha256)\""))
    #expect(script.contains("RS200_URL = \"\(parsed.provenance.url)\""))
    let readme = try repoText("README.md")
    #expect(readme.contains("RS200") && readme.contains("de Clercq"))
    let makefile = try repoText("Makefile")
    #expect(makefile.contains("melody-bigrams:"))
  }

  @Test func parseRejectsABrokenTable() throws {
    // A row that no longer sums to 1.
    #expect(throws: (any Error).self) {
      try melodyBigramsEdited(replacing: "[0.4248, ", with: "[0.9248, ")
    }
    // Degrees other than 1…7.
    #expect(throws: (any Error).self) {
      try melodyBigramsEdited(replacing: "\"7\"]", with: "\"8\"]")
    }
    #expect(try melodyBigramsFile().tables["default"] == MelodyBigrams.default)
  }
}
