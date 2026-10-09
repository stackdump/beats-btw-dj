import Testing

@testable import DJCore

/// Sampled instruments play from content on this Mac (Logic / GarageBand EXS, or macOS's
/// General MIDI bank, which every Mac has). An EXS that is missing falls back to its GM
/// program, so these hold either way.
struct SamplerTests {
  let sr = 48_000.0
  let table = InstrumentTable.shared
  var sampled: [String] { table.names.filter { table.sampler(for: $0) != nil } }

  func render(
    _ name: String, _ notes: [(note: Int, at: Double, seconds: Double)], _ seconds: Double
  ) throws -> [Float] {
    let s = try #require(table.sampler(for: name))
    let bank = SamplerBank(sampleRate: sr)
    let slot = try #require(bank.slot(for: s.sources, gain: s.gain), "\(name) loads")
    return WaveRunner.audition(
      table.voice(instrument: name, group: "melody"), notes: notes, sampleRate: sr,
      seconds: seconds, sampler: (bank, slot))
  }

  @Test func everySampledInstrumentLoads() {
    #expect(sampled.count >= 20)
    for n in sampled {
      let s = table.sampler(for: n)!
      #expect(SamplerBank(sampleRate: sr).slot(for: s.sources, gain: s.gain) != nil, "\(n)")
    }
  }

  @Test(arguments: [
    "acoustic-guitar", "electric-guitar", "bass", "808-bass", "sub-bass", "piano",
    "electric-piano", "marimba", "vibes", "kalimba", "music-box", "organ", "clavinet",
    "steel-drum", "sax", "trumpet", "brass", "strings",
  ])
  func playsInTune(_ name: String) throws {
    let a = try render(name, [(57, 0, 1)], 0.6)
    let f = partialPeak(a[4800..<24000], near: midiHz(57), sampleRate: sr)
    #expect(abs(cents(f, midiHz(57))) < 10, "\(name): \(cents(f, midiHz(57))) cents")
  }

  @Test func levelsSitWithTheLeadVoice() throws {
    let lead = WaveRunner.audition(
      tonalVoice(instrument: "supersaw", group: "melody"), notes: InstrumentTableTests.phrase,
      sampleRate: sr, seconds: 2)
    let ref = rmsDB(lead[...])
    for n in sampled {
      let db = rmsDB(try render(n, InstrumentTableTests.phrase, 2)[...])
      #expect(abs(db - ref) < 3, "\(n) at \(db) dB vs lead \(ref) dB")
    }
  }

  @Test func notesLandOnTheirSample() throws {
    let a = try render("electric-guitar", [(52, 0.25, 0.5)], 0.5)
    let onset = a.firstIndex { abs($0) > 1e-4 } ?? -1
    #expect(onset >= 12_000 && onset < 12_000 + 64, "onset at \(onset)")
  }

  /// Logic's guitars rotate between alternate recordings of a note (round robin), so two
  /// renders of them differ on purpose; every other instrument renders the same each time.
  static let roundRobin: Set<String> = ["acoustic-guitar", "electric-guitar"]

  @Test func rendersAreDeterministic() throws {
    for n in sampled where !Self.roundRobin.contains(n) {
      let a = try render(n, InstrumentTableTests.phrase, 1)
      #expect(a == (try render(n, InstrumentTableTests.phrase, 1)), "\(n)")
    }
  }

  @Test func aBankFullOfReferencedSlotsFallsBackToTheSynthVoice() {
    let bank = SamplerBank(sampleRate: sr)
    for p in 0..<SamplerBank.capacity { #expect(bank.slot(for: [.gm(p)], gain: 1) == p) }
    #expect(bank.slot(for: [.gm(100)], gain: 1) == nil)
    #expect(bank.slot(for: [.gm(3)], gain: 1) == 3, "a loaded source is shared")
    #expect(bank.references(of: 3) == 2)
  }

  @Test func aFullBankEvictsTheLeastRecentlyUsedUnreferencedSlot() {
    let bank = SamplerBank(sampleRate: sr)
    for p in 0..<SamplerBank.capacity { #expect(bank.slot(for: [.gm(p)], gain: 1) == p) }
    // Give back 5, then 9, then 17 (taking 9 once more in between): 5 is least recently used.
    bank.release(5)
    bank.release(9)
    bank.release(17)
    #expect(bank.slot(for: [.gm(9)], gain: 1) == 9, "still loaded: shared, not reloaded")
    bank.release(9)
    #expect(bank.slot(for: [.gm(100)], gain: 1) == 5)
    #expect(bank.source(of: 5) == .gm(100))
    #expect(bank.slot(for: [.gm(101)], gain: 1) == 17)
    #expect(bank.slot(for: [.gm(102)], gain: 1) == 9)
    #expect(bank.slot(for: [.gm(103)], gain: 1) == nil, "everything left is referenced")
    for p in 0..<SamplerBank.capacity where ![5, 9, 17].contains(p) {
      #expect(bank.source(of: p) == .gm(p), "referenced slot \(p) kept")
    }
    // An evicted source comes back by loading again, into whatever slot frees up.
    bank.release(0)
    #expect(bank.slot(for: [.gm(5)], gain: 1) == 0)
  }

  @Test func projectsHoldTheirSlotsUntilFreed() throws {
    var ov = JSONObject()
    ov["seed"] = .number(7)
    let bank = SamplerBank(sampleRate: sr)
    var prepared: WaveProject? = WaveRunner.prepare(
      compose(genre: "country", overrides: .object(ov)), sampleRate: sr,
      opts: .extended(samplers: bank))
    let used = Set(prepared!.lanes.map(\.samplerSlot).filter { $0 >= 0 })
    try #require(!used.isEmpty, "a sampled lane to hold")
    let held = Dictionary(uniqueKeysWithValues: used.map { ($0, bank.source(of: $0)) })
    // Fill the bank, then churn through more programs than it holds: only the slots no
    // project references are ever reused.
    for p in 0..<64 {
      guard let s = bank.slot(for: [.gm(p)], gain: 1) else { continue }
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
    for p in 64..<(64 + SamplerBank.capacity) { #expect(bank.slot(for: [.gm(p)], gain: 1) != nil) }
    #expect(
      (0..<SamplerBank.capacity).allSatisfy {
        bank.source(of: $0)?.description.hasPrefix("gm:") == true
      })
  }

  @Test func missingContentFallsThrough() {
    let bank = SamplerBank(sampleRate: sr)
    let slot = bank.slot(for: [.exs("/nope/Missing.exs"), .gm(25)], gain: 1)
    #expect(slot == 0)
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
    let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: .extended(samplers: bank))
    let wanted = p.nets.values.contains { table.sampler(for: $0.track.instrument) != nil }
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 } == wanted)
    #expect(!WaveRunner.prepare(p, sampleRate: sr).lanes.contains { $0.samplerSlot >= 0 })
  }
}
