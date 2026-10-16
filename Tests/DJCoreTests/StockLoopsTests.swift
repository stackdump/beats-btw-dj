import Testing

@testable import DJCore

struct StockLoopsTests {
  func loop(_ name: String, bpm: Double, category: String = "Drums") -> StockLoop {
    StockLoop(
      path: "/x/\(name).caf", name: name, pack: "Pack", category: category, subcategory: "",
      genre: "House", beats: 8, seconds: 8 * 60 / bpm, key: nil)
  }

  @Test func metadataPairsReadKeyValueStrings() {
    let d = Array("category\u{0}Drums\u{0}beat count\u{0}8\u{0}".utf8)
    let pairs = AppleLoopMetadata.pairs(.init(d))
    #expect(pairs.map(\.0) == ["category", "beat count"] && pairs.map(\.1) == ["Drums", "8"])
  }

  @Test func tempoComesFromBeatsAndSnapsToAWholeBPM() {
    // 8 beats in 3.9994 s (AAC runs a few frames short) is 120, not 120.02
    #expect(
      StockLoop(
        path: "", name: "", pack: "", category: "", subcategory: "", genre: "",
        beats: 8, seconds: 3.9994104308390024, key: nil
      ).bpm == 120)
    #expect(abs(loop("x", bpm: 93.5).bpm - 93.5) < 1e-9)
  }

  @Test func matchingFiltersThenSortsByTempoCountingHalfAndDoubleTime() {
    let all = [
      loop("Far", bpm: 90), loop("Half", bpm: 64), loop("Near", bpm: 126),
      loop("Bass Line", bpm: 128, category: "Bass"),
    ]
    #expect(
      all.matching(category: "Drums", query: "", near: 128).map(\.name) == ["Half", "Near", "Far"])
    #expect(all.matching(category: "", query: "bass", near: nil).map(\.name) == ["Bass Line"])
    #expect(all.categories == ["Drums", "Bass"])
  }

  @Test(.enabled(if: installedAppleLoop != nil, "needs the Apple Loops content"))
  func anInstalledLoopReadsItsMetadataAndTheIndexKeepsIt() throws {
    let lib = try temporaryLoopLibrary()
    let first = lib.load()
    #expect(first.count == 1)
    let l = try #require(first.first)
    #expect(l.name == "Chill Hip-Hop Beat 08" && l.pack == "Test Pack")
    #expect(l.category == "Drums" && l.genre == "Hip Hop" && l.beats == 8 && l.bpm == 120)
    // the second load reads the index, and gets the same
    #expect(lib.load() == first)
  }
}
