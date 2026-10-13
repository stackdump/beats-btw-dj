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

    /// The pad's chords voiced to move as little as they can from one to the next (beats
    /// stacks every chord root-up in one octave, so each change jumps as a block), within the
    /// register `.register` gave the pad. Octaves only: the same pitch classes, struck in the
    /// same order.
    public static let voicing = Fixes(rawValue: 1 << 9)

    /// The arrangement's energy arc: each section's `energy` and `filterOpen` from the
    /// composer's feel curve played as level and a lowpass on the tonal parts, buildups
    /// sweeping into what follows (`EnergyCurve`). Applied by the runner.
    public static let energy = Fixes(rawValue: 1 << 10)

    /// Bass and pad dip on every kick and swell back within an eighth note, the sidechain
    /// pump of dance music: the kick gets the low end to itself and the groove breathes.
    /// Depth by genre (`duckDepth`); applied by the runner.
    public static let duck = Fixes(rawValue: 1 << 11)

    /// Fewer melody notes repeating the pitch before them (beats' motif walk stalls at the
    /// scale's ends and on zero steps: up to 80% of a melody's intervals are unisons). An
    /// off-beat note that repeats becomes a step: towards the next note when that differs, else
    /// the upper neighbour. Notes on the beat, the chord tones the motif is built on, stay.
    public static let contour = Fixes(rawValue: 1 << 12)

    /// Chord colour where the style has it: beats' pads are bare triads in every genre; jazz,
    /// bossa, house, garage and funk play their chords as sevenths (the scale's own seventh on
    /// each root). Struck after the triad, before `.voicing` places it. (lofi and ambient are
    /// pentatonic: their chords are already stacked fourths and doubled tones, and a seventh
    /// measured worse there.)
    public static let color = Fixes(rawValue: 1 << 13)

    /// The arp plays the chords. In a song with sections beats builds each arp slot from the
    /// melody's motif (or a Markov line), so it doubles the lead in unison or an octave under
    /// it and arpeggiates nothing. This plays the bar's pad chord, rising through its tones in
    /// sixteenths (eighths in a sparse C variant), in the arp's own register; bars where the
    /// composed slot is silent stay silent.
    public static let arpeggio = Fixes(rawValue: 1 << 14)

    /// A buildup builds: a snare roll through its last eight bars that doubles its rate on the
    /// way (quarters, eighths, sixteenths) and swells into the drop. It is the fill net before
    /// the section change, which spans the song up to it, so it is voiced as `.fills` voices.
    public static let buildup = Fixes(rawValue: 1 << 15)

    /// A crash cymbal on the downbeat of every section after the first: the ear hears where a
    /// section starts (beats marks it with nothing but the parts changing). It goes on the fill
    /// net of the section's own end, which spans the song up to there, and the runner gives
    /// note 49 on a fill net a crash voice (beats has only a short open hat for it).
    public static let crash = Fixes(rawValue: 1 << 16)

    /// The bass moves to each chord root by the shorter way. beats takes every root from one
    /// octave of the scale, so a progression that comes back round leaps (A1 up a minor sixth
    /// to F2, then down a seventh to A1); this moves whole bars by octaves, inside the range
    /// `.register` gave the bass, so the line steps (A1 down to F1, G1, A1).
    public static let bassLine = Fixes(rawValue: 1 << 17)

    /// Open hats on the off-beat eighths in the four-on-the-floor dance genres: the "tss"
    /// between kicks that drives house, techno and trance. beats plays every hat closed (its
    /// drum map voices 42–46 alike); this binds those hats to note 46 and the runner gives it
    /// the open hat.
    public static let openHats = Fixes(rawValue: 1 << 18)

    /// A stereo picture (beats' engine is mono, every part dead centre): hats right, crash left,
    /// the pad's voices spread wide, the arp's alternating sides; kick, snare, bass and lead
    /// stay in the middle, so the low end is mono. Panned as mid/side (left = mid + side,
    /// right = mid − side): the mono sum is the mix as before. Applied by the runner
    /// (`stereoPlacement`); sampled instruments keep their own (centred) image.
    public static let stereo = Fixes(rawValue: 1 << 19)

    public static let all: Fixes = [
      .key, .timing, .register, .dynamics, .loudness, .groove, .offbeatBass, .phrases, .fills,
      .voicing, .energy, .duck, .contour, .color, .arpeggio, .buildup, .crash, .bassLine,
      .openHats, .stereo,
    ]

    /// Each fix by the name `djctl render --fixes` takes.
    public static let named: [String: Fixes] = [
      "key": .key, "timing": .timing, "register": .register, "dynamics": .dynamics,
      "loudness": .loudness, "groove": .groove, "offbeatBass": .offbeatBass, "phrases": .phrases,
      "fills": .fills, "voicing": .voicing, "energy": .energy, "duck": .duck, "contour": .contour,
      "color": .color, "arpeggio": .arpeggio, "buildup": .buildup, "crash": .crash,
      "bassLine": .bassLine, "openHats": .openHats, "stereo": .stereo,
      "none": [],
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
    if fixes.contains(.bassLine) { leadBass(&p) }
    if fixes.contains(.color) { colorChords(&p, genre: genre) }
    if fixes.contains(.voicing) { voiceLeadPads(&p) }
    if fixes.contains(.arpeggio) { arpeggiate(&p) }
    if fixes.contains(.offbeatBass) { moveBassOffTheKick(&p, genre: genre) }
    if fixes.contains(.contour) { stepRepeatedNotes(&p) }
    if fixes.contains(.dynamics) { accentByMeter(&p) }
    if fixes.contains(.fills) { playFills(&p, genre: genre) }
    if fixes.contains(.buildup) { rollIntoDrops(&p, genre: genre) }
    if fixes.contains(.crash) { crashOnSections(&p, genre: genre) }
    if fixes.contains(.openHats) { openOffbeatHats(&p, genre: genre) }
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

  // MARK: bass line

  /// In each bass ring, move every bar that plays by octaves (all its notes together, so a
  /// walking or bossa bar keeps its shape) to the placement with the least motion from bar to
  /// bar around the cycle (the ring loops: the last bar leads back to the first), every note
  /// from E1 up to the bass part's highest note or A2 (`bassCeiling`), whichever is higher, and
  /// under the pad's lowest note. Ties keep the composed octave. (A bar `.register` left under
  /// E1, where it is felt more than heard, comes up into the window.)
  static func leadBass(_ p: inout Project) {
    guard var top = notes(p, group: "bass").max() else { return }
    top = max(top, bassCeiling)
    if let pad = notes(p, group: "harmony").min() { top = min(top, pad - 1) }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "bass",
        nb.transitions.count % 16 == 0, nb.places.count == nb.transitions.count
      else { continue }
      var bars = [[(key: String, step: Int, note: Int)]](
        repeating: [], count: nb.transitions.count / 16)
      for (t, b) in nb.bindings.pairs where t.hasPrefix("t") && !isDrumChannel(b.channel) {
        if let i = Int(t.dropFirst()) { bars[i / 16].append((t, i, b.note)) }
      }
      let played = bars.indices.filter { !bars[$0].isEmpty }
      guard played.count > 1 else { continue }
      for b in played { bars[b].sort { $0.step < $1.step } }
      let options: [[Int]] = played.map { b in
        let ns = bars[b].map(\.note)
        let fit = [0, -12, 12, -24, 24].filter { s in
          ns.allSatisfy { $0 + s >= bassFloor && $0 + s <= top }
        }
        return fit.isEmpty ? [0] : fit
      }
      // the step from bar i placed at u to the next played bar placed at v; an octave moved
      // costs a little, so ties keep the composed placement
      func cost(_ i: Int, _ u: Int, _ j: Int, _ v: Int) -> Int {
        10 * abs(bars[played[i]].last!.note + u - (bars[played[j]].first!.note + v)) + abs(v) / 12
      }
      var best: (cost: Int, path: [Int])?
      for first in options[0].indices {
        let unreachable = Int.max / 4
        var acc = [Int](repeating: unreachable, count: options[0].count)
        acc[first] = abs(options[0][first]) / 12
        var back: [[Int]] = [Array(acc.indices)]
        for k in 1..<played.count {
          var next = [Int](repeating: unreachable, count: options[k].count)
          var from = [Int](repeating: 0, count: options[k].count)
          for (j, v) in options[k].enumerated() {
            for (i, u) in options[k - 1].enumerated() where acc[i] < unreachable {
              let x = acc[i] + cost(k - 1, u, k, v)
              if x < next[j] {
                next[j] = x
                from[j] = i
              }
            }
          }
          acc = next
          back.append(from)
        }
        let last = played.count - 1
        for (j, v) in options[last].enumerated() where acc[j] < unreachable {
          let total = acc[j] + cost(last, v, 0, options[0][first]) - abs(options[0][first]) / 12
          if best == nil || total < best!.cost {
            var path = [j]
            for k in stride(from: last, to: 0, by: -1) { path.append(back[k][path.last!]) }
            best = (total, path.reversed())
          }
        }
      }
      guard let path = best?.path else { continue }
      for (k, b) in played.enumerated() {
        let s = options[k][path[k]]
        guard s != 0 else { continue }
        for x in bars[b] { nb.bindings[x.key]?.note = x.note + s }
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

  // MARK: buildup

  /// Sixteenths between roll hits, by bars left in the buildup (1 = its last bar).
  static func rollSpacing(barsLeft: Int) -> Int {
    switch barsLeft {
    case 1...2: 1
    case 3...4: 2
    default: 4
    }
  }

  /// Each `buildup` section followed by another: the fill net that ends on its last tick
  /// (`drumFillNet` binds the chain's last steps; its transitions are the song's ticks up to the
  /// boundary) plays a snare roll over the section's last eight bars at `rollSpacing`, velocity
  /// rising from soft to the fill's peak, unmuted. The steps it had stay inside the roll.
  static func rollIntoDrops(_ p: inout Project, genre: GenreDef) {
    var ends: [Int: Int] = [:]  // boundary tick → steps of a buildup ending there
    var t = 0
    for (k, s) in p.structure.enumerated() {
      t += s.steps
      if s.name == "buildup" && k + 1 < p.structure.count { ends[t] = s.steps }
    }
    guard !ends.isEmpty else { return }
    let (_, peak) = fillVelocities(genre)
    let soft = 36
    var sounding = Set<String>()
    for id in p.nets.keys where id.hasPrefix("fill-") {
      guard var nb = p.nets[id], let steps = ends[nb.transitions.count],
        let template = nb.bindings.pairs.first(where: { isDrumChannel($0.value.channel) })?.value
      else { continue }
      let boundary = nb.transitions.count
      let length = min(steps, 128)
      var hits: [Int] = []
      var s = boundary - length
      while s < boundary {
        hits.append(s)
        s += rollSpacing(barsLeft: (boundary - s + 15) / 16)
      }
      var bound = OrderedMap<MidiBinding>()
      for (k, step) in hits.enumerated() {
        var b = template
        b.note = 38
        let x = hits.count > 1 ? Double(k) / Double(hits.count - 1) : 1
        b.velocity = clampVelocity(Int((Double(soft) + Double(peak - soft) * x * x).rounded()))
        bound["t\(step)"] = b
      }
      nb.bindings = bound
      p.nets[id] = nb
      sounding.insert(id)
    }
    p.initialMutes.removeAll { sounding.contains($0) }
  }

  // MARK: crash

  /// The note a crash is bound to (GM crash cymbal 1).
  static let crashNote = 49

  /// Sections that start with the full band, where the crash is loudest.
  static let peakSections: Set<String> = ["drop", "chorus"]

  /// Each section start after the first gets a crash on its downbeat, on the fill net whose
  /// chain runs through it (the one ending at that section's end). Loud into a drop or chorus,
  /// softer elsewhere, softer still outside the dance genres. A fill net still muted (the one
  /// at the song's end, or all of them without `.fills`) keeps only its crash.
  static func crashOnSections(_ p: inout Project, genre: GenreDef) {
    guard p.structure.count > 1 else { return }
    var starts: [Int: String] = [:]  // downbeat tick → section
    var t = 0
    for s in p.structure {
      if t > 0 { starts[t] = s.name }
      t += s.steps
    }
    let dance = BeatsTables.shared.family(of: genre.name) == 0
    var fillNets: [(id: String, end: Int)] = []
    for id in p.nets.keys where id.hasPrefix("fill-") {
      if let n = p.nets[id]?.transitions.count { fillNets.append((id, n)) }
    }
    var sounding = Set<String>()
    for (tick, name) in starts {
      // the shortest fill chain that reaches the downbeat
      guard let host = fillNets.filter({ $0.end > tick }).min(by: { $0.end < $1.end }),
        var nb = p.nets[host.id],
        let template = nb.bindings.pairs.first(where: { isDrumChannel($0.value.channel) })?.value
      else { continue }
      if p.initialMutes.contains(host.id) {
        nb.bindings = OrderedMap<MidiBinding>()  // its toms have no voice; keep only crashes
      }
      var b = template
      b.note = crashNote
      b.velocity = peakSections.contains(name) ? (dance ? 118 : 96) : (dance ? 92 : 76)
      nb.bindings["t\(tick)"] = b
      p.nets[host.id] = nb
      sounding.insert(host.id)
    }
    p.initialMutes.removeAll { sounding.contains($0) }
  }

  // MARK: voicing

  /// Semitones the voices move from chord `a` to chord `b`, lowest paired with lowest; a voice
  /// that appears or vanishes counts an octave.
  static func motion(_ a: [Int], _ b: [Int]) -> Int {
    let x = a.sorted()
    let y = b.sorted()
    var d = 12 * abs(x.count - y.count)
    for (u, v) in zip(x, y) { d += abs(u - v) }
    return d
  }

  /// Re-voice each pad net's chords by octaves so the cycle of chords (the ring loops, so the
  /// last leads back to the first) moves least, every note kept inside the pad's range: from
  /// its lowest note to an octave above it, or its highest if that is more. A chord is the run
  /// of notes struck on consecutive sixteenths (`chordPadNet` rolls each one root first).
  /// Ties go to the voicing nearest the composed one.
  static func voiceLeadPads(_ p: inout Project) {
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "harmony" else { continue }
      var steps: [(key: String, step: Int, note: Int)] = []
      for t in nb.bindings.keys {
        guard t.hasPrefix("t"), let i = Int(t.dropFirst()), let b = nb.bindings[t],
          !isDrumChannel(b.channel)
        else { continue }
        steps.append((t, i, b.note))
      }
      steps.sort { $0.step < $1.step }
      var chords: [[(key: String, step: Int, note: Int)]] = []
      for s in steps {
        if let last = chords.last?.last, s.step == last.step + 1 {
          chords[chords.count - 1].append(s)
        } else {
          chords.append([s])
        }
      }
      guard chords.count > 1, let lo = steps.map(\.note).min(), let top = steps.map(\.note).max()
      else { continue }
      let hi = max(top, lo + 12)
      // every octave placement of each chord's notes inside the range, no two a semitone or
      // less apart (a seventh next to its root is a cluster, not a voicing)
      let candidates: [[[Int]]] = chords.map { chord in
        var out: [[Int]] = []
        func place(_ i: Int, _ acc: [Int]) {
          if i == chord.count {
            out.append(acc)
            return
          }
          for k in -2...2 {
            let n = chord[i].note + 12 * k
            if n >= lo && n <= hi && !acc.contains(where: { abs($0 - n) <= 1 }) {
              place(i + 1, acc + [n])
            }
          }
        }
        place(0, [])
        return out.isEmpty ? [chord.map(\.note)] : out
      }
      // distance from the composed voicing, to break ties
      func drift(_ c: Int, _ v: [Int]) -> Int {
        var d = 0
        for (s, n) in zip(chords[c], v) { d += abs(s.note - n) }
        return d
      }
      // cheapest cycle: fix the first chord's voicing, dynamic programming over the rest
      var best: (cost: Int, path: [Int])?
      for first in candidates[0].indices {
        let unreachable = Int.max / 4
        var cost = [Int](repeating: unreachable, count: candidates[0].count)
        cost[first] = drift(0, candidates[0][first])
        var back: [[Int]] = [Array(cost.indices)]
        for c in 1..<chords.count {
          var next = [Int](repeating: unreachable, count: candidates[c].count)
          var from = [Int](repeating: 0, count: candidates[c].count)
          for (j, v) in candidates[c].enumerated() {
            for (i, u) in candidates[c - 1].enumerated() where cost[i] < unreachable {
              let x = cost[i] + 100 * motion(u, v) + drift(c, v)
              if x < next[j] {
                next[j] = x
                from[j] = i
              }
            }
          }
          cost = next
          back.append(from)
        }
        for (j, v) in candidates[chords.count - 1].enumerated() where cost[j] < unreachable {
          let total = cost[j] + 100 * motion(v, candidates[0][first])
          if best == nil || total < best!.cost {
            var path = [j]
            for c in stride(from: chords.count - 1, to: 0, by: -1) {
              path.append(back[c][path.last!])
            }
            best = (total, path.reversed())
          }
        }
      }
      guard let path = best?.path else { continue }
      for (c, chord) in chords.enumerated() {
        for (s, n) in zip(chord, candidates[c][path[c]]) { nb.bindings[s.key]?.note = n }
      }
      p.nets[id] = nb
    }
  }

  // MARK: open hats

  /// The note an open hat is bound to (GM open hi-hat).
  static let openHatNote = 46

  /// Dance-family genres with a kick on every beat.
  static func fourOnTheFloor(_ genre: GenreDef) -> Bool {
    BeatsTables.shared.family(of: genre.name) == 0 && genre.kick.count >= 3 && genre.kick[0] == 4
      && genre.kick[1] == 16 && genre.kick[2] == 0
  }

  /// In each hihat ring of a four-on-the-floor dance genre, the hats on the off-beat eighth
  /// (step 2 of every beat) become open hats; the rest stay closed, velocities as composed.
  static func openOffbeatHats(_ p: inout Project, genre: GenreDef) {
    guard fourOnTheFloor(genre) else { return }
    for id in p.nets.keys {
      // (a ring of 8 or 16 sixteenths: step % 4 is the place in the beat either way)
      guard var nb = p.nets[id], nb.role != "control", nb.riffGroup == "hihat" || id == "hihat",
        nb.transitions.count % 4 == 0
      else { continue }
      for (t, b) in nb.bindings.pairs where isDrumChannel(b.channel) && drumKind(b.note) == "hat" {
        guard t.hasPrefix("t"), let i = Int(t.dropFirst()), i % 4 == 2 else { continue }
        nb.bindings[t]?.note = openHatNote
      }
      p.nets[id] = nb
    }
  }

  // MARK: stereo

  /// Where a lane sits (`.stereo`): `pan` from −1 (left) to 1 (right), as the side gain of a
  /// mid/side pan, and `spread`, a tonal lane's voices alternating that far either side of it
  /// (a chord's notes across the field; an arp's successive notes left, right, left). `kind`
  /// is the lane's drum kind or "tonal"; `group` the net's part.
  public static func stereoPlacement(kind: String, group: String) -> (pan: Double, spread: Double)
  {
    switch kind {
    case "hat", "openhat": return (0.3, 0)
    case "crash": return (-0.3, 0)
    case "tonal":
      switch group {
      case "harmony": return (0, 0.5)
      case "arp": return (0, 0.45)
      default: return (0, 0)
      }
    default: return (0, 0)
    }
  }

  // MARK: ducking

  /// How far bass and pad dip on a kick (`.duck`): half (−6 dB) under a four-on-the-floor kick
  /// in the dance genres, less under broken dance beats (dnb, dubstep, garage, trap), synthwave's
  /// gentler pump; nothing where sidechaining is not the style (jazz, bossa, lofi, ambient, the
  /// band genres).
  public static func duckDepth(genre name: String) -> Double {
    guard let genre = BeatsTables.shared.genres[name] else { return 0 }
    if name == "synthwave" { return 0.4 }
    guard BeatsTables.shared.family(of: name) == 0 else { return 0 }
    let fourOnTheFloor =
      genre.kick.count >= 3 && genre.kick[0] == 4 && genre.kick[1] == 16 && genre.kick[2] == 0
    return fourOnTheFloor ? 0.5 : 0.35
  }

  // MARK: contour

  /// The nearest note of the project's key above (`up`) or below `note`, at most a minor third
  /// away; nil when there is none.
  static func neighbour(_ note: Int, up: Bool, key: Set<Int>) -> Int? {
    for d in 1...3 {
      let n = up ? note + d : note - d
      if key.contains(((n % 12) + 12) % 12) { return n }
    }
    return nil
  }

  /// In each melody ring, walk its notes in step order: an off-beat note (not on a quarter)
  /// at the pitch of the note before it, at most a beat earlier, moves a scale step towards the
  /// note after it, or up when that one repeats too — a passing or neighbour tone. A step that
  /// would rub a semitone against the bar's pad chord is not taken (the other direction is
  /// tried, else the repeat stays). The note before is the one as played (already moved), so a
  /// run of repeats becomes a turn.
  static func stepRepeatedNotes(_ p: inout Project) {
    let root = p.rootNote ?? 60
    let name = p.scaleName.isEmpty ? "Major" : p.scaleName
    let key = Set(scaleIntervals(name + "Scale").map { (root + $0) % 12 })
    guard !key.isEmpty else { return }
    // the pad's pitch classes in each bar of its cycle (every ring runs from tick 0, locked)
    var chordAt: [Int: Set<Int>] = [:]
    var padBars = 0
    for nb in p.nets.values where nb.role != "control" && part(nb) == "harmony" {
      padBars = max(padBars, nb.transitions.count / 16)
      for (t, b) in nb.bindings.pairs where t.hasPrefix("t") && !isDrumChannel(b.channel) {
        if let i = Int(t.dropFirst()) { chordAt[i / 16, default: []].insert(b.note % 12) }
      }
    }
    func rubs(_ note: Int, step: Int) -> Bool {
      guard padBars > 0, let chord = chordAt[(step / 16) % padBars] else { return false }
      return chord.contains { c in
        let d = ((note - c) % 12 + 12) % 12
        return d == 1 || d == 11
      }
    }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "melody",
        nb.transitions.count % 16 == 0, nb.places.count == nb.transitions.count
      else { continue }
      var steps: [(key: String, step: Int, note: Int)] = []
      for t in nb.bindings.keys {
        guard t.hasPrefix("t"), let i = Int(t.dropFirst()), let b = nb.bindings[t],
          !isDrumChannel(b.channel)
        else { continue }
        steps.append((t, i, b.note))
      }
      steps.sort { $0.step < $1.step }
      guard steps.count > 2 else { continue }
      let lo = steps.map(\.note).min()! - 2
      let hi = steps.map(\.note).max()! + 2
      var played = steps.map(\.note)
      for k in 1..<steps.count where steps[k].step % 4 != 0 {
        guard played[k] == played[k - 1], steps[k].step - steps[k - 1].step <= 4 else { continue }
        let next = k + 1 < steps.count ? steps[k + 1].note : steps[0].note
        let up = next == played[k] ? true : next > played[k]
        let options = [up, !up].compactMap { neighbour(played[k], up: $0, key: key) }
        guard
          let n = options.first(where: { $0 >= lo && $0 <= hi && !rubs($0, step: steps[k].step) })
        else { continue }
        played[k] = n
        nb.bindings[steps[k].key]?.note = n
      }
      p.nets[id] = nb
    }
  }

  // MARK: colour

  /// The interval each pad chord gains in `genre` (semitones above its root, by preference),
  /// or nil for genres that keep triads.
  static func chordColor(_ genre: String) -> [Int]? {
    switch genre {
    case "jazz", "bossa", "house", "garage", "funk": [10, 11]  // the scale's seventh
    default: nil
    }
  }

  /// Give each pad chord (a run of strikes on consecutive sixteenths, root first) one more
  /// tone, on the sixteenth after its last strike when that step is free and in the same bar:
  /// the first of `chordColor`'s intervals that is in the key and not already in the chord,
  /// near the chord's own notes, at its last strike's velocity and length.
  static func colorChords(_ p: inout Project, genre: GenreDef) {
    guard let intervals = chordColor(genre.name) else { return }
    let root = p.rootNote ?? 60
    let name = p.scaleName.isEmpty ? "Major" : p.scaleName
    let key = Set(scaleIntervals(name + "Scale").map { (root + $0) % 12 })
    guard key.count == 7 else { return }  // a seventh is a diatonic scale's
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "harmony" else { continue }
      var steps: [(step: Int, note: Int)] = []
      for (t, b) in nb.bindings.pairs where t.hasPrefix("t") && !isDrumChannel(b.channel) {
        if let i = Int(t.dropFirst()) { steps.append((i, b.note)) }
      }
      steps.sort { $0.step < $1.step }
      guard let lo = steps.map(\.note).min(), let top = steps.map(\.note).max() else { continue }
      let hi = max(top, lo + 12)  // the range `.voicing` keeps the pad in
      var chords: [[(step: Int, note: Int)]] = []
      for s in steps {
        if let last = chords.last?.last, s.step == last.step + 1 {
          chords[chords.count - 1].append(s)
        } else {
          chords.append([s])
        }
      }
      for chord in chords {
        let next = chord.last!.step + 1
        guard next < nb.transitions.count, next / 16 == chord[0].step / 16,
          nb.transitions["t\(next)"] != nil, nb.bindings["t\(next)"] == nil,
          let last = nb.bindings["t\(chord.last!.step)"]
        else { continue }
        let pcs = Set(chord.map { $0.note % 12 })
        guard
          let pc = intervals.map({ (chord[0].note + $0) % 12 }).first(where: {
            key.contains($0) && !pcs.contains($0)
          })
        else { continue }
        // the octave nearest the chord's middle, inside the pad's range, more than a semitone
        // from its notes
        var mid = 0
        for c in chord { mid += c.note }
        mid /= chord.count
        let below = mid - ((mid - pc) % 12 + 12) % 12  // the pitch class at or under the middle
        var note: Int?
        for n in [below, below + 12, below - 12, below + 24, below - 24] {
          let clear = n >= lo && n <= hi && !chord.contains { abs($0.note - n) <= 1 }
          if clear && (note == nil || abs(n - mid) < abs(note! - mid)) { note = n }
        }
        guard let note else { continue }
        var b = last
        b.note = note
        nb.bindings["t\(next)"] = b
      }
      p.nets[id] = nb
    }
  }

  // MARK: arpeggio

  /// The pad's chord in each bar of its cycle, as pitch classes in the order it strikes them
  /// (root first), and the cycle's length in bars; empty without a pad.
  static func padChords(_ p: Project) -> (chords: [Int: [Int]], bars: Int) {
    var bars = 0
    var struck: [Int: [(step: Int, pc: Int)]] = [:]
    for nb in p.nets.values where nb.role != "control" && part(nb) == "harmony" {
      bars = max(bars, nb.transitions.count / 16)
      for (t, b) in nb.bindings.pairs where t.hasPrefix("t") && !isDrumChannel(b.channel) {
        if let i = Int(t.dropFirst()) { struck[i / 16, default: []].append((i, b.note % 12)) }
      }
    }
    var chords: [Int: [Int]] = [:]
    for (bar, s) in struck {
      var pcs: [Int] = []
      for x in s.sorted(by: { $0.step < $1.step }) where !pcs.contains(x.pc) { pcs.append(x.pc) }
      chords[bar] = pcs
    }
    return (chords, bars)
  }

  /// Which of the five chord tones (from the lowest up) each sixteenth of a bar plays: up the
  /// chord twice, a step higher the third time, then back down to lead into the next bar.
  static let arpPattern = [0, 1, 2, 3, 1, 2, 3, 4, 2, 3, 4, 3, 2, 1, 2, 1]

  /// Every arp ring whose length is a whole pad cycle is rewritten bar by bar: in a bar where
  /// it had notes it now plays the bar's pad chord in `arpPattern`, every sixteenth (every
  /// eighth in a C variant, which beats composes sparser), from the lowest chord tone at or
  /// above the ring's median less a fourth, one step long, at the velocity it had. Bars it
  /// left silent stay silent: the arrangement's phrasing is kept, the notes are the chord's.
  static func arpeggiate(_ p: inout Project) {
    let (chords, padBars) = padChords(p)
    guard padBars > 0 else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", part(nb) == "arp",
        nb.transitions.count % (16 * padBars) == 0, nb.places.count == nb.transitions.count
      else { continue }
      var steps: [(step: Int, binding: MidiBinding)] = []
      for (t, b) in nb.bindings.pairs where t.hasPrefix("t") && !isDrumChannel(b.channel) {
        if let i = Int(t.dropFirst()) { steps.append((i, b)) }
      }
      guard let m = median(steps.map(\.binding.note)), let template = steps.first?.binding else {
        continue
      }
      let low = m - 5
      let rate = nb.riffVariant == "C" ? 2 : 1
      var bound = OrderedMap<MidiBinding>()
      for bar in 0..<(nb.transitions.count / 16) {
        let inBar = steps.filter { $0.step / 16 == bar }
        guard let chord = chords[bar % padBars], !chord.isEmpty,
          let velocity = inBar.map(\.binding.velocity).max()
        else { continue }
        // the chord's tones from `low` up, five of them
        var ladder: [Int] = []
        var n = low
        while ladder.count < 5 && n < low + 48 {
          if chord.contains(((n % 12) + 12) % 12) { ladder.append(n) }
          n += 1
        }
        guard ladder.count == 5 else { continue }
        for s in stride(from: 0, to: 16, by: rate) {
          var b = template
          b.note = max(0, min(127, ladder[arpPattern[s]]))
          b.velocity = velocity
          b.duration = 0
          b.durationSteps = 1
          bound["t\(bar * 16 + s)"] = b
        }
      }
      guard !bound.keys.isEmpty else { continue }
      nb.bindings = bound
      p.nets[id] = nb
    }
  }
}
