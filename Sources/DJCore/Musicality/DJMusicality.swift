import Foundation

/// dj's pass over a composed track before a deck plays it: the fixes for what makes beats'
/// generator sound unmusical (docs/musicality-notes.md).
///
/// `compose()` stays beats' byte for byte — shares, sessions and model CIDs keep meaning the
/// same track in both apps — and this runs after it, on `PreparedTrack.played`. It only
/// rewrites MIDI bindings (note, velocity, length) and initial markings, never places,
/// transitions or arcs, so the net views, section jumps and recorded sessions see the same
/// nets the composer built. A pure function of (project, spec): a replay plays the same notes.
public enum DJMusicality {
  public struct Fixes: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Tension variants (B / C sections) back in the track's key (`expandVariants` builds
    /// them on a root shifted by +2 / −3 semitones).
    public static let key = Fixes(rawValue: 1 << 0)

    /// Structure changes on the beat they were composed for (`buildAccumulatorNet` lands
    /// every event one tick later than the one before, and after the downbeat's notes).
    public static let timing = Fixes(rawValue: 1 << 1)

    /// Each part in its own octave: the bass down where a bass plays (beats builds it at the
    /// genre's root, C3 for most), the pad above the bass, the melody above the pad.
    public static let register = Fixes(rawValue: 1 << 2)

    /// Bass, melody, arp and pad notes accented by where they fall in the bar (beats gives
    /// every note of a part one velocity), and each melody bar's highest note leaned on.
    public static let dynamics = Fixes(rawValue: 1 << 5)

    /// Every track at about one loudness (`Loudness`), and sampled instruments through the
    /// master curve with the synth voices instead of added after it (where they could clip).
    /// Applied by `WaveRunner.prepare`, not by `apply`: the gain is measured from the project.
    public static let loudness = Fixes(rawValue: 1 << 3)

    /// The project's `swing` and `humanize`, which beats' browser plays and its wave engine
    /// does not: applied by the runner (`WaveRunner.grooveHit`).
    public static let groove = Fixes(rawValue: 1 << 4)

    /// In four-on-the-floor dance genres the bass moves off the kick to the off-beat eighth
    /// (beats locks it to the kick's steps: two low sounds starting together on every beat).
    public static let offbeatBass = Fixes(rawValue: 1 << 6)

    /// Phrase changes on the 2 / 4-bar grid the chords and motifs repeat on (a 12-bar section
    /// with four phrases is cut 3 + 3 + 3 + 3; this makes it 4 + 4 + 2 + 2).
    public static let phrases = Fixes(rawValue: 1 << 7)

    /// A drum fill into every section change. beats builds a `fill-N` net before each one and
    /// never lets it sound: it starts muted, nothing unmutes it, and it is a `control` net, which
    /// gets no voice; its toms have no voice in the wave engine either. This plays it as a
    /// snare roll swelling into the change (the runner voices `fill-*` nets under this flag).
    public static let fills = Fixes(rawValue: 1 << 8)

    public static let all: Fixes = [
      .key, .timing, .register, .dynamics, .loudness, .groove, .offbeatBass, .phrases, .fills,
    ]

