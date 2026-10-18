import Foundation

extension DJMusicality {
  /// The bridge melody normalised to the section's harmony plan (6.3 section harmony; the
  /// runner does the transpose).
  ///
  /// Stub (`.sectionHarmony`): a no-op until `p63-section-transpose-runner` builds it. Called
  /// from `apply` after `.key` / `.phrases` / `.timing` and `.backbeat`, before `.variety`.
  static func normaliseSectionMelody(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {}
}
