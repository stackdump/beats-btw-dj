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
  /// target place against the others.
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
}
