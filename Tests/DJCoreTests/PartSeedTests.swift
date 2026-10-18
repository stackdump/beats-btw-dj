import Testing

@testable import DJCore

// `TrackSpec.partSeeds` (TrackVariety.swift): a part seeded on its own keeps its seeded
// decisions whatever the track's seed, the rest of the track still the track's. dj-only deck
// state: never in the share payload, so `compose()`, the share and its CID do not see it.

private let seeds: [Double] = [17, 4242, 90_001, 123_457, 777_777, 31_337]

private func played(
  _ genre: String, _ seed: Double, parts: [String: Double] = [:], structure: String? = nil,
  fixes: DJMusicality.Fixes = .all
) -> Project {
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure, partSeeds: parts)
  return DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
}

/// Each part's (tick, note) pairs over `ticks` (the whole song when nil); drums are one part.
private func parts(_ p: Project, ticks: Int? = 64) -> [String: [[Int]]] {
  var out: [String: [[Int]]] = [:]
  for e in NoteLog.capture(p, ticks: ticks)
  where e.group != "stinger" && !e.group.hasPrefix("fill-") {
    out[e.isDrum ? "drums" : e.group, default: []].append([e.tick, e.note])
  }
  return out
}

private func ticks(_ events: [[Int]]?) -> [Int] { (events ?? []).map { $0[0] } }

struct PartSeedTests {
  /// Seeded drum parts play the same hits (tick and drum note) under every track seed; the
  /// same track seeds without part seeds do not.
  @Test(arguments: ["house", "techno", "dnb"])
  func seededDrumsKeepTheirPatternAcrossSeeds(genre: String) {
    let drumSeeds = ["kick": 501.0, "snare": 502, "hihat": 503]
    let seeded = Set(seeds.map { parts(played(genre, $0, parts: drumSeeds))["drums"] ?? [] })
    #expect(seeded.count == 1, "\(genre): \(seeded.count) drum patterns with seeded drums")
    let own = Set(seeds.map { parts(played(genre, $0))["drums"] ?? [] })
    #expect(own.count >= seeded.count, "\(genre): \(own.count) without")
  }

  /// A seeded bass keeps its rhythm (its figure's hits) under every track seed: the notes
  /// follow the track's key and chords. `.approach` (a step into the next root, which depends
  /// on the chords) is left out of both sides.
  @Test(arguments: ["techno", "house", "trance"])
  func aSeededBassKeepsItsRhythm(genre: String) {
    let fixes = DJMusicality.Fixes.all.subtracting(.approach)
    let rhythms = Set(
      seeds.map { ticks(parts(played(genre, $0, parts: ["bass": 9_001], fixes: fixes))["bass"]) })
    #expect(rhythms.count == 1, "\(genre): \(rhythms.count) bass rhythms")
  }

  /// A seeded melody is that seed's melody: with `.key` alone the melody nets play exactly what
  /// the melody seed's own track plays; with `.variety` too, its rhythm is kept under every
  /// track seed (the notes move with the track's key and chords).
  @Test(arguments: ["techno", "trance", "lofi"])
  func aSeededMelodyIsItsSeedsMelody(genre: String) {
    let donor = parts(played(genre, 55_555, fixes: [.key]))["melody"]
    for s in seeds.prefix(3) {
      let p = parts(played(genre, s, parts: ["melody": 55_555], fixes: [.key]))
      #expect(p["melody"] == donor, "\(genre) \(s)")
      #expect(p["harmony"] == parts(played(genre, s, fixes: [.key]))["harmony"], "\(genre) \(s)")
    }
    let rhythms = Set(
      seeds.map {
        ticks(
          parts(played(genre, $0, parts: ["melody": 55_555], fixes: [.key, .variety]))["melody"])
      })
    #expect(rhythms.count == 1, "\(genre): \(rhythms.count) melody rhythms")
  }

  /// Song structures too (slot nets by id): a seeded melody transplants into every section.
  @Test func aSeededMelodyTransplantsIntoASong() {
    let a = parts(
      played("trance", 4242, parts: ["melody": 808], structure: "minimal", fixes: [.key]),
      ticks: nil)
    let b = parts(played("trance", 808, structure: "minimal", fixes: [.key]), ticks: nil)
    #expect(a["melody"] == b["melody"])
    #expect(!(a["melody"] ?? []).isEmpty)
  }

  /// A part seed moves only its part: every other part plays as without it. The arp's figure
  /// follows its seed (`ArpFigure.seeded`); the song's arp changes for some track seed.
  @Test func aPartSeedMovesOnlyItsPart() {
    var arpMoved = false
    for s in seeds.prefix(4) {
      let plain = parts(played("trance", s, structure: "minimal"), ticks: nil)
      let arp = parts(played("trance", s, parts: ["arp": 31], structure: "minimal"), ticks: nil)
      for part in Set(plain.keys).union(arp.keys) where part != "arp" {
        #expect(plain[part] == arp[part], "\(s) \(part)")
      }
      if plain["arp"] != arp["arp"] { arpMoved = true }
      let hats = parts(played("house", s, parts: ["hihat": 31]))
      let house = parts(played("house", s))
      for part in Set(house.keys).union(hats.keys) where part != "drums" {
        #expect(house[part] == hats[part], "house \(s) \(part)")
      }
    }
    #expect(arpMoved)
  }

