import Testing

@testable import DJCore

/// End to end: the generator writes tracks whose guitars play sampled guitars. beats'
/// composer picks `acoustic-guitar` / `electric-guitar` / `distorted-guitar` for a role in
/// some genres (`instrumentSets`); `VoiceCatalog` turns that into a seeded pick from the
/// category's installed sounds, then its SoundFont programs. Each test finds a genre + seed
/// whose track lands on a real guitar sample — an EXS from the category's pool or a SoundFont
/// guitar program, not the pluck synth, not Apple's General MIDI — then renders that role's
/// stem.
///
/// Gap (by design of beats' tables, not a bug here): only `melody` and `bass` ever get a
/// guitar. `harmony` is always `warm-pad`/`dark-pad` (set in `compose`), and `arp` exists
/// only in edm/synthwave/trance with pluck pools; their fallback sets hold no guitar either.
/// No distorted-guitar EXS ships with Logic/GarageBand here, and `guitar.distorted` is
/// `keepSynth`, so Apple's GM programs are never offered: without a SoundFont, metal and
/// speedcore guitars play the synth voice and that test skips. With one (`make soundfonts`),
/// an empty pool offers no synth pick, so they play the bank's Distortion Guitar (GM 30,
/// 0-based; 1-based 31), else its Overdriven Guitar (29).
struct GuitarVoicingTests {
  let sr = 48_000.0
  let catalog = VoiceCatalog.shared

  /// Genres whose `instrumentSets` hold each guitar, in the order they are swept.
  static let genres: [String: [String]] = [
    "acoustic-guitar": ["country", "blues", "reggae", "lofi", "bossa"],
    "electric-guitar": ["country", "blues", "funk"],
    "distorted-guitar": ["metal", "speedcore"],
  ]

  static func installed(_ category: String) -> Bool {
    VoiceCatalog.shared.pool(category).contains { s in
      s.sources.contains { if case .exs = $0 { true } else { false } }
    }
  }

  static var soundFont: Bool { !VoiceCatalog.shared.soundFonts.isEmpty }

  /// A sample, not a synth voice or Apple's GM: an EXS or a SoundFont program.
  static func sampled(_ s: SamplerSource?) -> Bool {
    switch s {
    case .exs, .sf2: true
    default: false
    }
  }

  @Test(
    .enabled(
      if: installed("guitar.acoustic"),
      "no Logic/GarageBand acoustic guitar installed on this Mac"))
  func acousticGuitarTracksPlayASampledGuitar() throws {
    try check("acoustic-guitar", "guitar.acoustic")
  }

  @Test(
    .enabled(
      if: installed("guitar.electric"),
      "no Logic/GarageBand electric guitar installed on this Mac"))
  func electricGuitarTracksPlayASampledGuitar() throws {
    try check("electric-guitar", "guitar.electric")
  }

  @Test(
    .enabled(
      if: installed("guitar.distorted") || soundFont,
      "no distorted guitar EXS and no SoundFont (make soundfonts) on this Mac"))
  func distortedGuitarTracksPlayASampledGuitar() throws {
    try check("distorted-guitar", "guitar.distorted")
  }

  /// The first seed (0, 1, …; genres in order within a seed) whose track gives `instrument`
  /// to a role whose voicing pick is a sampled sound, prepared on a fresh bank: the track,
  /// the bank, the prepared project and the net ids playing the guitar.
  struct Found {
    var genre: String
    var seed: Int
    var role: String
    var nets: [String]
    var project: Project
    var bank: SamplerBank
    var prepared: WaveProject
    var slot: Int
  }

