import Foundation

extension DJMusicality {
  /// A leap: a fourth or more (`MusicalityReport.leapRecovery`'s).
  static let shapeLeap = 5
  /// Sixteenths within which two melody notes are neighbours (the report's interval window:
  /// at most half a bar apart).
  static let shapeWindow = 8
  /// Where in a 4-bar phrase (sixteenths of 64) a peak that came early is moved: 0.56–0.8.
  static let shapePeakWindow = 36...51

  /// Melodic contour by corpus (`.shape`, p64-shape), in each melody ring of whole bars. Runs
  /// after `.contour` (which steps the repeats it can, at most a beat apart) and before
  /// `.cadence`. Only off-beat notes (not on a quarter) move, always onto the key and never a
  /// semitone against the bar's pad chord, so the beats — and the chord tones on them — stay
  /// as composed. Three steps, each on the line as the one before left it:
  /// 1. Repeats and leaps onto non-chord tones: an off-beat note at most half a bar after the
  ///    one before that repeats it, or is a non-chord tone a leap (3+ semitones) away from it,
  ///    becomes a step from it (1–2 semitones): the degree the corpus's bigram table
  ///    (`MelodyBigrams.default.moves`) finds likeliest after that note, not onto the next note
  ///    (a new repeat) and rather not a leap from it. A note a step away already — a passing
  ///    or neighbour tone — stays: moving those to the table's likeliest degree (often a third)
  ///    took the steps out of the line. Keys without seven degrees step towards the next note.
  /// 2. The peak: a 4-bar phrase (of a ring of whole 4-bar phrases) whose highest note first
  ///    sounds before 0.55 of the way through gets a higher one near two-thirds: the highest
  ///    off-beat note in `shapePeakWindow` goes up to the nearest chord tone above the old
  ///    peak (at most a fourth), else the nearest key note (at most a minor third), at most a
  ///    minor third over the ring's top.
  /// 3. Leap recovery: after a leap (`shapeLeap`), the next note within the window, when it
  ///    is off the beat, not a raised peak, and does not already step back, takes the scale
  ///    step back (1–2 semitones the other way), round the cycle. When that note is on the beat
  ///    (or cannot step back) and the leap's own note is off the beat, the leap closes instead:
  ///    that note goes to the key note nearest it within a major third of the note before.
  static func shapeMelody(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    let key = keyPitchClasses(p)
    guard !key.isEmpty else { return }
    let (chords, padBars) = padChords(p)
    let root = pc(p.rootNote ?? 60)
    let name = p.scaleName.isEmpty ? "Major" : p.scaleName
    let intervals = scaleIntervals(name + "Scale").map { pc($0) }.sorted()
    let bigrams: MelodyBigrams? =
      intervals.count == MelodyBigrams.degrees ? MelodyBigrams.default : nil
    func degree(_ n: Int) -> Int? { intervals.firstIndex(of: pc(n - root)) }
    func chord(_ step: Int) -> [Int]? { padBars > 0 ? chords[(step / 16) % padBars] : nil }
    func rubs(_ n: Int, _ step: Int) -> Bool {
      guard let c = chord(step) else { return false }
      return c.contains { pc(n - $0) == 1 || pc(n - $0) == 11 }
    }
    func chordTone(_ n: Int, _ step: Int) -> Bool { chord(step)?.contains(pc(n)) ?? false }
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "melody" else { continue }
      let steps = ringNotes(nb)
      let m = steps.count
      guard m > 2 else { continue }
      let count = nb.transitions.count
      let lo = steps.map(\.note).min()! - 2
      let hi = steps.map(\.note).max()! + 2
      var played = steps.map(\.note)
      // sixteenths from note k to the next, round the cycle
      func gap(_ k: Int) -> Int {
        k + 1 < m ? steps[k + 1].step - steps[k].step : steps[0].step + count - steps[k].step
      }
      func free(_ n: Int, _ k: Int) -> Bool { key.contains(pc(n)) && !rubs(n, steps[k].step) }

      // 1. repeats and leaps onto non-chord tones become steps, by the corpus's bigrams
      for k in 1..<m where steps[k].step % 4 != 0 && gap(k - 1) <= shapeWindow {
        let prev = played[k - 1]
        let cur = played[k]
        let isStep = (1...2).contains(abs(cur - prev))
        // a step already (a passing or neighbour tone) or a chord tone reached by a leap
        // stays: only repeats and non-chord tones a leap away move
        guard cur == prev || (!isStep && !chordTone(cur, steps[k].step)) else { continue }
        let next: Int? = k + 1 < m && gap(k) <= shapeWindow ? played[k + 1] : nil
        func likelihood(_ n: Int) -> Double {
          guard n != prev else { return 0 }
          let corpus: Double
          if let bigrams, let from = degree(prev), let to = degree(n) {
            corpus = bigrams.moves[from][to]
          } else {
            // not a seven-note key: towards the next note, else up
            corpus = next.map { ($0 - prev).signum() == (n - prev).signum() ? 0.6 : 0.4 } ?? 0.5
          }
          // not onto the next note (a new repeat), and not a leap away from it
          let toNext = next.map { abs($0 - n) } ?? 0
          return corpus * (n == next ? 0.25 : 1) * (toNext >= shapeLeap ? 0.5 : 1)
        }
        var best: (p: Double, note: Int)?
        for d in [-1, 1, -2, 2] {
          let n = prev + d
          guard n >= lo, n <= hi, free(n, k) else { continue }
          let l = likelihood(n)
          if l > 0, best == nil || l > best!.p { best = (l, n) }
        }
        guard let best, best.note != cur else { continue }
        played[k] = best.note
      }

      // 2. a peak near two-thirds of each 4-bar phrase
      var peaks = Set<Int>()  // notes raised here, which step 3 leaves where they are
      if count % 64 == 0 {
        for start in stride(from: 0, to: count, by: 64) {
          let block = (0..<m).filter { steps[$0].step >= start && steps[$0].step < start + 64 }
          guard block.count >= 2 else { continue }
          let top = block.map { played[$0] }.max()!
          let first = block.first { played[$0] == top }!
          guard steps[first].step - start < 35 else { continue }  // before 0.55
          let window = block.filter {
            shapePeakWindow.contains(steps[$0].step - start) && steps[$0].step % 4 != 0
          }
          guard let k = window.max(by: { played[$0] < played[$1] }) else { continue }
          let ceiling = hi + 1  // the ring's top + a minor third
          let raised =
            (top + 1...top + 5).first {
              $0 <= ceiling && free($0, k) && chordTone($0, steps[k].step)
            } ?? (top + 1...top + 3).first { $0 <= ceiling && free($0, k) }
          guard let raised else { continue }
          played[k] = raised
          peaks.insert(k)
        }
      }

      // 3. a leap recovered by a step back
      for a in 0..<m {
        let b = (a + 1) % m
        let c = (a + 2) % m
        guard gap(a) <= shapeWindow, gap(b) <= shapeWindow else { continue }
        let leap = played[b] - played[a]
        guard abs(leap) >= shapeLeap else { continue }
        let back = played[c] - played[b]
        guard !((1...2).contains(abs(back)) && back.signum() == -leap.signum()) else { continue }
        if steps[c].step % 4 != 0, !peaks.contains(c),
          let n = neighbour(played[b], up: leap < 0, key: key), abs(n - played[b]) <= 2,
          n >= lo, n <= hi + 1, free(n, c)
        {
          played[c] = n
          continue
        }
        // the note after it is on the beat (or cannot step back): when the leap's own note is
        // off the beat, close the leap instead, to the key note nearest it within a third of
        // the note before that the next note is still within a fourth of
        guard steps[b].step % 4 != 0, !peaks.contains(b) else { continue }
        let from = played[a]
        let to = played[c]
        let options = (from - 4...from + 4).filter {
          $0 != from && $0 >= lo && $0 <= hi && free($0, b) && abs(to - $0) < shapeLeap
        }
        guard let n = options.min(by: { abs($0 - played[b]) < abs($1 - played[b]) }) else {
          continue
        }
        played[b] = n
      }

      for k in 0..<m where played[k] != steps[k].note {
        nb.bindings[steps[k].key]?.note = played[k]
      }
      p.nets[id] = nb
    }
  }
}
