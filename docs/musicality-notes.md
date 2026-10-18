# Musicality notes

Written 2026-10-12 (overnight run, branch `val/dj-musicality-2026-10-12`). Part 1 is how a
track is made today and what is measurably wrong with it. Part 2 (at the end) is what was
changed, with before/after numbers.

## 1. How a track is generated

A deck's track is a `TrackSpec` (genre, seed, structure size, cohesion), composed by
`compose()` (`Sources/DJCore/Beats/Generator/Composer.swift`), a byte-for-byte port of beats'
JS generator: the same spec gives the same project and the same model CID as beats. The app
composes with cohesion `v2` and structure `standard` by default.

1. **Genre table** (`Resources/beats/tables.json`): tempo, root note, scale, euclidean drum
   patterns (`[hits, steps, rotation, note]`), densities, `swing`, `humanize`,
   `tensionCurve`, chord progressions, phrase patterns, section energy profiles.
2. **Theme** (`Theme.swift`, cohesion v2): from (genre, seed) a 4-chord plan (one chord per
   bar), a 4-bar motif (6–8 hits per bar, a random walk of ±2 scale degrees between beats,
   beat notes snapped to the bar's chord), a groove template per genre, and an energy
   profile per section.
3. **Parts**, each a ring net of 16-step bars whose transitions carry MIDI bindings:
   - drums: euclidean kick / snare / hihat (ghost notes and accent velocities on the hats);
   - bass: `chordBassRing` — the chord's root, on the steps of the groove mask (for
     groove 0, the kick's own steps), at `genre.rootNote` (C3 for most genres);
   - melody: `motifNet` — the motif's scale degrees in the octave above the root;
   - harmony: `chordPadNet` — the chord's three tones, struck one sixteenth apart, from
     `genre.rootNote` (the same octave as the bass);
   - arp (edm / trance / synthwave): a euclidean melodic ring two octaves up;
   - stingers: one-shot accents, muted until fired.
4. **Structure** (`Structure.swift`): a blueprint of sections (intro, buildup, drop,
   breakdown, …; 4 or 12 bars each in `standard`), each split into phrases (`A B A B`).
   Every phrase letter of a melodic role becomes its own "slot" net (`bass-3`, `melody-5`);
   with the genre's `tensionCurve`, B and C variants are denser / sparser and shifted in
   register. Control nets (`struct-*`) switch slots and mute / unmute roles at phrase and
   section starts; a `feel-curve` net drives the master filter per section.
5. **Playback** (`Wave/WaveRunner.swift`): one tick per sixteenth. Drums are noise / sine
   sweep voices; tonal parts are wavetable voices (saw / soft / sine / bell / square) with an
   exponential decay over the note's length, or sampled instruments (Logic / GarageBand EXS,
   SoundFonts) chosen per role by `VoiceCatalog`. All synth lanes are summed mono and go
   through `tanh(sum × 0.8)`; sampled instruments are added after that curve. The master
   chain (filters, FX macros) follows.

## 2. Why it sounds unmusical — measured

Tooling added for this (both run headless, nothing on the speakers):

- `djctl render <genre> <seed> [--structure S] [--seconds N] [--out f.wav] [--notes f.txt]
  [--synth]` composes as a deck does, renders through the deck's net source offline, and
  prints a `MusicalityReport` (from the note log) and `AudioMetrics` (from the audio).
- `scripts/musicality-matrix.py OUTDIR [--sampled]` renders 12 genres × 2 seeds (75 s each)
  and adds integrated loudness from ffmpeg's `ebur128`; `--compare A B` diffs two runs.

Baseline, synth voices, `standard` structure (means over the 24 tracks; sampled renders agree
within a dB and on every note metric):

| metric | baseline | what it means |
|---|---|---|
| notes in key | 0.93 (six genres at 0.84–0.91) | B/C section variants play in another key |
| bass on the chord root | 0.71 (edm / trance / dnb / dubstep / jazz / ambient ≈ 0.5) | same cause |
| part changes on a bar line | 0.11–0.16 | structure changes drift off the grid |
| harmony inside the bass's range | 0.97 | pad and bass share one octave |
| bass onsets on a kick | 1.0 for techno / synthwave, 0.6–0.9 for most dance genres | kick and bass collide |
| melody velocity spread | 0 in 9 of 24 tracks, ~6 elsewhere | every note equally loud |
| semitone rubs per 100 overlapping pairs | 4.9 (jazz 10–12) | parts grinding |
| integrated loudness | −25.5 … −12.9 LUFS | 12 LU between genres |
| sampled renders over 0 dBFS | trance-7: +0.4 dB, 6 clipped samples | samplers bypass the master curve |
| energy above 2 kHz | 1–3 % for the dance genres | dull, all low end |

The causes, biggest first:

1. **Tension variants change key, not register.** `expandVariants` adds the variant's
   `registerShift` (+2 for B, −3 for C semitones) to the root and *rebuilds the scale on
   that root*. Every B section plays bass, melody and arp a whole tone up, every C section a
   minor third down, over a pad that stays in the home key. This is the single largest source
   of wrong notes (all out-of-key notes in the logs come from odd-numbered slots), and why the
   bass is on the chord root only half the time in those genres.
2. **Structure changes drift.** `buildAccumulatorNet` gives every event after the first a
   delay of `gap` ticks plus the one tick its gate needs, so each change lands one sixteenth
   later than the one before. By the third section the bass and melody switch 2–3 sixteenths
   after the bar line, and after the drums (whose control net has had fewer events). Phrase
   lengths are also `section ÷ phrases`, which gives 3-bar phrases in 12-bar sections, so
   variants switch mid-way through the 4-bar chord cycle.
3. **Register.** Bass at `rootNote` (C3, 130 Hz — a cello's range, not a bass's) and the pad
   built from the same `rootNote`: the chord tones sit in or under the bass line and turn
   into low-mid mud; the melody is only an octave above.
4. **Gain staging.** Every synth lane is summed and pushed through `tanh(×0.8)`: busy genres
   sit permanently in the curve (−13 LUFS with −1 dB peaks, i.e. squashed), sparse ones
   come out 10 dB quieter. Sampled instruments are added after the curve and can go over
   full scale.
5. **No groove.** The project's `swing` and `humanize` (jazz 60, blues 50, lofi 35 …) are
   carried but never applied by the wave engine; bass, pad and melody notes all have the
   same velocity, so nothing is accented and there are no phrase dynamics.
6. **Kick and bass on the same steps.** With groove template 0 (four-on-the-floor, 11
   genres) the bass is locked to the kick: two low sounds starting together on every beat,
   with nothing ducking either.

What is already right and stays: one chord plan shared by bass, pad and melody; melody beat
notes snapped to chord tones (chord tones on beats 0.98 in-key genres); a 4-bar motif that
recurs (0.55–0.86 of bars repeat a bar 4 or 8 earlier); sections whose lengths are whole
4-bar multiples; drum accents and ghost notes.

## Where the fixes live

`compose()` stays beats' exactly: shares, sessions and model CIDs mean the same thing in both
apps, and the parity fixtures stay green. The fixes are a dj pass (`DJMusicality`) that
`PreparedTrack` runs over the composed project before the deck plays it — it rewrites
bindings and markings, never net topology, so the net views, section jumps and recorded
sessions all see the same nets — plus render-side changes in the runner under
`WaveOptions.extended`. `WaveOptions()` (the parity path) is untouched. Where a fix is a
beats bug (1, 2), it goes on GO-DIVERGENCE.md §5 to backport.

## 3. What changed (2026-10-13)

Each fix is one `DJMusicality.Fixes` flag, all on in `WaveOptions.extended` (what the app
plays) and off in `WaveOptions()` (parity: every beats fixture still passes). `djctl render
--fixes none|all|key,timing,…` renders any combination, for A/B listening.

| fix | what it does | where |
|---|---|---|
| `.key` | B / C tension variants moved back into the home key | pass, bindings |
| `.timing` | every structure change fires on the last sixteenth before its bar (no drift, no lost downbeats) | pass, control-net markings |
| `.phrases` | phrase switches on 2 / 4-bar lines (12 bars = 4 + 4 + 2 + 2, not 3 × 4) | pass, control-net markings |
| `.register` | bass median ≤ A2 (≥ E1), pad clear of the bass with its median ≥ F3, melody / arp above the pad; octaves only | pass, bindings |
| `.offbeatBass` | four-on-the-floor dance genres (techno, edm, trance, speedcore): bass on the off-beat eighth | pass, bindings |
| `.dynamics` | bass / melody / arp / pad accented by meter, each melody bar's peak note leaned on | pass, bindings |
| `.groove` | the project's swing and humanize, as beats' browser plays them, deterministic | runner |
| `.loudness` | per-track gain to one loudness (measured from the drop, K-weighted); samplers inside the master curve | runner |

Before → after, 12 genres × 2 seeds, 75 s each, `standard` structure (`scripts/
musicality-matrix.py`; synth voices; sampled renders in brackets):

| metric | before | after |
|---|---|---|
| tonal notes in key | 0.93 | 0.99 (the rest: walking-bass chromatic approach notes) |
| bass on the chord root at each bar | 0.71 | 1.00 |
| part changes in effect at a bar line | 0.13 | 1.00 |
| part changes on a 2-bar line from the section start | 0.66 | 1.00 |
| pad notes inside the bass's range | 0.97 | 0.00 |
| bass onsets on a kick | 0.54 (techno 1.00) | 0.27 (techno 0.00; the rest are genres whose groove is meant to) |
| semitone rubs per 100 overlapping pairs | 4.9 | 2.8 |
| melody velocity spread | 3.7 | 8.2 |
| melody bars recurring 4 / 8 bars later | 0.63 | 0.84 |
| integrated loudness range across genres | −25.5 … −13.0 LUFS (sampled −25.3 … −12.9) | −18.1 … −14.3 (sampled −17.1 … −12.6) |
| clipped samples | 0 (sampled: 6, trance-7 at +0.4 dBFS) | 0 (sampled 0) |
| swing / humanize | ignored | off-beat 16ths late by swing% × ½ tick, ± jitter |

Tests that hold these: `MusicalityTests` (every note in key, bass on the root, downbeats
and bar lines, phrase grid, registers, accents, offbeat bass, loudness, the pass keeping
the net topology and `compose()` untouched) and `GrooveTests` (swing and humanize measured
from rendered audio; allocation-free in release).

Not done, next candidates:

