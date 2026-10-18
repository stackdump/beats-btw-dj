import Foundation

extension DJMusicality {
  /// How long the kick sits out at the end of a buildup (`.kickOut`): a bar, in sixteenths.
  public static let kickOutSteps = 16

  /// `.kickOut`: the kick rests for the last bar of a buildup (p62-kick-out): every buildup of
  /// at least two bars that leads straight into a drop loses its kick for its last
  /// `kickOutSteps`, the snare roll and everything else playing on. Only the kick class rests,
  /// so the `.duck` envelope (keyed by the kick's hits, which a rest drops) lets go with it.
  ///
  /// The project carries no genre, so "dance" is read from the structure: a buildup into a
  /// drop only comes from the dance family's blueprints (song genres build into a chorus; jazz,
  /// ambient and lofi have no buildups), and the other families are left as they were.
  ///
  /// Its stretches of the deck's `RestSchedule` (`RestSchedule.build`); a pure function of the
  /// played project.
  static func kickOutRests(_ project: Project) -> [RestSchedule.Entry] {
    var out: [RestSchedule.Entry] = []
    var t = 0
    let structure = project.structure
    for (k, s) in structure.enumerated() {
      let end = t + s.steps
      if s.name == "buildup", s.steps >= 2 * kickOutSteps, k + 1 < structure.count,
        structure[k + 1].name == "drop"
      {
        out.append(RestSchedule.Entry(from: end - kickOutSteps, to: end, mask: .kick))
      }
      t = end
    }
    return out
  }
}
