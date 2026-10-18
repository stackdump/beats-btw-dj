import Foundation

// `DJMusicality.Fixes.variety`: what makes two seeds of a genre two different songs.
//
// beats' generator draws only the melody from the seed. The key, scale and tempo are the
// genre's; the cohesion-v2 chord plan comes from a table of one or two progressions per genre
// (techno has one), the bass is the plan's roots on the genre's groove mask, the pad is the
// plan, and the drums are seeded from the genre's name — so every seed of a genre plays the
// same bass, chords and drums under a new 4-bar motif (docs/musicality-notes.md, "Variety").
// This pass, seeded from the track's seed (a pure function of (project, spec), like the rest
// of `DJMusicality`), moves the track to a nearby configuration of its own: another key,
// another progression, another bass figure and other drum details, all inside the genre.

extension DJMusicality {
  /// The pass's random source for one decision: the track's seed mixed with the decision's
  /// name, so adding a decision never moves another's draws.
  static func varietyRandom(_ name: String, genre: String, seed: Double) -> Mulberry32 {
    let u = UInt32(bitPattern: jsToInt32(seed))
    return Mulberry32(seed: Int(Int32(bitPattern: u ^ hashStr("dj-variety/\(name)/\(genre)"))))
  }

  /// The key offsets a track may move by (semitones): at most a fifth down or a tritone up, so
  /// `.register` has little to undo; 0 keeps the genre's key.
  static let keyOffsets = Array(-5...6)

  /// Diatonic progressions, as the scale degree (0-based) of each bar's chord root, by the
  /// scale the genre is in. Each bar's chord is the composed chord moved along the key to that
  /// root (a triad stays a triad, a seventh a seventh). beats' own progressions for the genre
  /// join the pool (`progressions(for:)`), so the composed plan stays one of the choices.
  /// Seven-note scales only: beats' degree arithmetic is mod 7, so pentatonic and blues
  /// genres keep their plan.
  static let progressionTable: [String: [[Int]]] = [
    // i  ii° III iv v VI VII
    "MinorScale": [
      [0, 5, 2, 6], [0, 6, 5, 6], [0, 5, 3, 4], [5, 6, 0, 0], [0, 3, 5, 6], [0, 2, 6, 5],
      [0, 0, 5, 6], [0, 3, 0, 4],
    ],
    // I ii iii IV V vi vii°
    "MajorScale": [
      [0, 4, 5, 3], [0, 3, 4, 3], [0, 5, 3, 4], [5, 3, 0, 4], [0, 3, 0, 4], [0, 1, 3, 4],
      [0, 2, 3, 4],
    ],
    // i ii III IV v vi° VII
    "DorianScale": [
      [0, 3, 0, 3], [0, 6, 3, 0], [0, 4, 3, 0], [3, 6, 0, 0], [0, 2, 3, 0], [1, 4, 0, 0],
    ],
    // I ii iii° IV v vi bVII
    "MixolydianScale": [
      [0, 6, 3, 0], [0, 3, 6, 3], [0, 4, 3, 0], [0, 6, 0, 3], [0, 5, 6, 0],
    ],
    // i bII III iv v° VI vii
    "PhrygianScale": [
      [0, 1, 0, 6], [0, 5, 1, 0], [0, 6, 5, 1], [0, 2, 1, 0], [0, 3, 1, 0],
    ],
  ]

  /// The progressions a track of `genre` may play: beats' (as roots) then dj's table, without
  /// repeats.
  static func progressions(for genre: GenreDef) -> [[Int]] {
    var out: [[Int]] = []
    for prog in genre.theory?.chordProgs ?? [] {
      let roots = prog.chords.map { clampDegree($0.root) }
      if !roots.isEmpty && !out.contains(roots) { out.append(roots) }
    }
    for roots in progressionTable[genre.scaleName] ?? [] where !out.contains(roots) {
      out.append(roots)
    }
    return out
  }

  /// The pass's first half: key, then progression. Runs before `.register` (which then puts
  /// each part back in its octave) and every other note-level fix, so they voice, accent and
  /// phrase the chords the track lands on.
  static func varyHarmony(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    var keyRng = varietyRandom("key", genre: genre.name, seed: spec.seed)
    let drawn = keyOffsets[keyRng.nextInt(keyOffsets.count)]
    // a key-locked walk pins the key it holds (`TrackSpec.pinnedKeyOffset`, from the genre root)
    transposeTrack(&p, by: spec.pinnedKeyOffset ?? drawn)
    guard p.cohesion == "v2" else { return }
    var progRng = varietyRandom("progression", genre: genre.name, seed: spec.seed)
    let pool = progressions(for: genre)
    if !pool.isEmpty { reharmonize(&p, to: pool[progRng.nextInt(pool.count)]) }
  }

