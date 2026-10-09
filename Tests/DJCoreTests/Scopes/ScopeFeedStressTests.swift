import Testing

@testable import DJCore

@MainActor
struct ScopeFeedStressTests {
  @Test func feedsStayConsistentWhileTheAudioThreadRunsAndTheMainThreadChurns() throws {
    let r = try stressFeeds(seconds: 3)
    #expect(r.violations.isEmpty, "\(r.violations)")
    #expect(r.pumps > 100 && r.acquires > 5 && r.releases > 3 && r.actions > 20)
    #expect(r.framesRendered > 100_000, "the audio thread really ran (\(r.framesRendered))")
    #expect(r.tapsOnAtEnd == 0, "every subscription was balanced")
  }

  @Test func anotherSeedAnotherOrderOfThings() throws {
    let r = try stressFeeds(seconds: 2, seed: 0xD1B5_4A32_D192_ED03)
    #expect(r.violations.isEmpty, "\(r.violations)")
    #expect(r.pumps > 100 && r.framesRendered > 30_000 && r.tapsOnAtEnd == 0)
  }
}
