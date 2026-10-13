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

    public static let all: Fixes = [.key, .timing, .register, .dynamics, .loudness, .groove]
  }

  /// `project` as the deck should play it. `spec` is the spec it was composed from.
  public static func apply(_ project: Project, spec: TrackSpec, fixes: Fixes = .all) -> Project {
    guard !fixes.isEmpty, let genre = BeatsTables.shared.genres[spec.genre] else { return project }
    var p = project
    if fixes.contains(.key) { keepVariantsInKey(&p, genre: genre, spec: spec) }
    if fixes.contains(.timing) { fixStructureTiming(&p) }
    if fixes.contains(.register) { separateRegisters(&p) }
    if fixes.contains(.dynamics) { accentByMeter(&p) }
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
}
