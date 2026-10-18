import Foundation

extension DJMusicality {
  /// `.bandStop`: song-family band stop before a chorus (p62-band-stop).
  /// Its stretches of the deck's `RestSchedule` (`RestSchedule.build`); a pure function of the
  /// played project. A stub until its task builds it: no rests.
  static func bandStopRests(_ project: Project) -> [RestSchedule.Entry] {
    []
  }
}
