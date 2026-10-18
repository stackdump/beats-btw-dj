import Testing

@testable import DJCore

// M1 form metrics (ROADMAP 6.2): where structure events land, how late, and how long the
// intro, outro and song are.

private func formReport(
  _ genre: String, _ seed: Double, structure: String? = "standard",
  fixes: DJMusicality.Fixes
) -> MusicalityReport {
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  let p = DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

struct FormReportTests {
  /// Without `.timing` the accumulator lands changes after the bar; with `.timing` and
  /// `.phrases` every one is heard on a bar line.
  @Test func latenessIsGoneWithTimingAndPhrases() {
    for genre in ["techno", "house"] {
      let raw = formReport(genre, 42, fixes: [])
      #expect((raw.maxLatenessTicks ?? 0) > 0, "\(genre): unfixed changes land late")
      let fixed = formReport(genre, 42, fixes: [.timing, .phrases])
      #expect(fixed.maxLatenessTicks == 0, "\(genre): every change on a bar")
      #expect(fixed.structureOn4Bars != nil)
      #expect((fixed.structureOn4Bars ?? 0) >= (raw.structureOn4Bars ?? 0))
    }
  }

  /// `standard` songs open with a 4-bar intro today and have a length; a loop has neither.
  @Test func introOutroAndLength() {
    let song = formReport("techno", 42, fixes: .all)
    #expect(song.introBars == 4)
    #expect(song.outroBars != nil)
    #expect((song.songSeconds ?? 0) > 0)
    #expect(!song.phraseBars.isEmpty)
    #expect(song.phraseBars.allSatisfy { $0 > 0 })
    let d = song.dictionary
    #expect(d["introBars"] as? Int == 4)
    #expect(d["songSeconds"] != nil)

    let loop = formReport("techno", 42, structure: nil, fixes: .all)
    #expect(loop.introBars == nil)
    #expect(loop.outroBars == nil)
    #expect(loop.songSeconds == nil)
    #expect(loop.phraseBars.isEmpty)
    #expect(loop.structureOn4Bars == nil)
  }

  /// The metrics on a hand-made log: a change heard on step 64 is on the 4-bar line, one on
  /// step 66 is two sixteenths late.
  @Test func handMadeChanges() {
    var p = Project()
    p.tempo = 120
    p.structure = [
      Section(name: "intro", steps: 64), Section(name: "drop", steps: 128),
      Section(name: "outro", steps: 64),
    ]
    let controls = [
      PartChange(tick: 64, net: "struct-a", action: .unmute, target: "a"),
      PartChange(tick: 130, net: "struct-a", action: .mute, target: "a"),
    ]
    let r = MusicalityReport(project: p, log: [], controls: controls)
    #expect(r.structureOn4Bars == 0.5)
    #expect(r.maxLatenessTicks == 2)
    #expect(r.introBars == 4)
    #expect(r.outroBars == 4)
    #expect(r.songSeconds == 256 * 60 / (120 * 4))
    // events at 0, 64, 130, 192 and the end at 256
    #expect(r.phraseBars == [62.0 / 16, 4, 66.0 / 16])
  }
}
