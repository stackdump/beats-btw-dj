import Foundation

extension DJMusicality {
  /// The sixteenth of a bar from which a note bar 1 does not play counts as bar 2's pickup
  /// (the last beat: `varyBassFigure`'s pickup lands on 14 or 15).
  static let bassPickupFrom = 12

  /// Bass bar 2 echoes bar 1's rhythm (`.bassMotif`, ROADMAP 6.4).
  ///
  /// In each bass ring of whole bars, every 4-bar phrase (2-bar, in a 2-bar ring) whose first
  /// bar plays two notes or more and whose second bar plays, on another rhythm: bar 2's notes
  /// are replaced by bar 1's, on the same sixteenths with the same lengths and velocities, each
  /// the same number of scale steps from bar 2's root as it was from bar 1's first note (bar
  /// 2's root: its pad chord's root nearest the note bar 2 began on, else that note), so the
  /// copy starts on the chord and stays in key. A note that would leave the bass's room (E1
  /// up to A2 or the part's highest note, under the pad) goes an octave the other way; when it
  /// cannot, or bar 1 has a note outside the key, the phrase stays as composed. A pickup bar 2
  /// plays in its last beat after bar 1's last note (`varyBassFigure`'s pickup into the next
  /// chord) stays, and bar 1 takes it too on the same sixteenth, the same steps from its first
  /// note, so the two bars still share one rhythm. Walking and bossa basses (`Groove.walking`,
  /// `.bossa`) are the genre's figure and stay as composed. Runs after `varyFigures` /
  /// `moveBassOffTheKick` (the rhythm it copies is the one that plays), before
  /// `approachChordChanges` (which then leads bar 2 into bar 3 from the copy).
  static func restateBassRhythm(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    let groove = BeatsTables.shared.themeTable(genre.name)?.groove ?? Groove.fourOnFloor
    guard groove != Groove.walking && groove != Groove.bossa else { return }
    let key = keyPitchClasses(p)
    guard !key.isEmpty else { return }
    let scale = (0...127).filter { key.contains(pc($0)) }
    let (chords, padBars) = padChords(p)
    // the bass's room, as `varyBassFigure` reads it
    var ceiling = max(notes(p, group: "bass").max() ?? bassCeiling, bassCeiling)
    if let pad = notes(p, group: "harmony").min() { ceiling = min(ceiling, pad - 1) }
    let room = bassFloor...max(bassFloor, ceiling)
    func fit(_ n: Int) -> Int? {
      if room.contains(n) { return n }
      if room.contains(n + 12) { return n + 12 }
      if room.contains(n - 12) { return n - 12 }
      return nil
    }
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "bass" else { continue }
      let count = nb.transitions.count
      let block = count % 64 == 0 ? 64 : 32
      guard count % block == 0 else { continue }
      let steps = ringNotes(nb)
      for start in stride(from: 0, to: count, by: block) {
        let first = steps.filter { $0.step >= start && $0.step < start + 16 }
        let second = steps.filter { $0.step >= start + 16 && $0.step < start + 32 }
        guard first.count >= 2, let opening = second.first,
          first.allSatisfy({ key.contains(pc($0.note)) })
        else { continue }
        let rhythm1 = first.map { $0.step % 16 }
        guard Set(rhythm1) != Set(second.map { $0.step % 16 }) else { continue }
        // bar 2's root: its chord's root nearest where it began, in key and in the room
        var root2 = opening.note
        if padBars > 0, let r = chords[((start + 16) / 16) % padBars]?.first, pc(root2) != r,
          key.contains(r),
          let near = (-6...6).map({ opening.note + $0 })
            .filter({ pc($0) == r && room.contains($0) })
            .min(by: { abs($0 - opening.note) < abs($1 - opening.note) })
        {
          root2 = near
        }
        guard let i1 = scale.firstIndex(of: first[0].note), let i2 = scale.firstIndex(of: root2)
        else { continue }
        // `n` moved `k` scale steps, then into the room
        func moved(_ n: Int, by k: Int) -> Int? {
          guard let i = scale.firstIndex(of: n), scale.indices.contains(i + k) else { return nil }
          return fit(scale[i + k])
        }
        var copy: [(step: Int, binding: MidiBinding)] = []
        for s in first {
          guard let n = moved(s.note, by: i2 - i1), var b = nb.bindings[s.key] else { break }
          b.note = n
          copy.append((s.step + 16, b))
        }
        guard copy.count == first.count else { continue }
        // bar 2's pickup: last-beat notes after bar 1's last, kept; bar 1 plays them too
        let last1 = rhythm1.max()!
        let pickups = second.filter { $0.step % 16 >= bassPickupFrom && $0.step % 16 > last1 }
        var lead: [(step: Int, binding: MidiBinding)] = []
        for s in pickups {
          guard let n = moved(s.note, by: i1 - i2), var b = nb.bindings[s.key],
            nb.transitions["t\(s.step - 16)"] != nil
          else { break }
          b.note = n
          lead.append((s.step - 16, b))
        }
        guard lead.count == pickups.count else { continue }
        let kept = Set(pickups.map(\.key))
        for s in second where !kept.contains(s.key) { nb.bindings[s.key] = nil }
        for c in copy { nb.bindings["t\(c.step)"] = c.binding }
        for l in lead { nb.bindings["t\(l.step)"] = l.binding }
      }
      p.nets[id] = nb
    }
  }
}
