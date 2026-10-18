# Go vs JS generator divergences (follow-up for beats-bitwrap-io)

**Decision (2026-10-08): the JS generator is canonical.** Shipped share links were
composed with `public/lib/generator/*.js`; Swift in this repo follows the JS
byte for byte (`ComposerGateTests`). beats' Go generator (`internal/generator`)
is *not* identical, so it cannot regenerate a JS-composed share exactly.
Nothing here modifies beats-bitwrap-io; this is the list to take to that repo.

Evidence: `make fixtures-go` composes all 542 JS-fixture cases in Go
(`scripts/beats-go-oracle.mjs`, data in `Tests/DJCoreTests/Fixtures/beats/go.json`).
Go's model CID equals JS's for **0 of 542**. Re-measured against beats `668978e`.
`BeatsGoOracleTests` documents this as known-diffs and pins what *does* agree, so a
fix in beats shows up as a failing "known divergence" test to update.

## 1. Drum MIDI channels

Go gives every drum voice channel 10. JS gives kick 10, snare 11, hihat 12, clap 13
(`composer.js`; the `edm` clap is this same difference, not a separate bug). The
channel is part of the canonical model JSON, so this alone changes the CID of every
project. Everything else in the kick, snare, hihat (non-ghost) and clap nets is
identical. With JS channels 11–13 mapped to 10, 24 whole projects (ambient,
synthwave, metal loops and their override variants) match Go exactly.

## 2. RNG: `math/rand` vs mulberry32 / the variety LCG

Go's `Compose` and `GhostNoteHihat`, `WalkingBassLine`, `CallResponseMelody`, markov
and friends draw from `rand.New(rand.NewSource(seed))`. JS draws from `mulberry32`
(composer, markov, riffs) and from the 31-bit LCG in `variety.js`. The streams are
unrelated, so every net whose notes or rests come from a draw differs: v1 bass and
melody, ghost-note hihats, walking bass, call/response, instrument choice, chord
progression pick, structure blueprint pick, drum-fill and stinger seeds. Cohesion-v2
bass/melody/harmony/arp nets agree because they come from `BuildTrackTheme`, which
*is* held in lockstep (`theme_parity_test.go`) — except two v2 bass nets in genres
not yet identified.

## 3. Structure control nets: linear chains vs accumulator nets

