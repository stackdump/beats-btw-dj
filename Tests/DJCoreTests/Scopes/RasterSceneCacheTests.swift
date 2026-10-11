import Testing

@testable import DJCore

// The small least-recently-used cache of finished rasters, by (deck, trackSerial).

private func scene(_ id: Int) -> RasterScene {
  RasterScene(result: RasterResult(steps: 16 * id), lanes: [], sections: [], id: id)
}

private func key(_ deck: String, _ serial: Int32) -> RasterSongKey {
  RasterSongKey(deck: deck, serial: serial)
}

struct RasterSceneCacheTests {
  @Test func aSceneIsFoundByItsDeckAndSerial() {
    var cache = RasterSceneCache()
    #expect(cache.scene(for: key("A", 1)) == nil)
    cache.insert(scene(1), for: key("A", 1))
    cache.insert(scene(2), for: key("B", 1))
    #expect(cache.scene(for: key("A", 1))?.id == 1 && cache.scene(for: key("B", 1))?.id == 2)
    #expect(cache.scene(for: key("A", 2)) == nil, "a new track on the deck is a different song")
    #expect(cache.scene(for: key("C", 1)) == nil, "and so is the same serial on another deck")
  }

  @Test func theLeastRecentlyUsedSceneGoesFirst() {
    var cache = RasterSceneCache(capacity: 3)
    cache.insert(scene(1), for: key("A", 1))
    cache.insert(scene(2), for: key("B", 1))
    cache.insert(scene(3), for: key("A", 2))
    #expect(cache.keys == [key("A", 1), key("B", 1), key("A", 2)])
    // looking at A1 makes it the freshest, so B1 is the next to go
    #expect(cache.scene(for: key("A", 1))?.id == 1)
    #expect(cache.keys == [key("B", 1), key("A", 2), key("A", 1)])
    cache.insert(scene(4), for: key("B", 2))
    #expect(cache.count == 3)
    #expect(cache.scene(for: key("B", 1)) == nil, "the oldest was dropped")
    #expect(cache.scene(for: key("A", 1))?.id == 1 && cache.scene(for: key("A", 2))?.id == 3)
  }

  @Test func insertingAKnownSongReplacesItWithoutGrowing() {
    var cache = RasterSceneCache(capacity: 2)
    cache.insert(scene(1), for: key("A", 1))
    cache.insert(scene(2), for: key("B", 1))
    cache.insert(scene(3), for: key("A", 1))
    #expect(cache.count == 2 && cache.scene(for: key("A", 1))?.id == 3)
    #expect(cache.scene(for: key("B", 1))?.id == 2, "B was not pushed out by the replacement")
  }

  @Test func theCapacityIsAtLeastOneAndTheDefaultIsThree() {
    #expect(RasterSceneCache.defaultCapacity == 3 && RasterSceneCache().capacity == 3)
    var cache = RasterSceneCache(capacity: 0)
    #expect(cache.capacity == 1)
    cache.insert(scene(1), for: key("A", 1))
    cache.insert(scene(2), for: key("A", 2))
    #expect(cache.keys == [key("A", 2)])
    cache.removeAll()
    #expect(cache.count == 0)
  }
}
