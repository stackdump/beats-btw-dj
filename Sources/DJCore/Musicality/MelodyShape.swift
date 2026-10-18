import Foundation

extension DJMusicality {
  /// Melodic contour by corpus: leaps recovered by step, a peak at two-thirds of the phrase.
  ///
  /// Stub (`.shape`): a no-op until `p64-shape` builds it. Called from `apply`
  /// in its planned slot: after `.contour`, before `.cadence`.
  static func shapeMelody(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {}
}