  func find(_ instrument: String, maxSeed: Int = 200) -> Found? {
    for seed in 0..<maxSeed {
      for genre in Self.genres[instrument]! {
        var ov = JSONObject()
        ov["seed"] = .number(Double(seed))
        let p = compose(genre: genre, overrides: .object(ov))
        let nets = p.nets.keys.filter {
          p.nets[$0]!.role != "control" && p.nets[$0]!.track.instrument == instrument
        }
        guard let first = nets.first else { continue }
        let b = p.nets[first]!
        let role = b.track.group ?? b.riffGroup
        // the pick is the synth voice (keepSynth) or nothing is installed: next seed
        guard
          Self.sampled(
            catalog.sources(instrument: instrument, role: role, seed: Double(seed))?.first)
        else { continue }
        let bank = SamplerBank(sampleRate: sr)
        let prepared = WaveRunner.prepare(
          p, sampleRate: sr, opts: .extended(samplers: bank, seed: Double(seed)))
        guard let li = prepared.byNet[first]?.first(where: { prepared.lanes[$0].isTonal }),
          prepared.lanes[li].samplerSlot >= 0
        else { continue }
        return Found(
          genre: genre, seed: seed, role: role, nets: nets.sorted(), project: p, bank: bank,
          prepared: prepared, slot: prepared.lanes[li].samplerSlot)
      }
    }
    return nil
  }

  func check(_ instrument: String, _ category: String) throws {
    let f = try #require(find(instrument), "no seed < 200 voices \(instrument) with a sample")
    let source = try #require(f.bank.source(of: f.slot))
    print("\(category): \(f.genre) seed \(f.seed) role \(f.role) nets \(f.nets) → \(source)")

    // (2) a real sample from the category — its pool or its SoundFont programs — not Apple's
    // General MIDI (and the lane is not the synth)
    switch source {
    case .exs(let path):
      #expect(
        catalog.pool(category).contains { $0.sources.contains(.exs(path)) },
        "\(path) is not in \(category)")
    case .sf2(_, let program):
      #expect(catalog.gm[category]?.contains(program) == true, "\(source) is not in \(category)")
    case .gm, .kit:
      Issue.record("\(category) fell back to \(source)")
      return
    }
    for n in f.nets {
      for li in f.prepared.byNet[n]! where f.prepared.lanes[li].isTonal {
        #expect(f.prepared.lanes[li].samplerSlot == f.slot, "\(n) plays the role's pick")
      }
    }
    // the loaded sound itself, through the deck's own slot: in tune, as the bank promised
    let note = f.role == "bass" ? 45 : 57
    let a = WaveRunner.audition(
      tonalVoice(instrument: instrument, group: f.role), notes: [(note, 0, 1)], sampleRate: sr,
      seconds: 0.5, sampler: (f.bank, f.slot))
    let p = pitchClassError(a[4800...], note: note, sampleRate: sr)
    #expect(abs(p.cents) <= SamplerInstrument.maxDetuneCents + 2, "audition \(p.cents) cents")

    // (3) the role's stem from the generated track: everything else muted
    let runner = WaveRunner(sampleRate: sr, opts: .extended(samplers: f.bank, seed: Double(f.seed)))
    runner.load(prepared: f.prepared)
    for id in f.project.nets.keys where !f.nets.contains(id) {
      if f.project.nets[id]!.role != "control" { runner.setMute(id, true) }
    }
    runner.play()
    let frames = Int(8 * sr)
    var stem = [Float](repeating: 0, count: frames)
    stem.withUnsafeMutableBufferPointer { b in
      var off = 0
      while off < frames {
        let n = min(512, frames - off)
        runner.process(b.baseAddress! + off, nil, frames: n)
        off += n
      }
    }
    // as loud as the sound itself plays: the track's loudness gain (`Loudness`) taken out
    let level = rmsDB(stem[...]) - ampDB(f.prepared.gain)
    let dev = gridDeviations(stem, sampleRate: sr).map(abs).sorted()
    print("  stem \(level) dB, cents off the grid per window \(dev)")
    #expect(level > -45, "the \(f.role) stem is silent (\(level) dB)")
    try #require(dev.count >= 4, "too few loud windows to judge pitch")
    let median = dev[dev.count / 2]
    #expect(
      median <= SamplerInstrument.maxDetuneCents, "the \(f.role) stem is \(median) cents off")
  }
}