- Energy above 2 kHz is still 2–3 % in the dance genres (hats at −10 dB under the kick, saw
  voices with no filter envelope): a brightness / sound-design pass, by ear.
- The loudness probe hears synth voices only, so sample-heavy genres (lofi, jazz, bossa)
  come out ~2 LU hot when sampled instruments load.
- The semitone-rub metric counts pitch classes across any octave distance; a bass note and
  a melody passing tone three octaves apart count as a rub.
- Section contrast (busiest / quietest notes per bar) is unchanged at 2.4; the arrangement's
  energy curve is beats' and untouched.

## 4. Visual polish (part B)

`DJStyle` (spacing scale, card, deck tints for the dark window, small-caps section labels, a
rounded monospaced readout font). Decks and mixer sit on cards (deck cards carry their tint
along the top); the deck header is a letter badge + the track title as the headline + what
it is underneath; position and BPM read large; play / pause is a round button that fills
with the tint while playing; cue + four small hot cues share its row; Song / Perform /
Channel group the rest; the platter's beat dot eases; the app's windows are dark. Offscreen
before / after renders: `WindowShotTests` with `DJ_SHOT_DIR` (AppKit sliders, menus and
bordered buttons draw as yellow placeholders offscreen; the custom views are exact).

## 5. Part C (2026-10-13, run b5b3bf39): form, harmony, mix

Built on part A/B (merged from `val/dj-musicality-2026-10-12`). Six more `Fixes` flags, all in
`.all` (so `WaveOptions.extended`), all off on the parity path. The pass now also *adds*
bindings to free steps of the pad (`.color`), still never places / transitions / arcs.

| fix | what it does | where |
|---|---|---|
| `.fills` | the `fill-N` nets beats builds before every section change and never plays (muted, `control` role, toms with no voice) sound as a snare roll that swells into the change | pass (bindings, `initialMutes`) + runner voices `fill-*` |
| `.voicing` | pad chords re-voiced by octaves to the cheapest cycle of chord changes inside the pad's range (no semitone clusters) | pass |
| `.energy` | the composer's per-section `energy` / `filterOpen` (the `feel-curve` net) played: section level against what it already plays (probed like `Loudness`; peak section at unity, a thinned breakdown lifted ≤ 4 dB), a lowpass on the tonal voices only (drums stay full-band, intros stay mixable), buildups sweeping up into the next section | `EnergyCurve`, runner |
| `.duck` | bass and pad dip on each kick (2 ms attack, back within an eighth): depth 0.5 under four-on-the-floor dance kicks, 0.35 broken dance beats, 0.4 synthwave, 0 elsewhere | runner (synth lanes and their sampler slots) |
| `.contour` | an off-beat melody note repeating the one before steps to a scale neighbour towards the next note, never a semitone against the bar's pad chord; beat notes stay | pass |
| `.color` | jazz, bossa, house, garage, funk pads play sevenths (the scale's seventh, struck after the triad) | pass |

Tried and dropped: rotating slot rings so a phrase enters at its motif's first note. Slot
rings are locked to the pad's 4-bar chord cycle, so a slot entering on a 2-bar line *should*
play the second half of its cell; rotating it would put the bass on the wrong root.
`slotsFromTheTop` stays in the report as information.

New measurements (`MusicalityReport`, `djctl render`, the matrix): `fillsBeforeSections`,
`slotsFromTheTop`, `padMotion` (semitones per chord change), `padColor` (chords with ≥ 4 pitch
classes), `melodyRepeats` / `melodySteps`, per-section RMS and `sectionSpreadDB`, and ffmpeg's
loudness range (LRA). `djctl render --fixes` names come from `DJMusicality.Fixes.named`.

Before → after, 12 genres × 2 seeds, whole songs (`--seconds 300`), synth voices; sampled in
brackets:

| metric | before (part B) | after |
|---|---|---|
| section changes with a fill in the bar before | 0 | 1.00 |
| pad motion per chord change (semitones, 3-voice chords) | 5.6 | 4.0 |
| pad chords with a seventh (jazz/bossa/house/garage/funk) | 0 | 0.75–1.00 |
| melody intervals that repeat the pitch | 0.54 | 0.29 |
| semitone rubs per 100 overlapping pairs | 2.8 | 2.7 |
| section level spread, min … max | 0.2 … 13.8 dB (0.3 … 13.0) | 3.5 … 9.2 dB (2.8 … 8.4) |
| loudness range (LRA), mean / min | 2.4 / 0.6 LU (2.2 / 0.6) | 4.7 / 2.6 LU (4.7 / 2.5) |
| integrated loudness, range | −18.0 … −13.9 LUFS | −19.6 … −15.3 (the peak section is unchanged; quieter intros and breakdowns pull the integral down ~1.3 dB) |
| clipped samples | 0 (0) | 0 (0) |
| in key, bass on root, changes on bars / 2-bar lines | 0.99, 1.00, 1.00 / 1.00 | unchanged |

Examples, seed 42: techno's sections were 0.2 dB apart and are now intro −5, buildup −1.6,
drop 0, verse −3 dB; trance's breakdown was 12 dB under the drop (pads alone) and is 8 dB;
ambient's pad moved 8.6 semitones per change and moves 4.0.

Tests: `MusicalityTests` (fills, voicing, contour, colour; topology allows harmony bindings to
grow), `EnergyTests` (curve shape, rendered contour, loops/parity untouched),
`DuckTests` (pad −6 dB just after a kick, back before the next; depth 0 bit-identical),
`EnergyRealTimeTests` / `DuckRealTimeTests` (release: no allocation). `make swift-rt-test`
green.

### Listen checklist (`make run-app-release`, or `djctl render <g> 42 --out f.wav`)

- trance / edm 42: a snare roll swelling into each drop; the buildup's pads opening up into the
  drop; the breakdown darker and quieter but not buried; bass and pad pumping on the kick.
- techno 42: the intro clearly under the drop (drums crisp, pads muffled), then the drop.
- jazz / bossa 7: sevenths in the pad, and the melody moving by step instead of hammering one note.
- house 42: seventh chords + pump; check the 7th never sits in the bass.
- `--fixes all` vs `--fixes key,timing,register,dynamics,loudness,groove,offbeatBass,phrases`
  (part B only) for A/B.

### Visual (part C)

Stinger rings (hit1–4) moved from the parts' grid to a short row of small rings; the section
timeline's playhead is drawn under the labels with caps at both edges. (Initials in 4-bar
intro / outro blocks were tried and taken out: SPEC mode 24, beats' `renderTimeline`, leaves
blocks of 28 pt or less unlabelled, and `StructureStripTests` holds the port to it.)

### Next ideas

- Stereo: everything is bit-identical mono. Per-part pan (hats, arp, melody off-centre, bass
  and kick centre) and a wide pad, mono below ~120 Hz; measure side/mid.
- DJ-length intros / outros (16–32 bars, drums only) — needs the control nets' delays *and* the
  section lengths changed, so it belongs in beats' structure tables (GO-DIVERGENCE §5).
- Section harmony: a per-section progression (the pad is one unslotted ring), cadences at
  phrase ends, harmonic rhythm per section.
- Hats: the "smile" spectrum (raw high-passed noise at 0.32) — a brightness / hat-level pass by ear.
- Build-up gestures beyond the sweep: snare density doubling, kick dropped in the last bar.
- `Loudness.targetDB` could rise ~1 dB to put integrated loudness back near −16 LUFS now that
  non-peak sections sit lower (check jazz's −0.3 dBFS peak first).

## 6. Part D (2026-10-13, run 9ff0e9f8): parts that do their job, gestures, stereo

Built on part C (merged from `val/run-b5b3bf39`, a fast-forward). Six more `Fixes` flags, all in
`.all`, all off on the parity path. Found by reading note logs bar by bar
(`djctl render … --notes`), not just the matrix: the arp in every section-structured
synthwave / trance / edm song was the melody again, and the bass jumped an octave-ish at
every chord change.

| fix | what it does | where |
|---|---|---|
| `.arpeggio` | arp slots play the bar's pad chord, rising through five chord tones in sixteenths (eighths in a C variant), in the arp's own register; bars the composed slot left silent stay silent. beats builds arp slots from the melody's motif, so the arp doubled the lead (unison in synthwave, an octave under in trance) | pass (rebinds the arp ring's steps) |
| `.buildup` | every `buildup` section rolls into what follows: a snare roll over its last 8 bars at quarters → eighths → sixteenths, velocity rising (quadratically) from 36 to the fill's peak | pass, on the `fill-N` net ending at the buildup (its chain spans the song up to there) |
| `.crash` | a crash on the downbeat of every section after the first, loudest into a drop / chorus, softer outside the dance genres; a crash voice (highpassed noise, 0.7 s tail) instead of beats' 0.1 s open hat for note 49 | pass (the next section's fill chain) + runner voice |
| `.bassLine` | each bass bar moved by octaves to the cheapest cycle of motion between roots, E1 up to A2 (or the part's top) and under the pad; also lifts bars `.register` left under E1 (techno 42 sat on C1, 33 Hz) | pass |
| `.openHats` | four-on-the-floor dance genres (techno, house, edm, trance, speedcore): the hats on each beat's off-beat eighth become open hats (note 46, voiced as beats' open hat) | pass + runner key |
| `.stereo` | mid/side pan per lane: hats +0.3, crash −0.3, pad voices ±0.5 and arp voices ±0.45 alternating (a wide chord, a ping-pong arp), kick / snare / bass / lead centre. A voice's spread narrows with pitch (centred at E3 and below, full from G4), and the sampler bus's side is highpassed at 150 Hz (EXS samples are stereo, basses too). left + right = 2 × the mono mix before the curve | runner (`stereoPlacement`, `SideHighpass`) |

Before → after, 12 genres × 2 seeds, whole songs, synth voices. "Before" is the same djctl with
part C's 14 fixes only (`--fixes key,…,color`), so every measure has a value on both sides:

