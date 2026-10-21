import Testing

@testable import DJCore

struct MusicXMLImportTests {
  @Test func readsPartsTiesChordsGraceNotesTempoAndDrums() throws {
    let m = try MusicXMLImport.parse(sampleMusicXMLData())
    #expect(m.title == "Tiny Score" && m.ticksPerQuarter == 480)
    #expect(m.tempos.first?.microsPerQuarter == 666_667)  // 90 BPM
    #expect(m.timeSignature?.numerator == 4 && m.timeSignature?.denominator == 4)
    let lead = try #require(m.sources.first { $0.name == "Lead" })
    // C4 D4 E4(tied across the barline) · G4+B4 chord; the grace note is left out
    #expect(lead.notes.map(\.pitch) == [60, 62, 64, 67, 71])
    let tied = lead.notes[2]
    #expect(tied.start == 960 && tied.end == 960 + 3 * 480)
    #expect(lead.notes[3].start == 4 * 480 + 2 * 480 && lead.notes[4].start == lead.notes[3].start)
    let bass = try #require(m.sources.first { $0.name == "Bass" })
    #expect(bass.program == 33 && bass.notes.map(\.pitch) == [36, 43])
    let kit = try #require(m.sources.first { $0.name == "Kit" })
    #expect(kit.isDrums && kit.notes.map(\.pitch) == [35, 38])  // midi-unpitched is 1-based
    #expect(m.warnings.contains("graceNotes: 1"))
  }

  @Test func convertsThroughTheSameRolePipelineAsMidi() throws {
    let r = try ScoreImport.convert(sampleMusicXMLData(), file: "/x/tiny.musicxml")
    #expect(r.envelope["tempo"]?.double == 90 && r.envelope["name"]?.string == "Tiny Score")
    let p = try #require(Share(payload: r.envelope).rawNetsProject())
    #expect(p.nets["kick"]?.places.count == 32)
    #expect(
      p.nets["kick"]?.bindings["t0"]?.note == 36 && p.nets["snare"]?.bindings["t8"]?.note == 38)
    #expect(p.nets["bass"]?.bindings["t0"]?.durationSteps == 16)
    #expect(p.nets["melody"]?.bindings["t8"]?.durationSteps == 12)  // the tie
    #expect(
      p.nets["melody"]?.bindings["t24"]?.note == 67
        && p.nets["melody-b"]?.bindings["t24"]?.note == 71)
    #expect(p.nets["bass"]?.track.instrument == "bass")
    let warnings = r.summary["warnings"]?.array?.compactMap(\.string) ?? []
    #expect(warnings.contains("graceNotes: 1"))
  }

  @Test func aZippedMxlUnpacksThroughItsContainer() throws {
    let r = try ScoreImport.convert(sampleMXLData(), file: "/x/tiny.mxl")
    #expect(r.summary["title"]?.string == "Tiny Score")
    #expect(r.summary["parts"]?.array?.count == 4)  // kick snare bass melody
  }

  @Test func refusesWhatItCannotRead() {
    #expect(throws: MidiImportError.self) { try MusicXMLImport.parse(notMusicXMLData()) }
    #expect(throws: MidiImportError.self) {
      try ScoreImport.convert(junkData(), file: "/x/song.mp3")
    }
  }
}
