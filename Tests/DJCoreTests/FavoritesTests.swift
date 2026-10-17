import Testing

@testable import DJCore

struct FavoritesTests {
  func store() -> FavoritesStore { temporaryFavorites() }

  let iron = TrackSpec(genre: "techno", seed: 831_071, structure: "standard")

  @Test func aMissingFileIsNoFavorites() {
    #expect(store().list().isEmpty)
  }

  @Test func favoritesRoundTripNewestFirstAndOncePerTrack() throws {
    let s = store()
    try s.add(Favorite(title: "techno · Iron Fracture", source: .net(iron)))
    try s.add(Favorite(title: "house · Other", source: .net(TrackSpec(genre: "house", seed: 7))))
    // starring the same track again moves it up, it doesn't add a second
    try s.add(Favorite(title: "techno · Iron Fracture", source: .net(iron)))
    let all = s.list()
    #expect(all.map(\.title) == ["techno · Iron Fracture", "house · Other"])
    #expect(all[0].source == .net(iron))
    #expect(s.contains(cid: BeatsCID.shareCID(iron.payload)))
    try s.remove(cid: all[0].cid)
    #expect(s.list().map(\.title) == ["house · Other"])
  }

  @Test func aSampleWithNoFileIsNotAFavorite() throws {
    let s = store()
    try s.add(Favorite(title: "demo", source: .sample(id: "demo-loop", title: "demo", grid: nil)))
    #expect(s.list().isEmpty)
  }

  @Test func aSampleIsAFavoriteByItsFileAndKeepsItsGridAndTags() throws {
    let s = store()
    let grid = BeatGrid(bpm: 150, offset: 0, confidence: 1)
    let f = Favorite(
      title: "Dubstep Siren Music 01",
      source: .sample(id: "", title: "Dubstep Siren Music 01", grid: grid),
      file: "/Library/Audio/Apple Loops/Apple/03 Dubstep/Dubstep Siren Music 01.caf",
      tags: ["siren", "drop"])
    try s.add(f)
    let back = try #require(s.list().first)
    #expect(back.isSample && back.cid == "file:" + f.file!)
    #expect(back.file == f.file && back.tags == ["siren", "drop"])
    if case .sample(_, let title, let g) = back.source {
      #expect(title == "Dubstep Siren Music 01" && g?.bpm == 150)
    } else {
      Issue.record("a sample source")
    }
  }

  @Test func tagsAreCleanedFilterAndSurviveAReStar() throws {
    let s = store()
    let net = Favorite(title: "techno · One", source: .net(TrackSpec(genre: "techno", seed: 1)))
    let other = Favorite(title: "house · Two", source: .net(TrackSpec(genre: "house", seed: 2)))
    try s.add(net)
    try s.add(other)
    try s.setTags(cid: net.cid, ["  intro ", "", "Intro", "heavy"])
    try s.setTags(cid: other.cid, ["heavy"])
    let all = s.list()
    #expect(
      all.first { $0.cid == net.cid }?.tags == ["intro", "heavy"], "trimmed, no blanks or repeats")
    #expect(all.allTags == ["heavy", "intro"], "most used first")
    #expect(all.tagged("intro").map(\.cid) == [net.cid] && all.tagged(nil).count == 2)
    try s.add(Favorite(title: "techno · One", source: net.source))  // starred again
    #expect(s.list().first?.tags == ["intro", "heavy"], "a re-star keeps the tags")
  }

  @Test func anInstrumentChangeIsATracksOverrideTheProjectPlays() throws {
    let base = iron.project()
    let bass = try #require(
      base.nets.keys.compactMap { base.nets[$0] }.first { $0.riffGroup == "bass" })
    let other = try #require(
      BeatsTables.shared.instrumentSets["techno"]?["bass"]?.first { $0 != bass.track.instrument })
    guard
      case .net(let spec)? = DeckSourceDescriptor.net(iron)
        .withInstrument(other, channel: bass.track.channel)
    else {
      Issue.record("not a net")
      return
    }
    // a second change on another channel keeps the first
    guard
      case .net(let both)? = DeckSourceDescriptor.net(spec).withInstrument("supersaw", channel: 99)
    else { return }
    #expect(both.layers["tracks"]?["\(bass.track.channel)"]?["instrument"]?.string == other)
    let p = spec.project()
    let changed = p.nets.keys.compactMap { p.nets[$0] }.filter { $0.riffGroup == "bass" }
    #expect(!changed.isEmpty && changed.allSatisfy { $0.track.instrument == other })
    // it is part of the share, so a favorite of it is a different track from the plain one
    #expect(
      DeckSourceDescriptor.net(spec).favoriteCID != DeckSourceDescriptor.net(iron).favoriteCID)
    // and survives the session encoding a favorite is stored in
    #expect(DeckSourceDescriptor(json: DeckSourceDescriptor.net(spec).json) == .net(spec))
  }
}
