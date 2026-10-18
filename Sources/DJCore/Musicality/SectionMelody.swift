import Foundation

extension DJMusicality {
  /// The bridge / solo melody brought back to the home harmony (6.3 section harmony; the
  /// runner does the transpose).
  ///
  /// beats moves only the melody and arp motif in a bridge (+5 degrees) or a solo (+4,
  /// `TrackTheme.harmonic`), so the later fixes see a melody a fifth away from the pad. Under
  /// `.sectionHarmony` the runner moves the whole band by the section's shift
  /// (`SectionHarmony.sectionDegrees`, the same table); this pass first moves every melody / arp
  /// slot net that sounds only in bridge sections (or only in solo ones) back by that shift,
  /// diatonically in the project's key (`SectionHarmony.shift`), so every fix after it works on
  /// one home harmony and the runner's move puts the melody back where beats had it, now with
  /// its band.
  ///
  /// Only nets beats actually moved: cohesion v2 (beats' theme), the section's motif mode for
  /// the role on (`TrackTheme.energy`), no `hook` technique (its nets take no offset). A net
  /// that also sounds in a home section, or in sections of two shifts, is left alone. Nothing
  /// moves when the runner would not move the band (`SectionHarmony(project:)` is nil: a loop,
  /// a five-note key). Bindings only; never places, transitions or arcs. Called from `apply`
  /// after `.key` / `.phrases` / `.timing` and `.backbeat`, before `.variety`.
  static func normaliseSectionMelody(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    guard p.cohesion == "v2", spec.extra["hook"]?.bool != true,
      SectionHarmony(project: p) != nil
    else { return }
    let intervals = scaleIntervals((p.scaleName.isEmpty ? "Major" : p.scaleName) + "Scale")
    guard intervals.count == 7 else { return }
    let theme = buildTrackTheme(genre: spec.genre, seed: spec.seed)
    let root = ((p.rootNote ?? 60) % 12 + 12) % 12
    for (net, d) in sectionMelodyShifts(p, theme: theme) {
      guard var nb = p.nets[net] else { continue }
      for t in nb.bindings.keys {
        guard var b = nb.bindings[t], !isDrumChannel(b.channel) else { continue }
        b.note = SectionHarmony.shift(b.note, by: -d, root: root, intervals: intervals)
        nb.bindings[t] = b
      }
      p.nets[net] = nb
    }
  }

  /// The melody / arp slot nets beats moved for a section's harmony, with the shift: each net
  /// whose windows (`slotWindows`) all fall in sections of one non-zero shift where the role's
  /// motif plays. Sorted by net id.
  static func sectionMelodyShifts(_ p: Project, theme: TrackTheme) -> [(net: String, degrees: Int)]
  {
    var out: [(net: String, degrees: Int)] = []
    for role in ["melody", "arp"] {
      for (net, windows) in slotWindows(p, role: role) {
        var shift: Int?
        var ok = !windows.isEmpty
        for w in windows {
          let d = SectionHarmony.sectionDegrees[w.sectionName] ?? 0
          let mode = theme.energy[w.sectionName]?.roles[role]?.motifMode
          guard d != 0, let mode, mode != MotifMode.ignore, shift == nil || shift == d else {
            ok = false
            break
          }
          shift = d
        }
        if ok, let shift { out.append((net, shift)) }
      }
    }
    return out.sorted { $0.net < $1.net }
  }
}

extension SectionHarmony {
  /// The plan a deck plays `project` (the played project) through with `fixes`: nil without
  /// `.sectionHarmony` or `.harmonicRhythm`, or when the song has nothing to move. What
  /// `WaveRunner.prepare` builds and what `djctl render` hands `NoteLog`, so the report hears
  /// what the runner plays.
  public static func playing(_ project: Project, fixes: DJMusicality.Fixes) -> SectionHarmony? {
    SectionHarmony(project: project, fixes: fixes)
  }
}
