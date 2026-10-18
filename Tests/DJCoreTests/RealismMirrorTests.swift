import Testing

@testable import DJCore

// dj-side mirrors of the realism audit's M2 and M5 (docs/research/realism-2026-10.md §5; M1 is
// `FormReportTests`), on what a deck plays: `PreparedTrack.played` under `WaveOptions.extended`
// (`DJMusicality.apply` with its fixes, which is how `PreparedTrack` makes `played`, without
// preparing a runner), its notes as the runner maps them per section (`SectionHarmony`), every
// genre at seeds 42 and 4242, standard structure.
//
// - M2a scale consistency: per tonal role, the share of notes in the project's key, leaving out
//   approach notes (a note off the key that steps a semitone into the same net's next note, in
//   key, within a beat: a walking bass's chromatic approach). Target ≥ 0.97.
// - M2b strong-beat chord tones: melody notes on beats 1 and 3 that are tones of the bar's pad
//   chord. Target ≥ 0.8.
// - M5 fills: at each section boundary where the energy changes (the `feel-curve` net's energy
//   or filter differs either side), the section's last bar has a note (role, sixteenth in the
//   bar, pitch) that none of the section's other bars play. Target: every such boundary.
//
// `MusicalityReport` has neighbours of these (`inKey` over all parts, `chordTonesOnBeats` on
// every beat, `fillsBeforeSections` on drum fills only); the figures here are computed in the
// helpers below so the report stays as it is.
//
// A genre that misses a figure today is listed in `knownIssues` with that figure and recorded
// with `withKnownIssue`; the test prints every genre's numbers (`realism mirror:` lines).

/// The figures, as `knownIssues` names them.
private enum RealismFigure: String, Sendable {
  case scale = "M2 scale"
  case strongBeats = "M2 strong beats"
  case fills = "M5 fills"
}

/// Genres that miss a figure today, with the figure. Seeded from the audit's 2026-10 beats
/// measurements (the tension genres miss M2 there, §2.2) before this mirror's first run on the
/// played tracks; `isIntermittent` until that run prunes the list to what fails both seeds.
private let knownIssues: [String: Set<RealismFigure>] = [
  "jazz": [.scale, .strongBeats],
  "metal": [.scale, .strongBeats],
  "dnb": [.scale, .strongBeats],
  "edm": [.scale, .strongBeats],
  "ambient": [.scale, .strongBeats],
  "trance": [.scale, .strongBeats],
  "synthwave": [.scale, .strongBeats],
  "trap": [.scale, .strongBeats],
]

private let scaleTarget = 0.97
private let strongBeatTarget = 0.8

/// What a deck plays for (genre, seed): the played project and its notes and part changes.
private func playedLog(_ genre: String, _ seed: Double) -> (
  project: Project, notes: [NoteEvent], controls: [PartChange]
) {
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  let fixes = WaveOptions.extended.musicality
  let played = DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
  let (notes, controls) = NoteLog.captureAll(
    played, harmony: SectionHarmony.playing(played, fixes: fixes))
  return (played, notes, controls)
}

private func keyClasses(_ p: Project) -> Set<Int> {
  let root = p.rootNote ?? 60
  let name = p.scaleName.isEmpty ? "Major" : p.scaleName
  return Set(scaleIntervals(name + "Scale").map { ((root + $0) % 12 + 12) % 12 })
}

private func pc(_ n: Int) -> Int { (n % 12 + 12) % 12 }

/// M2a: per tonal role (group), the share of its notes in the key, approach notes left out;
/// a role whose notes are all approach notes is left out too.
private func scaleConsistency(_ p: Project, _ log: [NoteEvent]) -> [String: Double] {
  let key = keyClasses(p)
  let tonal = log.filter(MusicalityReport.isTonal)
  var out: [String: Double] = [:]
  for (group, es) in Dictionary(grouping: tonal, by: \.group) {
    var counted = 0
    var inKey = 0
    for line in Dictionary(grouping: es, by: \.net).values {
      let sorted = line.sorted { ($0.tick, $0.note) < ($1.tick, $1.note) }
      for (k, e) in sorted.enumerated() {
        if key.contains(pc(e.note)) {
          counted += 1
          inKey += 1
          continue
        }
        // an approach: the next onset of the net, within a beat, a semitone away and in key
        let next = sorted[(k + 1)...].first { $0.tick > e.tick }
        if let next, next.tick - e.tick <= 4, abs(next.note - e.note) == 1,
          key.contains(pc(next.note))
        {
          continue
        }
        counted += 1
      }
    }
    if counted > 0 { out[group] = Double(inKey) / Double(counted) }
  }
  return out
}

