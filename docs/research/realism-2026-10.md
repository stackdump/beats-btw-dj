# Do the generated tracks sound like music? — realism audit and options (2026-10)

Research note for Matt, 2026-10-12. Read-only on code: nothing in `Sources/` or `Tests/` changed.
The measurement harness and its raw output are in [`realism-2026-10/`](realism-2026-10/).

**Scope.** The generator is beats' `public/lib/generator/*.js` (canonical, beats `668978e`).
dj-vevr-se's `Sources/DJCore/Beats/Generator` follows it byte for byte (`ComposerGateTests`), so
every symbolic number below also holds for a net deck in the app. Audio numbers come from beats'
offline wave renderer (`wave-engine/offline.js`). Notes and synth voices there are identical to
dj's parity path (`WaveOptions()`), but the sound is not what the app plays:

- The app's `WaveOptions.extended` replaces many synth voices with EXS/SoundFont samplers and
  Karplus-Strong plucks.
- The render farm records beats' Tone.js engine in headless Chrome. That engine applies swing,
  humanize and the feel curve, which the wave engine does not.

## Verdict

**The output is music-like at the scale of a 4-bar loop. It is not music-like at the scale of a
track.**

A single loop holds up:

- Drums sit on a Euclidean grid with accents.
- Bass lands on chord roots locked to the kick.
- On v2 tracks, the melody puts a chord tone on every beat and is built from one 4-bar motif.
- The pad plays a 4-chord progression taken from genre tables.

Over a whole song, these patterns break down:

- **Form.** Sections are 12 bars long and phrases are 2, 3 or 6 bars. Intros are 4 bars. Songs
  average 110 s.
- **Transitions.** Section changes land up to 19 sixteenths after the bar line. The drum fills
  that are generated never sound.
- **Dynamics.** On the path dj uses, loudness barely moves between intro and drop. Loudness range
  is 0.7–0.8 LU for techno, house and trance.
- **Feel.** Every note is exactly on the grid, and tonal parts have one velocity per song.
- **Harmony.** One chord loop repeats for the whole song.
- **Mix.** Output is mono, uses static envelopes and has no sidechain.

There is also a real bug: in the 10 genres with `tensionCurve` on, the B/C phrase variants play
9–75% out-of-key notes over an in-key pad.

