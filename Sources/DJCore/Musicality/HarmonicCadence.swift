import Foundation

extension DJMusicality {
  /// The pad cycle's last bar resolves into its first (a harmonic cadence).
  ///
  /// Stub (`.harmonicCadence`): a no-op until `p63-harmonic-cadence` builds it. Called from `apply`
  /// in its planned slot: right after `.variety`'s `varyHarmony`, before `.register`.
  static func resolvePadCycle(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {}
}
