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

    /// The melody sings instead of ticking: beats binds every melody note one sixteenth long,
    /// so a line of quarter notes is four blips with silence between. Each note now lasts until
    /// the next one in its ring (at most a beat), and the phrase's last note a beat.
    public static let legato = Fixes(rawValue: 1 << 20)

    /// Phrases end at rest: the last note of each melody phrase (before a rest of half a bar or
    /// more, or the end of its ring) lands on a tone of the bar's chord, the root if it is as
    /// near. beats' motif walk ends wherever its random steps leave it (often a passing tone,
    /// which leaves the phrase hanging on a clash with the pad).
    public static let cadence = Fixes(rawValue: 1 << 21)

    /// The bass leads into each chord change: where a bar's line moves (three notes or more)
    /// and the next bar has another root, its last note becomes the scale step next to that
    /// root, approached from the side it comes from. Not in the offbeat-bass dance genres, whose
    /// one-note pulse is the style, nor in jazz, which already walks.
    public static let approach = Fixes(rawValue: 1 << 22)

    /// The breath before the drop: in the last beat of a buildup (or pre-chorus) that lands on
    /// a drop or chorus, kick, snare, hats and bass stop, leaving the roll and the pads, so the
    /// drop's downbeat (with its crash) hits out of a gap. Applied by the runner
    /// (`DJMusicality.dropGaps`); the nets play on as composed.
    public static let dropGap = Fixes(rawValue: 1 << 23)

    /// A closed hat chokes the open hat before it, as a hi-hat pedal does: the "tss" stops on
    /// the next "ts" instead of ringing under it. Applied by the runner, per hihat net.
    public static let choke = Fixes(rawValue: 1 << 24)

    /// A room: a send reverb (`SpaceSpec`, `FDNReverb`) the pads, leads, arp, snare and claps
    /// send to, by genre (a long bright hall for trance, a short room for techno, a dark one for
    /// lofi); kick and bass stay dry. beats' engine has no space at all. Applied by the runner.
    public static let space = Fixes(rawValue: 1 << 25)

    /// Saw and square voices as an analogue synth plays them: band-limited oscillators with
    /// every partial that fits under Nyquist (beats' tables stop at the 8th, so a 55 Hz bass has
    /// nothing above 440 Hz), through a lowpass per voice that opens on the note — further the
    /// harder it is struck — and closes as it plays (`FilterEnvelope`). Applied by the runner.
    public static let subtractive = Fixes(rawValue: 1 << 26)

    /// Pads and saw leads as two oscillators detuned a few cents apart (`Unison`): a held
    /// chord moves and a lead is full instead of one static oscillator. With `.stereo` the
    /// pad's pair spreads across the field. Applied by the runner.
    public static let unison = Fixes(rawValue: 1 << 27)

    /// A tempo-synced ping-pong echo on the lead and arp where the style has one (`EchoSpec`:
    /// dotted eighths in trance, synthwave, edm; eighths in lofi; a long wash in ambient):
    /// phrases ring on into the gaps between them. Applied by the runner; set by genre.
    public static let echo = Fixes(rawValue: 1 << 28)

    /// The kick's body tuned to the key (`KickTuning`: the root or fifth nearest 50 Hz) instead
    /// of beats' 48 Hz in every track, so its tail and the bass agree. Applied by the runner.
    public static let kickTune = Fixes(rawValue: 1 << 29)

    /// A melody you can remember: each 4-bar phrase states its idea twice. beats' motif walks
    /// at random through all four bars, so no bar sounds like another and nothing in a phrase
    /// comes back. Here bar 2 replays bar 1's rhythm and shape, moved along the scale onto bar
    /// 2's chord (a sequence), ending open on a chord tone that is not the root; bars 3–4
    /// continue and close as composed. A bar the melody rests in stays a rest.
    public static let motif = Fixes(rawValue: 1 << 30)

    /// The parts balanced against each other (`MixBalance`): beats sets one level per voice
    /// family, so in the dance genres the kick is the whole mix (K-weighted, bass and lead sit
    /// 12–19 dB under it). Each part is measured soloed at prepare and trimmed (± 6 dB) toward
    /// `MixBalance.targetDB`; `.loudness` then sets the track's level. Synth voices only.
    public static let balance = Fixes(rawValue: 1 << 31)

    /// A track of its own per seed (`TrackVariety.swift`): beats draws only the melody from the
    /// seed, so every seed of a genre had the same key, chords, bass and drums. Seeded from the
    /// track's seed: a key offset (−5…+6 semitones, the root moving with it, so `.kickTune`
    /// follows), a progression from `progressionTable` (pad and bass moved along the key, the
    /// melody's beat notes snapped to the new chords), a bass figure (rhythm × line, the first
    /// note of each bar still the root where the groove put it) and drum detail (ghost hats,
    /// snares and kicks; hats thinned or moved an eighth).
    public static let variety = Fixes(rawValue: 1 << 32)

    // Phase 6 (ROADMAP 6.2–6.6): registered with fixed bits ahead of their passes, so each flag's
    // task owns its own file. In `all` from the start; each is a no-op until its task builds it.
    // Pass flags call a stub in `apply` (named in its comment); the rest are applied by the runner.

    /// The pad cycle's last bar resolves into its first (`HarmonicCadence.swift`,
    /// p63-harmonic-cadence).
    public static let harmonicCadence = Fixes(rawValue: 1 << 33)
    /// Per-section harmony: the bridge melody normalised (`SectionMelody.swift`) and the runner
    /// transposing the section (p63-section-transpose-runner).
    public static let sectionHarmony = Fixes(rawValue: 1 << 34)
    /// Two bars per chord in intros / breakdowns, a pickup into the drop. Runner
    /// (p63-harmonic-rhythm).
    public static let harmonicRhythm = Fixes(rawValue: 1 << 35)
    /// 8-bar question and answer on melody slot pairs (`Answer.swift`, p64-answer).
    public static let answer = Fixes(rawValue: 1 << 36)
    /// One seeded chord-tone hook in every melodic section (`Hook.swift`, p64-hook).
    public static let hook = Fixes(rawValue: 1 << 37)
    /// Contour by corpus, leap recovery, a peak at two-thirds (`MelodyShape.swift`, p64-shape).
    public static let shape = Fixes(rawValue: 1 << 38)
    /// Bass bar 2 echoes bar 1's rhythm (`BassMotif.swift`, p64-bass-motif).
    public static let bassMotif = Fixes(rawValue: 1 << 39)
    /// Per-genre arp figures (`ArpFigure.seeded(_:variant:genre:)`, p64-arp-style): trance
    /// rolls up and down in sixteenths, synthwave climbs in eighths with octave jumps, edm
    /// plays up or broken sixteenths; other genres keep `.arpeggio`'s pool (house has no arp).
    public static let arpStyle = Fixes(rawValue: 1 << 40)
    /// The arp's rate follows the phrase's density, bar by bar (`arpDensityRates`,
    /// p64-arp-density): sixteenths under a busy melody bar, eighths under a sparse one,
    /// quarters where it rests, the section's energy where no melody plays, a step busier in
    /// each phrase's fourth bar and in buildups. Needs `.arpeggio`.
    public static let arpDensity = Fixes(rawValue: 1 << 41)
    /// Kick and snare in chill / jazz verse and chorus (`Backbeat.swift`, p65-chill-backbeat).
    public static let backbeat = Fixes(rawValue: 1 << 42)
    /// The family's groove template and a tempo-scaled swing. Runner (p65-feel-runner).
    public static let feel = Fixes(rawValue: 1 << 43)
    /// Humanize as seeded 1/f noise keyed by (seed, net, tick). Runner (p65-pink-humanize).
    public static let drift = Fixes(rawValue: 1 << 44)
    /// Voices' filter envelopes open through a buildup. Runner (p65-buildup-sweep).
    public static let sweep = Fixes(rawValue: 1 << 45)
    /// At most N melodic parts per section (runner rests, p62-layer-budget).
    public static let layerBudget = Fixes(rawValue: 1 << 46)
    /// Song-family band stop before a chorus. Runner (p62-band-stop).
    public static let bandStop = Fixes(rawValue: 1 << 47)
    /// Kick out for the last bar of a buildup. Runner (p62-kick-out).
    public static let kickOut = Fixes(rawValue: 1 << 48)
    /// A noise riser into drops. Runner (p62-riser).
    public static let riser = Fixes(rawValue: 1 << 49)
    /// A sub-octave sine under dnb / dubstep / trap basses. Runner (p66-sub-octave).
    public static let subOctave = Fixes(rawValue: 1 << 50)
    /// HF tilt at the offending voices. Runner (p66-hf-tilt).
    public static let hfTilt = Fixes(rawValue: 1 << 51)
    /// Pad shimmer and room level from 6.1's references. Runner (p66-room-shimmer).
    public static let shimmer = Fixes(rawValue: 1 << 52)

    public static let all: Fixes = [
      .key, .timing, .register, .dynamics, .loudness, .groove, .offbeatBass, .phrases, .fills,
      .voicing, .energy, .duck, .contour, .color, .arpeggio, .buildup, .crash, .bassLine,
      .openHats, .stereo, .legato, .cadence, .approach, .dropGap, .choke, .space, .subtractive,
      .unison, .echo, .kickTune, .motif, .balance, .variety, .harmonicCadence, .sectionHarmony,
      .harmonicRhythm, .answer, .hook, .shape, .bassMotif, .arpStyle, .arpDensity, .backbeat,
      .feel, .drift, .sweep, .layerBudget, .bandStop, .kickOut, .riser, .subOctave, .hfTilt,
      .shimmer,
    ]

    /// Each fix by the name `djctl render --fixes` takes.
    public static let named: [String: Fixes] = [
      "key": .key, "timing": .timing, "register": .register, "dynamics": .dynamics,
      "loudness": .loudness, "groove": .groove, "offbeatBass": .offbeatBass, "phrases": .phrases,
      "fills": .fills, "voicing": .voicing, "energy": .energy, "duck": .duck, "contour": .contour,
      "color": .color, "arpeggio": .arpeggio, "buildup": .buildup, "crash": .crash,
      "bassLine": .bassLine, "openHats": .openHats, "stereo": .stereo, "legato": .legato,
      "cadence": .cadence, "approach": .approach, "dropGap": .dropGap, "choke": .choke,
      "space": .space, "subtractive": .subtractive, "unison": .unison, "echo": .echo,
      "kickTune": .kickTune, "motif": .motif, "balance": .balance,
      "variety": .variety, "harmonicCadence": .harmonicCadence, "sectionHarmony": .sectionHarmony,
      "harmonicRhythm": .harmonicRhythm, "answer": .answer, "hook": .hook, "shape": .shape,
      "bassMotif": .bassMotif, "arpStyle": .arpStyle, "arpDensity": .arpDensity,
      "backbeat": .backbeat, "feel": .feel, "drift": .drift, "sweep": .sweep,
      "layerBudget": .layerBudget, "bandStop": .bandStop, "kickOut": .kickOut, "riser": .riser,
      "subOctave": .subOctave, "hfTilt": .hfTilt, "shimmer": .shimmer, "none": [],
    ]
  }

  /// `project` as the deck should play it. `spec` is the spec it was composed from.
  public static func apply(_ project: Project, spec: TrackSpec, fixes: Fixes = .all) -> Project {
    guard !fixes.isEmpty, let genre = BeatsTables.shared.genres[spec.genre] else { return project }
    var p = project
    if fixes.contains(.key) { keepVariantsInKey(&p, genre: genre, spec: spec) }
    if fixes.contains(.phrases) { alignPhrases(&p) }
    if fixes.contains(.timing) { fixStructureTiming(&p) }
    if fixes.contains(.backbeat) { playBackbeat(&p, genre: genre, spec: spec) }
    if fixes.contains(.sectionHarmony) { normaliseSectionMelody(&p, genre: genre, spec: spec) }
    if fixes.contains(.variety) { varyHarmony(&p, genre: genre, spec: spec) }
    if fixes.contains(.harmonicCadence) { resolvePadCycle(&p, genre: genre, spec: spec) }
    if fixes.contains(.register) { separateRegisters(&p) }
    if fixes.contains(.bassLine) { leadBass(&p) }
    if fixes.contains(.variety) { varyFigures(&p, genre: genre, spec: spec) }
    if fixes.contains(.color) { colorChords(&p, genre: genre) }
    if fixes.contains(.voicing) { voiceLeadPads(&p) }
    let arpGenre = fixes.contains(.arpStyle) ? spec.genre : nil
    if fixes.contains(.arpeggio) && !fixes.contains(.arpDensity) {
      arpeggiate(&p, seed: spec.seed, genre: arpGenre)
    }
    if fixes.contains(.offbeatBass) { moveBassOffTheKick(&p, genre: genre) }
    if fixes.contains(.contour) { stepRepeatedNotes(&p) }
    if fixes.contains(.shape) { shapeMelody(&p, genre: genre, spec: spec) }
    if fixes.contains(.cadence) { resolvePhraseEnds(&p) }
    if fixes.contains(.hook) { placeHook(&p, genre: genre, spec: spec) }
    if fixes.contains(.motif) { stateIdeasTwice(&p) }
    if fixes.contains(.answer) { answerPhrases(&p, genre: genre, spec: spec) }
    if fixes.contains(.bassMotif) { restateBassRhythm(&p, genre: genre, spec: spec) }
    if fixes.contains(.approach) { approachChordChanges(&p, genre: genre) }
    if fixes.contains(.legato) { holdMelodyNotes(&p) }
    // After every melody rewrite, so the arp follows the melody as it plays (nothing in
    // between touches the arp or the pads).
    if fixes.contains(.arpeggio) && fixes.contains(.arpDensity) {
      arpeggiate(
        &p, seed: spec.seed, genre: arpGenre,
        rates: arpDensityRates(p, seed: spec.seed, genre: arpGenre))
    }
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
  /// E1, where it is felt more than heard, comes up into the window.) Then a ring placed a
  /// fifth or more from the rest of the part moves an octave toward it, so sections meet
  /// without an octave jump.
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
    // Each ring is placed on its own, so a section's slot can land an octave from the others
    // (a sparser C variant, say) and the bass jumps an octave where the sections meet: a ring
    // whose median sits a fifth or more from the part's moves an octave toward it, where all
    // its notes still fit.
    guard let partMedian = median(notes(p, group: "bass")) else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "bass" else { continue }
      let ring = ringNotes(nb)
      guard let m = median(ring.map(\.note)), abs(m - partMedian) >= 7 else { continue }
      let s = m > partMedian ? -12 : 12
      guard ring.allSatisfy({ $0.note + s >= bassFloor && $0.note + s <= top }) else { continue }
      for x in ring { nb.bindings[x.key]?.note = x.note + s }
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

  // MARK: drop gap

  /// How long the rhythm section stops before a drop (`.dropGap`): a beat, in sixteenths.
  public static let dropGapSteps = 4
  static let risingSections: Set<String> = ["buildup", "pre-chorus"]
  static let payoffSections: Set<String> = ["drop", "chorus"]

  /// First step of each gap: the last beat of every buildup / pre-chorus followed by a drop or
  /// chorus, ascending.
  public static func dropGaps(_ p: Project) -> [Int] {
    var out: [Int] = []
    var t = 0
    for (k, s) in p.structure.enumerated() {
      if k > 0, t >= dropGapSteps, payoffSections.contains(s.name),
        risingSections.contains(p.structure[k - 1].name)
      {
        out.append(t - dropGapSteps)
      }
      t += s.steps
    }
    return out
  }

  // MARK: stereo

  /// Where a lane sits (`.stereo`): `pan` from −1 (left) to 1 (right), as the side gain of a
  /// mid/side pan, and `spread`, a tonal lane's voices alternating that far either side of it
  /// (a chord's notes across the field; an arp's successive notes left, right, left), the
  /// runner narrowing it for notes below G4 so nothing at or under E3 leaves the middle. `kind`
  /// is the lane's drum kind or "tonal"; `group` the net's part. From `targets.json`'s `stereo`
  /// (`MixTargets`): hats 0.3 right, crash 0.3 left, harmony spread 0.5, arp 0.45.
  public static func stereoPlacement(kind: String, group: String) -> (pan: Double, spread: Double) {
    MixTargets.shared.placement(kind: kind, group: group)
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

  /// An arp figure: which tone of a `span`-tone ladder each sixteenth plays, its first tone
  /// (`start`, up the ladder), and whether it plays every sixteenth or every eighth. `phase`
  /// starts the figure part-way through its cycle (an up-and-down keeps its shape, where
  /// `start` would wrap it); with `octaves` each tone plays twice, the second an octave up.
  struct ArpFigure: Hashable {
    var shape: Int
    var span: Int
    var start: Int
    var rate: Int
    var phase = 0
    var octaves = false

    static let shapes = 6

    /// The ladder index for sixteenth `s` (0…15).
    func tone(_ s: Int) -> Int {
      let i = s / rate / (octaves ? 2 : 1) + phase
      let n = span
      let x: Int
      switch shape {
      case 1: x = n - 1 - i % n  // down
      case 2:  // up and down
        let period = max(1, 2 * n - 2)
        let k = i % period
        x = k < n ? k : period - k
      case 3: x = (i / 2 + (i % 2) * 2) % n  // broken: 0 2 1 3 2 4 …
      case 4: x = i % 2 == 0 ? 0 : 1 + (i / 2) % max(1, n - 1)  // pedal on the lowest tone
      case 5: x = min(n - 1, arpPattern[s])  // beats' figure (dj's first `.arpeggio`)
      default: x = i % n  // up
      }
      return (x + start) % n
    }

    /// Semitones above the ladder tone for sixteenth `s`: 12 on the second of each pair
    /// under `octaves`, else 0.
    func octave(_ s: Int) -> Int { octaves && (s / rate) % 2 == 1 ? 12 : 0 }

    /// The figure a slot of variant `variant` plays in a track of `seed`: drawn from the seed
    /// and the variant's letter, so every A slot plays one figure and a B slot another. A C
    /// variant (which beats composes sparser) plays eighths.
    ///
    /// With `genre` (`.arpStyle`) the figure comes from that genre's pool, the seed still
    /// picking within it: trance an up-and-down in sixteenths over 4–6 tones from a seeded
    /// phase, synthwave eighths rising (up, up and down or down) with every tone answered an
    /// octave up, edm up or broken sixteenths (a C slot's sixteenths are eighths, as in the full
    /// pool). Any other genre (house has no arp role, so
    /// nothing to play) and `nil` draw from the full pool.
    static func seeded(_ seed: Double, variant: String, genre: String? = nil) -> ArpFigure {
      let u = UInt32(bitPattern: jsToInt32(seed))
      var rng = Mulberry32(seed: Int(Int32(bitPattern: u ^ hashStr("dj-arp/" + variant))))
      switch genre {
      case "trance":
        let span = 4 + rng.nextInt(3)
        let phase = rng.nextInt(2 * span - 2)
        return ArpFigure(
          shape: 2, span: span, start: 0, rate: variant == "C" ? 2 : 1, phase: phase)
      case "synthwave":
        let shape = [0, 2, 1][rng.nextInt(3)]
        let span = 3 + rng.nextInt(3)
        let start = shape == 2 ? 0 : rng.nextInt(span)
        let phase = shape == 2 ? rng.nextInt(2 * span - 2) : 0
        return ArpFigure(
          shape: shape, span: span, start: start, rate: 2, phase: phase, octaves: true)
      case "edm":
        let shape = rng.nextInt(2) == 0 ? 0 : 3
        let span = 4 + rng.nextInt(3)
        let start = rng.nextInt(span)
        return ArpFigure(shape: shape, span: span, start: start, rate: variant == "C" ? 2 : 1)
      default: break
      }
      let shape = rng.nextInt(shapes)
      let span = 4 + rng.nextInt(3)
      let start = rng.nextInt(span)
      var rate = rng.nextInt(3) == 2 ? 2 : 1
      if variant == "C" { rate = 2 }
      return ArpFigure(shape: shape, span: span, start: start, rate: rate)
    }
  }

  /// Every arp ring whose length is a whole pad cycle is rewritten bar by bar: in a bar where
  /// it had notes it now plays the bar's pad chord as a ladder of `span` chord tones from the
  /// lowest at or above the ring's median less a fourth, in the slot's `ArpFigure` (up, down,
  /// up and down, broken, a pedal or beats-like, from a seeded first tone, every sixteenth or
  /// eighth: seeded from the track's seed and the slot's variant), one step long, at the
  /// velocity it had. Bars it left silent stay silent: the arrangement's phrasing is kept, the
  /// notes are the chord's. With `genre` (`.arpStyle`) the figure is drawn from its pool.
  ///
  /// With `rates` (`.arpDensity`: net → ring bar → steps between notes) a bar listed there
  /// plays at that rate instead of the figure's.
  static func arpeggiate(
    _ p: inout Project, seed: Double, genre: String? = nil, rates: [String: [Int: Int]]? = nil
  ) {
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
      let figure = ArpFigure.seeded(seed, variant: nb.riffVariant, genre: genre)
      var bound = OrderedMap<MidiBinding>()
      for bar in 0..<(nb.transitions.count / 16) {
        let inBar = steps.filter { $0.step / 16 == bar }
        guard let chord = chords[bar % padBars], !chord.isEmpty,
          let velocity = inBar.map(\.binding.velocity).max()
        else { continue }
        // the chord's tones from `low` up, `span` of them
        var ladder: [Int] = []
        var n = low
        while ladder.count < figure.span && n < low + 48 {
          if chord.contains(((n % 12) + 12) % 12) { ladder.append(n) }
          n += 1
        }
        guard ladder.count == figure.span else { continue }
        for s in stride(from: 0, to: 16, by: rates?[id]?[bar] ?? figure.rate) {
          var b = template
          b.note = max(0, min(127, ladder[figure.tone(s)] + figure.octave(s)))
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

  // MARK: arp density

  /// Which way the arp's density goes against the melody's: 1 follows it (a busy melody bar,
  /// a busy arp), -1 answers it (the arp fills where the melody rests). The one place the
  /// direction is decided; it's an ear call.
  static let arpDensityDirection = 1
  /// Steps between arp notes at each density level: quarters, eighths, sixteenths.
  static let arpDensityLevels = [4, 2, 1]
  /// Melody onsets in a bar from which it counts as busy (more than one a beat).
  static let arpBusyOnsets = 5
  /// Section energy (the feel curve's, over the loudest section's) from which the arp plays
  /// eighths, and sixteenths, where no melody plays.
  static let arpEnergyLevels = (eighths: 0.45, sixteenths: 0.75)

  /// `.arpDensity`'s rate for every bar of every arp slot ring that plays (net → ring bar →
  /// steps between notes). A song bar's level: where a melody slot plays (`slotWindows`), its
  /// onsets in that bar (none: quarters, fewer than `arpBusyOnsets`: eighths, else
  /// sixteenths; turned round when `arpDensityDirection` is -1); where none does, the
  /// section's feel-curve energy; with neither (a loop), the figure's own rate. Then a level
  /// up in the fourth bar of each four (rising into the phrase's end) and in a buildup
  /// (`EnergyCurve.rampSections`), at most sixteenths. A ring bar heard in several song bars
  /// (a section played twice) takes their mean level. Bars the slot leaves silent stay silent
  /// (`arpeggiate` only rewrites bars that had notes).
  static func arpDensityRates(_ p: Project, seed: Double, genre: String?) -> [String: [Int: Int]] {
    let melody = melodyOnsetsByBar(p)
    let energy = sectionEnergy(p)
    var sectionStart: [Int] = []
    var at = 0
    for s in p.structure {
      sectionStart.append(at)
      at += s.steps
    }
    let top = arpDensityLevels.count - 1
    var out: [String: [Int: Int]] = [:]
    for (id, windows) in slotWindows(p, role: "arp") {
      guard let nb = p.nets[id], nb.transitions.count >= 16 else { continue }
      let figure = ArpFigure.seeded(seed, variant: nb.riffVariant, genre: genre)
      let base = arpDensityLevels.firstIndex(of: figure.rate) ?? top
      let length = nb.transitions.count
      var levels: [Int: [Int]] = [:]
      for w in windows {
        let ringLength = w.ringLength ?? length
        for step in stride(from: w.start, to: w.end, by: 16) {
          let bar = step / 16
          var level: Int
          if let n = melody[bar] {
            level = n == 0 ? 0 : n < arpBusyOnsets ? 1 : 2
            if arpDensityDirection < 0 { level = top - level }
          } else if let e = energy?[w.section] ?? nil {
            level = e >= arpEnergyLevels.sixteenths ? 2 : e >= arpEnergyLevels.eighths ? 1 : 0
          } else {
            level = base
          }
          if (step - sectionStart[w.section]) / 16 % 4 == 3 { level += 1 }
          if EnergyCurve.rampSections.contains(w.sectionName) { level += 1 }
          let ring = ((w.ringStart ?? w.start) + step - w.start) % ringLength
          levels[ring / 16, default: []].append(min(top, level))
        }
      }
      out[id] = levels.mapValues { ls in
        arpDensityLevels[Int((Double(ls.reduce(0, +)) / Double(ls.count)).rounded())]
      }
    }
    return out
  }

  /// Melody onsets (distinct steps with a note) in each song bar a melody slot plays in.
  static func melodyOnsetsByBar(_ p: Project) -> [Int: Int] {
    var out: [Int: Int] = [:]
    for (id, windows) in slotWindows(p, role: "melody") {
      guard let nb = p.nets[id], nb.transitions.count > 0 else { continue }
      let onsets = Set(ringNotes(nb).map(\.step))
      for w in windows {
        let length = w.ringLength ?? nb.transitions.count
        for step in stride(from: w.start, to: w.end, by: 16) {
          let ring = ((w.ringStart ?? w.start) + step - w.start) % length
          let n = onsets.filter { ($0 - ring + length) % length < 16 }.count
          out[step / 16, default: 0] += n
        }
      }
    }
    return out
  }

  /// Each section's energy (its feel-curve `x`) over the most energetic section's, by
  /// structure index (nil for a section it doesn't mark); nil without a feel curve or with no energy in it. The composer marks
  /// each section name once, at its first start (as `EnergyCurve` reads it).
  static func sectionEnergy(_ p: Project) -> [Double?]? {
    guard p.structure.count > 1, let feel = p.nets["feel-curve"] else { return nil }
    var x: [Int: Double] = [:]
    for (t, c) in feel.controlBindings.pairs where c.action == "set-feel" {
      guard t.hasPrefix("ft"), let step = Int(t.dropFirst(2)),
        let v = c.macroParams?["x"]?.double
      else { continue }
      x[step] = v
    }
    var byName: [String: Double] = [:]
    var at = 0
    for s in p.structure {
      if byName[s.name] == nil, let v = x[at] { byName[s.name] = v }
      at += s.steps
    }
    guard let peak = byName.values.max(), peak > 0 else { return nil }
    return p.structure.map { s in byName[s.name].map { min(1, $0 / peak) } }
  }

  // MARK: shared

  /// The project's key, as pitch classes.
  static func keyPitchClasses(_ p: Project) -> Set<Int> {
    let root = p.rootNote ?? 60
    let name = p.scaleName.isEmpty ? "Major" : p.scaleName
    return Set(scaleIntervals(name + "Scale").map { (root + $0) % 12 })
  }

  /// A ring net of whole bars (one place per transition, `ti` firing on step `i` of the cycle).
  static func isBarRing(_ nb: NetBundle) -> Bool {
    nb.role != "control" && nb.transitions.count % 16 == 0
      && nb.places.count == nb.transitions.count
  }

  /// The tonal notes bound on a ring's steps, in step order.
  static func ringNotes(_ nb: NetBundle) -> [(key: String, step: Int, note: Int)] {
    var out: [(key: String, step: Int, note: Int)] = []
    for (t, b) in nb.bindings.pairs where t.hasPrefix("t") && !isDrumChannel(b.channel) {
      if let i = Int(t.dropFirst()) { out.append((t, i, b.note)) }
    }
    return out.sorted { $0.step < $1.step }
  }

  @inline(__always) static func pc(_ n: Int) -> Int { ((n % 12) + 12) % 12 }

  // MARK: legato

  /// The longest a melody note is held (sixteenths): a beat.
  static let legatoMax = 4

  /// Every note of a melody ring lasts until the next note of the ring (round the cycle), at
  /// most `legatoMax`; a note bound longer keeps its length.
  static func holdMelodyNotes(_ p: inout Project) {
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "melody" else { continue }
      let steps = ringNotes(nb)
      let n = nb.transitions.count
      for (k, s) in steps.enumerated() {
        let next = k + 1 < steps.count ? steps[k + 1].step : steps[0].step + n
        let len = min(next - s.step, legatoMax)
        guard var b = nb.bindings[s.key], b.durationSteps < len else { continue }
        b.durationSteps = len
        b.duration = 0
        nb.bindings[s.key] = b
      }
      p.nets[id] = nb
    }
  }

  // MARK: cadence

  /// Sixteenths of rest after a note that end its phrase: half a bar.
  static let phraseRest = 8

  /// In each melody ring, a note followed by `phraseRest` or more of silence (round the cycle)
  /// ends a phrase, and so does the last note before each 2-bar line of a ring of two bars or
  /// more (the motif's half and whole phrase; a section, or a 2-bar phrase slot, ends on one
  /// of them). One that is not a tone of the bar's pad
  /// chord moves to the nearest one, at most a fourth away and inside the part's range; the
  /// chord's root wins a tie, then the note below (a falling close), and the note before it is
  /// avoided (no stalled ending).
  static func resolvePhraseEnds(_ p: inout Project) {
    let (chords, padBars) = padChords(p)
    guard padBars > 0 else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "melody" else { continue }
      let steps = ringNotes(nb)
      guard steps.count > 1 else { continue }
      let n = nb.transitions.count
      let lo = steps.map(\.note).min()! - 2
      let hi = steps.map(\.note).max()! + 2
      for (k, s) in steps.enumerated() {
        let next = k + 1 < steps.count ? steps[k + 1].step : steps[0].step + n
        let end = next - s.step >= phraseRest || (n >= 32 && next / 32 > s.step / 32)
        guard end, let chord = chords[(s.step / 16) % padBars], !chord.isEmpty,
          !chord.contains(pc(s.note))
        else { continue }
        let before = steps[(k + steps.count - 1) % steps.count].note
        var best: (score: Int, note: Int)?
        for d in -5...5 where d != 0 {
          let c = s.note + d
          guard c >= lo, c <= hi, chord.contains(pc(c)) else { continue }
          // two points a semitone; the root, a fall and a new pitch each earn one back
          var score = 2 * abs(d)
          if pc(c) == chord[0] { score -= 1 }
          if d < 0 { score -= 1 }
          if c == before { score += 3 }
          if best == nil || score < best!.score { best = (score, c) }
        }
        guard let best else { continue }
        nb.bindings[s.key]?.note = best.note
      }
      p.nets[id] = nb
    }
  }

  // MARK: approach

  /// In each bass ring (not in the offbeat-bass dance genres, nor jazz), a bar of three notes
  /// or more whose next bar (round the cycle) starts on another pitch class ends on the scale
  /// step next to that note, from below when the line comes up to it (unless that step is under
  /// E1), from above when it comes down. Only a last note in the second half of the bar, more than a whole tone from the
  /// target, moves; the downbeats, and so the roots, stay.
  static func approachChordChanges(_ p: inout Project, genre: GenreDef) {
    guard genre.name != "jazz", !bassLockedToFourOnTheFloor(genre) else { return }
    let key = keyPitchClasses(p)
    guard !key.isEmpty else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "bass" else { continue }
      let count = nb.transitions.count / 16
      guard count > 1 else { continue }
      var bars = [[(key: String, step: Int, note: Int)]](repeating: [], count: count)
      for s in ringNotes(nb) { bars[s.step / 16].append(s) }
      for b in 0..<count where bars[b].count >= 3 {
        guard let target = bars[(b + 1) % count].first, let last = bars[b].last,
          pc(target.note) != pc(bars[b][0].note), last.step % 16 >= 8,
          abs(last.note - target.note) > 2,
          let near = neighbour(target.note, up: last.note > target.note, key: key),
          // from above where the step below would be under E1
          let c = near >= bassFloor ? near : neighbour(target.note, up: true, key: key),
          abs(c - target.note) <= 2
        else { continue }
        nb.bindings[last.key]?.note = c
      }
      p.nets[id] = nb
    }
  }

  // MARK: motif

  /// `note` moved `k` steps along the key (`scale`: every MIDI note in the key, ascending);
  /// nil when the note is not in the key or the move leaves the keyboard.
  static func diatonic(_ note: Int, _ k: Int, _ scale: [Int]) -> Int? {
    guard let i = scale.firstIndex(of: note), scale.indices.contains(i + k) else { return nil }
    return scale[i + k]
  }

  /// In each melody ring of whole bars, every 4-bar phrase (2-bar, in a 2-bar ring) whose first
  /// two bars both play: bar 2's notes are replaced by bar 1's, on the same sixteenths with the
  /// same lengths and velocities, moved `k` scale steps — the `k` (within an octave) that puts
  /// its first note on a tone of bar 2's pad chord nearest the note bar 2 began on, keeping
  /// bar 1's up / down / same shape where it can, inside the ring's range (down a minor third,
  /// up a fifth: a sequence may climb, but not into the pad). Beat notes and
  /// phrase ends that then miss bar 2's chord step to its nearest tone (as beats snaps its
  /// motif's beats, and `.cadence` its phrase ends); the last note goes to the nearest tone of
  /// the chord that is not its root (bar 2 ends open, as beats composes it, so bar 4's close
  /// answers it). Runs after `.contour` and `.cadence`, so bar 2 repeats bar 1 as it will be
  /// played.
  static func stateIdeasTwice(_ p: inout Project) {
    let (chords, padBars) = padChords(p)
    let key = keyPitchClasses(p)
    guard padBars > 0, !key.isEmpty else { return }
    let scale = (0...127).filter { key.contains(pc($0)) }
    for id in p.nets.keys {
      guard var nb = p.nets[id], isBarRing(nb), part(nb) == "melody" else { continue }
      let count = nb.transitions.count
      let block = count % 64 == 0 ? 64 : 32
      guard count % block == 0 else { continue }
      let steps = ringNotes(nb)
      guard let lo = steps.map(\.note).min(), let hi = steps.map(\.note).max() else { continue }
      for start in stride(from: 0, to: count, by: block) {
        let first = steps.filter { $0.step >= start && $0.step < start + 16 }
        let second = steps.filter { $0.step >= start + 16 && $0.step < start + 32 }
        guard first.count >= 2, let opening = second.first,
          let chord = chords[((start + 16) / 16) % padBars], !chord.isEmpty
        else { continue }
        // the moves that land bar 1's first note on bar 2's chord, nearest where bar 2 began
        // first; the first whose copy stays in range is taken
        var moves: [(k: Int, d: Int)] = []
        for k in -7...7 {
          guard let n = diatonic(first[0].note, k, scale), chord.contains(pc(n)) else { continue }
          moves.append((k, abs(n - opening.note)))
        }
        moves.sort { ($0.d, abs($0.k)) < ($1.d, abs($1.k)) }
        // the sixteenth after each note of bar 1 (the next note, or bar 2's first)
        let next = first.indices.map { j in j + 1 < first.count ? first[j + 1].step : start + 16 }
        // A note that has to be a chord tone goes to the nearest one that keeps the line's
        // direction from the note before (up, down, or the same), else the nearest.
        func snap(_ n: Int, prev: Int?, sign: Int, avoid: Int? = nil) -> Int {
          let options = (-6...6).map { n + $0 }.filter {
            chord.contains(pc($0)) && pc($0) != avoid
          }
          let keep = options.filter { o in prev.map { (o - $0).signum() == sign } ?? true }
          let pool = keep.isEmpty ? options : keep
          return pool.min { abs($0 - n) < abs($1 - n) } ?? n
        }
        var chosen: (copy: [(step: Int, binding: MidiBinding)], cost: Int)?
        for (k, d) in moves {
          var copy: [(step: Int, binding: MidiBinding)] = []
          var turns = 0  // intervals whose direction differs from bar 1's
          for (j, s) in first.enumerated() {
            guard var n = diatonic(s.note, k, scale), var b = nb.bindings[s.key] else { break }
            let step = s.step + 16
            let prev = copy.last?.binding.note
            let sign = j > 0 ? (s.note - first[j - 1].note).signum() : 0
            // beats on the chord; a phrase end (half a bar of rest after it) too; the last
            // note on a tone that is not the root
            if j == first.count - 1 && (pc(n) == chord[0] || !chord.contains(pc(n))) {
              n = snap(n, prev: prev, sign: sign, avoid: chord[0])
            } else if (step % 4 == 0 || next[j] - s.step >= phraseRest) && !chord.contains(pc(n)) {
              n = snap(n, prev: prev, sign: sign)
            }
            if let prev, (n - prev).signum() != sign { turns += 1 }
            b.note = n
            copy.append((step, b))
          }
          guard copy.count == first.count,
            copy.allSatisfy({ $0.binding.note >= lo - 3 && $0.binding.note <= hi + 7 })
          else { continue }
          // the shape first, then nearness to where bar 2 began
          let cost = 100 * turns + d
          if chosen == nil || cost < chosen!.cost { chosen = (copy, cost) }
        }
        guard let chosen = chosen?.copy else { continue }
        for s in second { nb.bindings[s.key] = nil }
        for c in chosen { nb.bindings["t\(c.step)"] = c.binding }
      }
      p.nets[id] = nb
    }
  }
}