  /// A part seed equal to the track's seed changes nothing; deterministic from the spec.
  @Test func ownSeedIsANoOpAndTheResultIsPure() {
    let parts = Dictionary(uniqueKeysWithValues: TrackSpec.seedableParts.map { ($0, 4242.0) })
    let a = played("techno", 4242, structure: "standard")
    let b = played("techno", 4242, parts: parts, structure: "standard")
    #expect(a.canonicalJSON == b.canonicalJSON)
    let c = played("techno", 4242, parts: ["melody": 12, "bass": 13], structure: "standard")
    let d = played("techno", 4242, parts: ["melody": 12, "bass": 13], structure: "standard")
    #expect(c.canonicalJSON == d.canonicalJSON)
    #expect(c.canonicalJSON != a.canonicalJSON)
  }

  /// dj-only: the share payload, its CID and the composed project are the same with or
  /// without part seeds, and the parity path (`WaveOptions()`, no musicality) plays the
  /// composed project as it is.
  @Test func shareCIDAndComposeIgnorePartSeeds() {
    for genre in ["techno", "jazz"] {
      let plain = TrackSpec(genre: genre, seed: 4242, structure: "standard")
      var seeded = plain
      seeded.partSeeds = ["melody": 9, "kick": 10, "arp": 11]
      #expect(seeded.payload.canonicalJS == plain.payload.canonicalJS)
      #expect(BeatsCID.shareCID(seeded.payload) == BeatsCID.shareCID(plain.payload))
      #expect(seeded.payload["partSeeds"] == nil)
      #expect(seeded.project().canonicalJSON == plain.project().canonicalJSON)
      let parity = PreparedTrack(spec: seeded, sampleRate: 22_050, opts: WaveOptions())
      #expect(parity.played.canonicalJSON == plain.project().canonicalJSON)
    }
  }

  /// A session with part seeds round-trips them (beside the share, never inside it); one
  /// without writes exactly what it always did.
  @Test func sessionsRoundTripPartSeeds() throws {
    var spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    spec.partSeeds = ["bass": 7, "melody": 8.5]
    let s = Session(
      sampleRate: 48_000, frames: 1_000, decks: ["A": .net(spec), "B": .none],
      params: ["A": DeckParams(), "B": DeckParams()], crossfader: 0.5, master: 0.8,
      events: [
        SessionEvent(frame: 10, kind: .action(.load(deck: "B", source: .net(spec)))),
        SessionEvent(frame: 20, kind: .action(.queueNext(deck: "A", spec: spec))),
      ])
    let back = try Session.decode(s.canonical, cid: s.cid)
    #expect(back == s)
    guard case .net(let a)? = back.decks["A"] else {
      Issue.record("deck A is not a net")
      return
    }
    #expect(a.partSeeds == spec.partSeeds)
    let share = try #require(s.json["decks"]?["A"]?["source"]?["share"])
    #expect(share["partSeeds"] == nil)
    #expect(s.json["decks"]?["A"]?["source"]?["cid"]?.string == BeatsCID.shareCID(share))
    // without part seeds: no key anywhere
    #expect(!SessionModelTests.sample().canonical.contains("partSeeds"))
    var plain = spec
    plain.partSeeds = [:]
    let d = DeckSourceDescriptor.net(plain).json
    #expect(d["partSeeds"] == nil)
  }

  /// The donor compose for a seeded melody is cached: a recompile does not compose it again.
  @Test func theDonorComposeIsCached() {
    let donors = PartSeedDonors()
    let spec = TrackSpec(genre: "techno", seed: 4242, structure: "standard")
    let a = donors.melody(spec, seed: 99)
    let b = donors.melody(spec, seed: 99)
    #expect(donors.composedCount == 1)
    #expect(a.keys.sorted() == b.keys.sorted())
    #expect(!a.isEmpty)
    _ = donors.melody(spec, seed: 100)
    #expect(donors.composedCount == 2)
  }

  /// Prepare on a long song with two seeded parts, timed (reported, not a benchmark gate).
  @Test func prepareWithTwoSeededPartsIsTimed() {
    var spec = TrackSpec(genre: "techno", seed: 4242, structure: "extended")
    spec.partSeeds = ["melody": 6_001, "bass": 6_002]
    let project = spec.project()
    let seconds = Double(NoteLog.length(project)) * 15 / max(1, project.tempo)
    let clock = ContinuousClock()
    let start = clock.now
    let track = PreparedTrack(spec: spec, sampleRate: 22_050, opts: .extended)
    let elapsed = clock.now - start
    print("PartSeedTests: prepare \(Int(seconds)) s song, 2 seeded parts: \(elapsed)")
    #expect(track.spec?.partSeeds == spec.partSeeds)
    #expect(elapsed < .seconds(120))
  }
}