In song mode Go emits the `struct-*` control nets as linear chains (one place and
transition per tick, ~40 KB each for a 320-tick `minimal` song). JS
`structure.js::buildAccumulatorNet` emits compact countdown/gate nets (~2–5 KB).
Different nets, so different CIDs even for identical sections. (Go also produced
fewer slot nets in the one case inspected, which follows from the RNG-driven
blueprint pick in #2.)

## 4. JS-internal: a share's counterMelody overlay never plays in the browser

Not a Go/JS difference, but one for the same list. On the composer path
`lib/backend/index.js` runs `arrangeWithOpts(el._project, …, { overlayOnly: true, … })` on
the worker's project-sync JSON. `injectCounterMelody` simulates the source nets, which are
plain objects there, so `nb.resetState()` throws (`nb.resetState is not a function`) whenever an
entry's section exists. The catch only logs, and since the throw comes after `fadeIn` /
`drumBreak` / `feelCurve` mutated `el._project` in place but before `project-load`, the worker
plays none of the overlay. Full arranges hit the same throw on cloned variant nets
(`cloneBundle` is a JSON round trip). Swift deliberately runs the overlay on parsed nets, so the
counter-melody plays (ROADMAP 2.8, "Deliberate deviation"); fixtures hold Swift to what the JS
function does with `NetBundle`s, and `wireProbe` records the browser throw.

## What to decide in beats

Either align Go to JS (channels, a mulberry32/LCG port, accumulator nets), or
declare Go output non-canonical and keep Go away from share regeneration. Until then nothing
in the Swift app depends on Go. For #4, decided 2026-10-12: parse the nets before simulating, as dj does (§5) — shares with a
counter-melody then start to sound different in the browser.

## 5. dj improvements to backport to beats (decision 2026-10-12)

Where dj and beats' JS differ by design, dj keeps its behaviour and beats takes the
improvement. When one lands in beats, regenerate the fixtures at the new beats commit and drop
the matching deviation note (ROADMAP 2.8 / 3.3).

1. **counterMelody overlay plays** (#4 above; ROADMAP 2.8). Run the overlay on parsed nets
   (`NetBundle`s), so the counter-melody plays and fadeIn / drumBreak / feelCurve are no longer
   dropped with it. Same fix for full arranges (`cloneBundle`'s JSON round trip).
2. **A neutral master chain is transparent** (ROADMAP 3.3). With `&fx=tone`, bypass HP / LP /
   pitch shift while they are at rest (beats' chain at rest still colours: HP 20 Hz, LP 20 kHz,
   the pitch shifter's fixed taps), fade them in and out of bypass over 5 ms, and drop the
   always-on Compressor(-12, 3).
3. **FX macros survive a project hand-over** (ROADMAP 3.3). beats' project-sync on regen / swap
   cancels running FX macros; dj lets them finish.

4. **Musicality fixes** (docs/musicality-notes.md; `DJMusicality`, run on the composed project
   before a deck plays it — dj's `compose()` and the model CID stay beats'). Generator bugs
   beats should fix at the source:
   - tension variants change key: `expandVariants` adds `registerShift` (+2 / −3) to the root
     and rebuilds the scale there, so B / C sections play a whole tone up / a minor third down
     over the home-key pad. dj moves those notes back (`.key`).
   - structure changes drift: `buildAccumulatorNet` gives every stage after the first `gap`
     ticks plus the tick its gate takes (one sixteenth later per event), and even the first
     fires on the downbeat's own tick, after the music nets have played it, so entering parts
     lose their first beat. dj starts every stage with `gap − 1` (`.timing`).
   - drum fills never sound: `drumFillNet` is a `control` net (no voice), starts muted and its
     `struct-fill-N` net carries no unmute; its toms (45 / 48 / 43) have no wave-engine voice
     either (they fall to hat / kick). dj unmutes them, voices `fill-*` nets and plays them as a
     swelling snare roll (`.fills`).
   - the section energy arc is lost: the composer writes each section's `energy` /
     `filterOpen` as `set-feel` controls; the wave engine drops them, and the Tone path feeds
     them to the feel pad, whose axes are tone and **tempo**, so a breakdown (filterOpen 0.25)
     plays at 0.8× BPM. dj plays them as level and a tonal lowpass with buildup sweeps
     (`.energy`, `EnergyCurve`).
   - the arp doubles the melody: with sections, `expandVariants` builds each arp slot from the
     melody's motif (`motifNet`) or a Markov line, so it plays the lead's notes in unison
     (synthwave) or an octave under it (trance) and arpeggiates nothing. dj plays the bar's pad
     chord in sixteenths (`.arpeggio`).
   - basses leap: `chordBassRing` takes every root from one octave of the scale, so a
     progression that comes back round jumps a sixth or seventh (and some land under E1, C1 in
     techno 42). dj moves whole bars by octaves to the smallest motion (`.bassLine`).
   - no open hats: the wave engine's drum map voices notes 42–46 as one closed hat, so the
     four-on-the-floor genres have no off-beat open hat. dj binds those to 46 and voices it
     (`.openHats`).
   - motifs never repeat inside a phrase: `generateMotif` walks every one of the 4 bars at
     random, so no bar of a phrase sounds like another. dj restates bar 1 in bar 2 as a diatonic
     sequence onto bar 2's chord (`.motif`); the generator could do it at the source.
   - the mix is the kick: one fixed level per voice family puts bass and lead 12–19 dB
     (K-weighted) under the kick in the dance genres. dj measures each part soloed and trims it
     (`.balance`, `MixBalance`); beats' voice levels want the same rebalancing.
   - the wave engine's saws stop at the 8th partial and never move (no filter envelope), the
     kick ends on 48 Hz in every key, and there is no delay: dj adds band-limited tables and a
     filter envelope (`.subtractive`), detuned pairs (`.unison`), a key-tuned kick
     (`.kickTune`) and a tempo echo (`.echo`).
   - the chill family (lofi, and jazz / bossa likewise) activates kick and snare only in
     buildup / drop / pre-chorus / solo, which their `standard` songs do not have: a lofi song
     is hats, bass, keys and no beat. Not fixed in dj yet (it needs the role control nets'
     unmutes rewritten); a table change in beats is the simple fix.
   - every seed of a genre is the same backing track: the key, scale and tempo are the
     genre's, cohesion v2's chord plan comes from one or two `chordProgs` per genre (techno has
     one), the bass is the plan's roots on the genre's groove mask, the pad is the plan, and
     the drums are seeded from the genre's name (`drumSeed(genreName)`, and
     `"genre:role:letter"` per slot) — so only the melody and the instrument picks follow the
     seed. dj moves each track to its own key, progression, bass figure and drum detail,
     seeded from the seed (`.variety`, `TrackVariety.swift`). In beats it would change what a
     seed composes, so a new cohesion version (`v3`) rather than an edit to v2.

5. **vinyl-brake is a turntable brake** (`TurntableBrake.swift`, `WaveOptions.turntableBrake`, on
   in `.extended`). beats' catalog makes it a compound of tape-stop (0 ms) and octave-down
   (60 ms), but `runCompound` fires only mute and FX sub-macros, so the tape-stop step does
   nothing and all that plays is an octave-down hold for a bar: an instant, grainy octave drop
   (the pitch shifter), not a brake. dj plays it as a platter spinning down: varispeed on the
   deck's whole output (the net renders in source time at rate r ≤ 1, resampled, so pitch and
   tempo fall together), r falling linearly to 0 over three quarters of the duration, silence
   for the last quarter, then the deck drops back in where it would have been had it kept
   playing (the tick clock caught up silently), so it stays on the other deck's beat and bar.
   The parity path (`WaveOptions()`, the fixtures) keeps beats' compound. For beats: run the
   step through `Tone.Transport` / the worker's tempo and a playback-rate ramp on the master
   (or, simplest, make the tape-stop step fire `tempo-sweep` in `runCompound`, then resync the
   transport at the end instead of snapping the tempo back mid-bar).

6. **Sampled drum kits** (dj option, off by default; `DrumKits`, `SamplerSource.kit`). beats'
   drum lanes always play its synth kits (`_synthDrumKit` / `drumVoice`). A dj track may pick a
   sound bank's kit instead — a GM percussion preset (bank 128) of an installed SoundFont or
   Apple's `gs_instruments.dls`, or a melodic "kit" preset with fixed-pitch zones — as a
   `tracks` override (`{"10": {"kit": "MuseScore_General.sf2#128:0"}, "11": …}` on every drum
   channel; beats ignores the key, so the share still composes and plays there, on the synth
   kit). The deck plays each drum kind on its GM key (kick 36, snare 38, clap 39, closed hat
   42, open hat 46, crash 49) through its `SamplerBank`, the kit level-matched on load to the
   synth kit (`kitTargetRMSdB`) and moved by `.balance`'s kick trim. The parity path
   (`WaveOptions()`: no bank, no instrument table) never samples drums, so the fixtures and
   `compose()` are unchanged. For beats: a kit choice would be a share-payload change, so only
   if beats wants sampled kits at all, and then with banks it may redistribute.
   Sound palettes (`SoundPalette`, the `tracks` override `palette`) are dj-only the same way;
   the Minecraft palette is local-only and never leaves the Mac, so it is not for beats.

7. **One loudness: a limiter instead of the tanh, tracks at −12 LUFS** (LevelMatch.swift,
   `PeakLimiter`, `WaveOptions.master = "limit"`, on in `.extended`). beats' wave engine ends in
   `tanh(0.8 × sum)`, and its tracks come out at whatever level their voices sum to: −17…−22 LUFS
   (lofi, jazz quietest), ~10 dB under an Apple loop or a commercial dance track, so a DJ mixing
   one against a loop has to ride the fader. dj normalises every track (`.loudness`, retargeted to
   `LevelMatch.referenceLUFS` = −12 LUFS integrated), keeps the runner's sum linear, and ends the
   deck in a lookahead peak limiter (1.5 ms, fast + slow release, ceiling −1 dBFS) after the
   master chain. Measured (`djctl render <genre> 4242`, whole songs): −11.8…−13.9 LUFS, peaks −1
   dBFS, median gain reduction ≤ 0.3 dB, 95th percentile ≤ 1.8 dB. Sample decks are levelled to
   the same reference on load. The parity path (`WaveOptions()`) keeps beats' tanh and no gain.
   For beats: the same normalisation (a per-track gain from a short loudness probe of the busiest
   section) and a limiter on the master would let its feed and share links play at one level.
   The loudness probe can't hear sampled instruments: dj plays sampled parts in it at measured
   offsets under their synth voices (`Loudness.sampledPartDB`), because samplers are levelled on a
   short phrase to the lead and take no `.balance` trim, and so sit 2–6 dB under the synth part
   they replace in a song (pads most).

8. **A beat in the chill family's verses and choruses** (`.backbeat`, Backbeat.swift; ROADMAP
   6.5). beats' theme table (`themes.<genre>.energy`) activates lofi, jazz and bossa's kick and
   snare only in buildup / drop / pre-chorus (jazz and bossa's kick also in the outro), and
   their `standard` blueprints have none of those, so those songs never play a beat. dj brings
   both parts in for every verse, pre-chorus, chorus and drop (lofi also buildup) and plays the
   family's figure: lofi boom-bap (kick 0 / 7 / 10, snare 4 / 12), jazz a feathered kick on every
   beat under a soft 2 and 4, bossa a surdo (0 / 6 / 8 / 14) and the bossa clave on the rim
   (0 / 3 / 6 / 10 / 13). dj may not add stages, so where the struct net has too few the edges
   ride on the fill chains. The parity path and `compose()` are unchanged. For beats: add `kick`
   and `snare` to those sections' theme roles (the control nets then carry the changes) and the
   figures to the family's drum specs (`kick` / `snare` in the genre table, or a theme
   `groove` drum map). beats' jazz drums are 12-step rings (three beats against a 16-step bar:
   the pattern drifts a beat every bar); a 16-step ring would let jazz play a true 2 and 4, which
   dj's 12-step fallback (snare on every beat) cannot.

beats bugs found on the way (dj matches beats today; fix in beats first, then follow):
- `scope-model.js` models Tone's `rolloff: -48` as four biquads; Tone cascades three.
