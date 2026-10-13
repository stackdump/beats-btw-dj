import Foundation

/// Objective measures of how musical a note log is: key, harmony, register, groove and form.
/// None of them says a track is good; each catches a specific way it can sound wrong (a note
/// out of key, a semitone rub between parts, bass and pad in the same octave, a bass that
/// lands on every kick, a melody that never repeats). `djctl render` prints it, and the
/// musicality tests hold tracks to thresholds on it.
public struct MusicalityReport: Sendable {
  public var notes = 0
  public var tonalNotes = 0
  /// Tonal notes (no drums, no stingers) whose pitch class is in the project's key.
  public var inKey = 1.0
  /// Melody / arp notes on a beat that are tones of the bar's chord (the harmony group's
  /// pitch classes); nil without a harmony part.
  public var chordTonesOnBeats: Double?
  /// Bars where the bass's first note is the chord's root (the harmony's first note).
  public var bassOnRoot: Double?
  /// Pairs of sounding notes from different parts a semitone (or major seventh) apart, per
  /// 100 overlapping pairs.
  public var semitoneClashes = 0.0
  /// Bass onsets that land on the same tick as a kick.
  public var bassOnKick: Double?
  /// Harmony notes at or below the bass's highest note (two parts in one register).
  public var harmonyInBassRange: Double?
  /// Median MIDI note per tonal group.
  public var medianNote: [String: Int] = [:]
  /// Standard deviation of velocity per group (0: every hit the same).
  public var velocitySpread: [String: Double] = [:]
  /// Bars of melody (after its first four) that repeat a bar 4 or 8 bars earlier, exactly or
  /// transposed: motifs coming back.
  public var melodyRecurrence: Double?
  /// Section lengths that are whole multiples of 4 bars.
  public var sectionsOnPhrases = 1.0
  /// Notes per bar of the busiest section over the quietest (1 = no contrast).
  public var sectionContrast = 1.0
  /// Notes per bar for each group.
  public var density: [String: Double] = [:]
  /// Part changes (a control net muting, unmuting or switching a part) that land on a bar
  /// line: the last tick of a bar or the first; nil when the song has none.
  public var changesOnBars: Double?

  public init() {}

  /// The groups that carry pitch (everything but drums and stingers).
  static func isTonal(_ e: NoteEvent) -> Bool { !e.isDrum && e.group != "stinger" }