/// M2b: melody notes on beats 1 and 3 of a bar with a pad chord that are tones of that chord;
/// nil without a pad or a melody note on a strong beat.
private func strongBeatChordTones(_ log: [NoteEvent]) -> Double? {
  var chord: [Int: Set<Int>] = [:]
  for e in log where e.group == "harmony" && MusicalityReport.isTonal(e) {
    chord[(e.tick - 1) / 16, default: []].insert(pc(e.note))
  }
  var total = 0
  var hits = 0
  for e in log where e.group == "melody" && (e.tick - 1) % 8 == 0 {
    guard let c = chord[(e.tick - 1) / 16] else { continue }
    total += 1
    if c.contains(pc(e.note)) { hits += 1 }
  }
  return total > 0 ? Double(hits) / Double(total) : nil
}

/// Each section's (energy, filter) from the `feel-curve` net, by section index; nil for a
/// section the curve does not mark (it marks each name at its first start).
private func sectionFeel(_ p: Project) -> [(x: Double, y: Double)?] {
  guard let feel = p.nets["feel-curve"] else { return p.structure.map { _ in nil } }
  var points: [Int: (x: Double, y: Double)] = [:]
  for (t, c) in feel.controlBindings.pairs where c.action == "set-feel" {
    guard t.hasPrefix("ft"), let step = Int(t.dropFirst(2)),
      let x = c.macroParams?["x"]?.double, let y = c.macroParams?["y"]?.double
    else { continue }
    points[step] = (x, y)
  }
  var byName: [String: (x: Double, y: Double)] = [:]
  var at = 0
  for s in p.structure {
    if byName[s.name] == nil, let pt = points[at] { byName[s.name] = pt }
    at += s.steps
  }
  return p.structure.map { byName[$0.name] }
}

/// One M5 boundary: the step it falls on, and the notes of the bar before it that the
/// section's other bars never play.
private struct FillBoundary: Equatable {
  var step: Int
  var from: String
  var to: String
  var newNotes: Int
}

/// M5: the boundaries (not the song's end) where energy or filter changes, each with the
/// number of notes in the section's last bar that differ from the section's loop: a note is
/// (group, sixteenth in the bar, pitch), and it differs when no other bar of the section has
/// it. A section of one bar has no loop to differ from: all its notes count.
private func fillBoundaries(_ p: Project, _ log: [NoteEvent]) -> [FillBoundary] {
  let feel = sectionFeel(p)
  struct Hit: Hashable {
    var group: String
    var step: Int
    var note: Int
  }
  var byBar: [Int: Set<Hit>] = [:]
  for e in log {
    byBar[(e.tick - 1) / 16, default: []].insert(
      Hit(group: e.group, step: (e.tick - 1) % 16, note: e.note))
  }
  var out: [FillBoundary] = []
  var start = 0
  for i in p.structure.indices.dropLast() {
    let s = p.structure[i]
    let end = start + s.steps
    defer { start = end }
    guard let a = feel[i], let b = feel[i + 1], a.x != b.x || a.y != b.y, s.steps >= 16 else {
      continue
    }
    let last = end / 16 - 1
    let loop = (start / 16..<last).reduce(into: Set<Hit>()) { $0.formUnion(byBar[$1] ?? []) }
    let fresh = (byBar[last] ?? []).subtracting(loop)
    out.append(
      FillBoundary(step: end, from: s.name, to: p.structure[i + 1].name, newNotes: fresh.count))
  }
  return out
}

private func tone(_ tick: Int, _ net: String, _ group: String, _ note: Int, channel: Int = 1)
  -> NoteEvent
{
  NoteEvent(
    tick: tick, net: net, group: group, note: note, velocity: 100, channel: channel, steps: 1)
}

private func cMajor(_ sections: [(String, Int)] = [("song", 64)]) -> Project {
  var p = Project()
  p.rootNote = 60
  p.scaleName = "Major"
  p.structure = sections.map { Section(name: $0.0, steps: $0.1) }
  return p
}

struct RealismMirrorTests {
  static let genres = BeatsTables.shared.genreIDs.sorted()

