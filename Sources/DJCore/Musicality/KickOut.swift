import Foundation

extension DJMusicality {
  /// `.kickOut`: the kick rests for the last bar of a buildup (p62-kick-out).
  /// Its stretches of the deck's `RestSchedule` (`RestSchedule.build`); a pure function of the
  /// played project. A stub until its task builds it: no rests.
  static func kickOutRests(_ project: Project) -> [RestSchedule.Entry] {
    []
  }
}