  public init(project: Project, log: [NoteEvent], controls: [PartChange] = []) {
    self.init()
    if !controls.isEmpty {
      let on = controls.filter { $0.tick % 16 == 0 || ($0.tick - 1) % 16 == 0 }.count
      changesOnBars = Double(on) / Double(controls.count)
    }
    notes = log.count
    let tonal = log.filter(Self.isTonal)
    tonalNotes = tonal.count
    let bars = max(1, (log.map(\.tick).max() ?? 16) / 16 + 1)

    // Key
    let root = project.rootNote ?? 60
    let name = project.scaleName.isEmpty ? "Major" : project.scaleName
    let pcs = Set(scaleIntervals(name + "Scale").map { (root + $0) % 12 })
    if !tonal.isEmpty {
      inKey = Double(tonal.filter { pcs.contains($0.note % 12) }.count) / Double(tonal.count)
    }

    // Chords per bar, from the harmony part (its first note in a bar is the chord's root:
    // `chordPadNet` strikes the tones root first)
    var chord: [Int: [Int]] = [:]  // bar → notes, in onset order
    for e in tonal where e.group == "harmony" {
      chord[(e.tick - 1) / 16, default: []].append(e.note)
    }
    if !chord.isEmpty {
      var hits = 0
      var total = 0
      for e in tonal where (e.group == "melody" || e.group == "arp") && (e.tick - 1) % 4 == 0 {
        guard let c = chord[(e.tick - 1) / 16] else { continue }
        total += 1
        if c.contains(where: { $0 % 12 == e.note % 12 }) { hits += 1 }
      }
      if total > 0 { chordTonesOnBeats = Double(hits) / Double(total) }
      var firstBass: [Int: Int] = [:]
      for e in tonal where e.group == "bass" {
        let b = (e.tick - 1) / 16
        if firstBass[b] == nil { firstBass[b] = e.note }
      }
      var agree = 0
      var counted = 0
      for (b, n) in firstBass {
        guard let root = chord[b]?.first else { continue }
        counted += 1
        if root % 12 == n % 12 { agree += 1 }
      }
      if counted > 0 { bassOnRoot = Double(agree) / Double(counted) }
    }

    // Semitone rubs between parts
    var pairs = 0
    var clashes = 0
    let byStart = Dictionary(grouping: tonal, by: \.tick)
    var sounding: [NoteEvent] = []
    for tick in (tonal.map(\.tick).min() ?? 0)...(tonal.map(\.tick).max() ?? 0) {
      sounding.removeAll { Double($0.tick) + max(1, $0.steps) <= Double(tick) }
      for e in byStart[tick] ?? [] {
        for o in sounding where o.group != e.group {
          pairs += 1
          let d = abs(o.note - e.note) % 12
          if d == 1 || d == 11 { clashes += 1 }
        }
        sounding.append(e)
      }
    }
    if pairs > 0 { semitoneClashes = 100 * Double(clashes) / Double(pairs) }

    // Kick and bass
    let kicks = Set(log.filter { $0.isDrum && ($0.note == 36 || $0.note == 35) }.map(\.tick))
    let bass = tonal.filter { $0.group == "bass" }
    if !bass.isEmpty && !kicks.isEmpty {
      bassOnKick = Double(bass.filter { kicks.contains($0.tick) }.count) / Double(bass.count)
    }
    let harmony = tonal.filter { $0.group == "harmony" }
    if let top = bass.map(\.note).max(), !harmony.isEmpty {
      harmonyInBassRange =
        Double(harmony.filter { $0.note <= top }.count) / Double(harmony.count)
    }

    // Register and dynamics
    for (g, es) in Dictionary(grouping: log, by: { $0.isDrum ? "drums" : $0.group }) {
      if g != "drums" && g != "stinger" {
        let sorted = es.map(\.note).sorted()
        medianNote[g] = sorted[sorted.count / 2]
      }
      let v = es.map { Double($0.velocity) }
      let mean = v.reduce(0, +) / Double(v.count)
      velocitySpread[g] = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count))
        .squareRoot()
      density[g] = Double(es.count) / Double(bars)
    }

    // Motifs: does a melody bar come back 4 or 8 bars later?
    var barShape: [Int: [Int]] = [:]  // bar → [step * 128 + note] in order
    for e in tonal where e.group == "melody" {
      barShape[(e.tick - 1) / 16, default: []].append(((e.tick - 1) % 16) * 128 + e.note)
    }
    func transposeFree(_ s: [Int]) -> [Int] {
      guard let first = s.first else { return [] }
      return s.map { ($0 / 128) * 1000 + ($0 % 128 - first % 128) }
    }
    let melodyBars = barShape.keys.sorted()
    if let firstBar = melodyBars.first {
      var recurring = 0
      var counted = 0
      for b in melodyBars where b >= firstBar + 4 {
        counted += 1
        let me = transposeFree(barShape[b]!)
        if [4, 8].contains(where: { barShape[b - $0].map(transposeFree) == me }) { recurring += 1 }
      }
      if counted > 0 { melodyRecurrence = Double(recurring) / Double(counted) }
    }

    // Form
    let sections = project.structure
    if !sections.isEmpty {
      sectionsOnPhrases =
        Double(sections.filter { $0.steps % 64 == 0 }.count) / Double(sections.count)
      var start = 0
      var perBar: [Double] = []
      for s in sections {
        let n = log.filter { $0.tick > start && $0.tick <= start + s.steps }.count
        perBar.append(Double(n) / Double(max(1, s.steps / 16)))
        start += s.steps
      }
      if let lo = perBar.min(), let hi = perBar.max() { sectionContrast = hi / max(lo, 1) }
    }
  }

  /// A JSON-friendly dictionary (keys sorted by the caller's serializer).
  public var dictionary: [String: Any] {
    var d: [String: Any] = [
      "notes": notes, "tonalNotes": tonalNotes, "inKey": round3(inKey),
      "semitoneClashesPer100": round3(semitoneClashes),
      "sectionsOnPhrases": round3(sectionsOnPhrases),
      "sectionContrast": round3(sectionContrast), "medianNote": medianNote,
      "velocitySpread": velocitySpread.mapValues(round3),
      "densityPerBar": density.mapValues(round3),
    ]
    if let v = chordTonesOnBeats { d["chordTonesOnBeats"] = round3(v) }
    if let v = bassOnRoot { d["bassOnRoot"] = round3(v) }
    if let v = bassOnKick { d["bassOnKick"] = round3(v) }
    if let v = harmonyInBassRange { d["harmonyInBassRange"] = round3(v) }
    if let v = melodyRecurrence { d["melodyRecurrence"] = round3(v) }
    if let v = changesOnBars { d["changesOnBars"] = round3(v) }
    return d
  }
}

func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
