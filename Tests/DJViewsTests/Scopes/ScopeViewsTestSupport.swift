import DJCore
import SwiftUI

@testable import DJViews

/// An offline engine for the view tests: deck A plays a composed song, deck B the demo loop, a
/// hub over them. (The DJCore tests have a richer `ScopeRig`; DJViews tests only see the public
/// API.) Mode agents: `run(seconds:)` then `hub.pump()` gives a feed with history and fires.
@MainActor
final class ScopeViewRig {
  let dj: DJEngine
  let hub: ScopeHub

  init(genre: String = "techno", seed: Double = 42, structure: String = "standard") throws {
    dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: genre, seed: seed, structure: structure), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.wave.setTempo(300)
    dj["A"]!.setPlaying(true)
    dj["B"]!.setPlaying(true)
    hub = ScopeHub(engine: dj)
    try dj.start()
  }

  func run(seconds: Double) throws {
    var left = Int(seconds * 22_050)
    while left > 0 {
      // pump as the UI would, so no tap ring overflows
      let n = min(left, 22_050 / 2)
      try renderOffline(dj, frames: n)
      hub.pump()
      left -= n
    }
  }

  func stop() { dj.stop() }
}
