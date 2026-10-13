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
  /// Part changes (a control net muting, unmuting or switching a part) that take effect at a
  /// bar line: fired on a bar's last tick, after its notes, so the next bar's downbeat already
  /// plays the new parts. nil when the song has none.
  public var changesOnBars: Double?
  /// Part changes in effect on a 2-bar line counted from their section's start (where the
  /// 2- and 4-bar chord cycles and motifs turn over), or on the section's own phrase line
  /// when its phrases are shorter; nil when the song has none.
  public var changesOnPhrases: Double?
  /// Section changes (not the song's end) with a drum fill in the bar before them; nil
  /// for a song without sections.
  public var fillsBeforeSections: Double?
  /// Slot switches onto a ring net that bring it in from the top of its cycle (the motif's
  /// first note, not the middle of it); nil when the song has none.
  public var slotsFromTheTop: Double?
  /// Mean semitones the pad's voices move from one chord to the next (sorted voices paired
  /// lowest to lowest), over bars where the chord changes: big leaps sound like blocks, small
  /// ones like voice leading.
  public var padMotion: Double?
  /// Consecutive melody notes (one net, at most half a bar apart) on the same pitch, and a
  /// step (1–2 semitones) apart.
  public var melodyRepeats: Double?
  public var melodySteps: Double?
  /// Pad chords with four or more pitch classes (sevenths, added ninths), of all pad chords.
  public var padColor: Double?
  /// Arp notes that are tones of the bar's chord; nil without an arp or a pad.
  public var arpChordTones: Double?
  /// Arp notes struck with a melody note of the same pitch class (unison or octaves): an arp
  /// that doubles the lead instead of playing a part of its own; nil without an arp.
  public var arpDoublesMelody: Double?
  /// Buildups (followed by another section) whose last eight bars (four, if shorter) carry a
  /// snare roll that never slows down and gets faster (fill-net hits per bar non-decreasing, the
  /// first bar at most quarters, the last at least eighths); nil for a song without one.
  public var buildupsBuild: Double?
  /// Section starts (after the first) marked by a crash cymbal on their downbeat; nil for a
  /// song without sections.
  public var crashOnSections: Double?
  /// Mean semitones the bass moves from the last note of a bar to the first of the next, where
  /// the chord changes (the pitch class differs); nil without a bass.
  public var bassLeap: Double?

  public init() {}

  /// The groups that carry pitch (everything but drums and stingers).
  static func isTonal(_ e: NoteEvent) -> Bool { !e.isDrum && e.group != "stinger" }

  public init(project: Project, log: [NoteEvent], controls: [PartChange] = []) {
    self.init()
    if !controls.isEmpty {
      let on = controls.filter { $0.tick % 16 == 0 }.count
      changesOnBars = Double(on) / Double(controls.count)
      var starts: [(start: Int, grid: Int)] = []
      var t = 0
      for sec in project.structure {
        // 2 bars, or the section's own phrase when it is shorter (a solo trading single bars)
        let count = max(1, sec.phrases.values.map(\.count).max() ?? 1)
        starts.append((t, max(1, min(32, sec.steps / count))))
        t += sec.steps
      }
      if !starts.isEmpty {
        // a change fired on tick T is in effect from step T (the next sixteenth)
        let grid = controls.filter { c in
          let s = starts.last { $0.start <= c.tick } ?? starts[0]
          return (c.tick - s.start) % s.grid == 0
        }.count
        changesOnPhrases = Double(grid) / Double(controls.count)
      }
      let slots = controls.compactMap(\.phase)
      if !slots.isEmpty {
        slotsFromTheTop = Double(slots.filter { $0 == 0 }.count) / Double(slots.count)
      }
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
      let arp = tonal.filter { $0.group == "arp" && chord[($0.tick - 1) / 16] != nil }
      if !arp.isEmpty {
        let tones = arp.filter { e in chord[(e.tick - 1) / 16]!.contains { $0 % 12 == e.note % 12 } }
        arpChordTones = Double(tones.count) / Double(arp.count)
      }
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
    let arpNotes = tonal.filter { $0.group == "arp" }
    if !arpNotes.isEmpty {
      let doubled = arpNotes.filter { a in
        byStart[a.tick]?.contains { $0.group == "melody" && $0.note % 12 == a.note % 12 } ?? false
      }
      arpDoublesMelody = Double(doubled.count) / Double(arpNotes.count)
    }

    // Kick and bass
    let kicks = Set(log.filter { $0.isDrum && ($0.note == 36 || $0.note == 35) }.map(\.tick))
    let bass = tonal.filter { $0.group == "bass" }
    if !bass.isEmpty && !kicks.isEmpty {
      bassOnKick = Double(bass.filter { kicks.contains($0.tick) }.count) / Double(bass.count)
    }
    var leaps: [Int] = []
    let bassLine = bass.sorted { $0.tick < $1.tick }
    for (a, b) in zip(bassLine, bassLine.dropFirst())
    where (a.tick - 1) / 16 + 1 == (b.tick - 1) / 16 && a.note % 12 != b.note % 12 {
      leaps.append(abs(b.note - a.note))
    }
    if !leaps.isEmpty { bassLeap = Double(leaps.reduce(0, +)) / Double(leaps.count) }
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

    // Pad voice leading: sorted voices of each bar's chord against the previous bar's
    var motion: [Double] = []
    var prevChord: [Int]?
    for b in chord.keys.sorted() {
      let c = chord[b]!.sorted()
      if let p = prevChord, p.count == c.count, Set(p.map { $0 % 12 }) != Set(c.map { $0 % 12 }) {
        motion.append(Double(zip(p, c).map { abs($0 - $1) }.reduce(0, +)))
      }
      prevChord = c
    }
    if !motion.isEmpty { padMotion = motion.reduce(0, +) / Double(motion.count) }
    if !chord.isEmpty {
      padColor =
        Double(chord.values.filter { Set($0.map { $0 % 12 }).count >= 4 }.count)
        / Double(chord.count)
    }

    // Melodic intervals, within a net
    var repeats = 0
    var stepwise = 0
    var intervals = 0
    for (_, es) in Dictionary(grouping: tonal.filter { $0.group == "melody" }, by: \.net) {
      let byTick = es.sorted { $0.tick < $1.tick }
      for (a, b) in zip(byTick, byTick.dropFirst()) where b.tick - a.tick <= 8 {
        intervals += 1
        let d = abs(b.note - a.note)
        if d == 0 { repeats += 1 }
        if d == 1 || d == 2 { stepwise += 1 }
      }
    }
    if intervals > 0 {
      melodyRepeats = Double(repeats) / Double(intervals)
      melodySteps = Double(stepwise) / Double(intervals)
    }

    // Form
    let sections = project.structure
    if sections.count > 1 {
      var boundary = 0
      var filled = 0
      for s in sections.dropLast() {
        boundary += s.steps
        if log.contains(where: {
          $0.isDrum && $0.net.hasPrefix("fill-") && $0.tick > boundary - 16 && $0.tick <= boundary
        }) {
          filled += 1
        }
      }
      fillsBeforeSections = Double(filled) / Double(sections.count - 1)
      var end = 0
      var buildups = 0
      var building = 0
      for s in sections.dropLast() {
        end += s.steps
        guard s.name == "buildup", s.steps >= 64 else { continue }
        buildups += 1
        let bars = min(8, s.steps / 16)
        let perBar = (0..<bars).map { bar in
          log.filter {
            $0.isDrum && $0.net.hasPrefix("fill-") && ($0.tick - 1) / 16 == end / 16 - bars + bar
          }.count
        }
        if perBar == perBar.sorted(), perBar[0] > 0, perBar[0] <= 4, perBar[bars - 1] >= 8 {
          building += 1
        }
      }
      if buildups > 0 { buildupsBuild = Double(building) / Double(buildups) }
      let crashes = Set(log.filter { $0.isDrum && ($0.note == 49 || $0.note == 57) }.map(\.tick))
      var downbeat = 0
      var crashed = 0
      for s in sections.dropLast() {
        downbeat += s.steps
        if crashes.contains(downbeat + 1) { crashed += 1 }
      }
      crashOnSections = Double(crashed) / Double(sections.count - 1)
    }
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
    if let v = changesOnPhrases { d["changesOnPhrases"] = round3(v) }
    if let v = fillsBeforeSections { d["fillsBeforeSections"] = round3(v) }
    if let v = slotsFromTheTop { d["slotsFromTheTop"] = round3(v) }
    if let v = padMotion { d["padMotion"] = round3(v) }
    if let v = melodyRepeats { d["melodyRepeats"] = round3(v) }
    if let v = melodySteps { d["melodySteps"] = round3(v) }
    if let v = padColor { d["padColor"] = round3(v) }
    if let v = arpChordTones { d["arpChordTones"] = round3(v) }
    if let v = arpDoublesMelody { d["arpDoublesMelody"] = round3(v) }
    if let v = buildupsBuild { d["buildupsBuild"] = round3(v) }
    if let v = crashOnSections { d["crashOnSections"] = round3(v) }
    if let v = bassLeap { d["bassLeap"] = round3(v) }
    return d
  }
}

public func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
