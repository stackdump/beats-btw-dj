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
  /// 1. Repeats and passing tones: an off-beat note at most half a bar after the one before
  ///    that repeats it, or is not a tone of the bar's chord, goes to the degree the corpus's
  ///    bigram table (`MelodyBigrams.default.moves`) finds likeliest after that note, within a
  ///    major third of it, when that is likelier than where it is; not onto the next note (a
  ///    new repeat). Diatonic keys only (the table has seven degrees).
  /// 2. The peak: a 4-bar phrase (of a ring of whole 4-bar phrases) whose highest note first
  ///    sounds before 0.55 of the way through gets a higher one near two-thirds: the highest
  ///    off-beat note in `shapePeakWindow` goes up to the nearest chord tone above the old
  ///    peak (at most a fourth), else the nearest key note (at most a minor third), at most a
  ///    minor third over the ring's top.
  /// 3. Leap recovery: after a leap (`shapeLeap`), the next note within the window, when it
  ///    is off the beat, not a raised peak, and does not already step back, takes the scale step back (1–2
  ///    semitones the other way), round the cycle.
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

      // 1. repeats and passing tones, by the corpus's bigrams
      if let bigrams {
        for k in 1..<m where steps[k].step % 4 != 0 && gap(k - 1) <= shapeWindow {
          let prev = played[k - 1]
          let cur = played[k]
          guard cur == prev || !chordTone(cur, steps[k].step), let from = degree(prev)
          else { continue }
          let next: Int? = k + 1 < m && gap(k) <= shapeWindow ? played[k + 1] : nil
          func likelihood(_ n: Int) -> Double {
            guard n != prev, abs(n - prev) <= 4, let to = degree(n) else { return 0 }
            return bigrams.moves[from][to] * (n == next ? 0.25 : 1)
          }
          var best: (p: Double, note: Int)?
          for d in [-1, 1, -2, 2, -3, 3, -4, 4] {
            let n = prev + d
            guard n >= lo, n <= hi, free(n, k) else { continue }
            let l = likelihood(n)
            if l > 0, best == nil || l > best!.p { best = (l, n) }
          }
          guard let best, best.note != cur,
            cur == prev || !free(cur, k) || best.p > likelihood(cur)
          else { continue }
          played[k] = best.note
        }
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
        guard !((1...2).contains(abs(back)) && back.signum() == -leap.signum()),
          steps[c].step % 4 != 0, !peaks.contains(c),
          let n = neighbour(played[b], up: leap < 0, key: key), abs(n - played[b]) <= 2,
          n >= lo, n <= hi + 1, free(n, c)
        else { continue }
        played[c] = n
      }

      for k in 0..<m where played[k] != steps[k].note {
        nb.bindings[steps[k].key]?.note = played[k]
      }
      p.nets[id] = nb
    }
  }
}
