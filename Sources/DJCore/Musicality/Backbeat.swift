import Foundation

extension DJMusicality {
  /// Kick and snare on the backbeat in chill / jazz verses and choruses.
  ///
  /// Stub (`.backbeat`): a no-op until `p65-chill-backbeat` builds it. Called from `apply`
  /// in its planned slot: after `.timing`, before `.variety`.
  static func playBackbeat(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {}
}
