import Testing

@testable import DJCore

// `DJMusicality.Fixes.balance`: the parts trimmed toward `MixBalance.targetDB`, measured by
// soloing each part of a whole song (`MixBalance.measure`).

private func levels(_ genre: String, _ fixes: DJMusicality.Fixes) -> [String: Double] {
  let spec = TrackSpec(genre: genre, seed: 42, structure: "standard")
  let played = DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
  var o = WaveOptions.extended
  o.musicality = fixes
  return MixBalance.measure(played, opts: o.forGenre(genre), bars: 4, sampleRate: 22_050)
}

struct BalanceTests {
  /// In the dance genres the kick was the whole mix, the bass 12 dB or more under it; balanced,
  /// the bass sits within 8 dB of the kick, the lead within 7, and every part is nearer its
  /// target place against the others. The bass trim sits at the +6 dB clamp in all three, so
  /// what the clamp leaves is the instrument's own level: funk's plain `bass` saw has an entry
  /// in instruments.json (0.31 over the family's 0.26) that brings its gap from 8.59 to 7.07 dB.
  @Test(arguments: ["techno", "trance", "funk"])
  func theKickNoLongerIsTheMix(genre: String) throws {
    let before = levels(genre, DJMusicality.Fixes.all.subtracting(.balance))
    let after = levels(genre, .all)
    let gapBefore = try #require(before["kick"]) - (try #require(before["bass"]))
    let gapAfter = try #require(after["kick"]) - (try #require(after["bass"]))
    #expect(gapBefore > 10, "\(genre): kick − bass before \(gapBefore) dB")
    #expect(gapAfter < 8, "\(genre): kick − bass after \(gapAfter) dB")
    #expect(try #require(after["kick"]) - (try #require(after["lead"])) < 7)
    let e0 = try #require(MixBalance.error(before))
    let e1 = try #require(MixBalance.error(after))
    #expect(e1 < e0 - 2 && e1 < 3, "\(genre): balance error \(e0) → \(e1) dB")
  }

  /// Trims stay within ± 6 dB, follow the parts a song has (none for a kick alone), and a
  /// deck's track keeps them across another start of the same song.
  @Test func trimsAreBoundedAndKept() {
    let spec = TrackSpec(genre: "edm", seed: 42, structure: "minimal")
    let track = PreparedTrack(spec: spec, sampleRate: 22_050)
    let trims = track.prepared.balance ?? [:]
    #expect(Set(trims.keys).isSuperset(of: ["kick", "bass", "lead", "pad", "hats"]))
    #expect(trims.values.allSatisfy { abs($0) <= MixBalance.maxTrimDB })
    #expect(trims["kick"]! < 0 && trims["bass"]! > 0)
    var kickOnly = Project()
    kickOnly.tempo = 120
    var n = NetBundle.ring(16)
    for s in [0, 4, 8, 12] { n.bind(s, note: 36, channel: 10, velocity: 100, duration: 50) }
    n.track.channel = 10
    kickOnly.nets["kick"] = n
    #expect(MixBalance.trims(for: kickOnly).isEmpty)
    #expect(
      PreparedTrack(spec: spec, sampleRate: 22_050).prepared.balance == track.prepared.balance)
  }

  /// Per-family targets (ROADMAP 6.6): chill has its own targets.json block, the
  /// [RULE-OF-THUMB] jazz / lofi entry (bass and keys forward, hats down); jazz has none and
  /// borrows it; dance and song, and no genre, keep the default.
  @Test func familiesPickTheirEntry() throws {
    #expect(MixBalance.family(genre: "lofi") == "chill")
    #expect(MixBalance.family(genre: "jazz") == "jazz")
    #expect(MixBalance.family(genre: "techno") == "dance")
    #expect(MixBalance.family(genre: nil) == nil)
    #expect(MixBalance.entry(family: "chill") == "chill")
    #expect(MixBalance.entry(family: "jazz") == "chill")
    for f in ["dance", "song", nil] as [String?] {
      #expect(MixBalance.entry(family: f) == "default")
      #expect(MixBalance.targets(family: f) == MixBalance.targetDB)
    }
    let chill: [String: Double] = [
      "kick": -2, "bass": -1, "lead": -4, "snare": -8, "pad": -4, "arp": -8, "hats": -14,
    ]
    #expect(MixBalance.targets(family: "chill") == chill)
    #expect(MixBalance.targets(family: "jazz") == chill)
    let block = try #require(MixTargets.shared.balance.families["chill"])
    for (part, t) in block { #expect(t.source.hasPrefix("[RULE-OF-THUMB]"), "\(part)") }
    let r = MixBalance.Report(levels: ["kick": -3, "bass": -2, "hats": -15], genre: "bossa")
    #expect(r.family == "jazz" && r.entry == "chill" && r.targets == chill)
    #expect(try #require(r.errorDB) < 1e-9)
  }

  /// A dance track's trims are what they were before families (the default entry) to within
  /// 0.1 dB, on what a deck prepares.
  @Test(arguments: ["techno", "house", "trance"])
  func danceTrimsAreUnchanged(genre: String) throws {
    let spec = TrackSpec(genre: genre, seed: 42, structure: "minimal")
    let track = PreparedTrack(spec: spec, sampleRate: 22_050)
    let trims = try #require(track.prepared.balance)
    let old = MixBalance.trims(for: track.played, fixes: track.opts.musicality)
    #expect(Set(trims.keys) == Set(old.keys))
    for (k, v) in old { #expect(abs(trims[k]! - v) < 0.1, "\(genre) \(k): \(v) → \(trims[k]!)") }
  }

  /// jazz and lofi, synth path, balanced to the chill entry: within 2 dB of it, and the bass
  /// sits further over the hats than the default's trims would put it.
  @Test(arguments: ["lofi", "jazz"])
  func chillFamiliesMeetTheirTargets(genre: String) throws {
    let after = levels(genre, .all)
    let family = MixBalance.family(genre: genre)
    let e = try #require(MixBalance.error(after, family: family), "\(genre): \(after)")
    print(
      "\(genre) synth balance error \(e) dB against \(MixBalance.entry(family: family)):", after)
    #expect(e <= 2, "\(genre): balance error \(e) dB, \(after)")
    let spec = TrackSpec(genre: genre, seed: 42, structure: "standard")
    let played = DJMusicality.apply(spec.project(), spec: spec, fixes: .all)
    let own = MixBalance.trims(for: played, fixes: .all, family: family)
    let plain = MixBalance.trims(for: played, fixes: .all)
    if let b = own["bass"], let h = own["hats"], let b0 = plain["bass"], let h0 = plain["hats"] {
      #expect(b - h >= b0 - h0, "\(genre): bass − hats trim \(b0 - h0) → \(b - h) dB")
    }
  }
}