  /// The second half: the bass figure and the drum detail. Runs after `.register` and
  /// `.bassLine` have placed each bass bar, so the figure's notes go where they fit (under the
  /// pad, above E1) and the bars still lead into each other as `.bassLine` placed them.
  static func varyFigures(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    if p.cohesion == "v2" {
      var bassRng = varietyRandom("bass", genre: genre.name, seed: spec.seed(forPart: "bass"))
      varyBassFigure(&p, genre: genre, rng: &bassRng)
    }
    varyDrums(&p, genre: genre, seed: spec.seed, partSeeds: spec.partSeeds)
  }

  // MARK: part seeds

  /// A seeded melody (`TrackSpec.partSeeds["melody"]`) plays the melody its own seed composes:
  /// each melody net of `p` whose id is in that seed's compose with the same transitions takes
  /// that net's bindings (bindings only, as every pass). beats draws only the melody from the
  /// seed, so the donor's melody sits on the same chord plan; `.key` and `.variety` then move
  /// it with the rest of the track. Runs first in `apply`.
  static func transplantSeededMelody(_ p: inout Project, spec: TrackSpec) {
    guard let seed = spec.partSeeds["melody"], seed != spec.seed else { return }
    let donor = PartSeedDonors.shared.melody(spec, seed: seed)
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "melody",
        let from = donor[id], from.transitions.keys == nb.transitions.keys
      else { continue }
      nb.bindings = from.bindings
      p.nets[id] = nb
    }
  }

  // MARK: key

  /// Every tonal note of the track `offset` semitones away, and the project's root with it (so
  /// `.kickTune`, the keys and every later fix that reads the key follow).
  static func transposeTrack(_ p: inout Project, by offset: Int) {
    guard offset != 0 else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control" else { continue }
      var changed = false
      for t in nb.bindings.keys {
        guard var b = nb.bindings[t], !isDrumChannel(b.channel) else { continue }
        b.note = max(0, min(127, b.note + offset))
        nb.bindings[t] = b
        changed = true
      }
      if changed { p.nets[id] = nb }
    }
    p.rootNote = (p.rootNote ?? 60) + offset
  }

  // MARK: progression

  /// The key's notes from MIDI 0 to 127, and its pitch classes from the tonic up (degree
  /// order); nil unless it has seven notes.
  static func sevenNoteKey(_ p: Project) -> (scale: [Int], degrees: [Int])? {
    let root = p.rootNote ?? 60
    let name = p.scaleName.isEmpty ? "Major" : p.scaleName
    let intervals = scaleIntervals(name + "Scale")
    guard intervals.count == 7 else { return nil }
    let degrees = intervals.map { pc(root + $0) }
    let key = Set(degrees)
    return ((0...127).filter { key.contains(pc($0)) }, degrees)
  }

  /// The pad chord of each bar moved along the key so its root is `roots[bar % count]`'s
  /// degree; the bass with it (each bar by its chord's move, a chromatic note by the root's
  /// interval); then every melody and arp note on a beat that is no longer a tone of its bar's
  /// chord to the nearest one (beats snaps its motif's beats to the chord in the same way), and
  /// a passing note that now rubs a semitone against the new chord one scale step away.
  /// Each move is the shortest way round (at most three scale steps up or down).
  static func reharmonize(_ p: inout Project, to roots: [Int]) {
    let (chords, padBars) = padChords(p)
    guard padBars > 0, !roots.isEmpty, let key = sevenNoteKey(p) else { return }
    // the scale steps each bar of the pad cycle moves, and the semitones its root moves
    var steps = [Int](repeating: 0, count: padBars)
    var semis = [Int](repeating: 0, count: padBars)
    for bar in 0..<padBars {
      guard let root = chords[bar]?.first, let from = key.degrees.firstIndex(of: root) else {
        continue
      }
      var k = ((roots[bar % roots.count] - from) % 7 + 7) % 7
      if k > 3 { k -= 7 }
      steps[bar] = k
      let to = key.degrees[(from + k + 7) % 7]
      var s = ((to - root) % 12 + 12) % 12
      if k < 0 && s > 0 { s -= 12 }
      semis[bar] = s
    }
    guard steps.contains(where: { $0 != 0 }) else { return }
    func move(_ n: Int, _ bar: Int) -> Int {
      let b = bar % padBars
      return diatonic(n, steps[b], key.scale) ?? max(0, min(127, n + semis[b]))
    }
    let inKey = Set(key.degrees)
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control" else { continue }
      let group = part(nb)
      guard group == "harmony" || group == "bass" else { continue }
      let before = ringNotes(nb)
      for s in before { nb.bindings[s.key]?.note = move(s.note, s.step / 16) }
      // A chromatic bass note (a walking bass's approach) steps into the next note as it
      // did, a semitone from it on the same side, now that the next note has moved.
      if group == "bass" && before.count > 1 {
        for (j, s) in before.enumerated() where !inKey.contains(pc(s.note)) {
          let next = before[(j + 1) % before.count]
          guard inKey.contains(pc(next.note)), let moved = nb.bindings[next.key]?.note else {
            continue
          }
          let side = s.note < next.note ? -1 : 1
          nb.bindings[s.key]?.note = moved + side
        }
      }
      p.nets[id] = nb
    }
    let (moved, _) = padChords(p)
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "melody" || part(nb) == "arp"
      else { continue }
      let line = ringNotes(nb)
      for (j, s) in line.enumerated() {
        let bar = (s.step / 16) % padBars
        guard let chord = moved[bar], !chord.isEmpty, !chord.contains(pc(s.note)) else {
          continue
        }
        let around = [j > 0 ? line[j - 1].note : nil, j + 1 < line.count ? line[j + 1].note : nil]
          .compactMap { $0 }
        if s.step % 4 == 0 {
          // a beat note: the nearest chord tone that does not repeat the note before or after
          // (a beat note `.contour` must leave alone), else the nearest
          nb.bindings[s.key]?.note = nearestTone(s.note, of: chord, avoiding: around)
        } else if rubs(s.note, chord), !rubs(s.note, chords[bar] ?? []) {
          // a passing note that now sits a semitone from the new chord (and did not against
          // the old one) steps along the key to the nearest note that does not
          for k in [-1, 1, -2, 2] {
            guard let n = diatonic(s.note, k, key.scale), !rubs(n, chord), !around.contains(n)
            else { continue }
            nb.bindings[s.key]?.note = n
            break
          }
        }
      }
      p.nets[id] = nb
    }
  }

  /// Whether `n` is a semitone from a tone of `chord` (pitch classes).
  static func rubs(_ n: Int, _ chord: [Int]) -> Bool {
    chord.contains { pc($0 - n) == 1 || pc(n - $0) == 1 }
  }

  /// The note nearest `n` whose pitch class is in `chord` and that is none of `avoiding`
  /// (a tie goes down), within a fifth; else the nearest chord tone.
  static func nearestTone(_ n: Int, of chord: [Int], avoiding: [Int] = []) -> Int {
    var nearest: Int?
    for d in 0...7 {
      for c in [n - d, n + d] where c >= 0 && c <= 127 && chord.contains(pc(c)) {
        if nearest == nil { nearest = c }
        if !avoiding.contains(c) { return c }
      }
    }
    return nearest ?? n
  }

  // MARK: bass figure

  /// A bass ring that plays one note per bar (beats' `chordBassRing`: the chord's root on the
  /// groove mask), by bar: the bar's steps in order, or nil when some bar plays two pitches.
  static func rootRingBars(_ nb: NetBundle) -> [[(key: String, step: Int, note: Int)]]? {
    guard isBarRing(nb) else { return nil }
    var bars = [[(key: String, step: Int, note: Int)]](
      repeating: [], count: nb.transitions.count / 16)
    for s in ringNotes(nb) { bars[s.step / 16].append(s) }
    for bar in bars where Set(bar.map(\.note)).count > 1 { return nil }
    return bars.contains { !$0.isEmpty } ? bars : nil
  }

  /// A seeded figure for a root-per-bar bass: a rhythm (as composed; a pickup into every
  /// second bar; or, on a busy mask, every other hit) times a line (roots; the fifth on every
  /// second hit; the fifth in the bar's back half; one octave jump mid-bar). Each
  /// bar's first and last notes stay the root as composed, so the bass still states the chord
  /// where the groove puts it and leads into the next one from its root, and added hits
  /// go only where the kick is not (the pickup on the last sixteenth of a four-on-the-floor
  /// bar, else an off-beat eighth). Walking and bossa basses (`Groove.walking`, `.bossa`) are
  /// the genre's figure and stay as composed.
  static func varyBassFigure(_ p: inout Project, genre: GenreDef, rng: inout Mulberry32) {
    let groove = BeatsTables.shared.themeTable(genre.name)?.groove ?? Groove.fourOnFloor
    guard groove != Groove.walking && groove != Groove.bossa else { return }
    let rhythm = rng.nextInt(3)
    let line = rng.nextInt(4)
    guard rhythm != 0 || line != 0 else { return }
    let kick = kickHitMask(genre)
    let pickup = bassLockedToFourOnTheFloor(genre) ? 15 : 14
    let key = sevenNoteKey(p)
    let pcs = keyPitchClasses(p)
    // the bass's room: up to A2 or its highest note, and under the pad
    var ceiling = max(notes(p, group: "bass").max() ?? bassCeiling, bassCeiling)
    if let pad = notes(p, group: "harmony").min() { ceiling = min(ceiling, pad - 1) }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "bass",
        let bars = rootRingBars(nb)
      else { continue }
      for (bi, bar) in bars.enumerated() where !bar.isEmpty {
        let root = bar[0].note
        var hits = bar
        if rhythm == 1, bi % 2 == 1, hits.last!.step % 16 < pickup,
          !(kick.count == 16 && kick[pickup]),
          let template = nb.bindings[bar[0].key], nb.transitions["t\(bi * 16 + pickup)"] != nil
        {
          let t = "t\(bi * 16 + pickup)"
          nb.bindings[t] = template
          hits.append((t, bi * 16 + pickup, root))
        } else if rhythm == 2, hits.count >= 6 {
          for (j, h) in hits.enumerated() where j % 2 == 1 { nb.bindings[h.key] = nil }
          hits = hits.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        }
        // the line: the bar's first and last notes stay the root as composed (the groove's
        // downbeat, and the note `.bassLine` / `.approach` lead into the next chord from); a
        // figure note goes up where it fits under `ceiling`, else down where it stays above
        // E1, else stays the root
        for (j, h) in hits.enumerated() where j > 0 && j < hits.count - 1 {
          var note = root
          if (line == 1 && j % 2 == 1) || (line == 2 && h.step % 16 >= 8) {
            // the chord's fifth along the key (in a five- or six-note key, the perfect fifth
            // when the key has it), above or else the one below
            let up = key.flatMap { diatonic(root, 4, $0.scale) } ?? root + 7
            let down = key.flatMap { diatonic(root, -3, $0.scale) } ?? root - 5
            if pcs.contains(pc(up)) && up <= ceiling {
              note = up
            } else if pcs.contains(pc(down)) && down >= bassFloor {
              note = down
            }
          } else if line == 3 && j == hits.count / 2 {
            // one octave jump in the middle of the bar
            if root + 12 <= ceiling {
              note = root + 12
            } else if root - 12 >= bassFloor {
              note = root - 12
            }
          }
          nb.bindings[h.key]?.note = max(0, min(127, note))
        }
      }
      p.nets[id] = nb
    }
  }

  // MARK: drums

  /// The drum part a net plays (`kick`, `snare`, `hihat`, `clap`, …), else nil.
  static func drumRole(_ nb: NetBundle, id: String) -> String? {
    guard nb.role != "control", !nb.bindings.keys.isEmpty,
      nb.bindings.values.allSatisfy({ isDrumChannel($0.channel) }),
      nb.places.count == nb.transitions.count
    else { return nil }
    let role = nb.riffGroup.isEmpty ? id : nb.riffGroup
    return ["kick", "snare", "hihat"].contains(role) ? role : nil
  }

  /// Seeded detail on the genre's drum patterns, the same choice in every slot of a part (so
  /// a section's A / B / C patterns keep their differences): hats as composed, with ghost
  /// sixteenths, thinned to the eighths, or moved by an eighth; zero to two ghost snares away
  /// from the backbeat; and outside four-on-the-floor genres sometimes one ghost kick on a
  /// free eighth. Ghosts are soft (a third to a half of the part's velocity) and never on the
  /// downbeat or next to a hit already there.
  ///
  /// A part in `partSeeds` (`kick`, `snare`, `hihat`) draws from its own seed instead.
  static func varyDrums(
    _ p: inout Project, genre: GenreDef, seed: Double, partSeeds: [String: Double] = [:]
  ) {
    let hats = varietyRandom("hihat", genre: genre.name, seed: partSeeds["hihat"] ?? seed)
    let snares = varietyRandom("snare", genre: genre.name, seed: partSeeds["snare"] ?? seed)
    let kicks = varietyRandom("kick", genre: genre.name, seed: partSeeds["kick"] ?? seed)
    let steady = fourOnTheFloor(genre)
    for id in p.nets.keys {
      guard var nb = p.nets[id], let role = drumRole(nb, id: id) else { continue }
      let n = nb.transitions.count
      guard n >= 8, let template = nb.bindings.values.first else { continue }
      var hit = [Bool](repeating: false, count: n)
      for t in nb.bindings.keys {
        if t.hasPrefix("t"), let i = Int(t.dropFirst()), i < n { hit[i] = true }
      }
      func free(_ i: Int) -> Bool {
        i > 0 && i < n && !hit[i] && !hit[(i + 1) % n] && !hit[(i - 1 + n) % n]
          && nb.transitions["t\(i)"] != nil
      }
      func ghost(_ i: Int, _ share: Double) {
        var b = template
        b.velocity = max(1, Int(Double(template.velocity) * share))
        nb.bindings["t\(i)"] = b
        hit[i] = true
      }
      switch role {
      case "hihat":
        var rng = hats
        switch rng.nextInt(4) {
        case 1:
          for i in rng.shuffle((0..<n).filter { $0 % 2 == 1 && !hit[$0] }).prefix(n / 8) {
            ghost(i, 0.45)
          }
        case 2:
          let odd = (0..<n).filter { $0 % 2 == 1 && hit[$0] }
          if odd.count < hit.filter({ $0 }).count {
            for i in odd { nb.bindings["t\(i)"] = nil }
          }
        case 3:
          var moved = OrderedMap<MidiBinding>()
          for (t, b) in nb.bindings.pairs {
            guard t.hasPrefix("t"), let i = Int(t.dropFirst()) else { continue }
            moved["t\((i + 2) % n)"] = b
          }
          if moved.keys.allSatisfy({ nb.transitions[$0] != nil }) { nb.bindings = moved }
        default: break
        }
      case "snare":
        var rng = snares
        let count = rng.nextInt(3)
        let spots = rng.shuffle((0..<n).filter { free($0) })
        for i in spots.prefix(count) { ghost(i, 0.35) }
      case "kick":
        guard !steady else { continue }
        var rng = kicks
        if rng.nextInt(2) == 1,
          let i = rng.shuffle((0..<n).filter { $0 % 2 == 0 && free($0) }).first
        {
          ghost(i, 0.6)
        }
      default: continue
      }
      p.nets[id] = nb
    }
  }
}

