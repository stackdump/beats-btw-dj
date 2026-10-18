import Foundation

extension DJMusicality {
  /// 8-bar question and answer on melody slot pairs (`.answer`, ROADMAP 6.4). Runs after
  /// `.motif`, so bars 1–2 of each phrase (its idea, stated twice) stay as they are.
  ///
  /// Each section is cut into 8-bar pairs from its start (a 12-bar section has one; its last
  /// 4 bars stay). In a pair where the melody plays both halves, the last note of bars 1–4 (the
  /// question) moves to an open tone of its bar's pad chord — the chord's fifth, else its
  /// third, never the key's tonic — and the last note of bars 5–8 (the answer) to the tonic,
  /// else the chord's root: the nearest one at most a tritone away, in the key and inside the
  /// ring's range (± 2). Only a last note in bars 3–4 of its half moves. Which net and which
  /// ring step sound there comes from `slotWindows` (beats gives every phrase its own slot net,
  /// and a ring keeps song time, so the step is `ringStart` plus the offset into the window,
  /// mod the ring). A ring step asked for in several windows (a slot net plays every verse's
  /// question) takes the note most of them ask for, the first asked on a tie. Bindings only.
  static func answerPhrases(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    let (chords, padBars) = padChords(p)
    let key = keyPitchClasses(p)
    guard !key.isEmpty else { return }
    let tonic = pc(p.rootNote ?? 60)
    let windows = slotWindows(p, role: "melody")

    // Per ring net: its notes by step and its range.
    var notes: [String: [Int: (key: String, note: Int)]] = [:]
    var range: [String: ClosedRange<Int>] = [:]
    for net in windows.keys {
      guard let nb = p.nets[net], isBarRing(nb), part(nb) == "melody" else { continue }
      let steps = ringNotes(nb)
      guard let lo = steps.map(\.note).min(), let hi = steps.map(\.note).max() else { continue }
      notes[net] = Dictionary(steps.map { ($0.step, ($0.key, $0.note)) }) { a, _ in a }
      range[net] = (lo - 2)...(hi + 2)
    }
    guard !notes.isEmpty else { return }
    let timeline = windows.flatMap { net, ws in ws.map { (net: net, w: $0) } }
      .filter { notes[$0.net] != nil && $0.w.ringStart != nil && $0.w.ringLength != nil }

    /// The last note struck in song steps `a ..< b`: its song step, net, binding and note.
    func lastNote(_ a: Int, _ b: Int) -> (step: Int, net: String, key: String, note: Int)? {
      var best: (step: Int, net: String, key: String, note: Int)?
      for (net, w) in timeline where w.start < b && w.end > a {
        let ring = notes[net]!
        for s in stride(from: min(b, w.end) - 1, through: max(a, w.start), by: -1) {
          if let best, best.step >= s { break }
          if let n = ring[(w.ringStart! + s - w.start) % w.ringLength!] {
            best = (s, net, n.key, n.note)
            break
          }
        }
      }
      return best
    }

    /// The nearest note of pitch class `want` to `n` (a tritone at most), in `r` and the key.
    func nearest(_ n: Int, _ want: Int, _ r: ClosedRange<Int>) -> Int? {
      guard key.contains(want) else { return nil }
      return (-6...6).map { n + $0 }.filter { pc($0) == want && r.contains($0) }
        .min { abs($0 - n) < abs($1 - n) }
    }

    // What each (net, ring binding) is asked to become, in the order first asked.
    var asks: [String: [String: [Int]]] = [:]
    var order: [(net: String, key: String)] = []
    func ask(_ net: String, _ key: String, _ note: Int) {
      if asks[net]?[key] == nil { order.append((net, key)) }
      asks[net, default: [:]][key, default: []].append(note)
    }

    var sectionStart = 0
    for s in p.structure {
      defer { sectionStart += s.steps }
      for pair in stride(from: sectionStart, through: sectionStart + s.steps - 128, by: 128) {
        guard let q = lastNote(pair, pair + 64), let a = lastNote(pair + 64, pair + 128),
          q.step - pair >= 32, a.step - pair - 64 >= 32
        else { continue }
        let qChord = padBars > 0 ? chords[(q.step / 16) % padBars] ?? [] : []
        let aChord = padBars > 0 ? chords[(a.step / 16) % padBars] ?? [] : []

        // question: the chord's fifth, else its third (the key's, without a pad)
        let root = qChord.first ?? tonic
        let open = [root + 7, root + 4, root + 3].map(pc).filter {
          $0 != tonic && (qChord.isEmpty || qChord.contains($0))
        }
        if open.first == pc(q.note) {
          ask(q.net, q.key, q.note)
        } else if let n = open.lazy.compactMap({ nearest(q.note, $0, range[q.net]!) }).first {
          ask(q.net, q.key, n)
        }

        // answer: the tonic, else the chord's root
        if let n = nearest(a.note, tonic, range[a.net]!)
          ?? aChord.first.flatMap({ nearest(a.note, $0, range[a.net]!) })
        {
          ask(a.net, a.key, n)
        }
      }
    }

    for (net, k) in order {
      let wanted = asks[net]![k]!
      var counts: [Int: Int] = [:]
      for n in wanted { counts[n, default: 0] += 1 }
      let top = counts.values.max()!
      if let note = wanted.first(where: { counts[$0] == top }) {
        p.nets[net]?.bindings[k]?.note = note
      }
    }
  }
}
