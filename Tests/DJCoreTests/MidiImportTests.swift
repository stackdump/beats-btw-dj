import Testing

@testable import DJCore

struct MidiImportTests {
  @Test func parsesNotesTempoAndSignature() throws {
    let m = try MidiImport.parse(sampleMidi())
    #expect(m.format == 1 && m.ticksPerQuarter == 480 && m.title == "Demo")
    #expect(m.tempos.first?.microsPerQuarter == 600_000)
    #expect(m.timeSignature?.numerator == 4 && m.timeSignature?.denominator == 4)
    let drums = try #require(m.sources.first { $0.isDrums })
    #expect(drums.notes.count == 13)
    let bass = try #require(m.sources.first { $0.channel == 1 })
    #expect(bass.program == 33 && bass.notes.map(\.pitch) == [36, 43])
    #expect(bass.notes[0].end - bass.notes[0].start == 480)
  }

  @Test func sortsChannelsIntoRolesAndQuantisesToSixteenths() throws {
    let r = try MidiImport.convert(sampleMidi(), file: "/x/demo.mid")
    let env = r.envelope
    #expect(env["tempo"]?.double == 100 && env["name"]?.string == "Demo")
    #expect(env["note"]?.string?.contains("demo.mid") == true)
    let p = try #require(Share(payload: env).rawNetsProject())
    // 8 beats = 2 bars = 32 steps
    #expect(p.nets["kick"]?.places.count == 32)
    #expect(
      Set(p.nets.keys) == ["kick", "snare", "bass", "melody", "harmony", "harmony-b", "harmony-c"])
    // a beat is 4 steps: kicks on 0 4 8 …, snares on the odd beats
    #expect(
      p.nets["kick"]?.bindings["t4"]?.note == 36 && p.nets["snare"]?.bindings["t4"]?.note == 38)
    #expect(p.nets["snare"]?.bindings["t0"] == nil && p.nets["snare"]?.bindings["t12"]?.note == 38)
    #expect(
      p.nets["bass"]?.bindings["t0"]?.durationSteps == 4
        && p.nets["bass"]?.bindings["t8"]?.note == 43)
    #expect(
      p.nets["melody"]?.bindings["t4"]?.note == 76 && p.nets["melody"]?.bindings["t16"]?.note == 79)
    #expect(p.nets["bass"]?.track.instrument == "bass")
    #expect(p.nets["harmony"]?.track.instrument == "warm-pad")
    // the report says what the grid left out
    #expect(r.summary["dropped"]?["drumsWithoutARole"]?.int == 1)
    #expect(r.summary["totalBars"]?.int == 2 && r.summary["bars"]?.int == 2)
    let roles = r.summary["sources"]?.array?.compactMap { $0["role"]?.string }
    #expect(roles == ["drums", "bass", "melody", "harmony"])
  }

  @Test func anExcerptAndAMapAndATempoOverrideApply() throws {
    var o = MidiImport.Options()
    o.from = 1
    o.bars = 1
    o.tempo = 140
    o.map = ["3": "arp", "4": "skip"]
    let r = try MidiImport.convert(sampleMidi(), file: "d.mid", options: o)
    #expect(r.envelope["tempo"]?.double == 140)
    let p = try #require(Share(payload: r.envelope).rawNetsProject())
    #expect(p.nets["kick"]?.places.count == 16)
    #expect(p.nets["arp"]?.bindings["t0"]?.note == 79)  // bar 2's lead note, now step 0
    #expect(p.nets["harmony"] == nil && p.nets["bass"]?.bindings["t0"] == nil)
    #expect(r.summary["dropped"]?["outsideExcerpt"]?.int ?? 0 > 0)
  }

  @Test func refusesWhatItCannotRead() {
    #expect(throws: MidiImportError.notMidi) {
      try MidiImport.parse(junkData())
    }
    #expect(throws: MidiImportError.smpte) { try MidiImport.parse(smpteVariantOfSample()) }
    #expect(throws: MidiImportError.noNotes) { try MidiImport.parse(noteLessMidi()) }
  }

  @Test func theNewToolsAreListedWithTheirConventions() throws {
    for (tool, method) in [("dj_inspired", "composeRoll"), ("dj_import", "importScore")] {
      #expect(MCPBridge.methods[tool] == method)
      #expect(MCPBridge.tools.contains { $0["name"]?.string == tool })
    }
    #expect(MCPBridge.instructions.contains("Inspired by"))
    let env = try PianoRoll.envelope(
      JSONValue.parse(
        #"{"inspiredBy":"Avicii","brief":"126 BPM, C# minor","parts":{"kick":{"notes":[[0]]}}}"#))
    #expect(env["name"]?.string == "Avicii-style (original)")
    #expect(env["note"]?.string?.contains("no melody or lyric taken") == true)
    #expect(env["note"]?.string?.contains("126 BPM") == true)
  }
}
