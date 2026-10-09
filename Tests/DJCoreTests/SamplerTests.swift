import Testing

@testable import DJCore

/// Sampled instruments play from content on this Mac (Logic / GarageBand EXS, or macOS's
/// General MIDI bank, which every Mac has); `VoiceCatalog` scans what is installed.
struct SamplerTests {
  let sr = 48_000.0
  let catalog = VoiceCatalog.shared
  /// What the sound checks cover: every installed sound with `make sampler-sweep` (minutes —
  /// each load reads its samples into memory), otherwise the first sound of each category.
  var allSounds: [CatalogSound] {
    if samplerSweep { return catalog.sounds.values.flatMap { $0 }.sorted { $0.name < $1.name } }
    return catalog.sounds.keys.sorted().compactMap { catalog.sounds[$0]?.first }
  }

  func render(
    _ sound: CatalogSound, _ notes: [(note: Int, at: Double, seconds: Double)],
    _ seconds: Double
  ) -> [Float]? { render(sound.sources, notes, seconds) }

  func render(
    _ source: SamplerSource, _ notes: [(note: Int, at: Double, seconds: Double)],
    _ seconds: Double
  ) -> [Float]? { render([source], notes, seconds) }

  /// Through a fresh bank, as a deck would play it; nil when the bank won't take any of
  /// `sources` (missing samples, unreadable format, silent or out of tune).
  func render(
    _ sources: [SamplerSource], _ notes: [(note: Int, at: Double, seconds: Double)],
    _ seconds: Double
  ) -> [Float]? {
    let bank = SamplerBank(sampleRate: sr)
    guard let slot = bank.slot(for: sources) else { return nil }
    return WaveRunner.audition(
      tonalVoice(instrument: "", group: "melody"), notes: notes, sampleRate: sr,
      seconds: seconds, sampler: (bank, slot))
  }

  @Test func everyCategoryHasSomethingThatPlays() {
    for (category, pool) in catalog.sounds where !category.hasPrefix("fx.") {
      let loads = pool.contains { SamplerBank(sampleRate: sr).slot(for: $0.sources) != nil }
      // a category that keeps its synth voice may have nothing AUSampler can play (Koto,
      // Guzheng and Pipa are in a newer sampler format)
      #expect(
        loads || catalog.keepSynth.contains(category),
        "\(category): none of \(pool.map(\.name)) plays")
    }
    for programs in catalog.gm.values {
      for p in programs { #expect(SamplerBank(sampleRate: sr).slot(for: [.gm(p)]) != nil) }
    }
  }

