import Foundation

extension DJMusicality {
  /// How long the band stops before a chorus (`.bandStop`): a beat, in sixteenths.
  public static let bandStopSteps = 4

  /// What stops: every part but the lead (`.melody`), fill chains' drums included. Crashes
  /// (the chorus's downbeat crash), stingers and the live keys never rest.
  public static let bandStopMask: RestSchedule.Class = [
    .kick, .drums, .bass, .harmony, .arp, .tonal, .fill,
  ]

  /// The genres whose band stops: beats' song family (country, blues, funk, reggae, synthwave,
  /// metal). The dance genres have the drop gap; jazz and the chill genres neither.
  public static func bandStopGenre(_ genre: String) -> Bool {
    ArrangeTables.family(genre) == "song"
  }

  /// `.bandStop`: song-family band stop before a chorus (p62-band-stop).
  /// Its stretches of the deck's `RestSchedule` (`RestSchedule.build`); a pure function of the
  /// played project and its genre. None for a genre outside the song family, or unknown (nil).
  static func bandStopRests(_ project: Project, genre: String?) -> [RestSchedule.Entry] {
    guard let genre, bandStopGenre(genre) else { return [] }
    return bandStops(project).map {
      RestSchedule.Entry(from: $0, to: $0 + bandStopSteps, mask: bandStopMask)
    }
  }

  /// First step of each band stop, ascending: the last beat before every chorus that does not
  /// open the song or follow a buildup / pre-chorus (`dropGaps`: the drop gap's), and in which
  /// the lead starts a note (a stop with nothing left playing would be dead air). Genre-blind:
  /// `bandStopRests` gates it by genre.
  ///
  /// The lead's onsets come from simulating only the lead nets and the control nets that act
  /// on them (`partOnly`'s cost, not the whole song's).
  public static func bandStops(_ p: Project) -> [Int] {
    var candidates: [Int] = []
    var t = 0
    for (k, s) in p.structure.enumerated() {
      if k > 0, t >= bandStopSteps, s.name == "chorus",
        !risingSections.contains(p.structure[k - 1].name)
      {
        candidates.append(t - bandStopSteps)
      }
      t += s.steps
    }
    guard let last = candidates.last else { return [] }
    let onsets = leadOnsets(p, ticks: last + bandStopSteps)
    return candidates.filter { c in onsets.contains { $0 >= c && $0 < c + bandStopSteps } }
  }

  /// The song steps (from 0) on which the lead (`RestSchedule.Class.melody` lanes: tonal nets
  /// of group `melody`) starts an audible note, in the first `ticks` steps, ascending.
  static func leadOnsets(_ p: Project, ticks: Int) -> [Int] {
    var lead = Set<String>()
    for (id, nb) in p.nets.pairs where nb.role != "control" {
      let group = nb.track.group ?? nb.riffGroup
      guard RestSchedule.Class.of(kind: "tonal", group: group, net: id) == .melody,
        nb.bindings.values.contains(where: { !isDrumChannel($0.channel) })
      else { continue }
      lead.insert(id)
    }
    guard !lead.isEmpty else { return [] }
    var only = partOnly(p, lead)
    for (id, nb) in p.nets.pairs where lead.contains(id) { only.nets[id] = nb }
    only.initialMutes = p.initialMutes.filter { lead.contains($0) }
    var out: [Int] = []
    for e in NoteLog.capture(only, ticks: ticks) where lead.contains(e.net) && !e.isDrum {
      // a note at tick n (1-based: after the fire) plays song step n - 1
      if out.last != e.tick - 1 { out.append(e.tick - 1) }
    }
    return out
  }
}
