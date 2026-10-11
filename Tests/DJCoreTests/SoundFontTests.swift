import Testing

@testable import DJCore

/// SoundFonts (`make soundfonts`): each category's `gm` programs from a .sf2 bank, after the
/// installed EXS pool and before the synth voice or Apple's GM. MuseScore_General.sf2 is the
/// floor. Tests that play the bank skip when it is not downloaded.
struct SoundFontTests {
  let sr = 48_000.0
  let catalog = VoiceCatalog.shared

  static var floor: String? {
    VoiceCatalog.shared.soundFonts.first {
      fileName($0) == SamplerSource.floorSoundFont
    }
  }

  /// The real rules and maps, no EXS content, one (absent) bank: the order alone.
  func bare(_ soundFonts: [String]) throws -> VoiceCatalog {
    try VoiceCatalog(
      json: .parse(try VoiceCatalog.loadText()), roots: [], soundFonts: soundFonts)
  }

  @Test func soundFontsComeAfterThePoolAndBeforeAppleGM() throws {
    let c = try bare(["/x/A.sf2"])
    #expect(
      c.sources(instrument: "piano", role: "melody", seed: 1)
        == [.sf2("/x/A.sf2", program: 0), .sf2("/x/A.sf2", program: 1), .gm(0), .gm(1)])
    // keepSynth with nothing installed: the SoundFont, not a synth pick, and never Apple's GM
    for seed in 0..<20 {
      #expect(
        c.sources(instrument: "distorted-guitar", role: "melody", seed: Double(seed))
          == [.sf2("/x/A.sf2", program: 30), .sf2("/x/A.sf2", program: 29)])
    }
    // without one, nothing changes: the synth voice
    #expect(try bare([]).sources(instrument: "distorted-guitar", role: "melody", seed: 3) == nil)
  }

  @Test func soundFontsAreFoundAndTheFloorIsLast() throws {
    try withScratchDir(files: [
      SamplerSource.floorSoundFont, "Zebra.sf2", "Alpha.SF2", "skip.sf3", "notes.md",
    ]) { dir in
      #expect(
        SamplerSource.soundFonts(in: dir).map(fileName)
          == ["Alpha.SF2", "Zebra.sf2", SamplerSource.floorSoundFont])
      #expect(SamplerSource.soundFonts(in: dir + "/none").isEmpty)
    }
  }

  /// The floor under every category: at least one of its `gm` programs loads from the bank
  /// and passes the bank's sound checks (not silent, within `maxDetuneCents`). Programs
  /// turned away are printed with the reason.
  @Test(.enabled(if: floor != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func everyCategoryHasASoundFontFloor() throws {
    let bank = try #require(Self.floor)
    var report: [String] = []
    for (category, programs) in catalog.gm.sorted(by: { $0.key < $1.key }) {
      var loads = false
      for p in programs {
        let b = SamplerBank(sampleRate: sr)
        let s = SamplerSource.sf2(bank, program: p)
        if b.slot(for: [s]) != nil {
          loads = true
        } else {
          report.append("\(category)\t\(s)\t\(b.loadFailure(for: s) ?? "?")")
        }
      }
      #expect(loads, "\(category): no SoundFont program of \(programs) plays")
    }
    print("SoundFont programs turned away (\(report.count)):")
    for line in report { print("  " + line) }
  }

  /// With the floor installed, no tonal category ends on Apple's General MIDI: each plays an
  /// installed sound, a SoundFont program or (keepSynth) its synth voice.
  @Test(.enabled(if: floor != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func everyTonalCategoryResolvesAboveAppleGM() {
    let bank = SamplerBank(sampleRate: sr)
    var by: [String: String] = [:]
    for (instrument, category) in catalog.categoryOf.sorted(by: { $0.value < $1.value })
    where by[category] == nil {
      let sources = catalog.sources(instrument: instrument, role: "melody", seed: 0)
      guard let sources else {
        #expect(catalog.keepSynth.contains(category), "\(category) has nothing to play")
        by[category] = "synth"
        continue
      }
      let firstGM = sources.firstIndex { if case .gm = $0 { true } else { false } }
      let firstSF2 = sources.firstIndex { if case .sf2 = $0 { true } else { false } }
      #expect(firstSF2 != nil, "\(category) offers no SoundFont program")
      if let firstGM, let firstSF2 { #expect(firstSF2 < firstGM) }
      guard let slot = bank.slot(for: sources) else {
        Issue.record("\(category): nothing in \(sources.prefix(3)) loads")
        continue
      }
      let s = bank.source(of: slot)!
      by[category] = s.description
      if case .gm = s { Issue.record("\(category) fell through to Apple's \(s)") }
      bank.release(slot)
    }
    for (c, s) in by.sorted(by: { $0.key < $1.key }) { print("  \(c)\t\(s)") }
  }

  @Test(.enabled(if: floor != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func soundFontRendersAreDeterministicAndInTune() throws {
    let bank = try #require(Self.floor)
    for p in [0, 25, 29, 30, 33, 48, 81] {
      let s = SamplerSource.sf2(bank, program: p)
      let a = try #require(render(s, InstrumentTableTests.phrase, 1), "\(s) loads")
      #expect(a == render(s, InstrumentTableTests.phrase, 1), "\(s) renders the same twice")
      let held = try #require(render(s, [(57, 0, 1)], 0.5))
      let e = pitchClassError(held[4800...], note: 57, sampleRate: sr)
      #expect(abs(e.cents) <= SamplerInstrument.maxDetuneCents + 2, "\(s): \(e.cents) cents")
    }
  }

  func render(
    _ source: SamplerSource, _ notes: [(note: Int, at: Double, seconds: Double)],
    _ seconds: Double
  ) -> [Float]? {
    let bank = SamplerBank(sampleRate: sr)
    guard let slot = bank.slot(for: [source]) else { return nil }
    defer { bank.release(slot) }
    return WaveRunner.audition(
      tonalVoice(instrument: "", group: "melody"), notes: notes, sampleRate: sr,
      seconds: seconds, sampler: (bank, slot))
  }
}
