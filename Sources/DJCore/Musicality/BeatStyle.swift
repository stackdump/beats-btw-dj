import Foundation

extension DJMusicality {
  /// The sections where a genre's style has a beat — a kick and a snare (or clap) playing
  /// through the section (ROADMAP 6.5's exit: `MusicalityReport.hasBeat`). nil when the style
  /// has none anywhere (ambient) or the genre is not in the catalogue.
  ///
  /// Intros, outros, breakdowns and bridges are left out everywhere (a kick alone, or nothing,
  /// is the style there), and so are solos (the band drops to kick and hats under a soloist).
  /// The dance family also counts its buildups. The chill and jazz families expect a beat in
  /// their verses and choruses, which beats' theme table leaves silent (found in part F).
  public static func beatStyle(genre: String) -> Set<String>? {
    switch genre {
    case "ambient":
      nil
    case "techno", "house", "edm", "trance", "dnb", "dubstep", "speedcore", "garage", "trap",
      "lofi":
      ["verse", "pre-chorus", "chorus", "buildup", "drop"]
    case "country", "blues", "funk", "reggae", "synthwave", "metal", "jazz", "bossa":
      ["verse", "pre-chorus", "chorus", "drop"]
    default:
      nil
    }
  }

  /// Whether a stretch of the note log has a beat: at least half its bars carry both a kick
  /// (35, 36) and a snare or clap (37–40). Drum fills (`fill-` chains) don't count — `.fills`
  /// puts a snare in the last bar of a section that otherwise has none.
  static func hasBeat(_ log: [NoteEvent], from start: Int, steps: Int) -> Bool {
    let bars = max(1, steps / 16)
    var kick = Set<Int>()
    var snare = Set<Int>()
    for e in log where e.isDrum && !e.net.hasPrefix("fill-") && e.tick > start {
      guard e.tick <= start + steps else { continue }
      let bar = (e.tick - start - 1) / 16
      switch GrooveTemplate.Voice(note: e.note) {
      case .kick: kick.insert(bar)
      case .snare: snare.insert(bar)
      default: break
      }
    }
    return 2 * kick.intersection(snare).count >= bars
  }
}
