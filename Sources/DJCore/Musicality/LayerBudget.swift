import Foundation

extension DJMusicality {
  /// `.layerBudget`: at most N melodic parts a section, the rest resting (p62-layer-budget).
  /// Its stretches of the deck's `RestSchedule` (`RestSchedule.build`); a pure function of the
  /// played project. A stub until its task builds it: no rests.
  static func layerBudgetRests(_ project: Project) -> [RestSchedule.Entry] {
    []
  }
}