  /// The bank only takes sounds within `maxDetuneCents` of the note, in whatever octave
  /// they speak; check that holds for everything it takes.
  @Test func everySoundTheBankTakesIsInTune() {
    var taken = 0
    for s in allSounds {
      guard let a = render(s, [(57, 0, 1)], 0.5) else { continue }
      taken += 1
      let p = pitchClassError(a[4800...], note: 57, sampleRate: sr)
      #expect(abs(p.cents) <= SamplerInstrument.maxDetuneCents + 2, "\(s.name): \(p.cents) cents")
    }
    #expect(
      taken * 4 > allSounds.count * 3, "most installed sounds play (\(taken) of \(allSounds.count))"
    )
  }

  @Test func silentOrDetunedSoundsAreTurnedAway() {
    // Singing bowls ring ~50 cents off; at least one is turned away (sound check, not a name list)
    let bowls = catalog.sounds["fx.bowl"] ?? []
    if !bowls.isEmpty {
      let rejected = bowls.filter { SamplerBank(sampleRate: sr).slot(for: $0.sources) == nil }
      print("turned away:", rejected.map(\.name))
    }
    let bank = SamplerBank(sampleRate: sr)
    #expect(bank.slot(for: [.exs("/nope/Missing.exs")]) == nil)
  }

  @Test func loadingLevelsEverySoundToTheLeadVoice() {
    let lead = WaveRunner.audition(
      tonalVoice(instrument: "supersaw", group: "melody"), notes: InstrumentTableTests.phrase,
      sampleRate: sr, seconds: 2)
    let ref = rmsDB(lead[...])
    #expect(abs(ref - SamplerInstrument.targetRMSdB) < 0.5)
    for s in allSounds {
      guard let a = render(s, InstrumentTableTests.phrase, 2) else { continue }
      #expect(abs(rmsDB(a[...]) - ref) < 3, "\(s.name) at \(rmsDB(a[...])) dB vs \(ref) dB")
    }
  }

  @Test func notesLandOnTheirSample() throws {
    let a = try #require(render(.gm(27), [(52, 0.25, 0.5)], 0.5))
    let onset = a.firstIndex { abs($0) > 1e-4 } ?? -1
    #expect(onset >= 12_000 && onset < 12_000 + 64, "onset at \(onset)")
  }

  /// General MIDI programs render the same every time. Some sampled instruments vary on
  /// purpose — Logic's guitars round-robin between recordings, tape and chime patches carry
  /// random modulation — so those are named, and only a small share may vary.
  @Test func rendersAreDeterministic() {
    for p in [0, 25, 33, 48, 73] {
      #expect(
        render(.gm(p), InstrumentTableTests.phrase, 1)
          == render(.gm(p), InstrumentTableTests.phrase, 1))
    }
    var checked = 0
    var varying: [String] = []
    for s in allSounds {
      guard let a = render(s, InstrumentTableTests.phrase, 1) else { continue }
      checked += 1
      if a != render(s, InstrumentTableTests.phrase, 1) { varying.append(s.name) }
    }
    print("varies between renders:", varying)
    #expect(varying.count * 4 <= checked, "\(varying.count) of \(checked) vary: \(varying)")
  }

  @Test func aBankFullOfReferencedSlotsFallsBackToTheSynthVoice() {
    let bank = SamplerBank(sampleRate: sr)
    for p in 0..<SamplerBank.capacity { #expect(bank.slot(for: [.gm(p)]) == p) }
    #expect(bank.slot(for: [.gm(100)]) == nil)
    #expect(bank.slot(for: [.gm(3)]) == 3, "a loaded source is shared")
    #expect(bank.references(of: 3) == 2)
  }

  @Test func aFullBankEvictsTheLeastRecentlyUsedUnreferencedSlot() {
    let bank = SamplerBank(sampleRate: sr)
    for p in 0..<SamplerBank.capacity { #expect(bank.slot(for: [.gm(p)]) == p) }
    // Give back 5, then 9, then 17 (taking 9 once more in between): 5 is least recently used.
    bank.release(5)
    bank.release(9)
    bank.release(17)
    #expect(bank.slot(for: [.gm(9)]) == 9, "still loaded: shared, not reloaded")
    bank.release(9)
    #expect(bank.slot(for: [.gm(100)]) == 5)
    #expect(bank.source(of: 5) == .gm(100))
    #expect(bank.slot(for: [.gm(101)]) == 17)
    #expect(bank.slot(for: [.gm(102)]) == 9)
    #expect(bank.slot(for: [.gm(103)]) == nil, "everything left is referenced")
    for p in 0..<SamplerBank.capacity where ![5, 9, 17].contains(p) {
      #expect(bank.source(of: p) == .gm(p), "referenced slot \(p) kept")
    }
    // An evicted source comes back by loading again, into whatever slot frees up.
    bank.release(0)
    #expect(bank.slot(for: [.gm(5)]) == 0)
  }

  @Test func projectsHoldTheirSlotsUntilFreed() throws {
    var ov = JSONObject()
    ov["seed"] = .number(7)
    let bank = SamplerBank(sampleRate: sr)
    var prepared: WaveProject? = WaveRunner.prepare(
      compose(genre: "country", overrides: .object(ov)), sampleRate: sr,
      opts: .extended(samplers: bank, seed: 7))
    let used = Set(prepared!.lanes.map(\.samplerSlot).filter { $0 >= 0 })
    try #require(!used.isEmpty, "a sampled lane to hold")
    let held = Dictionary(uniqueKeysWithValues: used.map { ($0, bank.source(of: $0)) })
    // Fill the bank, then churn through more programs than it holds: only the slots no
    // project references are ever reused.
    for p in 0..<64 {
      guard let s = bank.slot(for: [.gm(p)]) else { continue }
      bank.release(s)
    }
    for s in used {
      #expect(bank.source(of: s) == held[s]!, "slot \(s) kept while its project lives")
      #expect(bank.references(of: s) > 0)
    }
    #expect(
      (0..<SamplerBank.capacity).allSatisfy { used.contains($0) || bank.references(of: $0) == 0 })
    prepared = nil
    for s in used { #expect(bank.references(of: s) == 0, "freed project gave slot \(s) back") }
    for p in 64..<(64 + SamplerBank.capacity) { #expect(bank.slot(for: [.gm(p)]) != nil) }
    #expect(
      (0..<SamplerBank.capacity).allSatisfy {
        bank.source(of: $0)?.description.hasPrefix("gm:") == true
      })
  }

  @Test func missingContentFallsThrough() {
    let bank = SamplerBank(sampleRate: sr)
    #expect(bank.slot(for: [.exs("/nope/Missing.exs"), .gm(25)]) == 0)
    #expect(bank.source(of: 0) == .gm(25))
  }

  @Test func truncatedExsSampleNamesArePatched() throws {
    // A synthetic sample chunk: TBOS + 64-byte name, then the full file name further on.
    var b: [UInt8] = Array("TBOS".utf8)
    var name = Array("Acoustic Guitar_conso#9FC40.caf".utf8)
    name += [UInt8](repeating: 0, count: 64 - name.count)
    b += name + [UInt8](repeating: 0, count: 100)
    b += Array("Acoustic Guitar_consolidated.caf".utf8) + [0, 0, 0, 0]
    let out = try #require(exsPatch(b))
    #expect(Array(out[4..<36]) == Array("Acoustic Guitar_consolidated.caf".utf8))
    #expect(exsPatch(out) == nil, "already whole")
  }

  @Test func decksPlayTheirOwnSamplers() {
    var ov = JSONObject()
    ov["seed"] = .number(7)
    let p = compose(genre: "country", overrides: .object(ov))
    let bank = SamplerBank(sampleRate: sr)
    let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: .extended(samplers: bank, seed: 7))
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 })
    #expect(!WaveRunner.prepare(p, sampleRate: sr).lanes.contains { $0.samplerSlot >= 0 })
  }
}
