import Foundation

extension DJMusicality {
  /// One seeded chord-tone hook in every melodic section (`.hook`, p64-hook).
  ///
  /// The hook is compose-experiments' (`buildHook`, one bar, from genre + seed, its own rng):
  /// a rhythm and a contour of chord-tone targets. Every melody slot window
  /// (`slotWindows(_:role:)`) states it on its first bar, in its section's mode
  /// (`hookModes`): Play in verses / drops / choruses, Transposed (a third up) in buildups,
  /// Inverted in bridges. Fragment (intros, breakdowns, outros) and Augmented (solos) change the
  /// hook's rhythm, so there the first bar plays it whole and the variation answers it on the
  /// window's third bar (after `.motif`'s restatement in bar 2): the hook is still heard in
  /// every melodic section. Each note goes to the bar's pad chord nearest the target in the
  /// slot's register (the key's tonic at the ring's lowest note), keeping the hook's moves up /
  /// down / level, so every note is a chord tone and the shape survives the chord plan.
  ///
  /// Works on the ring steps the window covers (`ringStart`, mod the ring); a ring bar two
  /// windows reach takes the first (song order). Runs after `.cadence` and before `.motif`, so
  /// bar 2 restates the hook. Off when compose's own `hook` technique is on (the slots are
  /// already the hook), and on loops (no sections).
  static func placeHook(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    guard spec.overrides["hook"]?.bool != true else { return }
    let (chords, padBars) = padChords(p)
    let key = keyPitchClasses(p)
    guard padBars > 0, !key.isEmpty else { return }
    let scale = (0...127).filter { key.contains(pc($0)) }
    let tonic = pc(p.rootNote ?? 60)
    let density = spec.overrides["melodyDensity"]?.double ?? genre.melodyDensity
    let hook = buildHook(genre: spec.genre, seed: spec.seed, bars: 1, density: density)

    let windows = slotWindows(p, role: "melody")
      .flatMap { net, ws in ws.map { (net: net, w: $0) } }
      .sorted { ($0.w.start, $0.net) < ($1.w.start, $1.net) }
    var written: [String: Set<Int>] = [:]  // ring bars rewritten, per net
    for (id, w) in windows {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "melody",
        let ringStart = w.ringStart, ringStart % 16 == 0, w.end - w.start >= 16
      else { continue }
      let n = nb.transitions.count
      let steps = ringNotes(nb)
      guard let lo = steps.map(\.note).min(), let first = steps.first,
        let template = nb.bindings[first.key]
      else { continue }
      var base = lo - 2
      while pc(base) != tonic { base += 1 }

      let mode = hookModes[w.sectionName] ?? MotifMode.play
      let reshapes = mode == MotifMode.fragment || mode == MotifMode.augmented
      var bars: [(offset: Int, mode: Int)] = [(0, reshapes ? MotifMode.play : mode)]
      if reshapes && w.end - w.start >= 48 { bars.append((32, mode)) }
      for (offset, m) in bars {
        let start = (ringStart + offset) % n
        guard !written[id, default: []].contains(start / 16) else { continue }
        let chord = chords[((w.start + offset) / 16) % padBars] ?? []
        let notes = hookBar(hook, mode: m, base: base, chord: chord, key: key, scale: scale)
        guard notes.count >= 2 else { continue }
        // the bar's own velocity and length where it plays, else the ring's
        let inBar = steps.filter { $0.step >= start && $0.step < start + 16 }
        let like = inBar.first.flatMap { nb.bindings[$0.key] } ?? template
        for s in inBar { nb.bindings[s.key] = nil }
        for x in notes {
          var b = like
          b.note = x.note
          nb.bindings["t\(start + x.step)"] = b
        }
        written[id, default: []].insert(start / 16)
      }
      p.nets[id] = nb
    }
  }

  /// One bar of `hook` (a one-bar `HookCell`) as `mode` plays it: (sixteenth, MIDI note). Its
  /// targets are scale degrees above `base` (a tonic, on `scale`: every MIDI note in the key);
  /// Transposed adds two (a third), Inverted turns them about the tenth (9 − t), Fragment keeps
  /// the first half, Augmented plays the first half at half speed. Each note goes to the tone
  /// of `chord` (pitch classes; the key's notes when empty) nearest its target that keeps the
  /// hook's move from the note before (up, down or level), else the nearest; ties go down.
  static func hookBar(
    _ hook: HookCell, mode: Int, base: Int, chord: [Int], key: Set<Int>, scale: [Int]
  ) -> [(step: Int, note: Int)] {
    guard let root = scale.firstIndex(of: base) else { return [] }
    var cell: [(step: Int, target: Int)] = []
    for h in 0..<min(16, hook.length) where hook.mask[h] {
      var t = hook.target[h]
      if mode == MotifMode.transposed { t += 2 }
      if mode == MotifMode.inverted { t = 9 - t }
      switch mode {
      case MotifMode.fragment: if h < 8 { cell.append((h, t)) }
      case MotifMode.augmented: if h < 8 { cell.append((2 * h, t)) }
      default: cell.append((h, t))
      }
    }
    var out: [(step: Int, note: Int)] = []
    for (k, c) in cell.enumerated() {
      let raw = scale[min(scale.count - 1, max(0, root + c.target))]
      let options = (-6...6).map { raw + $0 }.filter {
        (0...127).contains($0) && (chord.isEmpty ? key.contains(pc($0)) : chord.contains(pc($0)))
      }
      let prev = out.last?.note
      let sign = k > 0 ? (c.target - cell[k - 1].target).signum() : 0
      let keep = options.filter { o in prev.map { (o - $0).signum() == sign } ?? true }
      let pool = keep.isEmpty ? options : keep
      let note = pool.min { (abs($0 - raw), $0) < (abs($1 - raw), $1) } ?? raw
      out.append((c.step, note))
    }
    return out
  }
}
