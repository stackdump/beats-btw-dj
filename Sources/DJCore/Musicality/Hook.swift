import Foundation

extension DJMusicality {
  /// One seeded chord-tone hook in every melodic section.
  ///
  /// Stub (`.hook`): a no-op until `p64-hook` builds it. Called from `apply`
  /// in its planned slot: after `.cadence`, before `.motif`.
  static func placeHook(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {}
}