| metric | before (part C) | after |
|---|---|---|
| arp notes that are tones of the bar's chord (trance / edm / synthwave) | 0.80 | 1.00 |
| arp notes doubling the melody's pitch class at the same moment | 0.86 | 0.09 |
| buildups whose last 8 bars roll faster and faster | 0 | 1.00 |
| section starts with a crash | 0 | 1.00 |
| bass motion at chord changes, mean semitones | 5.5 (techno 11, synthwave 7.4) | 3.4 (techno 1, synthwave 4.6) |
| energy above 2 kHz, % (mean; four-on-the-floor genres) | 5.2 (techno 1.8–2.1, edm 2.0–3.3, trance 2.4–3.6) | 6.7 (techno 4.1–5.0, edm 4.7–7.2, trance 5.6–8.2) |
| side / mid, dB | mono (−∞) | −19.0 (dance −17 … −27, jazz / lofi / ambient −8 … −14) |
| side / mid below 150 Hz, dB | mono | −38.8 mean, −26 worst (ambient 42); sampled jazz 42 −8.6 → −16.4 |
| semitone rubs per 100 overlapping pairs | 2.7 | 2.4 |
| integrated loudness, mean | −17.2 LUFS | −16.9 (crashes, open hats; peaks −2.6 → −2.2 dBFS) |
| clipped samples (synth; sampled jazz 42) | 0 (0) | 0 (0) |
| in key, bass on root, changes on bars / 2-bar lines, fills | 0.99, 1.00, 1.00 / 1.00, 1.00 | unchanged |

Audio at the section edges (`edm 42`, 0.5 s after vs before each section start, > 4 kHz): +2 …
−4.7 dB without the crash, +1.2 … +7.5 dB with it, peaks within 0.5 dB.

Tests: `MusicalityTests` `arpPlaysTheChords`, `buildupsRollIntoTheDrop`,
`sectionsStartWithACrash`, `bassStepsBetweenRoots`, `offbeatHatsOpen` (each also checks the
fix's "before" really was wrong); `StereoTests` (kick bit-identical in both channels, hats right,
pad wide, mono sum = mono mix, `.stereo` off is mono, trance / lofi / jazz wide above and below
−30 dB side under 150 Hz, the sampler side highpass), `StereoRealTimeTests` (release: no
allocation). `make swift-rt-test` green.

Test runs: the final full `make swift-test` passed 1829 of 1830. The one failure,
`MasterFlameMixerTests.theMixerMeterLeavesTheIdleLineWhenADeckPlays`, was bisected to
`.openHats`: open hats light the meter's middle bins, and the test found the meter box by the
dark rows of that column. Its box detection was fixed and it passes. An earlier full run had a
test process die (signal 5) with `SamplerTests.aFullBankEvicts…` and
`SessionTests.theReplayIsTheSameAudioAsTheLiveSet` failing. Both suites pass alone (33/33) and
passed in the final full run; they load AUSamplers, so it looks like contention under parallel load.

### Listen checklist (`make run-app-release`, or `djctl render <g> <seed> --out f.wav`)

- synthwave 42 / trance 42, any section with the arp: a chord arpeggio under the lead, bouncing
  left-right, instead of the lead doubled.
- edm 42 / trance 42 buildups: the snare roll speeding up through the last 8 bars, then a crash
  on the drop's downbeat.
- house 42 / techno 7: off-beat open hats ("tss") between kicks, leaning right.
- techno 42: the bass is now C2/B1 (it was C1, felt more than heard) and steps a semitone.
- trance 42: the bass steps A1 → F1 → G1 → A1 instead of A1 → F2 → G2 → A1.
- headphones, any genre: pads wide, kick and bass dead centre; fold to mono and nothing
  disappears.
- `--fixes all` against `--fixes key,timing,register,dynamics,loudness,groove,offbeatBass,phrases,fills,voicing,energy,duck,contour,color` for A/B.

### Visual (part D)

Net rings: a loud step's flash (2.4 × base round a dot 6 pt in) ran over the role label under
the ring and the ring beside it, on 8-step rings especially (techno / house hats). The grid now
pads each ring by the most any ring overflows (`RingGeometry.maxOverflow`); labels are 10 pt,
medium while the part plays. `NetRingsTests.aFlashStaysInsideItsCell`.

### Next ideas

- Sampled instruments' stereo between 150 and 300 Hz (stereo piano / pad samples) is still
  wide (sampled jazz: side −16 dB under 150 Hz in a fourth-order measurement); a per-category
  width (keys and pads wide, bass mono outright) would place them as the synth lanes are.
- Arp patterns per genre (trance up-down sixteenths, synthwave eighths with octave jumps) and
  an arp that follows a phrase's density curve rather than a fixed rate.
- Pre-drop gap: the last beat before a drop with kick and bass cut. It needs a bar-specific
  mute, and ring nets repeat every bar, so the cut would have to come from the runner
  (EnergyCurve knows the section edges).
- Ambient 42's low side (−26 dB): its pad reaches down to C3 with long tails; a narrower
  spread there, or width by genre.
