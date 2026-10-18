import Testing

@testable import DJCore

/// ROADMAP 6.7: a raw-`nets` share deck gets the runner's fixes and not the pass, explicitly
/// (`DJMusicality.Fixes.runnerOnly`), and the deck says which it plays with.
struct RunnerOnlyFixesTests {
  typealias Fixes = DJMusicality.Fixes

  /// Every flag `DJMusicality.apply` (or a runner half of a pass flag) reads.
  static let passFlags: Fixes = [
    .key, .timing, .register, .dynamics, .offbeatBass, .phrases, .fills, .voicing, .contour,
    .color, .arpeggio, .buildup, .crash, .bassLine, .openHats, .legato, .cadence, .approach,
    .motif, .variety, .harmonicCadence, .sectionHarmony, .harmonicRhythm, .answer, .hook,
    .shape, .bassMotif, .arpStyle, .arpDensity, .backbeat,
  ]

  func handMade() throws -> (payload: JSONValue, modelCID: String) {
    let rows = try JSONValue.parse(try beatsFixtureText("share-urls"))["rawNets"]!.array!
    let row = try #require(rows.first { $0["payload"]?["name"]?.string == "Hand Made" })
    return (row["payload"]!, row["project"]!["modelCID"]!.string!)
  }

  @Test func runnerOnlyIsAllButThePass() {
    #expect(Fixes.runnerOnly.isSubset(of: .all))
    #expect(Fixes.runnerOnly.isDisjoint(with: Self.passFlags))
    #expect(Fixes.runnerOnly.union(Self.passFlags) == .all)
    for flag in [Fixes.stereo, .space, .balance, .subtractive, .unison, .loudness] {
      #expect(Fixes.runnerOnly.contains(flag))
    }
  }

  @Test func namesAreEveryFlagOnceInBitOrder() {
    #expect(Fixes.all.names.count == Fixes.named.count - 1)  // "none" names no flag
    #expect(Fixes.runnerOnly.names.first == "loudness")
    #expect(Fixes.runnerOnly.names.allSatisfy { Fixes.runnerOnly.contains(Fixes.named[$0]!) })
    #expect(
      Fixes.runnerOnly.names.reduce(into: Fixes()) { $0.formUnion(Fixes.named[$1]!) }
        == .runnerOnly)
    #expect(Fixes().names.isEmpty)
  }

  @Test func aRawNetsShareSkipsThePassAndKeepsItsNets() throws {
    let (payload, cid) = try handMade()
    let track = try #require(PreparedTrack(rawNets: payload, sampleRate: 22_050, opts: .extended))
    #expect(!track.passApplied)
    #expect(track.fixes == .runnerOnly)
    #expect(track.played.modelCID == cid && track.project.modelCID == cid)
    #expect(track.restarted(atTick: 0).fixes == .runnerOnly)
    #expect(!track.restarted(atTick: 0).passApplied)
    // parity options stay beats exactly: no fixes at all
    let parity = try #require(
      PreparedTrack(rawNets: payload, sampleRate: 22_050, opts: WaveOptions()))
    #expect(parity.fixes.isEmpty && !parity.passApplied && parity.played.modelCID == cid)
  }

  @Test func aRawNetsSharesGenreGivesItsSettings() throws {
    let (payload, _) = try handMade()
    #expect(
      PreparedTrack.genre(rawNets: payload)
        == payload["genre"]?.string.flatMap {
          BeatsTables.shared.genres[$0] != nil ? $0 : nil
        })
    var o = payload.object!
    o["genre"] = .string("techno")
    let techno = try #require(
      PreparedTrack(rawNets: .object(o), sampleRate: 22_050, opts: .extended))
    #expect(techno.opts.genre == "techno")
    #expect(techno.opts.duckDepth == DJMusicality.duckDepth(genre: "techno"))
    o["genre"] = .string("no-such-genre")
    let unknown = try #require(
      PreparedTrack(rawNets: .object(o), sampleRate: 22_050, opts: .extended))
    #expect(unknown.opts.genre == nil, "neutral settings without a known genre")
    #expect(unknown.fixes == .runnerOnly)
  }

  @Test func aComposedTrackGetsThePass() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "house", seed: 3, structure: "minimal"), sampleRate: 22_050)
    #expect(track.passApplied)
    #expect(track.fixes == .all)
    let bare = PreparedTrack(
      spec: TrackSpec(genre: "house", seed: 3, structure: "minimal"), sampleRate: 22_050,
      opts: WaveOptions())
    #expect(!bare.passApplied && bare.fixes.isEmpty)
  }

  @Test func theDeckRecordsWhatItPlaysWith() throws {
    let (payload, _) = try handMade()
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let deck = try #require(dj["A"])
    #expect(deck.fixes == nil && !deck.passApplied)
    let track = try #require(
      PreparedTrack(rawNets: payload, sampleRate: dj.sampleRate, opts: deck.waveOptions))
    deck.loadNet(track)
    #expect(deck.fixes == .runnerOnly && !deck.passApplied)
    // a section jump re-prepares with the deck's options: still the runner's only
    #expect(deck.sameSongOptions(deck.waveOptions).musicality == .runnerOnly)
    let song = PreparedTrack(
      spec: TrackSpec(genre: "house", seed: 3, structure: "minimal"),
      sampleRate: dj.sampleRate, opts: deck.waveOptions)
    deck.loadNet(song)
    #expect(deck.fixes == .all && deck.passApplied)
    #expect(deck.sameSongOptions(deck.waveOptions).musicality == .all)
    deck.eject()
    #expect(deck.fixes == nil && !deck.passApplied)
  }
}