  /// The three figures for every genre at two seeds, against the audit's targets.
  @Test(arguments: genres, [42.0, 4242.0])
  func playedTracksMeetTheAudit(genre: String, seed: Double) {
    let (p, notes, _) = playedLog(genre, seed)
    #expect(!notes.isEmpty, "\(genre) \(seed): no notes")
    let known = knownIssues[genre] ?? []

    let scale = scaleConsistency(p, notes)
    #expect(!scale.isEmpty, "\(genre) \(seed): no tonal role")
    let strong = strongBeatChordTones(notes)
    let fills = fillBoundaries(p, notes)
    let bare = fills.filter { $0.newNotes == 0 }
    let roles = scale.sorted { $0.key < $1.key }.map { "\($0.key) \(round3($0.value))" }
    let strongText = strong.map { "\(round3($0))" } ?? "-"
    let bareText = bare.map { "\($0.from)→\($0.to)@\($0.step)" }.joined(separator: " ")
    print(
      "realism mirror: \(genre) \(Int(seed)) scale \(roles.joined(separator: ", "))"
        + " | strong \(strongText) | fills \(fills.count - bare.count)/\(fills.count) \(bareText)")

    check(.scale, genre, known) {
      for (role, share) in scale.sorted(by: { $0.key < $1.key }) {
        #expect(
          share >= scaleTarget,
          "\(genre) \(seed) \(RealismFigure.scale.rawValue): \(role) \(round3(share))")
      }
    }
    if let strong {
      check(.strongBeats, genre, known) {
        #expect(
          strong >= strongBeatTarget,
          "\(genre) \(seed) \(RealismFigure.strongBeats.rawValue): \(round3(strong))")
      }
    }
    check(.fills, genre, known) {
      #expect(
        bare.isEmpty, "\(genre) \(seed) \(RealismFigure.fills.rawValue): no fill at \(bareText)")
    }
  }

  /// A figure's expectations, under `withKnownIssue` when the genre is listed for it.
  private func check(
    _ figure: RealismFigure, _ genre: String, _ known: Set<RealismFigure>, _ body: () -> Void
  ) {
    if known.contains(figure) {
      withKnownIssue("\(genre): \(figure.rawValue)", isIntermittent: true) { body() }
    } else {
      body()
    }
  }

  /// A walking line's chromatic approach (C♯ into D, a sixteenth later) is not counted; an
  /// F♯ that goes nowhere a semitone away is. Per role.
  @Test func scaleConsistencyLeavesOutApproaches() {
    let log = [
      tone(1, "bass-0", "bass", 36), tone(5, "bass-0", "bass", 37), tone(6, "bass-0", "bass", 38),
      tone(9, "bass-0", "bass", 40),
      tone(1, "melody-0", "melody", 72), tone(5, "melody-0", "melody", 78),
      tone(9, "melody-0", "melody", 76), tone(13, "melody-0", "melody", 74),
      tone(1, "kick", "drums", 36, channel: 10),
    ]
    let r = scaleConsistency(cMajor(), log)
    #expect(r["bass"] == 1)
    #expect(r["melody"] == 0.75)
    #expect(r["drums"] == nil)
    // an approach more than a beat early, or a whole tone away, counts against the role
    let late = scaleConsistency(
      cMajor(), [tone(1, "b", "bass", 37), tone(6, "b", "bass", 38), tone(9, "b", "bass", 36)])
    #expect(late["bass"].map { abs($0 - 2.0 / 3) < 1e-9 } == true)
  }

  /// Beats 1 and 3 count, 2 and 4 do not; a bar without a pad chord is not measured.
  @Test func strongBeatsAgainstThePad() {
    var log = [60, 64, 67].map { tone(1, "pad", "harmony", $0) }
    log += [
      tone(1, "m", "melody", 72),  // C on beat 1: a chord tone
      tone(5, "m", "melody", 74),  // D on beat 2: not counted
      tone(9, "m", "melody", 77),  // F on beat 3: off the chord
      tone(17, "m", "melody", 74),  // bar 2 has no pad
    ]
    #expect(strongBeatChordTones(log) == 0.5)
    #expect(strongBeatChordTones(log.filter { $0.group != "harmony" }) == nil)
  }

  /// A section whose last bar repeats its loop has no fill; a snare roll in the last bar is
  /// one. Boundaries where the energy stays the same are not measured.
  @Test func fillsAtEnergyChanges() {
    var p = cMajor([("intro", 64), ("drop", 64), ("outro", 64)])
    var feel = NetBundle()
    for (step, level) in [(0, 0.3), (64, 0.9), (128, 0.9)] {
      var c = ControlBinding(action: "set-feel", targetNet: "", targetNote: 0)
      c.macroParams = try? JSONValue.parse("{\"x\":\(level),\"y\":\(level)}")
      feel.controlBindings["ft\(step)"] = c
    }
    p.nets["feel-curve"] = feel
    var log: [NoteEvent] = []
    for bar in 0..<12 {
      for beat in 0..<4 { log.append(tone(16 * bar + 4 * beat + 1, "kick", "drums", 36)) }
    }
    #expect(
      fillBoundaries(p, log) == [FillBoundary(step: 64, from: "intro", to: "drop", newNotes: 0)])
    for s in 12..<16 { log.append(tone(16 * 3 + s + 1, "fill-0", "drums", 38)) }
    #expect(fillBoundaries(p, log).map(\.newNotes) == [4])
  }
}