- Choke the open hat with the next closed hat (a real hat's pedal) instead of letting it ring
  over.
- Section harmony and cadences (part C's list) are still open.

## 7. Part E (2026-10-13, run e7cdf25f): phrasing, the drop, a room

Built on part D (merged from `val/run-9ff0e9f8`, a fast-forward). Six more `Fixes` flags, all in
`.all`, all off on the parity path. Chosen by reading note logs again: every melody note in every
genre was a sixteenth long (`durationSteps` 1: a line of quarter notes is four blips), phrases
ended on whatever passing tone the motif walk left, funk 42's bass hammered one root per bar
and leapt at each change, nothing marked the moment before a drop, and the whole engine is dry.

| fix | what it does | where |
|---|---|---|
| `.legato` | each melody note lasts until the next note of its ring, at most a beat (`legatoMax`); onsets, pitches, velocities unchanged | pass |
| `.cadence` | a melody phrase end — a note followed by half a bar of rest, or the last note before a 2-bar line of its ring — moves to the nearest tone of the bar's pad chord (≤ a fourth; the root, a falling step and not the note before win ties) | pass |
| `.approach` | where a bass bar moves (≥ 3 notes) and the next bar has another root, its last note (second half of the bar) becomes the scale step next to that root, from the side the line comes from. Not in the offbeat-bass dance genres (their one-note pulse is the style) nor jazz (already walks) | pass |
| `.dropGap` | the last beat of every buildup / pre-chorus that lands on a drop / chorus: kick, snare, hats and bass lanes skip their hits; the fill roll, the crash and the pads play on, so the drop's downbeat comes out of a gap | runner (`DJMusicality.dropGaps`, `WaveProject.gaps`, `Lane.gapped`) |
| `.choke` | a hihat net's closed hat cuts its open hat off (10 ms), as a hat pedal does | runner (`Lane.choke`) |
| `.space` | a send reverb: 8-line feedback delay network (`Space.swift`), per runner, buffers allocated at init. Pads 0.5, arp 0.4, leads 0.3, clap 0.3, crash 0.25, snare 0.22, open hat 0.1, hat 0.05, kick and bass 0. Room by genre (`SpaceSpec.forGenre`: ambient 4 s, trance / synthwave 2.4 s bright, edm 2 s, lofi 1.8 s dark, jazz / bossa 1.6 s, techno / house 1.3 s, funk 1 s). Input highpassed at 200 Hz (12 dB/oct), the return's side at 300 Hz (4th order). Sampled slots that send render as their own group (`flushSamplers`) and reach the room a block later (`sendFifo`) | runner, `PreparedTrack` sets the room like `duckDepth` |

New measurements: `MusicalityReport.melodyLegato` (sounding share of the time to the next melody
note, ≤ a beat ahead), `phraseEndsOnChordTones` (phrase ends as defined above, within a section),
`bassStepwise` (arrivals at a new root from ≤ 2 semitones); `djctl render` adds
`audio.preDropDipDB` (the last beat before a drop against the beat before it, below 200 Hz) and,
with `--room`, `audio.roomReturnDB` (renders again without `.space`; the difference against the
dry mix). The matrix prints `bStep`, `legato`, `pEnd`, `gapDB`.

Before → after, 12 genres × 2 seeds, whole songs, synth voices. "Before" is the same djctl with
part D's 20 fixes (`--fixes key,…,stereo`):

| metric | before (part D) | after |
|---|---|---|
| melody legato (1 = held to the next note) | 0.60 | 1.00 |
| melody phrase ends on a chord tone | 0.71 (techno 42 0.60, dubstep 42 0.00) | 0.99 |
| bass arrivals at a new root by step | 0.50 (funk, house, dnb, synthwave 0–0.6) | 0.79 (those 1.00; techno / trance / jazz untouched) |
| bass motion at chord changes, mean semitones | 3.4 | 2.4 (funk 42 5.0 → 1.5) |
| last beat before a drop, < 200 Hz, against the beat before | +0.2 dB | −11.6 dB (edm 42 +0.4 → −12.0) |
| side / mid, dB | −19.0 | −16.2 (the room's return is wide) |
| side / mid below 150 Hz, dB | −38.8 | −37.9 |
| semitone rubs per 100 overlapping pairs | 2.4 | 2.4 (techno 42: 4.9 → 4.2) |
| integrated loudness, mean; peak | −16.9 LUFS; −2.2 dBFS | −17.0; −2.4 |
| clipped samples | 0 | 0 |
| in key, bass on root, changes on bars / 2-bar lines, fills, crashes | 0.99, 1.00, 1.00 / 1.00, 1.00, 1.00 | unchanged |

Room returns against the dry mix (`--room`, seed 42, 60 s, synth): ambient −8.0 dB, trance −14.7,
synthwave −14.5, lofi −13.5, jazz −14.9, bossa −16.2, edm −16.7, dnb −17.3, funk −19.5, dubstep
−20.9, house −21.4, techno −22.3. Sampled jazz 42: −15.7 dB, low side −15.1 → −14.9 dB (the room
adds nothing under the mix's own low end). Before the side highpass went to 300 Hz the return
widened the low end (techno low side −49 → −30 dB; `StereoTests` caught it on jazz).

Tests: `MusicalityTests` `melodiesAreHeld`, `phrasesEndOnChordTones`,
`bassApproachesChordChanges` (each checks its "before" was wrong and that only what the fix
names moved); `DropGapTests` (gaps sit before drops; the rhythm section > 20 dB down in the gap,
the drop's downbeat as loud as an earlier one, everything before bit-identical; pads untouched;
the choke > 20 dB off the open hat's tail, nets without an open hat bit-identical);
`SpaceTests` (a tail that falls at the room's rate; wide above, mono below 100 Hz; kick and bass
bit-identical with the room on; rooms by genre, `PreparedTrack` gets its genre's);
`DropGapRealTimeTests`, `SpaceRealTimeTests` (release: no allocation). Three older A/B tests now
leave `.cadence` / `.approach` out of both sides (`playedWithout`): which neighbour those pick
depends on the octave or step the earlier fix chose, so the "same pitch classes" checks no longer
held across them. `EnergyTests.sectionsHaveALevelContour` checks the intro ≥ 3 dB under the
peak and ≥ 2 dB under its flat level (it was 3 under flat): held melody notes lift lofi's melodic
sections, which lowers its loudness gain, so its flat intro already sits 1.2 dB lower; the
intro against the peak is 4.1 dB, as it was (4.4).

### Listen checklist (`make run-app-release`, or `djctl render <g> 42 --out f.wav`)

- any genre with a lead (trance 42, funk 42, lofi 42): the melody sings — notes held into the
  next, not ticked — and each phrase settles on a chord tone.
- funk 42 / house 42 / dnb 42: the bass walks into each chord change (a step before the new
  root) instead of jumping to it.
- edm 42 / trance 42: the beat before each drop drops out — snare roll and pads alone — then the
  drop and its crash land.
- house 42 / techno 7: the open hat's "tss" stops on the next closed hat.
- trance 42 / ambient 42: pads and lead in a hall, the kick and bass still dry and centred;
  techno 42: a short, tight room on snare and pads only. Fold to mono: nothing hollows out.
- A/B: `--fixes all` against
  `--fixes key,timing,register,dynamics,loudness,groove,offbeatBass,phrases,fills,voicing,energy,duck,contour,color,arpeggio,buildup,crash,bassLine,openHats,stereo`,
  or one flag at a time (`all` minus one is not a CLI form; list the others).

### Visual (part E)

From the offscreen window shot (`make swift-shots SHOT_DIR=… FILTER=WindowShot`, a new target:
`DJ_SHOT_DIR` through make): the section timeline's playhead ran straight through the current
section's name (white on white: "bu|ldup"). Labels are now laid out first; the line breaks
where it crosses a name (caps and stubs still mark it) and names carry a soft dark halo, so they
read on pale blocks too (`SectionTimelineRenderTests.thePlayheadBreaksOverAName`). The three
cards were ragged (deck A ~1500 pt tall, mixer ~500, deck B ~800): they now share the tallest's
height, and each deck's Channel strip and the mixer's crossfader sit at the card's foot, so the
faders of A, the crossfader and B's faders read as one row, as on a hardware mixer
(`WindowShotTests` asserts the card bottoms within 2 pt).

### Next ideas

- A synth filter envelope (saws open on the note and close as it decays): the synth leads and
  basses are raw saws at a fixed brightness.
- Arp patterns per genre (trance up-down sixteenths, synthwave eighths with octave jumps).
- Echo: a tempo-synced ping-pong delay send for leads and arps in trance / synthwave / dub.
- Question / answer across 8 bars: rings repeat every 4 bars, so the second phrase cannot answer
  the first without new slot topology; the runner could transpose or rest alternate cycles.
- `.dropGap` in the song family: a pre-chorus into a chorus gets it; a band "stop" (everything
  but the vocal-like lead) would suit rock / pop better than cutting only the rhythm section.
- The room's level was set by measurement, not by ear: worth a listen on monitors, lofi and
  ambient especially.

## 8. Part F (2026-10-13, run 1b7960bf): sound design, a motif, a balanced mix

Built on part E (merged from `val/run-e7cdf25f`, a fast-forward). Six more `Fixes` flags, all in
`.all`, all off on the parity path. Chosen by listening for what the earlier parts left alone —
the voices themselves and the mix — and by soloing parts (`djctl render --balance`, new): in the
dance genres the kick *was* the mix, everything else 12–19 dB under it.

| fix | what it does | where |
|---|---|---|
| `.subtractive` | saw / square voices read band-limited tables, one per octave (`MipTables`: every partial under 0.45 × the rate, ≤ 128, at beats' fundamental level; beats' tables stop at the 8th partial, so an A1 bass had nothing above 440 Hz), through a two-pole SVF lowpass per voice: cutoff = note × `base` + velocity² × `amount` × an envelope that closes over `seconds` (`FilterEnvelope`: bass 2.5× + 1.4 kHz / 0.16 s, lead 4× + 5 kHz / 0.35 s, pluck 3× + 6 kHz / 0.12 s). Pads (soft table), bells, subs, Karplus-Strong strings and instruments with their own lowpass are left alone | runner (`shapeVoice`, `filterSample`) |
| `.unison` | pads (±7 cents) and saw leads (±6) as two detuned oscillators at equal power; under `.stereo` a pad's pair goes either side (0.35, none at A3 and below, full from C5), its difference highpassed at 300 Hz so the low end stays mono. Leads stay mono (they are filtered, and the filter takes the pair's sum) | runner (`detune`) |
| `.echo` | a ping-pong delay send (`PingPong`): dotted eighths in trance (fb 0.42), synthwave, edm, dnb / dubstep / trap; eighths in lofi; dotted quarters in ambient; none in techno, house, funk, jazz, bossa. Lead sends 0.4, arp 0.22; repeats darken (loop lowpass) and go on into the room (0.3). Follows the tempo, gliding over 50 ms. Synth lanes only (sampled slots render as one bus) | runner; `EchoSpec.forGenre` via `WaveOptions.forGenre` |
| `.kickTune` | the kick's sweep lands on the key's root or fifth nearest 50 Hz (A → 55, C → G1 49, F → 43.7) instead of 48 Hz in every key | runner (`KickTuning`) |
| `.motif` | in each melody ring, bar 2 of every 4-bar phrase (2-bar ring: of every 2 bars) restates bar 1 — same sixteenths, lengths, velocities — moved along the scale so it starts on a tone of bar 2's chord near where bar 2 began; beat notes and phrase ends snap to the chord in the direction that keeps bar 1's up / down / same shape; bar 2 ends open (a chord tone, not the root), so bar 4's close (beats ends it on the tonic) answers it. The shift with the fewest turned intervals wins; range: down a minor third, up a fifth | pass (`stateIdeasTwice`, after `.cadence`) |
| `.balance` | each part (kick, snare/clap, hats, bass, pad, lead, arp) soloed through the loudness probe at 22 kHz, then trimmed ± 6 dB toward `MixBalance.targetDB` (kick 0, bass −3, lead −4, snare −6, pad −7, arp −8, hats −10, K-weighted) around the median; `.loudness` measures the track's gain with the trims on. Synth lanes only | runner (lane level), `MixBalance.trims` at prepare; `WaveOptions.trackBalance` kept on section jumps |

New measurements: `MusicalityReport.melodyIdeaRepeats` (4-bar melody phrases whose bar 2 has bar
1's rhythm and, within a third of its moves, its shape); `djctl render --balance`
(`audio.balanceDB`, each part soloed against the mix, and `balanceErrorDB`, the spread of the parts
around their targets); the matrix prints `idea`, `balErr`, `k-b` (kick minus bass) and runs
`--balance`.

Before → after, 12 genres × 2 seeds, whole songs (`--seconds 300`), synth voices. "Before" is the
same djctl with part E's 26 fixes:

| metric | before (part E) | after |
|---|---|---|
| melody phrases stating their idea twice | 0.00 | 1.00 |
| kick − bass, K-weighted (kick genres) | 14.5 dB (edm 42: 20.8) | 5.4 dB (edm 42: 8.6) |
| parts against the kick: snare / hats / bass / pad / lead / arp | −12.7 / −11.7 / −14.5 / −13.6 / −13.3 / −9.0 | −7.0 / −8.6 / −5.4 / −7.7 / −4.7 / −7.9 |
| balance error (spread around the targets), mean / worst | 4.2 / 6.3 dB | 1.3 / 3.7 dB |
| energy below 250 Hz | 66 % | 60 % |
| energy above 2 kHz | 6.4 % | 7.0 % |
| side / mid | −16.2 dB | −14.7 dB (pads' detuned pairs) |
| side / mid below 150 Hz | −37.9 dB | −37.5 dB |
| integrated loudness, mean; peak | −17.0 LUFS; −2.4 dBFS | −16.8; −1.9 |
| clipped samples | 0 | 0 |
| last beat before a drop, < 200 Hz, against the beat before | −11.6 dB | −7.5 dB (the kick is 6 dB lower in the mix and the pads, which play on through the gap, higher: still a clear gap) |
| in key, bass on root, changes on bars / 2-bar lines, fills, crashes, legato, phrase ends | 0.99, 1.00, 1.00 / 1.00, 1.00, 1.00, 1.00, 0.99 | unchanged |

The voice fixes barely move the mix-wide band shares (the kick dominated the energy); they are
measured per note instead (`SynthVoiceTests`, `UnisonTests`, `KickTuneTests`, `EchoTests`):

- an A1 bass note: 12th harmonic (660 Hz) at the attack under −60 dB before, over −40 dB after;
  its 8th harmonic falls over 10 dB in the first half second after (within 2 dB before);
- a lead A4 at velocity 120 against 50: 7th harmonic within 0.5 dB before, over 3 dB stronger after;
- a held C5 pad: one partial at the 4th harmonic before; two, 17 Hz apart (±7 cents), after; left /
  right correlation 1.0 → under 0.9 under `.stereo`, mono fold within 1.5 dB, a C3 note still 1.0;
- the kick's tail at the key's frequency within 15 cents (it was 48 Hz, 65 cents off A1 55 Hz);
- the echo: nothing before the first repeat, then dotted eighths left, right, left, each lower,
  silence between; a bass or pad renders bit-identically with it on.

Tests: `SynthVoiceTests`, `UnisonTests`, `KickTuneTests`, `EchoTests`, `BalanceTests`,
`MusicalityTests.ideasAreStatedTwice` (each with its "before was wrong" check), and the
`…RealTime…` suites for the filter and the echo (release: no allocation; `.balance` and the
tables are built at prepare). `.motif` joins `.cadence` / `.approach` in `phrasing`, the fixes
older A/B tests leave out of both sides. `StereoTests.aTrackIsWideAboveAndMonoBelow` caught two
things on the way: the first band-limited tables were normalised by their peak, which lowered the
fundamental and thinned the low end (now they keep beats' fundamental level), and the pads' pair
widened the low mids (now its side is highpassed at 300 Hz).

Found, not fixed: the chill-family theme table activates kick and snare only in buildup / drop /
pre-chorus / solo, so lofi, jazz and bossa `standard` songs never play a kick or snare (GO-DIVERGENCE
§5). And `.balance` / `.echo` see synth voices only: a sampled bass or lead keeps its own level
and stays dry of echo.

### Listen checklist (`make run-app-release`, or `djctl render <g> <seed> --out f.wav`)

- techno 42 / house 42 / edm 42: the bass is a part now, not a rumble under the kick; the kick
  still leads but no longer swallows the mix. Compare with `--fixes` = part E's list.
- trance 42 / synthwave 42: the lead bites on accented notes and mellows as it holds (filter
  envelope); dotted-eighth echoes bounce left-right after each phrase; the pads shimmer and spread.
- any genre with a lead: bar 2 answers bar 1 with the same rhythm a step or two away — a hook you
  can hum — then bars 3–4 go on and close.
- techno / trance basses: you hear the notes on small speakers (harmonics up to ~1 kHz on the
  attack), then they darken.
- headphones: fold to mono; nothing hollows out, the low end is centred.
- `--fixes all` against
  `--fixes key,timing,register,dynamics,loudness,groove,offbeatBass,phrases,fills,voicing,energy,duck,contour,color,arpeggio,buildup,crash,bassLine,openHats,stereo,legato,cadence,approach,dropGap,choke,space`
  (part E), or that list plus one of `subtractive`, `unison`, `echo`, `kickTune`, `motif`, `balance`.

### Visual (part F)

From the offscreen window shot: the mixer card (made as tall as the decks in part E so the faders
line up) had ~550 pt of nothing between its cue controls and the crossfader. It now holds a
**Sync** panel: per deck its BPM and four beat lamps (the current beat lit in the deck's tint while
it plays, outlined when stopped, the downbeat lamp wider), and which deck is faster and by how much
("A +8.0 BPM", "in sync") — what a DJ reads to beat-match, between the two platters
(`SyncPanel`, `BeatLamps`; `SyncPanelTests` render the lamps). A net deck's readout says
"bar 10 of 56" where it showed the song's length to the hundredth: a song is counted in bars.

### Next ideas

- The chill family's missing beat (above): rewrite the role control nets so verse / chorus unmute
  kick and snare in lofi (a boom-bap pattern with swing), or fix beats' table.
- `.balance` and `.echo` for sampled instruments: a per-slot level (the bank renders slots as
  groups already: ducking, room) and an echo group.
- Filter envelope on the arp too (a trance pluck arp), and a resonance sweep in buildups (the
  energy curve's lowpass opens; the voices' own filters could follow it).
- A sub-octave sine under the bass in dnb / dubstep (reese / 808 weight) now that the bass sits in
  the mix.
- Motif in the arp and bass: the same statement / repetition shape (the bass's bar 2 could echo
  bar 1's rhythm).
- Balance targets by genre (jazz and lofi want the bass and keys forward and the hats lower; the
  dance targets are a single rule of thumb).

## 9. Part G (2026-10-17): a song of its own per seed (`.variety`)

The complaint: "we get the same underlying notes, but different instruments". Measured over 30
seeds per genre (8 genres, standard songs and loops, the note log before and after the pass):
beats' generator draws **only the melody** from the seed. The key, scale and tempo are the
genre's (`proj.rootNote = genre.rootNote`); the cohesion-v2 chord plan is one of one or two
`chordProgs` per genre (techno: one, i–VII–i–VII); the bass is the plan's roots on the genre's
groove mask (`chordBassRing`); the pad is the plan (`chordPadNet`); the drums are seeded from the
genre's name (`drumSeed(genreName)`, `"genre:role:letter"` per slot). So 30 techno seeds played
1–2 bass phrases, 1–2 pad phrases and 3 drum parts between them, under 30 different 4-bar
motifs. dj's own `.arpeggio` made it worse for the arp: one figure (`arpPattern`) over the same
chords, so every trance seed had the same arp (13 distinct arp bars in 30 seeds, 99% shared).

`.variety` (`TrackVariety.swift`), seeded from the track's seed, one random stream per decision
(`varietyRandom("key" | "progression" | "bass" | "hihat" | "snare" | "kick", genre, seed)`):

- **Key** (`transposeTrack`): every tonal note −5…+6 semitones, the project's `rootNote` with it
  (so `.kickTune`, `DeckPerform`'s keys and every later fix read the new key). `.register` then
  puts each part back in its octave.
- **Progression** (`reharmonize`, cohesion v2, seven-note and pentatonic keys): a root per bar
  from `progressionTable` (by scale: minor, major, dorian, mixolydian, phrygian, 5–8 each; minor
  and major pentatonic, 2–3 each, in five-degree space; beats'
  own `chordProgs` for the genre join the pool first). Each bar's pad chord and bass move along
  the key by the shortest number of scale steps that puts the root there (triads stay triads);
  a walking bass's chromatic approach is re-aimed a semitone from the moved next note; melody
  and arp notes on the beat that are no longer chord tones go to the nearest one that does not
  repeat a neighbour (beats snaps its motif's beats the same way). Pentatonic genres (lofi:
  minor, ambient: major) move in five-degree space (2026-10-18): beats' mod-7 roots are wrapped
  mod 5 as `degreeToMidi` plays them, dj's tables add e.g. minor 1–5–4–b7 / 1–4–5–1 / 1–b7–5–4
  and major 1–5–6–3 / 1–3–5–2; a chord two pentatonic steps apart is a sus / quartal shape
  and stays in key, each move at most two steps. Blues (six notes) only changes key. The bass
  figure, `.harmonicCadence` and `SectionHarmony` stay seven-note (`sevenNoteKey`; the figure's
  fifth falls back to the perfect fifth). Measure: (pending, matrix compare on lofi / ambient).
  Whether the quartal shapes sound like lofi needs an ear.
- **Bass figure** (`varyBassFigure`, after `.register` and `.bassLine`, root-per-bar basses
  only): rhythm (as composed / a pickup into every second bar, on the 16th before the downbeat
  in four-on-the-floor genres, else the last off-beat eighth, never on a kick / every other hit
  of a busy mask) × line (roots / the fifth on every second hit / the fifth in the back half /
  one octave jump mid-bar). Each bar's first and last notes stay the composed root, so the bass
  states the chord where the groove puts it and `.bassLine` / `.approach` still lead into the
  next chord; figure notes stay under the pad and above E1. Walking and bossa basses are the
  genre's figure and stay.
- **Drums** (`varyDrums`): per part, the same choice in every slot (A / B / C keep their
  differences): hats as composed / ghost sixteenths / thinned to eighths / moved an eighth;
  0–2 ghost snares off the backbeat; outside four-on-the-floor, sometimes one ghost kick on a
  free eighth. Ghosts at a third to a half of the part's velocity, never on the downbeat or next
  to a hit.
- **Arp** (`.arpeggio`, `ArpFigure.seeded(seed, variant:)`): the ladder's shape (up, down, up
  and down, broken, pedal, beats-like), span (4–6 chord tones), first tone and rate (sixteenths
  or eighths; a C variant always eighths), from the seed and the slot's letter.

Two fixes the pass needed in older ones: `.bassLine` places each ring on its own, so a sparser C
slot could sit an octave from the others and the bass jumped an octave where sections met; a
ring a fifth or more from the part's median now moves an octave toward it. `.approach` comes
from above when the step below the next root would be under E1.

Measured (30 seeds, standard songs, as played; distinct 4-bar phrases across seeds, before →
after; "rel." = relative to the track's root, i.e. not counting a transposition):

| genre (v2) | melody | arp | bass | harmony | drums |
|---|---|---|---|---|---|
| techno | 84 → 84 (rel. 84) | – | 1 → 36 (rel. 32) | 1 → 27 (rel. 8) | 5 → 70 (rel. 70) |
| house | 84 → 84 (rel. 84) | – | 3 → 33 (rel. 29) | 3 → 29 (rel. 10) | 6 → 22 (rel. 22) |
| trance | 85 → 85 (rel. 85) | 7 → 90 (rel. 90) | 3 → 31 (rel. 28) | 2 → 28 (rel. 13) | 7 → 110 (rel. 110) |
| edm | 78 → 78 (rel. 78) | 16 → 90 (rel. 89) | 2 → 30 (rel. 27) | 2 → 27 (rel. 13) | 8 → 124 (rel. 124) |
| dnb | 84 → 84 (rel. 84) | – | 1 → 34 (rel. 27) | 1 → 27 (rel. 9) | 6 → 70 (rel. 70) |
| jazz | 65 → 65 (rel. 65) | – | 2 → 27 (rel. 14) | 2 → 26 (rel. 10) | 11 → 55 (rel. 55) |
| lofi | 60 → 60 (rel. 60) | – | 2 → 19 (rel. 2) | 2 → 19 (rel. 2) | 2 → 10 (rel. 10) |
| ambient | 60 → 60 (rel. 60) | – | 1 → 17 (rel. 6) | 1 → 11 (rel. 1) | 3 → 24 (rel. 24) |

The melody already was the seed's (every phrase unique to its seed) and is unchanged in count;
v1 (free-form) gains the key and drums only (its bass and melody are beats' own lines).

Rendered (`djctl render <g> <seed> --synth --seconds 90`, techno / house / trance / jazz / lofi /
dnb × seeds 7, 42, 1234, with and without the flag): no clipped samples either way, peaks within
±0.7 dB, RMS within ±0.6 dB, every track as much in key as before (jazz's walking-bass approach
notes aside), chord tones on beats 0.98–1.00, semitone rubs per 100 overlapping pairs 2.89 → 2.66
on average (house 7: 1.9 → 4.3 and dnb 1234: 2.2 → 3.7 are the worst; jazz 7: 8.4 → 5.6 the
best). `djctl render` now reports on the played project (its key), not the composed one.

Trade-offs: a key offset puts a genre off its conventional key (dubstep / trap low D / E for sub
weight, metal's E): `.register` keeps the parts in their octaves, so the bass's register is
kept but its exact pitch moves up to a tritone. The kick follows (`.kickTune`'s root-or-fifth
nearest 50 Hz). The seeded progressions are diatonic and shortest-move, so the motif still fits
them (beats only re-snaps beats; off-beat passing notes stay as composed).

`VarietyTests` holds it: per genre (techno, house, trance, lofi, jazz, dnb), 30 loop seeds give
bass ≥ 8, harmony ≥ 6, drums ≥ 4, arp ≥ 10 distinct 4-bar patterns and 30 melodies with a mean
pairwise pitch Jaccard ≤ 0.25; the seven-note genres ≥ 3 progressions relative to the root;
without the flag the bass is still the genre's (≤ 3); in key, chord tones on beats and semitone
rubs no worse than without it.

## 10. Level match (2026-10-18): net decks at the app's reference

A net deck on the app's path (`WaveOptions.extended`) is gained to `LevelMatch.referenceLUFS`
(−12 LUFS integrated) by `Loudness.targetDB` and held under −1 dBFS by the deck's `PeakLimiter`;
beats' `tanh` curve no longer bends it. The parity path (`WaveOptions()`) is unchanged: no limiter,
beats' curve, no loudness gain (`theParityPathHasNoLimiter`). Measured, not listened to: whether
the limiter pumps is an ear call, so the gain-reduction numbers are the whole claim.

Matrix (`scripts/musicality-matrix.py OUTDIR`, 12 genres × seeds 42 / 7, 75 s, synth voices;
`--compare` main against the branch):

| metric | main (118a950) | branch |
|---|---|---|
| integrated loudness, mean ± sd | −16.9 ± 0.5 LUFS | −11.7 ± 0.5 |
| range | −18.0 (ambient 42) … −15.7 (edm 42) | −12.6 (ambient 42) … −10.6 (edm 42) |
| sample peak, worst | −1.3 dBFS | −1.0 (the ceiling, every track) |
| clipped samples | 0 | 0 |
| loudness range (LRA), mean | 4.6 LU | 3.9 |
| section spread, mean change | – | −0.7 dB (the limiter works hardest in the loudest sections) |
| every musicality column (key, root, phrasing, fills, …) | | unchanged |

60 s from the top (`djctl render <g> 4242 --seconds 60 [--synth]`), LUFS; GR = the limiter's gain
reduction, P50 / P95 / P99 / max dB:

| genre | main synth | branch synth | main sampled | branch sampled | branch synth GR |
|---|---|---|---|---|---|
| techno | −17.7 | −12.4 | −18.7 | −12.6 | 0 / 0.8 / 2.2 / 6.5 |
| house | −18.3 | −12.9 | −19.6 | −12.8 | 0 / 0.5 / 1.6 / 4.8 |
| trance | −16.4 | −11.5 | −17.3 | −11.8 | 0.1 / 1.4 / 3.8 / 8.1 |
| dnb | −17.7 | −12.2 | −18.4 | −12.4 | 0 / 0.4 / 1.2 / 4.9 |
| lofi | −17.7 | −12.1 | −22.3 | −13.3 | 0 / 0.2 / 0.9 / 3.4 |
| jazz | −16.6 | −11.5 | −20.4 | −12.2 | 0 / 1.0 / 2.8 / 6.7 |

Main's peaks were −1.6 … −6.4 dBFS; the branch's are −1.0 on all twelve. Sampled is every
instrument this Mac has installed, so those columns are this machine's.

Whole songs (`LevelSurveyTests.wholeSongsAgainstTheReference`, seed 4242, standard structure to
the end, 24 kHz, ten genres): synth −12.0 ± 0.5 LUFS (−12.8 synthwave … −11.0 jazz), sampled
−12.3 ± 0.5 (−13.1 lofi … −11.5 dubstep). The probe's gain ran +2.1 (dnb) … +9.3 dB (lofi) synth,
up to +13.1 sampled (lofi), all inside `Loudness.range` (−12 … +18 dB): neither `targetDB`
(reference − 0.4) nor the range needed to move. Median gain reduction 0 … 0.2 dB, P99 0.6 …
5.2 dB, max 4.3 … 11.2 dB (synthwave sampled); 7 % (lofi synth) to 63 % (trance sampled) of
samples limited by more than 0.1 dB. `aNetTrackPlaysAtTheReference` holds techno, house,
trance, dnb, lofi and jazz to ±1.5 LU, peak < 0 dBFS and ≤ the ceiling, median GR ≤ 0.5 dB.

`Loudness.sampledPartDB`, re-measured under the default palette (Studio) by
`LevelSurveyTests.sampledPartsAgainstTheirSynthVoices` (each part soloed, sampled − synth, 40 s,
seed 4242, ten genres): bass −4.1 ± 1.9 (was −4.3), harmony −5.0 ± 1.3 (was −5.8), melody
−1.7 ± 1.5 (was −1.6); house is the outlier (bass −8.9, melody −4.8). No arp played on a sampler.
The new values move the sampled whole songs −0.1 LU (−12.2 → −12.3): what is left between
sampled and synth is not in the soloed parts' levels.

The loop channel ("L") at its defaults against a deck at the centred crossfader
(`LevelSurveyTests.theLoopChannelAgainstACentredDeck`: a 2-bar take of a techno net deck looped
on L alone, against the deck alone, on the master): **L plays 2.9 LU louder** (A −16.1, L −13.2
LUFS; the channel gains alone 3.01 dB). A and B take the crossfader's equal-power −3 dB at the
centre, L takes none (`DJEngine.crossfadeGain`); the −3 dB trim for L is ow-level-loop-channel's.
(A take loops on L as soon as it is made: the survey takes it off L before measuring the deck.)

The surveys are measurements, not checks: `DJ_LEVEL_SURVEY=1 swift test -c release -Xswiftc
-enable-testing --filter LevelSurveyTests` (with the Makefile's framework flags; about three
minutes in release, the sampled parts need the installed instruments).

## 11. 6.4 metrics (2026-10-18): phrases that answer, a hook, contour

Report only (`MusicalityReport`, `djctl render`'s `musicality`, matrix columns
ans / hook / b1ct / bidea / peak / leapR); no note and no existing metric changes.
`PhraseMetricsTests` holds each to exact values on hand-built logs.

- **`answerPhrases`** (ans): 8-bar melody pairs (one net, bars 1–8, 9–16, … on the song's grid,
  both halves playing) whose first half ends open and second ends closed — closed = the half's
  last note is the key's tonic (`rootNote`'s pitch class). 6.4's exit wants ≥ 0.9 in song-form
  genres.
- **`hookRecurrence`** (hook): the hook is the first melody bar with two notes or more; of the
  later sections with melody, the share with a bar on its rhythm (same sixteenths) and shape
  (same up / down / level moves, or all of them turned: an inversion). Transposition is free.
- **`barOneChordTones`** (b1ct): melody notes in bar 1 of each 4-bar phrase that are tones of
  the bar's chord (all onsets, not only beats): where a hook is stated over the chord plan.
- **`bassIdeaRepeats`** (bidea): 4-bar bass phrases (first bar two notes or more, second
  playing) whose bar 2 repeats bar 1's rhythm.
- **`melodyPeakPosition`** (peak): where each 4-bar melody phrase's highest note first sounds,
  as a share of the phrase, averaged (the arch's target is about 0.67).
- **`leapRecovery`** (leapR): melody leaps (a fourth or more, ≤ half a bar apart) followed
  within half a bar by a step (1–2 semitones) the other way.

### 6.4 baseline

To be filled from `scripts/musicality-matrix.py OUTDIR` on `main` (12 genres × seeds 42 / 7,
75 s, synth voices) and `PhraseMetricsTests.playedTracksReportPhraseMetrics`'s printout;
not yet run (this change was built without renders).

| genre | ans | hook | b1ct | bidea | peak | leapR |
|---|---|---|---|---|---|---|
| (pending) | | | | | | |

### 6.4 the bass motif (`.bassMotif`, p64-bass-motif)

The plan was to measure first: leave the pass empty if the baseline's mean `bassIdeaRepeats`
is ≥ 0.95. The baseline above is still pending (built without renders), so the pass is built
and the measurement decides whether it earns its place: compare `--fixes all` with
`all` minus `bassMotif` in the matrix's bidea / root columns.

- `restateBassRhythm` (BassMotif.swift): in each bass ring of whole bars, a 4-bar phrase
  (2-bar, in a 2-bar ring) whose bar 1 has two notes or more and whose bar 2 plays another
  rhythm gets bar 1's sixteenths, lengths and velocities in bar 2, each note the same scale
  steps from bar 2's root (its pad chord's root nearest where bar 2 began) as from bar 1's first
  note. In key by construction; a note out of the bass's room (E1 … A2 or the part's top,
  under the pad) folds an octave, and a phrase that cannot (or has a chromatic bar-1 note)
  stays as composed.
- A pickup in bar 2's last beat after bar 1's last note (`varyBassFigure`'s pickup) stays, and
  bar 1 plays it too, so variety's pickup figure survives as a pickup into both bars.
- Walking and bossa grooves (jazz, blues, lofi, bossa) are exempt. Runs after `varyFigures` /
  `moveBassOffTheKick`, before `.approach`.
- `BassMotifTests`: bidea ≥ 0.95 and bassOnRoot no lower than without the flag in 11 figure
  genres × 2 seeds, every bass note in key; the exempt genres byte-identical with and without
  it; a hand-set ring for the copy and the pickup. `MusicalityTests`' `phrasing` A/B set now
  leaves `.bassMotif` out of both sides too.

## 12. The chill family's beat (`.backbeat`, 2026-10-18)

beats' theme table brings lofi, jazz and bossa's kick and snare in only for buildup / drop /
pre-chorus (and jazz / bossa's kick for the outro), and their `standard` blueprints have none of
those: verses and choruses never play a beat (`BeatTests.surveyEveryGenreBeforeThePass`: exactly
these three read `hasBeat` 0 at seed 42). `.backbeat` (Backbeat.swift) runs after `.timing`,
before `.variety`:

- **Where**: each part plays wherever the composer had it plus every section the style expects a
  beat in (`beatStyle`: verse, pre-chorus, chorus, drop; lofi also buildup). Intros, bridges,
  breakdowns, solos and outros keep what the composer gave them. The part starts unmuted when the
  first section has a beat.
- **How, without topology**: `struct-kick` / `struct-snare` are accumulator chains with one stage
  per change the composer made (none at all for the snare, which no `standard` chill section
  activates). When a chain has as many stages as there are edges they are retimed onto them;
  otherwise its stages are rebound to agree with the plan and each edge is a mute / unmute
  binding on a free transition of a `fill-N` chain spanning it (one transition per tick, as
  `.buildup` / `.crash` use them). Every change fires on the section's start tick after that
  tick's notes, `.timing`'s convention. A slotted part (`kick-0`…, `activate-slot`) is skipped.
- **What**: the figures are rewritten on each ring's own transitions, as shares of its loudest
  composed hit: lofi boom-bap (kick 1, a-of-2, and-of-3; snare 2 and 4), jazz a feathered kick
  (0.45 on every beat) under a soft 2 and 4, bossa a surdo (dotted quarter and eighth, leaning
  on 3) and the bossa clave on the rim (note 37). beats' jazz drums are 12-step rings (three
  beats against a 16-step bar), which can't hold a 2 and 4: there the kick feathers every beat
  and the snare keeps time softly on every beat, as brushes do. `.variety`'s ghost hits then
  land around the figure; the runner's groove (`.feel`) swings it.
- Exit (BackbeatTests): `hasBeat` = 1 for lofi / jazz / bossa at seeds 42 / 7 / 1234, with the
  pass alone and with every fix; ambient and the other genres unchanged; nets, places,
  transitions, arcs and the composed project's CID unchanged.

Ear-gated: whether lofi reads as boom-bap and jazz as brushes needs listening. The matrix before
/ after (`scripts/musicality-matrix.py OUTDIR` on integrate/roadmap against this branch,
`--compare`) has not been run yet: it goes here with the chill rows' `hasBeat`, loudness and
balance columns. The kick and snare now sound in the level probe and `.balance`'s solos, so the
chill tracks' gain and part trims move.

## 13. 6.2 layer budget (2026-10-18): at most N melodic parts a section (`.layerBudget`)

- **What**: per section, the melodic parts that play there (`slotWindows` of each role) in
  `layerPriority` order — by rest class, so bass, melody (and lead), harmony (pad, chords), arp —
  keep the first `autoLayerBudget[name]` (intro / breakdown / outro 1, verse / buildup /
  bridge / solo 2, drop / chorus 3, others 2); the rest rest over the whole section
  (`DJMusicality.layerBudgetRests`, a `RestSchedule` gesture). Both tables are beats' own
  (`Techniques.swift`), the same rule as the composer's `layerBudget: "auto"` technique.
- **Deviation from the roadmap's "mute slots" wording**: beats' technique mutes the dropped
  roles' slots in the structure nets (`applyLayerBudget`); dj does not touch nets (the pass
  rewrites bindings and markings only, and compose stays beats'), so the parts rest in the
  runner instead: their nets keep running and only their hits are dropped. `NetSnapshot` and
  the visuals therefore still show a rested part as playing. Roles that share a rest class
  count as one part (a lead cannot rest while the melody plays).
- **Measured**: `djctl render --layers` adds `audio.layersPerSection` (`OfflineRender.
  layersPerSection`): every melodic part soloed (`MixBalance.solo`) through the whole song with
  the deck's fixes and rests, synth voices, linear master; a part is a layer in a section where
  its solo is within 40 dB of the mix (first bar of each section left out for tails).
- **Risk**: the loudness and balance probes don't see the rests (they measure the busiest
  section's solos), so a capped drop can sit a little under the old level; check the matrix LUFS.
- `LayerBudgetTests` (priority, caps on a hand-built project and edm 4242, a rested solo
  < −80 dB, the layer count with and without the flag).

### Matrix before / after

Not yet run (built in fast mode, without renders): `scripts/musicality-matrix.py` with
`--fixes all` against `all` minus `layerBudget`, LUFS per genre (±0.5 LU or the shift listed)
and `djctl render <genre> 42 --layers` per section.

| genre | LUFS before | LUFS after | layers before → after |
|---|---|---|---|
| (pending) | | | |

## 14. 6.6 HF tilt (a) (2026-10-18): slope and 16 kHz bump per family, measured first

Measure only: no voice, filter or fix changes. `SpectralSlopeTests` (always on) holds the
measurement finite and the parity path (`WaveOptions()`, the composed track and its share CID)
untouched; `SpectralSlopeSurveyTests.perFamilySlopeAndHFBump` (with `DJ_SPECTRAL_SURVEY=1`)
prints the table below.

- How: each of the matrix's 12 genres at seed 42, standard structure, 60 s from the top,
  48 kHz, `.extended` with synth voices and again on the deck's sampler bank; loudness gain
  fixed at 1 and a linear master (no limiter), so the mix and its solos share one gain (trims
  and energy curve still come from the whole project). `Spectrum` gives the mix's
  `slopeDBPerOct` (63 Hz … 8 kHz fit) and `hfBumpDB` (12.5 / 16 kHz over the fit).
- Parts: kick, snare (+ clap), hats (`hihat`: closed + open), fills (the `fill-N` chains:
  buildups and the section crash), bass, harmony, melody, arp, each soloed with `RoleFilter`.
  A part *carries* the bump when its 12.5 / 16 kHz power is ≥ 25 % of the mix's; the survey
  prints its share, its own slope / bump and the file its voice lives in.
- Where the bright voices live: synth drums — `Sources/DJCore/Beats/Wave/WaveSynth.swift`
  `drumVoice` (hat, openhat and crash are highpassed noise: the expected carriers); synth
  tonal parts — `Sources/DJCore/Musicality/SynthVoice.swift` (`MipTables`, `FilterEnvelope`)
  with `Resources/voices/instruments.json`; sampled parts — the picked EXS / SoundFont through
  `Sources/DJCore/Audio/Sampler.swift` (`VoiceCatalog`).

### 6.6 slope table

To be filled from `SpectralSlopeSurveyTests`' printout (`DJ_SPECTRAL_SURVEY=1 make
swift-test-filter FILTER=SpectralSlopeSurveyTests`, release recommended); not yet run (this
change was built without renders). Families are `BeatsTables.family(of:)`'s
(dance, song, jazz, chill).

| family | voices | n | slope dB/oct | hfBump dB | parts carrying the bump (file) |
|---|---|---|---|---|---|
| dance | synth | (pending) | | | |
| dance | sampled | (pending) | | | |
| song | synth | (pending) | | | |
| song | sampled | (pending) | | | |
| jazz | synth | (pending) | | | |
| jazz | sampled | (pending) | | | |
| chill | synth | (pending) | | | |
| chill | sampled | (pending) | | | |

## 15. 6.3 harmony that goes somewhere (2026-10-18)

The complaint (ROADMAP 6.3, open since part C): one 4-chord loop at one chord per bar for the
whole song, and the pad a single unslotted ring, so beats' bridge / solo melody (`harmonic` +5 /
+4) moves away from a pad and bass that stay put. The dj half, three flags, all in `Fixes.all` /
`Fixes.named` and off in `WaveOptions()` (parity unchanged):

| flag | where | what |
|---|---|---|
| `.harmonicCadence` | pass (`HarmonicCadence.swift`), after `.variety`'s progression | each pad bar ending a 4-bar line whose root does not already rise a fourth or a whole step into the next moves to the next bar's V, else its ♭VII (♭VII first in minor dance genres); `reharmonize` moves the bass and melody / arp beat notes with it. Bindings only |
| `.sectionHarmony` | pass (`SectionMelody.swift`) + runner (`SectionHarmony`, `WaveProject.harmony`) | bridge +5, solo +4, breakdown to vi (major-third keys) or III (minor-third): the runner maps every tonal lane's note at the fire's step through the section's shift (octave per group, E1…C8), so the band moves together; the pass moves beats' bridge / solo-only melody / arp slot nets back home by the same table so the melody isn't shifted twice |
| `.harmonicRhythm` | runner, through `SectionHarmony(project:fixes:)`'s half-bar slots | intros / breakdowns / outros hold each chord 2 bars; a buildup's last half-bar plays the V (else ♭VII) of the next section's first chord; the bar before a chorus (not from a drop or chorus) plays 2 chords, ending on that V; drops keep 1 chord a bar |

Metrics (`MusicalityReport`, matrix columns cad / prog / secCT / padMv / rub / clip):
`harmonicCadences` (4-bar lines whose root falls a fifth or rises a whole step into the next),
`progressions` (distinct 4-bar root sequences relative to `rootNote`), `sectionChordAgreement`
(melody / arp / bass beat notes on the bar's chord, per section and the minimum), `padMotion`
(mean semitones per pad change), `semitoneClashesPer100`, `clippedSamples`. `djctl render`
captures the `NoteLog` through the same `SectionHarmony` the runner plays, so the report hears
the shifted sections.

### Baseline (before 6.3, from `HarmonyReportTests`)

Seed 42, standard structure, `--fixes all`, integrate/roadmap ad884c1: one progression in every
genre but blues (3; its 12 bars are three blocks); cad 1.0 in ambient, country, dubstep, edm,
garage, house, reggae, synthwave, techno, trap and 0.0 in bossa, dnb, funk, jazz, lofi, metal,
speedcore, trance (blues 0.27); secCT's lowest section 0.125 (blues outro) … 1.0. With one 4-bar
loop per song, cad is all or nothing per genre.

### Matrix before / after

Not yet run (built in fast mode, without renders). To fill, on a quiet machine (not alongside
other test runs):

```
scripts/musicality-matrix.py OUT/before --fixes "$BEFORE"
scripts/musicality-matrix.py OUT/after
scripts/musicality-matrix.py OUT/before-s --sampled --fixes "$BEFORE"
scripts/musicality-matrix.py OUT/after-s --sampled
scripts/musicality-matrix.py --compare OUT/before OUT/after
```

`$BEFORE` is every name in `Fixes.named` except `harmonicCadence`,
`sectionHarmony`, `harmonicRhythm` (or integrate/roadmap before d588f56 / c5e0337 / c236ce3
built with `--djctl`). The matrix renders the standard structure, which has no bridge in the
dance family: whole songs with a bridge or solo come from `djctl render <g> <seed> --structure
extended --synth` (dance: techno, house, trance; song: synthwave, funk; jazz / bossa standard has
a solo, lofi / ambient standard a bridge), seeds 42 and 7.

| genre | cad before → after | prog | padMv | rub /100 | clip |
|---|---|---|---|---|---|
| (pending) | | | | | |

Exit (ROADMAP 6.3): cad ≥ 0.9, prog ≥ 2 in a song with a bridge, padMv ≤ 4, rub not up, clip 0.
Expected where it can't move: ambient, lofi, blues (pentatonic / blues keys keep their plan
under `.harmonicCadence`; `SectionHarmony` is nil for keys that aren't seven notes), so their
cad / prog are beats' and only the gates above on the seven-note genres are the claim.

### What was dropped or differs from the roadmap

- **Harmonic rhythm is in the runner, not a rebinding of the pad ring.** The roadmap said
  "rebinding the pad ring"; the ring is shared by every section (one unslotted 64-step net), so
  a per-section rhythm can't live in its bindings. The runner's half-bar shift slots play it
  instead; nets and bindings are unchanged by it, so `NetSnapshot` and the visuals show beats'
  pad chord, not the held / pushed one.
- **The breakdown moves to the relative key, not a new progression**: the same loop a third
  away. A section's own progression is the beats half (slotted `harmony-N` pads, cohesion v3).
- **Live keys are not mapped** (`DeckPerform`'s keys play the home key in a bridge).
- **Pentatonic and blues genres** keep beats' plan (as with `.variety`).
- **7ths / 9ths at compose time, Markov progressions with a cadence constraint, chord-
  transition tables**: beats-side (GO-DIVERGENCE §5.9); `.color` still adds the seventh after
  the fact.

### Listen checklist (`djctl render <g> <seed> --structure extended --out f.wav`, or the app in release)

Ear-gated: the numbers above are the claim, not that it sounds better.

- techno / trance 42 `extended`: does the bridge read as a new place with the bass under it,
  and does the band come home cleanly at the next drop (no octave jump in the bass)?
- synthwave / funk 42 `extended`: the bar before each chorus — two chords pushing into it, the
  second a V: a lift, or a hiccup?
- jazz / bossa 42 standard: the solo +4 with pad and bass moving with it — still in the genre's
  colour, or a key change that sounds like a mistake?
- house / edm 42: breakdown at the relative key holding each chord 2 bars — calmer, or static?
- trance / dnb 7: the pad cycle's last bar now a V / ♭VII into the loop — does it resolve, or
  sound like a wrong chord against the melody?
- any track with a sampled pad or bass (`--synth` off): the shifted section played by the
  sampler, at its mapped notes — in tune, and no sample stretched out of its range?

Rows for Matt to add to `docs/listening-log.md` after listening (genre, seed, build, device;
verdict and first wrong are his): techno 42, trance 42, synthwave 42, funk 42, jazz 42, bossa 42,
house 42, lofi 42, dnb 7 — the four the exit names (jazz, lofi, house, trance) first: 6.3 is done
when the log stops naming *harmony* first for them.

## 16. 6.4 a hook, and an answer (2026-10-18): the write-up

The complaint (ROADMAP 6.4): the melody is one 4-bar cell — nothing at 8 bars, no hook that
survives a section change, and an interval profile of mostly repeats (54 % in the audit). Six
flags, all in `Fixes.all` / `Fixes.named` and off in `WaveOptions()` (parity unchanged), every one
a pass stage (bindings only; `compose()` and the CID stay beats'). §11 has the metrics they are
judged by and the bass motif's own notes.

| flag | where (pass order) | what |
|---|---|---|
| `.shape` | `MelodyShape.swift`, after `.contour`, before `.cadence` | off-beat repeats and passing tones go to the degree RS200's bigram table (`MelodyBigrams.default.moves`, `Resources/beats/melody-bigrams.json`) finds likeliest after the note before, within a major third; a 4-bar phrase that peaks before 0.55 gets a higher off-beat note in 0.56–0.8; a leap of a fourth or more is followed by a step back. Only off-beat notes move, onto the key, never a semitone against the pad chord. Diatonic keys only |
| `.hook` | `Hook.swift`, after `.cadence`, before `.motif` | one seeded 1-bar chord-tone hook (`buildHook`, genre + seed) on the first bar of every melody slot window (`slotWindows`): Play in verses / drops / choruses, Transposed (a third up) in buildups, Inverted in bridges; Fragment (intros / breakdowns / outros) and Augmented (solos) state it whole first and vary it on the window's third bar. Notes snap to the bar's pad chord keeping the hook's moves. Off when compose's own `hook` technique is on |
| `.answer` | `Answer.swift`, after `.motif` | per section, 8-bar pairs from its start where the melody plays both halves: the last note of bars 1–4 (in bars 3–4) goes to the chord's fifth (else third, never the tonic), the last of bars 5–8 to the tonic (else the chord's root), on the ring step `slotWindows` says sounds there; a ring step several windows ask for takes the majority note. Bars 1–2 (`.motif`'s idea) untouched |
| `.bassMotif` | `BassMotif.swift`, after `.answer`, before `.approach` | bar 2 of each 4-bar bass phrase takes bar 1's rhythm, each note the same scale steps from bar 2's root; walking and bossa grooves exempt (§11) |
| `.arpStyle` | `ArpFigure.seeded(_:variant:genre:)`, in `arpeggiate` | per-genre pools: trance up-and-down sixteenths over 4–6 tones from a seeded phase, synthwave eighths with each tone answered an octave up, edm up or broken sixteenths; other genres keep `.arpeggio`'s full pool (house has no arp role, so no off-beat stabs) |
| `.arpDensity` | `arpDensityRates`; `arpeggiate` moves after `.legato` | each arp ring bar's rate from the melody's bar: sixteenths under 5+ onsets, eighths under fewer, quarters where it rests; the section's energy where no melody slot plays; a step busier in each phrase's fourth bar and in buildups. Direction (follow / answer) is one constant, `arpDensityDirection` (1 = follow), since it is an ear call. Needs `.arpeggio` |

Groundwork the flags stand on: `slotWindows` (`SlotWindows.swift`, p64-slot-windows) — which slot
net of a role plays which bars of each section, and where its ring is when it comes in. Its spike
is why `.answer` is pass-side: bars 5–8 of an 8-bar section are always a different slot net from
bars 1–4, so the answer can be a binding. The roadmap's runner-side version (alternate ring cycles
transposed through `SectionHarmony`, p64-answer-runner) was the fallback and was not built; it is
not needed unless the matrix below shows `ans` short of the exit with the pass alone.

### Exit numbers against the targets

Not yet measured: every 6.4 change was built in fast mode (compiled, no test runs, no renders).
The targets, and where each number will come from:

| target (ROADMAP 6.4 exit, plus the stage's own) | metric (matrix column) | where it is asserted |
|---|---|---|
| `melodyIdeaRepeats` stays 1.0 | idea | matrix only |
| `answerPhrases` ≥ 0.9 in song-form genres | ans | `AnswerTests` (9 genres × seeds; inKey and rub hold) |
| melody repeats ≤ 0.30 | rep | `MelodyShapeTests.contourMeetsTheCorpusTargets` (mean) |
| melody steps ≥ 0.45 | `melodySteps` (render JSON, no column) | same |
| leaps recovered ≥ 0.8, peak 0.55–0.8 | leapR, peak | same |
| hook heard in ≥ 0.9 of later sections, bar-1 chord tones ≥ 0.95 | hook, b1ct | `HookTests` (song genres) |
| bass bar 2 repeats bar 1 ≥ 0.95, root no lower | bidea, root | `BassMotifTests` (11 figure genres × 2 seeds) |
| arp rate correlates with melody density r ≥ 0.5 | — | `ArpDensityTests` |
| *hummable* for at least half the genres at seed 42 | — | the listening log, Matt's only |

To fill, on a quiet machine (not alongside other test runs):

```
make swift-test-filter FILTER='AnswerTests|HookTests|MelodyShapeTests|BassMotifTests|ArpStyleTests|ArpDensityTests|PhraseMetricsTests|SlotWindowsTests'
scripts/musicality-matrix.py OUT/before --fixes "$BEFORE"
scripts/musicality-matrix.py OUT/after
scripts/musicality-matrix.py OUT/before-s --sampled --fixes "$BEFORE"
scripts/musicality-matrix.py OUT/after-s --sampled
scripts/musicality-matrix.py --compare OUT/before OUT/after
```

`$BEFORE` is every name in `Fixes.named` except `answer`, `hook`, `shape`, `bassMotif`,
`arpStyle`, `arpDensity` — the same set is §11's 6.4 baseline, so filling this table fills that
one. One flag's own effect is `all` minus that flag against `after` (the bass motif's keep-or-drop
call in §11 is `--fixes` without `bassMotif`).

| genre | ans before → after | idea | rep | leapR | peak | hook | b1ct | bidea | rub /100 | key |
|---|---|---|---|---|---|---|---|---|---|---|
| (pending) | | | | | | | | | | |

Gates beyond the targets: inKey and rub no worse than before (every flag moves notes onto the
key and off semitones against the pad, so a rise in rub is a bug), clip 0, `WaveOptions()` parity
bit-identical (the parity filter).

### Found, not fixed

- **The question can't be its own transposed cycle.** The roadmap's first idea (alternate cycles
  of one ring a step up / at the dominant) needs a per-cycle map in `WaveRunner.hit()`; with
  slot nets per phrase the pass covers it with bindings, so the runner path stays unbuilt.
- **A slot net shared by several windows is one set of bindings.** A melody slot that plays every
  verse's question gets the majority note (`.answer`) or the first window's hook bar (`.hook`):
  where two sections want different notes on one ring step, one of them loses. Fixing that is
  beats-side slot topology (an 8-bar ring per slot, beats v3).
- **House has no arp role**, so the roadmap's "house off-beat stabs" have nothing to rebind; it
  would be a new part, not a rewrite.
- **Contour by family is one table.** The roadmap wanted a bigram table per family; only RS200
  (rock vocals) is checked in, so every diatonic genre reads the same table, and pentatonic /
  blues keys (not seven degrees) skip `.shape`'s first step.
- **Net views show the bindings**, so the hook, the answer's tonic and the shaped notes are all
  visible in `NetSnapshot` (no runner-side mapping in 6.4).

### Listen checklist (`djctl render <g> 42 --out f.wav`, or the app in release)

Ear-gated: the numbers above are the claim, not that it sounds better. A/B one flag at a time
with `--fixes` (all names but the one against all).

- techno / trance / edm 42: can you hum the hook after the first drop, and is it there again
  (or inverted, in a bridge) after the breakdown? `--fixes` without `hook` for the A.
- synthwave / funk / house 42: bars 4 and 8 of each verse — does the first sound like a question
  and the second like it lands? Without `answer` for the A.
- lofi / jazz / bossa 42: fewer hammered repeats and a phrase that climbs to a peak late — a line,
  or busier for nothing? Without `shape` for the A.
- dnb / dubstep / techno 7: the bass saying its bar twice — a riff, or monotonous? Without
  `bassMotif` for the A (the call in §11).
- trance / synthwave / edm 42: the arp's figure — a trance roll, a synthwave octave climb — and
  its rate following the melody bar by bar; does the rate change read as phrasing or as the arp
  stumbling? Without `arpDensity` (then without `arpStyle`) for the A; if it stumbles, try
  `arpDensityDirection = -1` (the arp answers the melody instead of following it).
- any sampled-lead track (`--synth` off): the hook's notes on the sampler — in tune, in range?

Rows for Matt to add to `docs/listening-log.md` after listening (genre, seed, build, device;
verdict and first wrong are his, left blank here): techno 42, house 42, edm 42, trance 42,
dnb 42, dubstep 42, synthwave 42, lofi 42, jazz 42, funk 42, bossa 42, ambient 42 — every matrix
genre at seed 42, since the exit is *hummable* for at least half of them; 6.4 is done when the log
says so, not when the table above is green.
