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
