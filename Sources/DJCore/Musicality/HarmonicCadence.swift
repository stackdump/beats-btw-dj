import Foundation

// `DJMusicality.Fixes.harmonicCadence` (ROADMAP 6.3, the pass-level cadence): beats' cohesion-v2
// pad loops one 4-bar progression for the whole song, and whether its last chord leads back
// into its first is luck of the table (`HarmonyReportTests`' baseline: all or nothing per
// genre). This pass makes the pad cycle's phrase end a cadence — the chord on the bar before
// each 4-bar line resolves into the next bar's: V → I, or ♭VII → i in minor dance genres —
// by moving that bar along the key with `reharmonize` (pad, bass, and the melody / arp beat
// notes with it). Bindings only, like the rest of the pass.

extension DJMusicality {
  /// The semitones a bar's root rises into the next bar's that count as a cadence (as
  /// `MusicalityReport.harmonicCadences` counts them): a fourth (falls a fifth: V → I) or a
  /// whole step (♭VII → i, IV → V).
  static let cadenceRises: Set<Int> = [5, 2]

  /// Whether `genre` resolves ♭VII → i rather than V → i: dance-family genres in a minor mode.
  static func cadencesFromFlatSeven(_ genre: GenreDef) -> Bool {
    BeatsTables.shared.family(of: genre.name) == 0
      && ["MinorScale", "DorianScale", "PhrygianScale"].contains(genre.scaleName)
  }

  /// The pad cycle's last bar resolves into its first (a harmonic cadence).
  ///
  /// Cohesion v2 in a seven-note key only (pentatonic and blues genres keep their plan, as
  /// with `.variety`). Each pad bar that ends a 4-bar line on the song's grid (the cycle's
  /// last bar, in beats' 4-bar loop) and whose root does not already rise a fourth or a whole
  /// step into the next bar's (a last bar on V, ♭VII, or IV before V stays) moves to the next
  /// bar's V (its diatonic fifth, when that is a perfect fifth), else its ♭VII (the diatonic
  /// degree a whole step below) — ♭VII first in minor dance genres. `reharmonize` then moves
  /// that bar's pad, bass and beat notes; `.register` and `.voicing` place and re-voice it.
  /// Runs right after `.variety`'s `varyHarmony`, so it resolves the progression the seed drew.
  static func resolvePadCycle(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    guard p.cohesion == "v2", let key = sevenNoteKey(p) else { return }
    let (chords, padBars) = padChords(p)
    guard padBars >= 2 else { return }
    // each bar's root degree as it is (a bar without a chord, or off the key, keeps 0, a
    // placeholder `reharmonize` skips for it)
    var roots = [Int](repeating: 0, count: padBars)
    for bar in 0..<padBars {
      if let r = chords[bar]?.first, let d = key.degrees.firstIndex(of: r) { roots[bar] = d }
    }
    // the pad bars that end a 4-bar line of the song (the ring loops from bar 0)
    let span = padBars * 4 / gcd(padBars, 4)
    let ends = Set(stride(from: 3, to: span, by: 4).map { $0 % padBars })
    let flatSevenFirst = cadencesFromFlatSeven(genre)
    var changed = false
    for bar in ends.sorted() {
      let next = (bar + 1) % padBars
      // a bar that both ends a line and starts one (odd cycles) is left as it is
      guard !ends.contains(next), let last = chords[bar]?.first, let first = chords[next]?.first,
        key.degrees.contains(last), let d0 = key.degrees.firstIndex(of: first)
      else { continue }
      if cadenceRises.contains(pc(first - last)) { continue }
      // (degree, the semitones it must rise into the next bar's root)
      var candidates = [((d0 + 4) % 7, 5), ((d0 + 6) % 7, 2)]
      if flatSevenFirst { candidates.reverse() }
      guard let target = candidates.first(where: { pc(first - key.degrees[$0.0]) == $0.1 })
      else { continue }
      roots[bar] = target.0
      changed = true
    }
    if changed { reharmonize(&p, to: roots) }
  }
}