    /// Each fix by the name `djctl render --fixes` takes.
    public static let named: [String: Fixes] = [
      "key": .key, "timing": .timing, "register": .register, "dynamics": .dynamics,
      "loudness": .loudness, "groove": .groove, "offbeatBass": .offbeatBass, "phrases": .phrases,
      "fills": .fills, "none": [],
    ]
  }

  /// `project` as the deck should play it. `spec` is the spec it was composed from.
  public static func apply(_ project: Project, spec: TrackSpec, fixes: Fixes = .all) -> Project {
    guard !fixes.isEmpty, let genre = BeatsTables.shared.genres[spec.genre] else { return project }
    var p = project
    if fixes.contains(.key) { keepVariantsInKey(&p, genre: genre, spec: spec) }
    if fixes.contains(.phrases) { alignPhrases(&p) }
    if fixes.contains(.timing) { fixStructureTiming(&p) }
    if fixes.contains(.register) { separateRegisters(&p) }
    if fixes.contains(.offbeatBass) { moveBassOffTheKick(&p, genre: genre) }
    if fixes.contains(.dynamics) { accentByMeter(&p) }
    if fixes.contains(.fills) { playFills(&p, genre: genre) }
    return p
  }

  // MARK: key

  /// The roles `expandVariants` builds melodic slot variants for.
  static let melodicRoles: Set<String> = ["bass", "melody", "arp"]

  /// With the genre's tension curve, a B / C slot of a melodic role was composed on
  /// `rootNote + registerShift` with the scale rebuilt there: every note of it is the home-key
  /// note moved by that shift. Move it back. The variant keeps its density and velocity
  /// (what makes it B or C), and now plays over the same chords as everything else.
  static func keepVariantsInKey(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    guard spec.overrides["tension-curve"]?.bool ?? genre.tensionCurve else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", melodicRoles.contains(nb.riffGroup)
      else { continue }
      let shift = tensionForVariant(nb.riffVariant).registerShift
      guard shift != 0 else { continue }
      for t in nb.bindings.keys {
        guard var b = nb.bindings[t], !isDrumChannel(b.channel) else { continue }
        b.note = max(0, min(127, b.note - shift))
        nb.bindings[t] = b
      }
      p.nets[id] = nb
    }
  }

  // MARK: timing

  /// `buildAccumulatorNet` chains one stage per event: `p_delay_i` holds the gap to the
  /// previous event, drained one token per tick, then `t_ctrl_i` fires on the next tick and
  /// opens the next stage's gate. Two things go wrong:
  /// - every stage after the first starts the tick after the previous control, so each event
  ///   lands one tick later than the one before (the bass's fifth change is five sixteenths
  ///   off, the drums', with fewer events, less);
  /// - even the first lands on the downbeat's own tick, and control nets fire after the music
  ///   nets within a tick: the mute / slot change applies only after the downbeat's notes, so
  ///   every part that enters a section loses its first beat (the old slot plays it instead).
  /// A delay of `gap - 1` on every stage fires each change on the last sixteenth before its
  /// step, after that sixteenth's notes: the new section starts complete, on the bar.
  static func fixStructureTiming(_ p: inout Project) {
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role == "control", nb.places["p_delay_0"] != nil,
        nb.places["p_gate_0"] != nil
      else { continue }
      var i = 0
      while var place = nb.places["p_delay_\(i)"] {
        if let gap = place.initial.first, gap >= 1 { place.initial = [gap - 1] }
        nb.places["p_delay_\(i)"] = place
        i += 1
      }
      p.nets[id] = nb
    }
  }

  // MARK: register

  /// The bass's median note goes no higher than this (A2, 110 Hz): below it a bass line sits
  /// under the chords instead of among them.
  static let bassCeiling = 45
  /// …and no lower than this (E1, 41 Hz, a bass guitar's lowest string).
  static let bassFloor = 28
  /// A pad's median goes no lower than this (F3, 175 Hz): close triads under it are mud.
  static let padFloor = 53

  /// Move whole parts by octaves (pitch classes, so key and chords, stay as composed):
  /// the bass down until its median is at most A2, then the pad up until its lowest note
  /// clears the bass's highest and its median is F3 or higher, then the melody and arp up until their median clears the
  /// pad's. A part moves as one (every slot by the same octaves), so its phrases keep their
  /// shape across sections.
  static func separateRegisters(_ p: inout Project) {
    let bass = notes(p, group: "bass")
    var bassShift = 0
    if let m = median(bass) {
      while m + bassShift > bassCeiling { bassShift -= 12 }
      while m + bassShift < bassFloor { bassShift += 12 }
    }
    transpose(&p, group: "bass", by: bassShift)
    let bassTop = (bass.max() ?? 0) + bassShift

    let pad = notes(p, group: "harmony")
    var padShift = 0
    if let low = pad.min(), let m = median(pad) {
      while low + padShift <= bassTop || m + padShift < padFloor { padShift += 12 }
    }
    transpose(&p, group: "harmony", by: padShift)
    let padMedian = median(pad).map { $0 + padShift }

    for lead in ["melody", "arp"] {
      let ns = notes(p, group: lead)
      var shift = 0
      if let m = median(ns), let floor = padMedian {
        while m + shift <= floor && (ns.max() ?? 0) + shift + 12 <= 96 { shift += 12 }
      }
      transpose(&p, group: lead, by: shift)
    }
  }

  /// The part a net belongs to: its mixer group, else its riff group.
  static func part(_ nb: NetBundle) -> String {
    if let g = nb.track.group, !g.isEmpty { return g }
    return nb.riffGroup
  }

  static func notes(_ p: Project, group: String) -> [Int] {
    var out: [Int] = []
    for nb in p.nets.values where nb.role != "control" && part(nb) == group {
      for b in nb.bindings.values where !isDrumChannel(b.channel) { out.append(b.note) }
    }
    return out
  }

  static func median(_ xs: [Int]) -> Int? { xs.isEmpty ? nil : xs.sorted()[xs.count / 2] }

  static func transpose(_ p: inout Project, group: String, by shift: Int) {
    guard shift != 0 else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == group else { continue }
      for t in nb.bindings.keys {
        guard var b = nb.bindings[t], !isDrumChannel(b.channel) else { continue }
        b.note = max(0, min(127, b.note + shift))
        nb.bindings[t] = b
      }
      p.nets[id] = nb
    }
  }

  // MARK: dynamics

  /// Velocity offset by position in the bar (sixteenths): the downbeat strongest, then beat 3,
  /// beats 2 and 4, the off-beat eighths, the sixteenths in between softest.
  static let meterAccent = [10, -8, -3, -8, 3, -8, -3, -8, 6, -8, -3, -8, 3, -8, -3, -8]
  /// Extra for the highest note of each melody bar: the line's peak, where the ear goes.
  static let peakAccent = 5

  /// Accent the tonal parts' ring nets by meter. A ring's transition `ti` fires on step `i`
  /// of its cycle, and every ring here is a whole number of 16-step bars, so `i % 16` is the
  /// step in the bar. Drums keep beats' accents (they have their own); stingers stay flat.
  static func accentByMeter(_ p: inout Project) {
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control",
        ["bass", "melody", "arp", "harmony"].contains(part(nb)),
        nb.transitions.count % 16 == 0, nb.places.count == nb.transitions.count
      else { continue }
      var steps: [(key: String, step: Int, note: Int)] = []
      for t in nb.bindings.keys {
        guard t.hasPrefix("t"), let i = Int(t.dropFirst()), let b = nb.bindings[t],
          !isDrumChannel(b.channel)
        else { continue }
        steps.append((t, i, b.note))
      }
      var peak: [Int: Int] = [:]  // bar → highest note
      if part(nb) == "melody" {
        for s in steps { peak[s.step / 16] = max(peak[s.step / 16] ?? 0, s.note) }
      }
      for s in steps {
        var b = nb.bindings[s.key]!
        var v = b.velocity + meterAccent[s.step % 16]
        if peak[s.step / 16] == s.note { v += peakAccent }
        b.velocity = clampVelocity(v)
        nb.bindings[s.key] = b
      }
      p.nets[id] = nb
    }
  }

  // MARK: kick and bass

  /// The genres whose bass is locked to a four-on-the-floor kick: dance family, groove
  /// template 0 (`grooveLock` copies the kick mask), kick on every beat.
  static func bassLockedToFourOnTheFloor(_ genre: GenreDef) -> Bool {
    let t = BeatsTables.shared
    return t.family(of: genre.name) == 0 && t.themeTable(genre.name)?.groove == Groove.fourOnFloor
      && genre.kick.count >= 3 && genre.kick[0] == 4 && genre.kick[1] == 16 && genre.kick[2] == 0
  }

  /// Every bass note on a beat moves to that beat's off-beat eighth (step + 2): the
  /// trance / techno offbeat bass, which leaves the kick alone in the low end. Notes, lengths
  /// and the slot nets stay as composed; only the transition they are bound to changes.
  static func moveBassOffTheKick(_ p: inout Project, genre: GenreDef) {
    guard bassLockedToFourOnTheFloor(genre) else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "bass",
        nb.transitions.count % 16 == 0, nb.places.count == nb.transitions.count
      else { continue }
      let n = nb.transitions.count
      var moved = OrderedMap<MidiBinding>()
      for t in nb.bindings.keys {
        guard let b = nb.bindings[t], t.hasPrefix("t"), let i = Int(t.dropFirst()) else { continue }
        let target = i % 4 == 0 ? "t\((i + 2) % n)" : t
        if moved[target] == nil { moved[target] = b }
      }
      nb.bindings = moved
      p.nets[id] = nb
    }
  }

  // MARK: phrases

  /// Phrase lengths for a section of `steps` split into `count` phrases: unchanged when the
  /// even split is whole 4-bar phrases (or 2 bars or less), else 2-bar units handed out longest first in
  /// powers of two (12 bars in 4 phrases: 4 + 4 + 2 + 2; in 2: 8 + 4).
  static func phraseLengths(steps: Int, count: Int) -> [Int] {
    guard count > 1, steps % count == 0 || steps % 32 == 0 else {
      return [Int](repeating: steps / max(1, count), count: max(1, count))
    }
    if steps % count == 0, (steps / count) % 64 == 0 || steps / count <= 32 {
      return [Int](repeating: steps / count, count: count)
    }
    guard steps % 32 == 0, steps / 32 >= count else {
      return [Int](repeating: steps / count, count: count)
    }
    var units = steps / 32
    var out: [Int] = []
    for left in stride(from: count, to: 0, by: -1) {
      var p = 1
      while p * 2 <= units - (left - 1) { p *= 2 }
      if left == 1 { p = units }
      out.append(p * 32)
      units -= p
    }
    return out
  }

  /// Move the phrase-start events of the role control nets (`roleControlNet`: one stage per
  /// change, `p_delay_i` = ticks since the previous one) from the even split onto
  /// `phraseLengths`. Section starts stay where they are; a net whose events don't sit on the
  /// even split is left alone.
  static func alignPhrases(_ p: inout Project) {
    var sections: [(start: Int, steps: Int, count: Int)] = []
    var t = 0
    for s in p.structure {
      let count = s.phrases.values.map(\.count).max() ?? 1
      sections.append((t, s.steps, count))
      t += s.steps
    }
    guard !sections.isEmpty else { return }
    func remap(_ tick: Int) -> Int? {
      guard let s = sections.first(where: { tick > $0.start && tick < $0.start + $0.steps }) else {
        return tick  // a section start (or past the end): unchanged
      }
      let even = s.steps / max(1, s.count)
      let offset = tick - s.start
      guard even > 0, offset % even == 0 else { return nil }
      let lengths = phraseLengths(steps: s.steps, count: s.count)
      return s.start + lengths.prefix(offset / even).reduce(0, +)
    }
    for id in p.nets.keys where id.hasPrefix("struct-") {
      guard var nb = p.nets[id], nb.role == "control", nb.places["p_delay_0"] != nil else {
        continue
      }
      var gaps: [Double] = []
      while let d = nb.places["p_delay_\(gaps.count)"]?.initial.first { gaps.append(d) }
      var ticks: [Int] = []
      var acc = 0
      for g in gaps {
        acc += Int(g)
        ticks.append(acc)
      }
      let moved = ticks.map(remap)
      guard !moved.contains(where: { $0 == nil }) else { continue }
      let new = moved.map { $0! }
      guard zip(new, new.dropFirst()).allSatisfy({ $0 < $1 }), new.first.map({ $0 > 0 }) ?? false
      else { continue }
      var prev = 0
      for (i, tick) in new.enumerated() {
        nb.places["p_delay_\(i)"]!.initial = [Double(tick - prev)]
        prev = tick
      }
      p.nets[id] = nb
    }
  }

  // MARK: fills

  /// Velocity of a fill's first and last hit: dance genres roll harder.
  static func fillVelocities(_ genre: GenreDef) -> (from: Int, to: Int) {
    BeatsTables.shared.family(of: genre.name) == 0 ? (50, 115) : (40, 95)
  }

  /// Every `fill-N` net that ends before the song does plays its steps as one snare roll
  /// (sixteenths, the last before the section change loudest), unmuted. Its steps are the
  /// last 4 or 8 sixteenths of a sink chain as long as the section boundary, so the roll
  /// lands on the change; the fill at the song's end stays silent.
  static func playFills(_ p: inout Project, genre: GenreDef) {
    let total = p.structure.reduce(0) { $0 + $1.steps }
    let (from, to) = fillVelocities(genre)
    var sounding = Set<String>()
    for id in p.nets.keys where id.hasPrefix("fill-") {
      guard var nb = p.nets[id] else { continue }
      let steps = nb.bindings.keys.compactMap { $0.hasPrefix("t") ? Int($0.dropFirst()) : nil }
        .sorted()
      guard let last = steps.last, last + 1 < total else { continue }
      for (k, i) in steps.enumerated() {
        guard var b = nb.bindings["t\(i)"], isDrumChannel(b.channel) else { continue }
        let x = steps.count > 1 ? Double(k) / Double(steps.count - 1) : 1
        b.note = 38
        b.velocity = clampVelocity(Int((Double(from) + Double(to - from) * x).rounded()))
        nb.bindings["t\(i)"] = b
      }
      p.nets[id] = nb
      sounding.insert(id)
    }
    p.initialMutes.removeAll { sounding.contains($0) }
  }
}
