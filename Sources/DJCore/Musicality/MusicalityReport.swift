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
  /// …and the share of those arrivals that come by step (two semitones or less): a line that
  /// leads into the chord change.
  public var bassStepwise: Double?
  /// How much of the time to the next melody note (in its net, at most a beat ahead) each note
  /// sounds, averaged: 1 = legato, 0.25 = a sixteenth blip in a line of quarters.
  public var melodyLegato: Double?
  /// Melody phrase ends (a note followed by half a bar or more of rest in its net within the
  /// section, or its net's last note before a 4-bar line) that are tones of the bar's chord.
  public var phraseEndsOnChordTones: Double?
  /// 4-bar melody phrases (one net, on the 4-bar grid, both first bars playing, the first two
  /// notes or more) whose second bar repeats the first's rhythm and shape: the same sixteenths,
  /// moving up, down or staying in the same places (at most a third of the moves turned
  /// otherwise: a beat note bent onto the new chord). A phrase that states an idea and
  /// repeats it.
  public var melodyIdeaRepeats: Double?
  /// 4-bar lines (bar 4 → 5, 8 → 9, … on the song's grid, both bars with a chord) where the
  /// chord's root falls a fifth (V → I) or rises a whole step (♭VII → i, IV → V) into the next
  /// bar's: harmonic phrase ends; nil without a harmony part or a line to count.
  public var harmonicCadences: Double?
  /// Distinct 4-bar root sequences (bars 1–4, 5–8, … with a chord in every bar; roots as pitch
  /// classes from `rootNote`): one loop for the whole song is 1. nil without a full block.
  public var progressions: Int?
  /// Melody, arp and bass notes on a beat that are tones of the bar's chord, per section (in
  /// song order; sections with no such notes are left out) — where a part moves and the pad
  /// does not — and the lowest of them; nil without a harmony part.
  public var sectionChordAgreement: Double?
  public var sectionChordAgreementBySection: [(section: String, agreement: Double)] = []
  /// 8-bar melody pairs (one net, bars 1–8, 9–16, … on the song's grid, both halves playing)
  /// whose first half ends open and whose second ends closed: a question and its answer. A half
  /// ends closed when its last note is the key's tonic (pitch class of `rootNote`); nil without
  /// a pair.
  public var answerPhrases: Double?
  /// The hook is the song's first melody bar with two notes or more. Of the sections with
  /// melody after the one it first plays in, the share with a bar on the hook's rhythm (the
  /// same sixteenths) and shape (the same moves up / down / level, or all of them turned: an
  /// inversion); nil without a later melodic section.
  public var hookRecurrence: Double?
  /// Melody notes in the first bar of each 4-bar phrase (bar 1, 5, 9, … on the song's grid)
  /// that are tones of the bar's chord: where a hook is stated; nil without a harmony part.
  public var barOneChordTones: Double?
  /// 4-bar bass phrases (one net, on the 4-bar grid, the first bar two notes or more, the second
  /// playing) whose second bar repeats the first's rhythm (the same sixteenths).
  public var bassIdeaRepeats: Double?
  /// Where in each 4-bar melody phrase (one net, two notes or more) its highest note first
  /// sounds, as a share of the phrase (0 = its first sixteenth, 63/64 its last), averaged:
  /// a peak near two-thirds is the classic arch.
  public var melodyPeakPosition: Double?
  /// Melody leaps (a fourth or more, at most half a bar apart, one net) followed within half a
  /// bar by a step (1–2 semitones) the other way, of the leaps followed by a note at all.
  public var leapRecovery: Double?

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
        let tones = arp.filter { e in chord[(e.tick - 1) / 16]!.contains { $0 % 12 == e.note % 12 }
        }
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
    if !leaps.isEmpty {
      bassLeap = Double(leaps.reduce(0, +)) / Double(leaps.count)
      bassStepwise = Double(leaps.filter { $0 <= 2 }.count) / Double(leaps.count)
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

    // Phrasing: notes held, phrases closed. A phrase ends at half a bar of rest inside a
    // section, or on a net's last note before a 4-bar line.
    var sectionStarts: [Int] = []
    var at = 0
    for s in project.structure {
      sectionStarts.append(at)
      at += s.steps
    }
    func section(_ step: Int) -> Int { sectionStarts.lastIndex { $0 <= step } ?? 0 }
    var held: [Double] = []
    var ends = 0
    var resolved = 0
    for (_, es) in Dictionary(grouping: tonal.filter { $0.group == "melody" }, by: \.net) {
      let byTick = es.sorted { $0.tick < $1.tick }
      for (k, e) in byTick.enumerated() {
        let next = k + 1 < byTick.count ? byTick[k + 1].tick : nil
        if let next, next > e.tick, next - e.tick <= 4 {
          held.append(min(1, e.steps / Double(next - e.tick)))
        }
        let rest = next.map { $0 - e.tick >= 8 && section($0 - 1) == section(e.tick - 1) } ?? false
        let line = next.map { ($0 - 1) / 64 > (e.tick - 1) / 64 } ?? true
        if rest || line, let c = chord[(e.tick - 1) / 16] {
          ends += 1
          if c.contains(where: { $0 % 12 == e.note % 12 }) { resolved += 1 }
        }
      }
    }
    if !held.isEmpty { melodyLegato = held.reduce(0, +) / Double(held.count) }
    if ends > 0 { phraseEndsOnChordTones = Double(resolved) / Double(ends) }

    // Ideas stated twice: bar 2 of each 4-bar phrase against bar 1
    var phrases = 0
    var restated = 0
    for (_, es) in Dictionary(grouping: tonal.filter { $0.group == "melody" }, by: \.net) {
      for (_, block) in Dictionary(grouping: es, by: { ($0.tick - 1) / 64 }) {
        let sorted = block.sorted { $0.tick < $1.tick }
        let a = sorted.filter { ($0.tick - 1) % 64 < 16 }
        let b = sorted.filter { ($0.tick - 1) % 64 >= 16 && ($0.tick - 1) % 64 < 32 }
        guard a.count >= 2, !b.isEmpty else { continue }
        phrases += 1
        func directions(_ x: [NoteEvent]) -> [Int] {
          zip(x, x.dropFirst()).map { ($1.note - $0.note).signum() }
        }
        guard a.map({ ($0.tick - 1) % 16 }) == b.map({ ($0.tick - 1) % 16 }) else { continue }
        let turns = zip(directions(a), directions(b)).filter { $0 != $1 }.count
        if 3 * turns <= a.count - 1 { restated += 1 }
      }
    }
    if phrases > 0 { melodyIdeaRepeats = Double(restated) / Double(phrases) }

    // Harmonic motion: cadences at 4-bar lines, progressions per 4-bar block, and how well
    // each section's parts agree with its chords
    if !chord.isEmpty {
      var lines = 0
      var cadences = 0
      for (b, c) in chord where b % 4 == 3 {
        guard let last = c.first, let next = chord[b + 1]?.first else { continue }
        lines += 1
        let up = ((next - last) % 12 + 12) % 12
        if up == 5 || up == 2 { cadences += 1 }
      }
      if lines > 0 { harmonicCadences = Double(cadences) / Double(lines) }
      var blocks = Set<[Int]>()
      for k in Set(chord.keys.map { $0 / 4 }) {
        let roots = (4 * k..<4 * k + 4).compactMap { chord[$0]?.first }
        if roots.count == 4 { blocks.insert(roots.map { (($0 - root) % 12 + 12) % 12 }) }
      }
      if !blocks.isEmpty { progressions = blocks.count }
      var agreeing = [Int](repeating: 0, count: max(1, sectionStarts.count))
      var onBeats = [Int](repeating: 0, count: max(1, sectionStarts.count))
      for e in tonal
      where ["melody", "arp", "bass"].contains(e.group) && (e.tick - 1) % 4 == 0 {
        guard let c = chord[(e.tick - 1) / 16] else { continue }
        let s = section(e.tick - 1)
        onBeats[s] += 1
        if c.contains(where: { $0 % 12 == e.note % 12 }) { agreeing[s] += 1 }
      }
      for s in onBeats.indices where onBeats[s] > 0 {
        let name = s < project.structure.count ? project.structure[s].name : "song"
        sectionChordAgreementBySection.append((name, Double(agreeing[s]) / Double(onBeats[s])))
      }
      sectionChordAgreement = sectionChordAgreementBySection.map(\.agreement).min()
    }

    // 6.4: phrases that answer, a hook that comes back, bass ideas, contour
    let tonic = ((project.rootNote ?? 60) % 12 + 12) % 12
    let melodyByNet = Dictionary(grouping: tonal.filter { $0.group == "melody" }, by: \.net)
      .sorted { $0.key < $1.key }.map { $0.value.sorted { $0.tick < $1.tick } }
    var pairs8 = 0
    var answered = 0
    var peaks: [Double] = []
    var leapsTaken = 0
    var recovered = 0
    for line in melodyByNet {
      for (_, block) in Dictionary(grouping: line, by: { ($0.tick - 1) / 128 }) {
        let first = block.filter { ($0.tick - 1) % 128 < 64 }.max { $0.tick < $1.tick }
        let second = block.filter { ($0.tick - 1) % 128 >= 64 }.max { $0.tick < $1.tick }
        guard let first, let second else { continue }
        pairs8 += 1
        if first.note % 12 != tonic && second.note % 12 == tonic { answered += 1 }
      }
      for (_, block) in Dictionary(grouping: line, by: { ($0.tick - 1) / 64 })
      where block.count >= 2 {
        let top = block.map(\.note).max()!
        let peak = block.filter { $0.note == top }.map(\.tick).min()!
        peaks.append(Double((peak - 1) % 64) / 64)
      }
      for k in 0..<max(0, line.count - 2) {
        let a = line[k]
        let b = line[k + 1]
        let c = line[k + 2]
        guard b.tick - a.tick <= 8, abs(b.note - a.note) >= 5, c.tick - b.tick <= 8 else {
          continue
        }
        leapsTaken += 1
        let back = c.note - b.note
        if (1...2).contains(abs(back)) && back.signum() == -(b.note - a.note).signum() {
          recovered += 1
        }
      }
    }
    if pairs8 > 0 { answerPhrases = Double(answered) / Double(pairs8) }
    if !peaks.isEmpty { melodyPeakPosition = peaks.reduce(0, +) / Double(peaks.count) }
    if leapsTaken > 0 { leapRecovery = Double(recovered) / Double(leapsTaken) }

    func rhythm(_ x: [NoteEvent]) -> [Int] { x.map { ($0.tick - 1) % 16 } }
    func moves(_ x: [NoteEvent]) -> [Int] {
      zip(x, x.dropFirst()).map { ($1.note - $0.note).signum() }
    }
    let melodyBarNotes = Dictionary(
      grouping: tonal.filter { $0.group == "melody" }, by: { ($0.tick - 1) / 16 }
    ).mapValues { $0.sorted { ($0.tick, $0.note) < ($1.tick, $1.note) } }
    if let hookBar = melodyBarNotes.keys.sorted().first(where: { melodyBarNotes[$0]!.count >= 2 }) {
      let hook = melodyBarNotes[hookBar]!
      let shape = moves(hook)
      let home = section(16 * hookBar)
      var later = 0
      var heard = 0
      for s in sectionStarts.indices where s > home {
        let lo = sectionStarts[s] / 16
        let hi = (sectionStarts[s] + project.structure[s].steps) / 16
        let bars = (lo..<hi).compactMap { melodyBarNotes[$0] }
        guard !bars.isEmpty else { continue }
        later += 1
        if bars.contains(where: { bar in
          rhythm(bar) == rhythm(hook) && (moves(bar) == shape || moves(bar) == shape.map { -$0 })
        }) {
          heard += 1
        }
      }
      if later > 0 { hookRecurrence = Double(heard) / Double(later) }
    }
    if !chord.isEmpty {
      let onOne = tonal.filter { $0.group == "melody" && ($0.tick - 1) / 16 % 4 == 0 }
        .compactMap { e in chord[(e.tick - 1) / 16].map { (e, $0) } }
      if !onOne.isEmpty {
        let tones = onOne.filter { e, c in c.contains { $0 % 12 == e.note % 12 } }
        barOneChordTones = Double(tones.count) / Double(onOne.count)
      }
    }
    var bassPhrases = 0
    var bassEchoes = 0
    for (_, es) in Dictionary(grouping: bass, by: \.net) {
      for (_, block) in Dictionary(grouping: es, by: { ($0.tick - 1) / 64 }) {
        let sorted = block.sorted { $0.tick < $1.tick }
        let a = sorted.filter { ($0.tick - 1) % 64 < 16 }
        let b = sorted.filter { ($0.tick - 1) % 64 >= 16 && ($0.tick - 1) % 64 < 32 }
        guard a.count >= 2, !b.isEmpty else { continue }
        bassPhrases += 1
        if Set(rhythm(a)) == Set(rhythm(b)) { bassEchoes += 1 }
      }
    }
    if bassPhrases > 0 { bassIdeaRepeats = Double(bassEchoes) / Double(bassPhrases) }

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
    if let v = bassStepwise { d["bassStepwise"] = round3(v) }
    if let v = melodyLegato { d["melodyLegato"] = round3(v) }
    if let v = phraseEndsOnChordTones { d["phraseEndsOnChordTones"] = round3(v) }
    if let v = melodyIdeaRepeats { d["melodyIdeaRepeats"] = round3(v) }
    if let v = harmonicCadences { d["harmonicCadences"] = round3(v) }
    if let v = progressions { d["progressions"] = v }
    if let v = answerPhrases { d["answerPhrases"] = round3(v) }
    if let v = hookRecurrence { d["hookRecurrence"] = round3(v) }
    if let v = barOneChordTones { d["barOneChordTones"] = round3(v) }
    if let v = bassIdeaRepeats { d["bassIdeaRepeats"] = round3(v) }
    if let v = melodyPeakPosition { d["melodyPeakPosition"] = round3(v) }
    if let v = leapRecovery { d["leapRecovery"] = round3(v) }
    if let v = sectionChordAgreement {
      d["sectionChordAgreement"] = round3(v)
      d["sectionChordAgreementBySection"] = sectionChordAgreementBySection.map {
        ["section": $0.section, "agreement": round3($0.agreement)] as [String: Any]
      }
    }
    return d
  }
}

public func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
