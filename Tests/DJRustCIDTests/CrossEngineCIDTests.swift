import DJCore
import DJRust
import Foundation
import Testing

/// Proof of concept for CID sharing across the two engines: a track the embedded Rust engine
/// (djrust, via the `djmobile` UniFFI crate: the same `Player` the Android app drives) shares
/// carries a CID, and DJCore's `BeatsCID` (the Swift engine's, beats' own scheme) computes the
/// *same* CID from the shared document. So a share made in either engine names the same
/// content, and a CID from Android can be checked in Swift without trusting the sender.
@Suite(.serialized) struct CrossEngineCIDTests {
  /// Compose `genre`/`seed` on deck A of a fresh player and return its share.
  func share(genre: String, seed: Int64) async throws -> TrackShare {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djrust-cid-sf")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let player = try Player(soundfontDir: dir.path)
    _ = try player.compose(deck: "A", genre: genre, seed: seed, structure: nil)
    // the compose lands on a worker
    for _ in 0..<400 {
      if let s = try? player.state(deck: "A"), s.loaded, s.seed == seed,
        let sh = try player.trackShare(deck: "A")
      { return sh }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw CIDTestError.timeout
  }

  enum CIDTestError: Error { case timeout }

  @Test func rustShareCIDMatchesDJCoreCID() async throws {
    let sh = try await share(genre: "house", seed: 42)
    #expect(sh.cid.hasPrefix("z"))
    let doc = try JSONValue.parse(sh.json)
    #expect(BeatsCID.shareCID(doc) == sh.cid)
  }

  @Test func sameConfigurationSameCID() async throws {
    let a = try await share(genre: "house", seed: 42)
    let b = try await share(genre: "house", seed: 42)
    #expect(a.cid == b.cid)
    #expect(a.json == b.json)
  }

  @Test func differentSeedDifferentCID() async throws {
    let a = try await share(genre: "house", seed: 42)
    let c = try await share(genre: "house", seed: 43)
    #expect(a.cid != c.cid)
  }
}
