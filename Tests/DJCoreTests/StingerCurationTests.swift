import Testing

@testable import DJCore

/// Curated stingers (`StingerCuration`, stingers.json): Hit 1–4 resolved from the genre, the
/// palette and the seed, as a pure function of the configuration; the table's data; missing
/// content falling back; and beats' composition and CID left alone.
struct StingerCurationTests {
  /// A stock loop as the index would list it (no audio needed to resolve one).
  func stock(_ name: String, beats: Int = 16, bpm: Double = 128, category: String = "Sound Effect")
    -> StockLoop
  {
    StockLoop(
      path: "/nowhere/\(name).caf", name: name, pack: "Test Pack", category: category,
      subcategory: "", genre: "", beats: beats, seconds: Double(beats) * 60 / bpm, key: nil)
  }

  // MARK: the table

  /// Every candidate parses and names something this app knows: a SoundPalette option in its
  /// grammar (a known instrument, a GM program, a category, a bank category), a macro either
  /// catalogue plays, a stock query; its families and palettes are real.
  @Test func everyCandidateParsesAndNamesSomethingKnown() throws {
    let all = StingerCuration.candidates
    let text = try StingerCuration.loadText()
    let raw = try JSONValue.parse(text)["candidates"]?.array ?? []
    #expect(all.count == raw.count, "every entry parses")
    #expect(all.count >= 20)
    #expect(Set(all.map(\.id)).count == all.count, "unique ids")
    let families = Set(BeatsTables.shared.genres.keys.map(StingerCuration.family(of:)))
    for kind in StingerCandidate.Kind.allCases {
      #expect(all.contains { $0.kind == kind }, "the table has \(kind) candidates")
    }
    for c in all {
      #expect(!c.label.isEmpty, "\(c.id)")
      #expect(["any", "tonal"].contains(c.key), "\(c.id): key \(c.key)")
      #expect(c.tempo.lowerBound >= 0 && c.tempo.upperBound > c.tempo.lowerBound, "\(c.id)")
      for f in c.families { #expect(f == "*" || families.contains(f), "\(c.id): family \(f)") }
      for p in c.palettes { #expect(p == "*" || SoundPalette.named(p) != nil, "\(c.id): \(p)") }
      switch c.kind {
      case .oneShot:
        let o = try #require(c.option, "\(c.id) has an option")
        if let name = SoundPalette.synthName(o) {
          #expect(SoundPalette.knownInstrument(name), "\(c.id): \(name)")
        } else if o.hasPrefix("gm:") || o.hasPrefix("dls:") {
          let n = Int(o.split(separator: ":")[1])
          #expect(n.map { (0..<128).contains($0) } == true, "\(c.id): \(o)")
        } else if o.hasPrefix("cat:") {
          let cat = String(o.dropFirst(4))
          #expect(VoiceCatalog.shared.gm[cat] != nil, "\(c.id): category \(cat)")
        } else if o.hasPrefix("bank:") {
          #expect(SoundPalette.categories[String(o.dropFirst(5))] != nil, "\(c.id): \(o)")
        } else {
          Issue.record("\(c.id): \(o) is not an option")
        }
      case .macro:
        #expect(c.macro.map(Deck.isMacro(id:)) == true, "\(c.id): \(c.macro ?? "-")")
      case .loop:
        switch c.loop {
        case .stock(_, let query)?: #expect(!query.isEmpty, "\(c.id)")
        case .clip(let id)?: #expect(!id.isEmpty, "\(c.id)")
        case nil: Issue.record("\(c.id) names no loop")
        }
        #expect(c.isLocalOnly || c.loop.map { if case .clip = $0 { true } else { false } } == true)
      }
    }
    // every genre beats composes sorts into a family, and every Hit draws from something
    for g in BeatsTables.shared.genres.keys {
      #expect(!StingerCuration.family(of: g).isEmpty, "\(g) has a family")
    }
    #expect(StingerCuration.slotKinds.count == StingerCuration.slotCount)
    #expect(StingerCuration.slotKinds.allSatisfy { !$0.isEmpty })
  }

  // MARK: the resolver

  /// The same (genre, palette, seed) always gets the same four hits; another seed may not.
  @Test func theResolverIsDeterministic() {
    for genre in ["techno", "lofi", "dubstep", "jazz", "metal", "synthwave"] {
      for palette in [nil, "club", "orchestral", "chiptune"] {
        for seed in [0.0, 1, 42, 123_456_789] {
          let a = StingerCuration.resolve(
            genre: genre, palette: palette, seed: seed, installed: .everything)
          let b = StingerCuration.resolve(
            genre: genre, palette: palette, seed: seed, installed: .everything)
          let c = StingerCuration.compute(
            genre: genre, paletteID: SoundPalette.playing(palette)?.id ?? "studio", seed: seed,
            installed: .everything, tempo: BeatsTables.shared.genres[genre]?.bpm ?? 120, key: nil)
          #expect(a == b && a == c, "\(genre) \(palette ?? "-") \(seed)")
          #expect(a.count == 4 && a.map(\.slot) == [0, 1, 2, 3])
          let picked = a.compactMap(\.candidate)
          #expect(Set(picked).count == picked.count, "no candidate twice")
        }
      }
    }
    let seeds = (0..<24).map {
      StingerCuration.resolve(
        genre: "techno", palette: nil, seed: Double($0), installed: .everything)
    }
    #expect(
      Set(seeds.map { $0.compactMap(\.candidate).joined(separator: ",") }).count > 1,
      "the seed moves the picks")
  }

  /// Genre families get different hits: a club track and a chill one share almost nothing.
  @Test func hitsDifferAcrossGenreFamilies() {
    var differ = 0
    for s in 0..<20 {
      let club = StingerCuration.resolve(
        genre: "techno", palette: nil, seed: Double(s), installed: .everything)
      let chill = StingerCuration.resolve(
        genre: "lofi", palette: nil, seed: Double(s), installed: .everything)
      if club.map(\.candidate) != chill.map(\.candidate) { differ += 1 }
      // a club-only candidate never lands on a chill track, and back
      let clubOnly = Set(
        StingerCuration.candidates.filter {
          !$0.families.contains("*") && !$0.families.contains("chill")
        }
        .map(\.id))
      #expect(chill.compactMap(\.candidate).allSatisfy { !clubOnly.contains($0) })
    }
    #expect(differ >= 18, "\(differ)/20 seeds differ")
    #expect(StingerCuration.family(of: "techno") != StingerCuration.family(of: "lofi"))
  }

  /// The palette counts: a palette's own candidates join (and weigh double), others' never do.
  @Test func thePaletteSteersTheHits() {
    let orchestralOnly = Set(
      StingerCuration.candidates.filter { $0.palettes == ["orchestral"] }.map(\.id))
    #expect(!orchestralOnly.isEmpty)
    var seen = false
    for s in 0..<40 {
      let plain = StingerCuration.resolve(
        genre: "trance", palette: nil, seed: Double(s), installed: .everything)
      #expect(plain.compactMap(\.candidate).allSatisfy { !orchestralOnly.contains($0) })
      let orch = StingerCuration.resolve(
        genre: "trance", palette: "orchestral", seed: Double(s), installed: .everything)
      if orch.contains(where: { $0.candidate.map(orchestralOnly.contains) == true }) { seen = true }
    }
    #expect(seen, "the orchestral palette's own hits get drawn")
  }

  /// A tonal one-shot sounds on the stinger nets' C: never on a track whose scale has no C.
  @Test func tonalHitsKeepToTheKey() {
    let fSharpMajor = StingerCuration.Key(root: 66, intervals: scaleIntervals("MajorScale"))
    #expect(!fSharpMajor.holds(StingerCuration.stingerNote))
    let tonal = Set(StingerCuration.candidates.filter { $0.key == "tonal" }.map(\.id))
    for s in 0..<30 {
      let hits = StingerCuration.resolve(
        genre: "house", palette: nil, seed: Double(s), installed: .everything, key: fSharpMajor)
      #expect(hits.compactMap(\.candidate).allSatisfy { !tonal.contains($0) }, "seed \(s)")
    }
  }

  /// Nothing installed: the one-shot Hits fall back to the track's own stinger nets, the
  /// macro Hit still fires a macro (nothing to install), and no loop is assigned without a loop.
  @Test func missingContentFallsBack() {
    for genre in ["techno", "lofi", "jazz", "dnb"] {
      let hits = StingerCuration.resolve(
        genre: genre, palette: nil, seed: 3, installed: .nothing)
      #expect(hits[0].kind == .fallback && hits[1].kind == .fallback, "\(genre)")
      #expect(hits[0].candidate == nil && hits[0].netID == "hit1")
      #expect(hits[2].kind == .macro, "\(genre)")
      #expect(hits.allSatisfy { $0.kind != .loop && $0.kind != .oneShot }, "\(genre)")
    }
    // an option that isn't here is skipped, not assigned
    let noGM = StingerContent(option: { !$0.hasPrefix("gm:") }, stamp: "no-gm")
    for s in 0..<20 {
      let hits = StingerCuration.resolve(
        genre: "trance", palette: "orchestral", seed: Double(s), installed: noGM)
      #expect(hits.compactMap(\.option).allSatisfy { !$0.hasPrefix("gm:") })
    }
    // no stock loops: Hit 4 is never a loop
    for s in 0..<20 {
      let hits = StingerCuration.resolve(
        genre: "edm", palette: nil, seed: Double(s), installed: .everything)
      #expect(hits[3].kind != .loop)
    }
  }

  /// An installed riser at the track's tempo becomes Hit 4's loop (local-only); one far off the
  /// tempo, or too long, does not.
  @Test func aStockLoopIsAssignedWhenItFits() {
    let riser = stock("Test FX Riser 01")
    let content = StingerContent(
      option: { _ in true },
      stock: [riser, stock("Slow FX Riser", bpm: 90), stock("Long FX Riser", beats: 64)],
      stamp: "riser")
    for s in 0..<10 {
      let hits = StingerCuration.resolve(
        genre: "techno", palette: nil, seed: Double(s), installed: content)
      #expect(hits[3].kind == .loop, "seed \(s)")
      #expect(hits[3].loop?.path == riser.path)
      #expect(hits[3].localOnly)
      #expect(hits[3].json["loop"]?["name"]?.string == riser.name)
    }
    // lofi (82 BPM, chill): the riser's family and tempo don't fit
    let lofi = StingerCuration.resolve(genre: "lofi", palette: nil, seed: 1, installed: content)
    #expect(lofi[3].kind != .loop)
  }

  // MARK: beats' composition untouched

  /// The curation lives on what the deck plays: the composed project (its canonical text and
  /// model CID) and the share CID are beats', and `WaveOptions()` (parity) curates nothing.
  @Test func composeAndTheCIDAreUnchanged() throws {
    for genre in ["techno", "lofi", "jazz"] {
      let spec = TrackSpec(genre: genre, seed: 5, structure: "standard")
      let composed = spec.project()
      let cid = BeatsCID.shareCID(spec.payload)
      let track = PreparedTrack(spec: spec, sampleRate: 24_000, opts: .extended)
      #expect(track.project.canonicalJSON == composed.canonicalJSON, "\(genre)")
      #expect(track.project.modelCID == composed.modelCID)
      #expect(track.project.stingers.isEmpty, "the composition carries no curation")
      let played = try #require(track.spec)
      #expect(played == spec && BeatsCID.shareCID(played.payload) == cid)
      #expect(track.played.stingers.count == 4, "\(genre): what plays is curated")
      // a curated one-shot is its stinger net's sound; the net itself is the composer's
      for a in track.played.stingers where a.kind == .oneShot {
        let nb = track.played.nets[a.netID]
        #expect(nb?.track.sound.curated == a.option)
        #expect(nb?.track.sound.option == a.option)
        #expect(composed.nets[a.netID]?.track.sound.curated == nil)
      }
      let parity = PreparedTrack(spec: spec, sampleRate: 24_000, opts: WaveOptions())
      #expect(parity.played.stingers.isEmpty)
      #expect(parity.played.canonicalJSON == composed.canonicalJSON)
      for id in ["hit1", "hit2", "hit3", "hit4"] {
        #expect(parity.played.nets[id]?.track.sound.curated == nil)
      }
    }
  }

  // MARK: on a deck

  /// A deck's Hits are its track's, they follow a palette change, and a macro Hit fires the
  /// macro instead of the stinger net.
  @Test func aDeckFiresItsAssignments() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 24_000)
    dj.deterministic = true
    let d = try #require(dj["A"])
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard")
    d.loadNet(PreparedTrack(spec: spec, sampleRate: d.wave.sampleRate, opts: d.waveOptions))
    let hits = d.stingers
    #expect(hits.count == 4)
    #expect(hits == d.netProject?.resolvedStingers(genre: "house", seed: 11, installed: .here))
    dj.perform(.setPalette(deck: "A", palette: "orchestral"))
    let after = d.stingers
    #expect(after == d.netProject?.resolvedStingers(genre: "house", seed: 11, installed: .here))
    #expect(d.currentSpec?.genre == "house" && d.currentSpec?.seed == 11)
    // every Hit fires without touching the composition
    let before = try #require(d.netProject).canonicalJSON
    for n in 0..<4 { d.stinger(n) }
    #expect(d.netProject?.canonicalJSON == before)
    #expect(after.map(\.json).count == 4)
  }
}
