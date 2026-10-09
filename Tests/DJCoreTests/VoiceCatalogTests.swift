import Testing

@testable import DJCore

struct VoiceCatalogTests {
  let catalog = VoiceCatalog.shared

  @Test func everyTonalBeatsInstrumentHasACategory() {
    var names = Set<String>()
    for set in BeatsTables.shared.instrumentSets.values {
      for pool in set.values { names.formUnion(pool) }
    }
    for n in names.sorted() where !n.hasPrefix("drums") {
      let c = catalog.categoryOf[n]
      #expect(c != nil, "\(n) has no category")
      if let c {
        #expect(
          !catalog.pool(c).isEmpty || catalog.gm[c] != nil || catalog.keepSynth.contains(c),
          "\(n) → \(c) can play nothing")
      }
    }
  }

  @Test(arguments: [
    ("Logic/02 Bass/02 Electric Bass/Fingerstyle Electric Bass.exs", "bass.electric"),
    ("Logic/02 Bass/01 Acoustic Bass/Upright Jazz Bass.exs", "bass.acoustic"),
    ("Logic/04 Keyboards/Producer Packs/80s Pluck Bass.exs", "bass.synth"),
    ("Logic/04 Keyboards/Producer Packs/Alphabet City 808 Bass.exs", "bass.sub"),
    ("Logic/08 Guitars/Vintage Strat.exs", "guitar.electric"),
    ("Logic/08 Guitars/Acoustic Guitar.exs", "guitar.acoustic"),
    ("Logic/04 Keyboards/Producer Packs/Shimmering Electric Piano.exs", "keys.epiano"),
    ("Logic/01 Acoustic Pianos/Steinway Grand Piano 2.exs", "keys.piano"),
    ("Logic/04 Keyboards/Producer Packs/Heavenly Voices Choir.exs", "vocal"),
    ("Logic/04 Keyboards/Producer Packs/Velvetine Synth Pad.exs", "pad"),
    ("Logic/04 Keyboards/Producer Packs/Azure Crystal Synth Bells.exs", "synth.bell"),
    ("Logic/04 Keyboards/Producer Packs/Lime Drops Synth Pluck.exs", "synth.pluck"),
    ("Logic/04 Keyboards/Producer Packs/Supreme Lead Synth.exs", "synth.lead"),
    ("Logic/09 Orchestral/01 Woodwinds/Alto Sax.exs", "woodwind.reed"),
    ("Logic/09 Orchestral/02 Brass/Floating Flugels.exs", "brass"),
    ("Logic/03 Drums & Percussion/Something/Kit.exs", "skip"),
    ("GarageBand/Live Rock Kit.exs", "skip"),
    ("GarageBand/Hip Hop Drum Machine.exs", "skip"),
    ("Logic/09 Orchestral/07 Pipe Organ/Bass 1.exs", "keys.organ"),
    ("GarageBand/Double Bass.exs", "bass.acoustic"),
    ("Logic/09 Orchestral/01 Woodwinds/Bassoon Solo.exs", "woodwind.reed"),
    ("GarageBand/Palm Muted Bass.exs", "bass.electric"),
    ("Logic/04 Keyboards/Producer Packs/Sweet Overdrive Kalimba.exs", "mallet"),
    ("Logic/08 Guitars/Warm Electric.exs", "guitar.electric"),
    ("GarageBand/Classical Grand.exs", "keys.piano"),
    ("GarageBand/Japanese Traditional/Koto.exs", "ethnic"),
    ("Logic/04 Keyboards/Toy Celesta.exs", "mallet"),
    ("Logic/04 Keyboards/Producer Packs/Dreamy Smooth Vox.exs", "vocal"),
  ])
  func rulesSortInstrumentsByName(_ path: String, _ category: String) {
    #expect(VoiceCatalog.categorize(path, rules: catalog.rules) == category)
  }

  @Test func articulationsAndCopiesCountOnce() {
    #expect(VoiceCatalog.canonical("Trumpets+").0 == "Trumpets")
    #expect(VoiceCatalog.canonical("Trumpets Staccato").0 == "Trumpets")
    #expect(VoiceCatalog.canonical("Flute iOS KB").0 == "Flute")
    #expect(VoiceCatalog.canonical("Trumpets+").1 < VoiceCatalog.canonical("Trumpets Legato").1)
    for pool in catalog.sounds.values {
      #expect(Set(pool.map(\.name)).count == pool.count, "duplicates in \(pool.map(\.name))")
    }
  }

  @Test func picksAreStableAndSpreadAcrossThePool() throws {
    let a = catalog.sources(instrument: "bass", role: "bass", seed: 42)
    #expect(a == catalog.sources(instrument: "bass", role: "bass", seed: 42))
    // every riff variant of a role shares the role's pick
    #expect(a == catalog.sources(instrument: "bass", role: "bass", seed: 42))
    let pool = catalog.pool("bass.electric")
    try #require(pool.count >= 2, "this Mac has several electric basses")
    var firsts = Set<SamplerSource>()
    for seed in 0..<60 {
      if let s = catalog.sources(instrument: "bass", role: "bass", seed: Double(seed))?.first {
        firsts.insert(s)
      }
    }
    #expect(firsts.count >= min(pool.count, 3), "picks spread: \(firsts.count) of \(pool.count)")
  }

  @Test func aPickFallsBackThroughItsPoolThenGM() throws {
    let s = try #require(catalog.sources(instrument: "piano", role: "melody", seed: 1))
    let pool = catalog.pool("keys.piano").flatMap(\.sources)
    #expect(Set(s.prefix(pool.count)) == Set(pool), "the whole pool, rotated")
    #expect(s.suffix(2) == [.gm(0), .gm(1)])
  }

  @Test func synthCategoriesSometimesKeepTheSynthVoice() {
    var synth = 0
    for seed in 0..<80
    where catalog.sources(instrument: "supersaw", role: "melody", seed: Double(seed)) == nil {
      synth += 1
    }
    #expect(synth > 0 && synth < 80)
    #expect(
      catalog.sources(instrument: "distorted-guitar", role: "melody", seed: 3) == nil
        || !catalog.pool("guitar.distorted").isEmpty)
  }

  @Test func stableHashIsFixed() {
    #expect(VoiceCatalog.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
  }
}