Several of these problems are bugs or unported features, not missing research. The cheapest gains
come from fixing them, behind a generator version flag (see [Determinism](#determinism-and-versioning)).

## 1. Method

| What | How |
|---|---|
| Symbolic audit | [`analyze.mjs`](realism-2026-10/analyze.mjs) composes every genre (19) with seeds 42, 7 and 2026, `structure: standard` (57 songs). It runs each song through beats' real net executor (`wave-engine/net.js` `tick`) until `struct-stop` and records every audible note (tick, net, role, pitch, velocity, duration) plus every `activate-slot` control. It computes form, lateness, density, velocity, melody, harmony, bass and repetition metrics. Raw output: [`symbolic.json`](realism-2026-10/symbolic.json); summary: [`agg.mjs`](realism-2026-10/agg.mjs). |
| Key check | [`key.mjs`](realism-2026-10/key.mjs): share of out-of-scale notes per role and riff variant. |
| Audio audit | [`render.mjs`](realism-2026-10/render.mjs) renders whole songs (8 genres, seed 42) with `renderOffline` at 48 kHz. It computes octave-band long-term spectrum, spectral slope, per-bar and per-section RMS, and side/mid ratio. ffmpeg `ebur128` and `astats` give integrated LUFS, LRA, peak and RMS. Output: [`audio.json`](realism-2026-10/audio.json). |
| Live app | `dj_state` and `dj_screenshot` only. Deck B was playing live, a controller was in use and deck A had a track cued. Calling `dj_generate` or `dj_record` would have replaced or recorded Matt's session, so they were not used. Both decks were endless loops (no sections) using EXS samplers. In that mode only the 4-bar loop is heard, and the song-form findings do not apply. |
| Code reading | `Composer`, `Theme`, `Markov`, `Euclidean`, `Variety`, `Structure`, `WaveRunner`/`WaveNet` (Swift), plus beats' `structure.js`, `backend/index.js` (`swingDelay`, `humanizeNote`), `wave-engine/synth.js`. |

Reproduce with `node docs/research/realism-2026-10/analyze.mjs` (about 3 s; reads
`~/Workspace/beats-bitwrap-io/public`) and `node docs/research/realism-2026-10/render.mjs`
(about 1 s per song; WAVs go to `$WAV_DIR` or the temp directory).

## 2. Evidence, dimension by dimension

### 2.1 Song form and phrasing — weak

- **Section lengths.** `sectionSteps` makes standard sections 64 steps (4 bars) for intro, outro,
  breakdown, bridge and solo, and 192 steps (**12 bars**) for everything else. Minimal uses 2/8
  bars and extended 8/12. In the standard structure, **not one section in the 57 songs is a
  multiple of 8 bars long.** Phrase lengths (section ÷ phrase letters) come
  out at **1, 2, 3 and 6 bars**: a `drop` is A-B-A-B over 12 bars, so each phrase is 3 bars long.
  EDM form is built from parts entering and leaving on 4/8/16/32-bar boundaries (Butler 2006;
  Solberg 2014). A 3-bar phrase therefore audibly lands "early" or "late".
- **Song length.** Mean 110 s (61–192 s), 54 bars. Intro and outro are 4 bars (2 in minimal). For a
  DJ app this matters on its own: DJs mix over phrase-aligned intros and outros that usually run
  16–32 bars (Kim et al. 2020 analyse 20,765 real DJ transitions).
- **Transitions are late — a bug.** `buildAccumulatorNet` gives each event a countdown place
  initialised to the gap since the previous event. `t_ctrl_i` fires on the tick after the countdown
  empties, and the next countdown starts only after that. Each event therefore lands **one tick
  later than the one before**, and the error accumulates:

  | Song | Intended bass switches | Actual |
  |---|---|---|
  | techno 42 | 64, 160, 256, 304, … 784 | 64, 161, 258, 307, … 797 |

  Over 57 songs the last switch is **11–19 ticks late (mean 15.8)**, i.e. about one beat. Roles
  with different event counts drift by different amounts: kick, bass and melody change on
  different sixteenths at the same "section boundary". `structure.js` describes a clock-plus-counter
  design, but the code implements a countdown chain. `struct-stop` has only one event, so the song
  still ends on time.
- **Drum fills never sound — a bug.** `drumFillNet` builds `fill-0…fill-5` at every boundary for
  every genre (`df` is forced on under cohesion v2). `songStructure` then treats them as plain nets
  that no section lists as active. They start muted and their `struct-fill-*` nets carry **zero**
  control bindings. Measured: 0 fill notes in every song.
- **Odd role tables.** Example: jazz 42 has no kick or snare for the whole song, then a kick enters
  in the 4-bar outro. This comes from the section archetypes, not from chance.

### 2.2 Harmony and voice leading — thin

- **One progression per song.** Cohesion v2 (every genre with chord progressions, which is all 19
  here) picks one progression and plays it as a 4-bar loop at one chord per bar for the whole song.
  The 12-bar blues is the exception at 12 bars. Measured: **2–5 distinct chords per song** (mean
  3.9). The `harmonic` offsets (bridge +5, solo +4) are applied only to the melody motif. The pad
  is a single unslotted `harmony` net, so the bridge and solo melody move away from a pad that
  does not move. There is no section-specific progression, no cadence at phrase ends, and harmonic
  rhythm never changes.
- **Voicing.** `chordPadNet` maps each chord tone to its own scale degree inside one octave. The
  result is root-position-ish triads, rolled 1/16 apart, held for 95% of a bar, always at velocity
  68. There are no 7ths or extensions, even in jazz, lofi and house. Total semitone movement
  between consecutive chords averages **5.6, against 3.8 for the best inversion choice** (+49%;
  computed in `analyze.mjs` `optimalVL`). Ambient moves 8.6 where 3.9 is possible.
- **Out-of-key B/C variants — a bug.** `expandVariants` applies `tensionForVariant`'s
  `registerShift` (+2 for B, −3 for C) to `rootNote` and then calls `genre.scale(rootNote)`. That
  rebuilds the scale on a root a whole tone higher or a minor third lower, which transposes the
  phrase out of key. It is not a register change. The pad stays in key. Out-of-key share per
  variant, seed 42:

  | genre | worst B | worst C |
  |---|---|---|
  | blues | bass 68%, melody 52% | melody 74% |
  | dubstep | melody 31% | melody 74% |
  | jazz | bass 32% | melody 75% |
  | metal | melody 64% | — |
  | dnb, edm, ambient, trance, synthwave, trap | 8–36% | 25–61% |

  Genres without `tensionCurve` (techno, house, country, reggae, funk, bossa, garage, speedcore)
  measure 0%. The only exception is walking-bass chromatic approach notes in jazz and lofi, which
  are idiomatic. Strong-beat melody/pad agreement follows the same split: 0.86–1.0 without
  tension, 0.41–0.63 with it.

### 2.3 Melody — coherent cell, little development

- **Motif construction.** The v2 motif is one 4-bar cell. It always hits every quarter note plus
  2–4 random sixteenths per bar. Beat notes snap to the nearest chord tone. In between it takes
  random steps of −2…+2 degrees, clamped at the scale ends. Cadences are forced at the end of bars
  2 and 4.
- **Intervals.** Measured across 57 songs: **repeated pitches 54%**, steps (1–2 semitones) 26%,
  skips 14%, leaps 6%; range about 11 semitones. Melody corpora are dominated by steps, not unisons
  (Huron 2006; Narmour's implication–realisation model). The repeats come from the clamp at degree
  0/6 and the zero step.
- **Development.** Sections reuse the same cell played as-is, transposed, fragmented, augmented or
  inverted (`MotifMode`). That is the right idea, but a song has only 13 distinct melody bars out
  of about 37 sounding bars. There is no phrase-level grammar (sentence A A′ B, or question and
  answer).
- **Phrase alignment.** All slot nets tick from tick 0, and `activate-slot` only unmutes; it does
  not reset the token. A slot that comes in at a 3-bar phrase boundary (plus the drift above)
  therefore starts **in the middle of its 64-step motif**. This happens at 15 of 16 melody slot
  starts in techno 42, and at 96% of melody slot starts across all songs (915 of 954). The listener rarely
  hears the motif from its first note at a section start.

### 2.4 Groove — quantised and static on the deterministic path

- **Timing.** 100% of onsets sit exactly on the 16th grid. 12 of 19 genres set `swing` (house 20,
  lofi 35, jazz 60) and all 19 set `humanize`. Only beats' Tone backend reads them
  (`backend/index.js` `swingDelay`, `humanizeNote`), and it uses `Math.random()`. As a result:
  - The farm's `.webm` renders swing, but two renders of the same CID differ in timing and
    velocity.
  - The wave engine (beats `?engine=wave` and offline render) and dj-vevr-se ignore both
    parameters. dj's `PFlow.swift` parses them, but nothing in `Wave/` reads them.

  Swing as implemented is also a fixed share of a 16th, not the tempo-dependent ratio measured in
  real players (Friberg & Sundström 2002), and it is not applied per voice.
- **Velocity.**
  - Drums: `accentVelocity` gives fixed metrical accents. Its "jitter" is `((step*7+13)%11)-5`, a
    fixed function of the step index. Each hi-hat grid position has **1.04 distinct velocities per
    song** on average: the same bar repeats at identical dynamics.
  - Tonal roles: median **1 distinct velocity per song**. The pad is always 68. `motifNet` binds
    every note at the track velocity; Markov melodies get beat accents, but v2 does not.
  - Ghost-note hats exist, at velocity 30–49.
- **What matters for groove.** Studies of real drum patterns find that syncopation, event density
  and accent structure drive groove ratings (Senn et al. 2018). Arbitrary microtiming does not help
  and can hurt (Davies et al. 2013). If jitter is used, listeners prefer long-range-correlated
  (1/f) fluctuation to white noise (Hennig et al. 2011). The current grid-plus-accents approach is
  defensible. The gaps are missing swing on the deterministic path and velocities that never move.

### 2.5 Arrangement density and tension/release — composed, then mostly dropped

- **Density.** Roles enter and leave per section archetype. Notes per bar vary by **2.2× on
  average** between the busiest and sparsest section (1.3–4.2×).
- **Loudness.** On the wave path, loudness hardly follows that density:

  | Song | intro | drop | breakdown | LRA |
  |---|---|---|---|---|
  | techno 42 | −14.8 | −14.6 | — | 0.7 LU |
  | house 42 | −14.9 | −14.5 | — | 0.7 LU |
  | trance 42 | −15.2 | −14.9 | **−24.6** | 0.8 LU |

  Values are section RMS in dB. The 4-on-the-floor kick dominates RMS, and nothing else changes
  level. Trance's breakdown is the one real drop in level.
- **Energy and filter data are thrown away.** Each section's `energy` / `filterOpen` (e.g. EDM
  drop 0.95 / 0.90, breakdown 0.30 / 0.25) is written as a `feel-curve` net firing `set-feel`.
  `fire-macro` (`macroCurve`) is similar. Both are `.other` actions: "reported, not applied" in
  `WaveNet.swift` and `net.js`. So the per-section energy and filter arc that cohesion v2 computes
  is heard only on the Tone path.
- **Build-ups and transitions.** A `buildup` section is just another section with a different role
  set. There is no snare-roll acceleration, riser, filter sweep or pre-drop kick removal, which
  are the standard build-up gestures (Solberg 2014). Drum fills are silent (§2.1). Stingers
  (`hit1–4`) are always muted and reserved for live use.

### 2.6 Sound design and mix — static

- **Voices.** A wave-engine tonal voice is a band-limited wavetable times a two-exponential pulse:
  attack, then decay. There is no sustain stage, no filter or filter envelope, no velocity-to-timbre
  mapping and no LFO. Only the drums have filters, and those are static. dj's extended options help
  a lot here (samplers, Karplus-Strong, per-instrument lowpass and vibrato). They do not change
  notes or form.
- **Mix.**
  - No sidechain or ducking.
  - No send reverb or delay. These are not ported in dj (ROADMAP 3.3), and the wave engine has
    none.
  - The master chain moves only when a macro is fired by hand.
- **Measured** (offline render, seed 42):
  - Side/mid is −200 dB in all 8 songs: **bit-identical mono**.
  - On drum genres, the long-term spectrum is a "smile". Relative to 1 kHz: 63–250 Hz at +19 to
    +27 dB, 8 kHz at +2 to +8 dB, 16 kHz at +6 to +12 dB. Raw high-passed-noise hats at level 0.32
    sit high. Commercial mixes converge on a falling long-term spectrum (Pestana et al. 2013).
  - Lofi and ambient have almost nothing below 125 Hz (−41 to −55 dB at 63 Hz).
  - Integrated loudness runs from −13.3 LUFS (house, techno) to −23.9 LUFS (lofi), a 10.6 LU spread
    between genres. That is a gain-staging problem the moment two decks are crossfaded.
  - Sample peaks reach −1.5 dBFS, with no limiter.

## 3. Top gaps, ranked

Ranked by how much they make a track sound unlike a real track, weighted towards what a DJ notices.

1. **Form and phrasing.** 12-bar sections, 3-bar phrases, 4-bar intros, ~110 s songs; transitions
   drift up to a beat late; fills are silent. (§2.1)
2. **Out-of-key tension variants.** A bug, audible as wrong notes in 10 genres. (§2.2)
3. **No energy arc on the deterministic path.** `set-feel` and `fire-macro` are dropped; LRA is
   under 1 LU; there are no build-up gestures. (§2.5)
4. **Static groove.** No swing or humanise on the wave path. Velocities are identical every bar.
   The Tone path's humanise is non-deterministic. (§2.4)
5. **Static harmony.** One chord loop per song; the pad is not slotted, so it ignores section
   harmony; voicing is wasteful; no extensions. (§2.2)
6. **Melody development.** Motifs start mid-cell; 54% repeated notes; no phrase grammar. (§2.3)
7. **Mix.** Mono, no sidechain, smile spectrum, a 10 LU loudness spread between genres, static
   envelopes. Partly addressed in dj by the samplers. (§2.6)

## 4. Options, ranked by impact versus effort

Every option is meant to stay deterministic: seeded draws, tables checked in, no model at play
time. Every option changes what an existing envelope sounds like, so each must ship behind a
version flag (see [Determinism](#determinism-and-versioning)).

| # | Option | Impact | Effort |
|---|---|---|---|
| 1 | Fix the three bugs (drift, fills, tension transpose) | high | low |
| 2 | Hypermetric form tables (8/16/32-bar sections, 4/8-bar phrases, DJ intros) | high | low–med |
| 3 | Play the energy arc: `set-feel` on the wave path, plus a build-up subnet | high | med |
| 4 | Deterministic groove: swing, groove templates, seeded 1/f humanise | high | med |
| 5 | Kick-keyed ducking and velocity dynamics on tonal roles | med | low |
| 6 | Section harmony: slotted pad, chord-transition tables, cadences, voice-leading search | med–high | med |
| 7 | Melody phrase grammar and phase alignment | med | med |
| 8 | Mix normalisation: LUFS targets, spectral tilt, stereo | med | low–med |
| 9 | Learned priors distilled offline into tables | med | high |
| 10 | Reference-track conditioning (offline templates) | med | high |

### 4.1 Fix the three bugs

- **Drift.** In `buildAccumulatorNet`, start `p_delay_i` at `gap − 1` for `i > 0`, or let `t_ctrl`
  share the tick with the last drain.
- **Fills.** Give each `fill-N` an unmute event at `boundary − fillLen` and a mute at the boundary
  in its `struct-fill-N` net. Since a fill is a one-shot sink chain, it could also simply not be
  muted.
- **Tension.** Make `registerShift` a diatonic or octave shift: shift degrees (`degree + k`), or
  add ±12 to the MIDI note. Do not rebuild `genre.scale(root + n)`.

**Nets/macros.** All three are local changes to net construction: `structure.js` /
`Structure.swift` and `composer.js` / `Composer.swift`.

**First experiment.** Patch the three functions in a scratch copy of beats' generator and rerun
`analyze.mjs` and `key.mjs`. Expect lateness max = 0, fill events > 0 before every boundary, and
out-of-key share = 0 outside walking-bass approach notes. Then listen to techno, trance and blues
seed 42 before and after.

### 4.2 Hypermetric form tables

- Replace `sectionSteps` with per-family length tables:
  - intro and outro: 16–32 bars, drums-forward and mixable;
  - buildup: 8–16 bars;
  - drop and chorus: 16–32 bars;
  - breakdown: 8–16 bars.
- Phrase length should be 4 or 8 bars, so A-B-A-B becomes 4 × 4 or 4 × 8.
- Distil the tables (P(next section), P(length | section)) from annotated corpora: the Harmonix
  Set (912 pop/EDM tracks with segment labels) and McGill Billboard (CC0, with phrase lengths).
  Check them in like `tables.json`.

**Nets.** No new net shape. The accumulator nets just get events at multiples of 64/128 ticks. An
optional guard (a bar-counter place with an `at bar % 8 == 0` inhibitor pattern) would make "only
on hypermetric boundaries" structural rather than a convention.

**First experiment.** Set standard to 16/32-bar sections in a scratch generator, render techno and
trance, and check that phrase lengths are all 4 or 8 bars and that songs come out at 4–6 min.

### 4.3 Play the energy arc (`set-feel`) and add a build-up subnet

- **`set-feel` on the wave path.** Implement it in dj's `WaveDeckSource` as a `MasterMacro` /
  `FxAutomation` ramp: `filterOpen` → LP/HP cutoff, `energy` → master gain or a drive offset. The
  machinery exists (`MasterChain`, `FxAutomation` on the transport clock), and the audio thread
  only reads a ramp.
- **Build-up subnet.** In the last 8 bars before any section whose energy jumps by ≥ 0.3:
  - snare or clap density doubling per 2 bars (4 → 8 → 16 → 32 per bar), which is a chain of
    rings selected by a bar counter;
  - an HP sweep;
  - a noise riser on a stinger lane;
  - the kick removed in the last bar;
  - an impact at the downbeat (Solberg 2014; Butler 2006).

  It is a generated control net plus a few music nets, the same pattern as fills.

**First experiment.** On a branch, honour `set-feel` in dj's deck source and record techno 42 offline
(`DJEngine(offline: true)`). Target a section RMS spread ≥ 6 dB between breakdown and drop and an
LRA ≥ 3 LU; it is 0.7 LU today. Calibrate the target against the reference corpus (§5).

### 4.4 Deterministic groove

- **Swing.** A per-genre swing percentage in MPC terms (50% straight, about 54–58% subtle, 66%
  triplet; Roger Linn 2013). Scale it with tempo, since the swing ratio falls as tempo rises
  (Friberg & Sundström 2002). Apply it in the runner as a sample offset per odd 16th. It is a
  constant per tick and position, computed at prepare time, so no allocation on the audio thread.
- **Groove templates.** Per genre or style, a table of (timing offset ms, velocity scale) per drum
  voice × 16th position, distilled from the Groove MIDI Dataset and E-GMD (CC BY 4.0; human
  drummers with microtiming and velocity; Gillick et al. 2019). This is how Ableton and MPC grooves
  work.
- **Humanise.** Make `humanize` seeded 1/f noise, e.g. Voss–McCartney keyed by
  `hash(seed, net, tick)`. That keeps the same CID → same render and replaces `Math.random()` on the
  Tone path. Keep it to a few ms. Davies et al. 2013 and Senn et al. 2018 warn that microtiming
  adds little, while accent and velocity structure carry the groove.

**Nets/notes.** Per-note attributes: either an `offset` field on `MidiBinding`, or a project-level
groove table the runner applies at fire time. The net topology does not change.

**First experiment.**

1. Compute a 16-position velocity and offset template for one GMD style (e.g. "funk" or "hiphop")
   offline.
2. Apply it to the drum events in the harness.
3. Render A/B with beats' offline engine after shifting onsets.
4. Check that velocity entropy per hi-hat position goes above 0 and that MusPy groove consistency
   stays at 0.9–0.99.

### 4.5 Kick-keyed ducking and tonal dynamics

- **Ducking.** A kick transition triggers a short gain envelope (−4 to −8 dB, about 100–150 ms
  release, depth per genre) on bass and pad lanes. It is a deterministic "sidechain" with no
  compressor, and allocation-free: one more exponential in the lane gain.
- **Tonal dynamics.** Use `computeVelocity`-style accents for motif notes. Make the pad velocity
  follow section energy.

**First experiment.** Render house 42 with ducking and compare the bass/pad envelope modulation at
beat rate (§5 M6).

### 4.6 Section harmony

- **Slotted pad.** Make the pad a slotted role like bass and melody, so `harmonic` offsets and
  per-section progressions apply to it.
- **Progressions.** Draw them from a chord-transition table: McGill Billboard (CC0) or the RS200
  rock corpus (CC BY 4.0). Use Markov constraints (Pachet & Roy 2011) so each phrase ends on a
  cadence (V → I, or ♭VII → i for minor EDM) at bar 4/8.
- **Harmonic rhythm.** Vary it per section: 2 bars per chord in intros and breakdowns, 1 in drops,
  2 per bar in pre-choruses.
- **Voicing.** Choose inversions with a small dynamic program minimising total semitone movement
  (Tymoczko 2011; Huron 2016). Add 7ths and 9ths per genre (jazz, lofi, house, garage).

**Nets.** The pad becomes `harmony-N` slot rings; the chord plan becomes per-section.

**First experiment.** Add the voice-leading search to the harness on the existing progressions.
Expect `vlActual` to fall from 5.6 to about 3.8 with no other change. Then add one Billboard-derived
transition table and a cadence constraint for one genre.

### 4.7 Melody phrase grammar and phase alignment

- **Phase.** Rotate each slot net's initial token to `(activationTick mod ringSize)` so that the
  cell starts at bar 1 when the slot comes in. This is a compose-time change: the net's initial
  marking moves, and runtime semantics stay the same.
- **Phrase grammar.** Build phrases over the cell: sentence form (a a′ b) or period
  (antecedent/consequent ending on a half and then full cadence).
- **Contour rules.**
  - Cap repeated notes.
  - Reverse direction by step after a leap (Narmour; Huron 2006).
  - Aim the peak note at about 2/3 of the phrase.
- **Repetition with variation.** Score it with a compression ratio or structureness index (§5).

**First experiment.** Rotate initial markings in the harness and confirm `motifPhaseOff` is 0/16.
Then cap repeats at 25% and check that the interval histogram moves toward steps.

### 4.8 Mix normalisation

- One integrated-loudness target for all decks, e.g. −14 LUFS ±1 LU, plus a true-peak ceiling of
  −1 dBTP (EBU R128 / ITU-R BS.1770). Apply it as a per-project gain computed offline from a
  render, or as a running-LUFS trim.
- A per-family long-term spectrum target from references (Pestana et al. 2013): hats down 4–6 dB at
  8–16 kHz in drum genres, a sub layer for lofi and ambient bass.
- Per-role pan or width, with mono below about 120 Hz.

**First experiment.** A gain table per genre from `audio.json`, then re-measure the LUFS spread
across genres (10.6 LU → target ≤ 2 LU).

### 4.9 Learned priors, distilled offline

- Train or count offline on Lakh MIDI (CC BY 4.0, statistics only) and the Groove MIDI Dataset.
  Distil variable-order Markov / n-gram tables (Begleiter et al. 2004) for melody degree, chord and
  bass motion per genre. Check in the tables and put their hash into the generator version.
- Larger models (Music Transformer, MusicVAE, MMM's per-track infilling, the Anticipatory Music
  Transformer) are useful **offline**, to pre-generate riff libraries indexed by seed.
- At play time the only safe pattern is the net as a constraint mask: the net enumerates enabled
  transitions or legal tokens and a pinned model ranks them. This is SymPAC-style FSM-constrained
  decoding. It needs CPU-pinned inference and golden-CID tests, because float drift across hardware
  breaks content addressing.

**First experiment.** A degree-bigram table from RS200 melodies (CC BY) replacing the uniform
−2…+2 step draw. Compare the pitch-class transition matrix to the corpus (Yang & Lerch overlap
area).

### 4.10 Reference-track conditioning, offline only

Use these tools to turn a reference set into checked-in templates, not transcriptions:

- Beat This! or madmom for the grid.
- HT-Demucs for stems.
- Basic Pitch for MIDI.
- A chord recogniser.

The templates are groove (per-position offset and velocity), form (section lengths), long-term
spectrum and LUFS targets. Averaged templates avoid both the licensing problem and the
"cloned riff" problem.

**First experiment.** Extract the form and long-term spectrum of 20 reference tracks per family as
the calibration set for the §5 metrics.

## 5. Suggested metrics, as deterministic tests

All of these run on compose output through the net executor, as this harness does. In dj they can
be Swift tests on `DJEngine(offline: true)` renders. They are pure functions of (genre, seed), so
they can gate generator changes.

| # | Metric | Today | Target (to calibrate on references) |
|---|---|---|---|
| M1 | **Phrase alignment**: every slot or mute event at `tick % (16·4) == 0`, with lateness 0 | max lateness 11–19 ticks; phrases of 1/2/3/6 bars | lateness 0; phrases 4 or 8 bars; intro/outro ≥ 16 bars |
| M2 | **Scale consistency** (MusPy) per role, excluding tagged approach notes; strong-beat chord-tone share | down to 25–64% in tension genres; 0.41–1.0 | ≥ 0.97; ≥ 0.8 |
| M3 | **Arrangement contrast**: max/min section notes per bar; section RMS spread; LRA | 2.2×; 0.3 dB; 0.7 LU | ≥ 2×; ≥ 6 dB breakdown vs drop; LRA ≥ 3 LU (EDM family) |
| M4 | **Repetition with variation**: distinct bars / sounding bars; deflate ratio of the bar-relative token stream; structureness (Wu & Yang 2020) | 0.60; 0.05; — | within the reference-corpus band (both "one loop forever" and "no repetition" fail) |
| M5 | **Fills/transitions**: notes in the last bar before each boundary that differ from the section's loop | 0 | ≥ 1 per boundary with an energy change |
| M6 | **Groove**: distinct velocities per drum position; MusPy groove consistency; measured swing ratio vs target | 1.04; —; 0 | > 1; 0.9–0.99; within ±2% of the genre target |
| M7 | **Mix**: integrated LUFS spread across genres; true peak; long-term spectral slope 63 Hz–8 kHz; side/mid; beat-rate ducking depth on bass/pad | 10.6 LU; −1.5 dBFS sample peak; −2.4 to −4 dB/oct on drum genres (positive on lofi/ambient) with a +6–12 dB 16 kHz bump; −200 dB; 0 | ≤ 2 LU; ≤ −1 dBTP; falling slope, no HF bump; > −20 dB for wide genres; genre-dependent |
| M8 | **Corpus distance** (nightly, not unit): Yang & Lerch pitch-class / IOI / note-length overlap areas vs a per-genre reference set; optionally FAD-∞ on renders (Gui et al. 2023, not plain FAD) | — | trend only |

M1, M2 and M5 would have caught all three bugs and are trivial to write, since this harness already
computes them.

## Determinism and versioning

The CID addresses the **share envelope** (genre, seed, parameters), not the audio. Any generator
change therefore changes what an already-published CID sounds like.

- Every option above should be gated behind an envelope field, following the existing pattern:
  `cohesion: "v2"` already selects the theme engine. A `cohesion: "v3"` (or `form` / `groove`
  keys) can carry the bug fixes and new tables, with v2 kept byte-identical for old shares.
- The JS generator stays canonical. If dj builds an improvement first, it keeps it and the change
  is backported to beats (GO-DIVERGENCE.md §5).
- Tables distilled from corpora are checked in (like `tables.json`) and their hash is part of the
  version.
- Separately: the Tone path's `Math.random()` humanize already makes farm renders of one CID differ
  run to run. Seeding it (§4.4) restores "same CID, same audio" there too.

## Sources

Form and structure
- M. J. Butler, *Unlocking the Groove: Rhythm, Meter, and Musical Design in Electronic Dance Music*, Indiana UP, 2006.
- R. T. Solberg, "'Waiting for the bass to drop': correlations between intense emotional experiences and production techniques in build-up and drop sections of EDM", *Dancecult* 6(1), 2014.
- O. Nieto et al., "The Harmonix Set: beats, downbeats, and functional segment annotations", ISMIR 2019 — https://github.com/urinieto/harmonixset
- T. Kim et al., "A computational analysis of real-world DJ mixes using mix-to-track subsequence alignment", ISMIR 2020 — https://arxiv.org/abs/2008.10267
- K. Yadati et al., "Detecting drops in electronic dance music", ISMIR 2014 — https://archives.ismir.net/ismir2014/paper/000297.pdf
- J. A. Burgoyne, J. Wild, I. Fujinaga, "An expert ground truth set for audio chord recognition and music analysis" (McGill Billboard), ISMIR 2011 — https://ddmal.music.mcgill.ca/research/The_McGill_Billboard_Project_(Chord_Analysis_Dataset)
- F. Lerdahl, R. Jackendoff, *A Generative Theory of Tonal Music*, MIT Press, 1983.
- M. Rohrmeier, "Towards a generative syntax of tonal harmony", *J. Math. & Music* 5(1), 2011 — https://doi.org/10.1080/17459737.2011.573676
- M. J. Steedman, "A generative grammar for jazz chord sequences", *Music Perception* 2(1), 1984.
- F. Pachet, P. Roy, "Markov constraints: steerable generation of Markov sequences", *Constraints* 16(2), 2011 — https://link.springer.com/article/10.1007/s10601-010-9101-4
- R. Begleiter, R. El-Yaniv, G. Yona, "On prediction using variable order Markov models", *JAIR* 22, 2004 — https://arxiv.org/abs/1107.0051
- M. Farbood, "A parametric, temporal model of musical tension", *Music Perception* 29(4), 2012.

Harmony, voice leading, melody
- T. de Clercq, D. Temperley, "A corpus analysis of rock harmony", *Popular Music* 30(1), 2011 — https://rockcorpus.midside.com/
- D. Tymoczko, *A Geometry of Music*, OUP, 2011.
- D. Huron, *Voice Leading: The Science behind a Musical Art*, MIT Press, 2016; *Sweet Anticipation*, MIT Press, 2006.
- E. Narmour, *The Analysis and Cognition of Basic Melodic Structures*, U. Chicago Press, 1990.
- D. Herremans, E. Chew, "MorpheuS: generating structured music with constrained patterns and tension", *IEEE Trans. Affective Computing*, 2017 — https://arxiv.org/abs/1812.04832

Groove and humanisation
- A. Friberg, A. Sundström, "Swing ratios and ensemble timing in jazz performance", *Music Perception* 19(3), 2002.
- R. Linn interview on MPC swing, Attack Magazine, 2013 — https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/
- J. Gillick, A. Roberts, J. Engel, D. Eck, D. Bamman, "Learning to groove with inverse sequence transformations" (GrooVAE, Groove MIDI Dataset), ICML 2019 — https://arxiv.org/abs/1905.06118
- L. Callender, C. Hawthorne, J. Engel, "Improving perceptual quality of drum transcription with the Expanded Groove MIDI Dataset", 2020 — https://arxiv.org/abs/2004.00188
- H. Hennig et al., "The nature and perception of fluctuations in human musical rhythms", *PLoS ONE* 6(10), 2011 — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3202537/
- M. Davies, G. Madison, P. Silva, F. Gouyon, "The effect of microtiming deviations on the perception of groove in short rhythms", *Music Perception* 30(5), 2013.
- O. Senn et al., "Groove in drum patterns as a function of both rhythmic properties and listeners' attitudes", *PLoS ONE* 13(6), 2018 — https://pmc.ncbi.nlm.nih.gov/articles/PMC6025871
- Ableton Live manual, "Using Grooves" — https://www.ableton.com/en/live-manual/12/using-grooves/

Learned priors and datasets
- C.-Z. A. Huang et al., "Music Transformer", 2018 — https://arxiv.org/abs/1809.04281
- A. Roberts et al., "A hierarchical latent vector model for learning long-term structure in music" (MusicVAE), ICML 2018 — https://arxiv.org/abs/1803.05428
- Y.-S. Huang, Y.-H. Yang, "Pop Music Transformer" (REMI), ACM MM 2020 — https://arxiv.org/abs/2002.00212
- J. Ens, P. Pasquier, "MMM: exploring conditional multi-track music generation with the Transformer", 2020 — https://arxiv.org/abs/2008.06048
- J. Thickstun et al., "Anticipatory Music Transformer", 2023 — https://arxiv.org/abs/2306.08620
- SymPAC: "Scalable symbolic music generation with prompts and constraints", ISMIR 2024 — https://arxiv.org/abs/2409.03055
- C. Raffel, Lakh MIDI Dataset, 2016 — https://colinraffel.com/projects/lmd/

Reference conditioning
- F. Foscarin et al., "Beat this! Accurate beat tracking without DBN postprocessing", ISMIR 2024 — https://arxiv.org/abs/2407.21658
- S. Rouard, F. Massa, A. Défossez, "Hybrid Transformers for music source separation" (HT-Demucs), 2022 — https://arxiv.org/abs/2211.08553
- R. Bittner et al., "A lightweight instrument-agnostic model for polyphonic note transcription and multipitch estimation" (Basic Pitch), ICASSP 2022 — https://arxiv.org/abs/2203.09893

Metrics and mix
- L.-C. Yang, A. Lerch, "On the evaluation of generative models in music", *Neural Computing & Applications* 32, 2020 — https://doi.org/10.1007/s00521-018-3849-7
- H.-W. Dong et al., "MusPy: a toolkit for symbolic music generation", ISMIR 2020 — https://arxiv.org/abs/2008.01951
- S.-L. Wu, Y.-H. Yang, "The Jazz Transformer on the front line" (structureness indicator), ISMIR 2020 — https://arxiv.org/abs/2008.01307
- C. Louboutin, D. Meredith, "Using general-purpose compression algorithms for music analysis", *JNMR* 45(1), 2016.
- K. Kilgour, M. Zuluaga, D. Roblek, M. Sharifi, "Fréchet Audio Distance: a reference-free metric for evaluating music enhancement algorithms", Interspeech 2019 — https://arxiv.org/abs/1812.08466; A. Gui et al., "Adapting Fréchet Audio Distance for generative music evaluation", 2023 — https://arxiv.org/abs/2311.01616
- P. Pestana, Z. Ma, J. Reiss, A. Barbosa, D. Black, "Spectral characteristics of popular commercial recordings 1950–2010", AES 135th Convention, 2013 — https://aes2.org/publications/elibrary-page/?id=17010
- EBU R 128, "Loudness normalisation and permitted maximum level of audio signals" — https://tech.ebu.ch/publications/r128
- R. Brøvig-Hanssen, B. E. Sandvik, J. M. Aareskjold-Drecker, "Dynamic range processing's influence on perceived timing in electronic dance music", *MTO* 26(2), 2020 — https://www.mtosmt.org/issues/mto.20.26.2/mto.20.26.2.brovighanssen.html

Citations were checked by web search on 2026-10-12. Sources given without a URL are cited by
venue and year only.
