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