extension TrackSpec {
  /// The parts `partSeeds` can seed on their own: the bass figure, each drum part's detail,
  /// the melody (transplanted from its seed's compose) and the arp figure.
  public static let seedableParts = ["bass", "kick", "snare", "hihat", "melody", "arp"]

  /// The seed `part`'s seeded decisions are drawn from: its own (`partSeeds`), else the track's.
  public func seed(forPart part: String) -> Double { partSeeds[part] ?? seed }
}

/// The melody nets each donor spec composes (genre, structure, settings and layers of the
/// track, the part's seed), kept so a recompile — a section jump, another part reseeded — does
/// not compose the donor again. A few songs' worth (melody nets only); oldest out first.
final class PartSeedDonors: @unchecked Sendable {
  static let shared = PartSeedDonors()
  static let capacity = 8

  private let lock = NSLock()
  private var entries: [(key: String, nets: [String: NetBundle])] = []
  private var composed = 0
  /// How many donors have been composed (tests read it to see the cache work).
  var composedCount: Int { lock.withLock { composed } }

  func melody(_ spec: TrackSpec, seed: Double) -> [String: NetBundle] {
    var donor = spec
    donor.seed = seed
    donor.partSeeds = [:]
    let key = donor.payload.canonicalJS
    lock.lock()
    if let i = entries.firstIndex(where: { $0.key == key }) {
      let hit = entries.remove(at: i)
      entries.append(hit)
      lock.unlock()
      return hit.nets
    }
    lock.unlock()
    let project = donor.project()
    var nets: [String: NetBundle] = [:]
    for id in project.nets.keys {
      guard let nb = project.nets[id], nb.role != "control", DJMusicality.part(nb) == "melody"
      else { continue }
      nets[id] = nb
    }
    lock.lock()
    defer { lock.unlock() }
    composed += 1
    if !entries.contains(where: { $0.key == key }) {
      entries.append((key, nets))
      if entries.count > Self.capacity { entries.removeFirst() }
    }
    return nets
  }
}

extension Mulberry32 {
  /// `xs` in a seeded order (Fisher–Yates on this generator's draws).
  mutating func shuffle<T>(_ xs: [T]) -> [T] {
    var out = xs
    var i = out.count - 1
    while i > 0 {
      out.swapAt(i, nextInt(i + 1))
      i -= 1
    }
    return out
  }
}
