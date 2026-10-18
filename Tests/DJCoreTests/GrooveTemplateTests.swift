import Testing

@testable import DJCore

// Groove templates (ROADMAP 6.5): Resources/beats/grooves.json, distilled from the Groove MIDI
// Dataset by scripts/groove-templates.py. These hold the checked-in table to its contract;
// `make groove-templates && git diff --exit-code` holds it to the dataset.

@Suite struct GrooveTemplateTests {
  @Test func everyFamilyAndGenreHasATemplate() throws {
    let all = GrooveTemplate.all
    #expect(Set(all.keys) == Set(GrooveTemplate.familyNames))
    for (i, name) in GrooveTemplate.familyNames.enumerated() {
      #expect(GrooveTemplate.family(index: i)?.family == name)
    }
    let genres = BeatsTables.shared.genreIDs
    #expect(genres.count >= 19)
    for g in genres + ["wrapped"] {
      let t = try #require(GrooveTemplate.forGenre(g), "\(g)")
      #expect(t.index == BeatsTables.shared.family(of: g), "\(g)")
    }
    #expect(GrooveTemplate.forGenre("techno")?.family == "dance")
    #expect(GrooveTemplate.forGenre("funk")?.family == "song")
    #expect(GrooveTemplate.forGenre("bossa")?.family == "jazz")
    #expect(GrooveTemplate.forGenre("lofi")?.family == "chill")
  }

  @Test func valuesAreInRange() {
    for t in GrooveTemplate.all.values {
      #expect(t.files > 0 && !t.styles.isEmpty, "\(t.family)")
      #expect(t.offsetMs.count == GrooveTemplate.Voice.allCases.count)
      for v in GrooveTemplate.Voice.allCases {
        let off = t.offsetMs[v.rawValue]
        let vel = t.velocity[v.rawValue]
        #expect(off.count == 16 && vel.count == 16 && t.hits[v.rawValue].count == 16)
        #expect(
          off.allSatisfy { (0...GrooveTemplate.maxOffsetMs).contains($0) }, "\(t.family).\(v)")
        #expect(vel.allSatisfy { GrooveTemplate.velocityRange.contains($0) }, "\(t.family).\(v)")
        // Thin cells are neutral.
        for s in 0..<16 where t.hits[v.rawValue][s] < 20 {
          #expect(off[s] == 0 && vel[s] == 1, "\(t.family).\(v)[\(s)]")
        }
      }
      // A drummer's hats are not flat: more than one velocity across the bar (exit M6).
      #expect(Set(t.velocity[GrooveTemplate.Voice.hihat.rawValue]).count > 1, "\(t.family)")
      // A backbeat (2 and 4) louder than the snare's average, except where it comps (jazz).
      let snare = t.velocity[GrooveTemplate.Voice.snare.rawValue]
      if t.family != "jazz" { #expect(snare[4] > 1.2 && snare[12] > 1.2, "\(t.family)") }
      // Swing within Linn's straight … triplet at every tempo.
      for bpm in stride(from: 40.0, through: 300, by: 5) {
        let r = t.swing.ratio(bpm: bpm)
        #expect(r >= 0.5 && r <= 0.66, "\(t.family) \(bpm)")
      }
    }
    #expect(GrooveTemplate.all["jazz"]?.swing.grid == .eighth)
    #expect(GrooveTemplate.all["song"]?.swing.grid == .sixteenth)
  }

  @Test func provenanceMatchesTheScriptsPin() throws {
    let parsed = try grooveTable()
    #expect(parsed.provenance.license.hasPrefix("CC BY 4.0"))
    #expect(parsed.provenance.minHits == 20)
    let script = try repoText("scripts/groove-templates.py")
    #expect(script.contains("GMD_SHA256 = \"\(parsed.provenance.sha256)\""))
    #expect(script.contains("GMD_URL = \"\(parsed.provenance.url)\""))
    let readme = try repoText("README.md")
    #expect(readme.contains("Groove MIDI Dataset") && readme.contains("CC BY 4.0"))
  }

  @Test func voicesFoldTheDatasetsKit() {
    #expect(GrooveTemplate.Voice(note: 36) == .kick)
    #expect(GrooveTemplate.Voice(note: 38) == .snare)
    #expect(GrooveTemplate.Voice(note: 39) == .snare)
    #expect(GrooveTemplate.Voice(note: 42) == .hihat)
    #expect(GrooveTemplate.Voice(note: 46) == .openHat)
    #expect(GrooveTemplate.Voice(note: 51) == .ride)
    #expect(GrooveTemplate.Voice(note: 49) == nil)
    #expect(
      GrooveTemplate.Voice.allCases.map(\.name) == ["kick", "snare", "hihat", "openHat", "ride"])
  }

  @Test func swingIsTempoScaledAndClamped() {
    let s = GrooveTemplate.Swing(
      grid: .sixteenth, intercept: 0.3, perBpm: 0.003, bpmRange: 80...140)
    #expect(abs(s.ratio(bpm: 100) - 0.6) < 1e-9)
    #expect(abs(s.ratio(bpm: 60) - 0.54) < 1e-9)  // bpm clamps to 80
    #expect(s.ratio(bpm: 200) == 0.66)  // 140 → 0.72, held at triplet
    // 120 bpm: a sixteenth is 125 ms, the pair 250 ms; ratio 0.66 → off-beat 40 ms late.
    #expect(abs(s.delayMs(bpm: 120) - 0.16 * 250) < 1e-9)
    let e = GrooveTemplate.Swing(grid: .eighth, intercept: 0.6, perBpm: 0, bpmRange: 60...200)
    #expect(abs(e.delayMs(bpm: 120) - 0.1 * 500) < 1e-9)
  }

  @Test func preparedFoldsSwingIntoTheOffBeats() throws {
    for t in GrooveTemplate.all.values {
      let bpm = 110.0
      let sr = 48_000.0
      let p = t.prepared(bpm: bpm, sampleRate: sr)
      #expect(p.delaySamples.count == 5 * 16 && p.velocityScale.count == 5 * 16)
      #expect(p.swingRatio == t.swing.ratio(bpm: bpm))
      let swingSamples = t.swing.delayMs(bpm: bpm) / 1000 * sr
      let pair = t.swing.pairSteps
      for v in GrooveTemplate.Voice.allCases {
        for step in 0..<32 {
          let s = step % 16
          let swung = s % pair == pair / 2
          let want = t.offsetMs(v, step: s) / 1000 * sr + (swung ? swingSamples : 0)
          #expect(abs(p.delay(v, step: step) - want) < 1e-9)
          #expect(p.velocity(v, step: step) == t.velocity(v, step: s))
        }
      }
      #expect(p.delay(.kick, step: 0) == t.offsetMs(.kick, step: 0) / 1000 * sr)
    }
  }
}
