# dj-vevr-se

DJ-controller input for Petri-net music, driven **natively** rather than only
through the browser. Private; split out of
[beats-bitwrap-io](https://github.com/stackdump/beats-bitwrap-io)'s jog-wheel
lab (`public/jog/`, commit `b7704ba`) because the goals diverged: beats is a
deterministic, shareable web studio; this is live performance with real
hardware (first target: Hercules DJControl Inpulse 200 MK3).

**The app is Swift** (SwiftUI + CoreMIDI + AVAudioEngine), built with
SwiftPM — no Xcode project. The Go CLI and the browser lab stay as hardware
and capture tools.

## Where we are (2026-10-18, integrate/roadmap at `28d0b47`)

Phases 1–5 of [ROADMAP.md](ROADMAP.md) are done on `main`; Phase 6 (musicality) is built on
`integrate/roadmap` (below). What is still open is listed in the roadmap. In short:

- **Decks and mixer** — two decks, each a scratchable turntable (an audio file; ported from
  the lab's scrub worklet) or a **live Petri net** composed natively from genre + seed
  (+ structure), or loaded from a beats share link (composed or raw-`nets`). Volume, one-knob filter, 3-band EQ, gain, ±8 % pitch, crossfader, master,
  headphone cue on the Inpulse's outputs 3/4; 4 hot cues, sync, quantized cues and loops;
  scratching a net deck runs its clock backwards. "Awake" in the bottom bar keeps the screen
  from sleeping while the app is open (remembered between launches).
- **Generation** — beats' composer, arrange / overlays, share envelopes and URLs and its wave
  engine are ported to Swift and held to the same CIDs and bytes by fixtures from the real JS.
  In the app, installed Logic / GarageBand instruments and SoundFonts can stand in for the
  synth voices (the parity path stays beats-exact).
- **Performing a net** — section jumps, role mutes, stingers, MPK keys into the track's scale,
  beats' net macros and its 18 master-chain FX / pitch / feel macros, from any controller, the
  UI or MCP.
- **LOOP record and reverb** — hold a deck's LOOP to take its bars (dry, after the EQ) as a
  clip. Any number of clips loop under the mixer at once, each in or out on the downbeat, in
  time with its deck; drag a tile's edge to crop it to the beat, join tiles into sequences,
  move one onto A or B. The row is saved (`~/Library/Application Support/dj-vevr-se/loops`).
  Removing a loop never deletes it: it moves to `loops/removed/` (Undo for 8 s, or Removed… to
  restore it where it was, or delete it for good). Loops can be renamed (double-click) and
  coloured, filtered by deck / sequence / search / near the playing tempo, traced back (Load
  source on A/B reloads the track at its section), exported as WAV or dragged out to Finder.
  A quick tap of LOOP (on screen or the Inpulse) records exactly N bars from the downbeat (the
  "tap N" chip beside it: 1/2/4/8, default 2); ⟲ 1 2 4 grabs the last bars the deck already
  played, after the fact, from its ~21 s history.
  Loops launch on a beat, a bar, or a 2-, 4- or 8-bar phrase of the playing deck ("Launch
  on"), and a waiting tile counts down to it ("in 3"). "Save scene" keeps the loops playing
  now (and their levels) as a chip: tap it and exactly those come in, the rest go out, on one
  boundary. Scenes are saved with the row.
  Each loop has mute (silent, still in phase), solo and 🔒 key (key lock: at another tempo it
  plays a WSOLA time-stretched copy, made in the background, instead of going sharp or flat);
  loops come in and go out with a fade (off, 10 ms de-click, 1 beat, 1 bar).
  Every channel has a reverb (Apple's AUReverb2: wet, size, tone) in its Reverb section.
- **Sessions** — every control event is recorded; a set is a content-addressed `<cid>.json`
  that re-renders to the same bytes, exports to WAV and publishes to cdn.stackdump.com
  (`djctl publish`, or Publish… in the app, which shows the public URL).
- **Visuals** — waveform, platter, net / marking view, section timeline, APC grid mirror,
  device map, and beats' scopes and Stage ([SCOPES.md](SCOPES.md)). All tested by rendering
  offscreen; the scopes and Stage have not been looked at in a live window yet.
- **Remote control** — the running app listens on a local socket; `djctl mcp` is the
  `dj-vevr-se` MCP server over it.

### The product path: `WaveOptions.extended` and `Fixes.all`

Two ways to play a net, and only one is the product:

- **`WaveOptions()` is the parity path** — beats' wave engine exactly: no instrument table, no
  musicality, no limiter, beats' `tanh` master curve, no loudness gain. It is what the beats
  fixtures run (`compose()`, shares, CIDs and the wave engine held to the real JS's bytes), and
  it stays beats-exact; nothing below changes it.
- **`WaveOptions.extended` is what the app plays** (`Deck.waveOptions`, `djctl render`): the
  instrument table (`Resources/voices/instruments.json`), the deck's sampler bank voiced by the
  track's seed, every `DJMusicality.Fixes` flag (`Fixes.all`), the vinyl brake, and
  `master = "limit"`. `compose()` still runs beats' composer byte for byte; the deck plays
  `PreparedTrack.played` = `DJMusicality.apply(project, spec:)` (bindings and initial markings
  only), and the rest is the runner. Per-genre settings (room, echo, voice design, groove
  template, HF tilt, duck depth) come from `forGenre`.

`Fixes.all`, by the part that added each flag (`djctl render --fixes none|all|name,…` takes
these names; [docs/musicality-notes.md](docs/musicality-notes.md) has the numbers):

| part | flags |
|---|---|
| A — key, time, register | `key`, `timing`, `register`, `dynamics`, `loudness`, `groove`, `offbeatBass`, `phrases` |
| C — form, harmony, mix | `fills`, `voicing`, `energy`, `duck`, `contour`, `color` |
| D — parts that do their job, gestures, stereo | `arpeggio`, `buildup`, `crash`, `bassLine`, `openHats`, `stereo` |
| E — phrasing, the drop, a room | `legato`, `cadence`, `approach`, `dropGap`, `choke`, `space` |
| F — sound design, a motif, a balanced mix | `subtractive`, `unison`, `echo`, `kickTune`, `motif`, `balance` |
| G — a song of its own per seed | `variety` |
| 6.2 — arrangement | `layerBudget`, `bandStop`, `kickOut`, `riser` |
| 6.3 — harmony that goes somewhere | `harmonicCadence`, `sectionHarmony`, `harmonicRhythm` |
| 6.4 — a hook, and an answer | `answer`, `hook`, `shape`, `bassMotif`, `arpStyle`, `arpDensity` |
| 6.5 — a beat in every genre | `backbeat`, `feel`, `drift`, `sweep` |
| 6.6 — sound and mix | `subOctave`, `hfTilt`, `shimmer` |

(Part B was visual polish: no flag.)

- **Runner-only subset** — a raw-`nets` share was never composed, so the pass has nothing to
  rewrite: its deck plays `Fixes.runnerOnly` (`loudness`, `groove`, `energy`, `duck`, `stereo`,
  `dropGap`, `choke`, `space`, `subtractive`, `unison`, `echo`, `kickTune`, `balance`, `feel`,
  `drift`, `sweep`, `layerBudget`, `bandStop`, `kickOut`, `riser`, `subOctave`, `hfTilt`,
  `shimmer`). Not the pass's flags, nor the runner halves of pass flags (`fills` / `buildup` /
  `crash` / `openHats` voicing, `backbeat`'s brushes, `sectionHarmony` / `harmonicRhythm`),
  which would re-voice or re-pitch nets the composer did not build. `dj_state` reports the
  deck's set by name.
- **Level match and limiter** — `.loudness` gains a net deck to `LevelMatch.referenceLUFS`
  (−12 LUFS integrated; `Loudness.targetDB`, per family), and the deck's `PeakLimiter`
  (stereo-linked, lookahead, true-peak) holds it under −1 dBTP after the master chain, before
  the deck's EQ. Measured, not listened to: whole songs sit at −12.0 ± 0.5 LUFS synth, −12.3 ±
  0.5 sampled (notes §10). The loop channel is trimmed −3 dB to sit level with A / B at the
  centred crossfader.
- **The sampled path** — installed Logic / GarageBand EXS instruments and SoundFonts stand in
  for the synth voices (`VoiceCatalog`, a sound palette per track, Studio by default); each
  slot is level-normalised on load and measured per part, the loudness probe plays it at that
  level, and `balance`, `stereo` (per-category width) and `echo` reach sampled parts. Sampled
  renders depend on what this Mac has installed, and some instruments vary between renders on
  purpose; GM programs and synth voices are byte-identical on replay.

Where to look: [docs/musicality-notes.md](docs/musicality-notes.md) (what each part changed,
measured, before / after matrices), [docs/listening-log.md](docs/listening-log.md) (what a
person heard: rows only a listener writes; the 6.7 first set waits there), and
[GO-DIVERGENCE.md](GO-DIVERGENCE.md) §5 (the generator bugs these fixes work around, to
backport to beats).

Open: the Inpulse hardware pass (controls captured but unnamed, or never captured; which
centre knob is headphones); reverb / delay / pan / shape macros are not ported; the scopes
need a look on a real display.

## Controllers

All at once, hot-pluggable:

| Device | Profile | Bound | Parked |
|---|---|---|---|
| Hercules DJControl Inpulse 200 MK3 | `inpulse-200-mk3.json` (jogs) + `inpulse-200-mk3-surface.json` | Jogs (scratch / bend / shift-seek), PLAY, CUE, SYNC (beat; SHIFT+SYNC bar), SHIFT+CUE rewind, PFL, LOAD (next track), hot-cue pads + SHIFT clear, FX-mode pads 0x10–0x13 (macros cut / beat-repeat / drop / breakdown), pads 0x20+ (6 role mutes, section prev/next), pads 0x30+ (stingers 1–4), volume, filter, EQ low/mid/high, SHIFT+HIGH gain, pitch, crossfader, master, headphone level, LOOP (hold: record the deck's bars as a clip on the loop row), STEMS music / mic (net decks: mute everything but the drums / the lead; again brings back what they silenced), LOOP pad mode pads (SHIFT + HOT CUE: loops 1–4 on deck A, 5–8 on deck B, in/out on the downbeat, lit while playing), browser wheel (the playing loop's seed ± one per click, recomposed at the next bar); LEDs. `[MIXXX]`/`[UNVERIFIED]` (not yet seen on this unit): every SHIFT+control but the jog (SYNC, CUE, gain, hot-cue clear), hot-cue pads 2/4 on deck A and all on deck B, deck B PFL/LOAD, pads 0x20+/0x30+, the browser wheel, which centre knob is master vs headphones | the three centre buttons (captured, not yet named); SHIFT+LOOP (VINYL, captured, no action yet); browser push and SHIFT+browser (not captured); SHIFT+PLAY, SHIFT+LOOP/STEMS, pad bend (not captured). SHIFT and the HOT CUE/FX mode buttons are hardware layers |
| Akai APC mini mk2 (Control port) | `apc-mini-mk2.json` | An FX surface beside the Inpulse, laid out as beats.bitwrap.io maps it (lib/backend/apc-mini-mk2.js), acting on the **aimed deck** (scene 4 / 5 aim at A / B; else whichever deck a controller touched last). Grid = beats' macro catalog in beats' rows from the bottom: mutes (drop, breakdown, solo drums, cut, beat-repeat, double drop), FX (sweep LP / HP, reverb wash, riser; bit crush, phaser drone, res ping), pan (not in dj: dark), pitch + tempo (octave up / down, pitch bend, vinyl brake, half time, tape stop, tempo anchor), feel (chill … reset), —, hits 1–4; lit in beats' group colours, bright while a macro runs. Track buttons: mute kick / snare / hihat / clap / bass / melody / harmony / arp. Scenes: play, regenerate (next seed), auto-next, aim A, aim B, FX reset, next track, panic. Faders: phaser wet, distortion, reverb wet, reverb size, LP, HP, master pitch, crush; master. SHIFT (software) + grid = the loop page: loops 1–64 read like text from the top-left, in/out on the downbeat, violet while playing; LEDs (`[UNVERIFIED]`: the blink status 0x9E) | DRUM mode pads (notes 64–79, ch 10) — instrument mode, pad positions not mapped yet |
| Akai MPK Mini Mk II | `mpk-mini-mk2.json` | Keys → the focus deck's net, snapped to its scale; joystick X = tempo nudge (focus deck); knobs 2–8 (A / B vol, crossfader, A / B filter, A / B pitch); pads in PROG CHANGE = hot cues (A 1–4, B 1–4); pads in NOTE mode, bank A = stingers 1–4 on A / B, bank B = loops 1–8 (pad n = loop n) `[UNVERIFIED]` | knob 1 (CC 1 is also the joystick's Y axis in this preset) |

Every control is either bound or explicitly parked with a reason (`"action": "unbound"`), and
tests replay every distinct message captured from the real hardware on 2026-10-07. Two devices
on one parameter: last mover wins, with soft takeover (a knob must reach the current value
before it takes over). `djctl monitor` shows each message's control name and what it does.

The layouts are data: edit the `layout` array in the profile JSON.

```bash
make swift-test                           # swift-testing suite (DJCore)
make djctl ARGS=ports                     # Swift CoreMIDI: list sources/destinations
make djctl ARGS="monitor"                 # raw bytes, decoded per device profile
make djctl ARGS="play a.wav b.mp3"        # headless: two decks + every controller (demo loop if no file)
make run-app                              # build build/DJApp.app (DEBUG, ad-hoc signed) and open it
make run-app-release                      # the same, optimized: use this to listen / judge the audio
make fmt lint                             # swift format (bundled with the toolchain)

make build && ./dj-vevr-se ports          # Go CLI: list MIDI ins/outs
make monitor MATCH=inpulse                # print messages live (Ctrl-C to stop)
./dj-vevr-se capture -o jog-capture-native.json inpulse   # record, Ctrl-C writes
make test                                 # swift + go + node --test web/jog
make serve                                # browser lab on http://localhost:8765/jog/
make devices                              # live device maps (Chrome): http://localhost:8765/devices/
```

## Layout

| Path | What |
|---|---|
| `Package.swift` | SwiftPM manifest, macOS 15+. |
| `Sources/DJCore/` | `Turntable` (real-time DSP, fed by a lock-free `SPSCRing`), `DJEngine`/`Deck` (AVAudioEngine graph, mixer, cues), `JogAdapter`, `SurfaceProfile`/`SurfaceController` (pads/faders + LEDs), `ControllerHub` (matches ports to profiles, hot-plug), `MIDIIn`/`MIDIOut`. |
| `Sources/DJCore/Beats/` | beats' generator, share envelopes / URLs and wave engine (`Wave/`, master chain in `Wave/MasterFx/`), ported from the JS. |
| `Sources/DJCore/Session/`, `Sources/DJCore/Scopes/` | Session record / replay / publish; the scope and stage models. |
| `Sources/DJCore/Resources/profiles/*.json` | **Device profiles — single source of truth.** `web/jog/profile-parity.test.mjs` fails if the JS copy drifts. |
| `Sources/djctl/` | Swift CLI for hardware checks. |
| `Sources/DJApp/` | SwiftUI app; `scripts/bundle-app.sh` wraps it in `build/DJApp.app`. |
| `Sources/DJViews/` | SwiftUI views (the only SwiftUI outside `DJApp`). |
| `Tests/DJCoreTests/`, `Tests/DJViewsTests/` | swift-testing tests; views are tested by rendering them to pixels. |
| `cmd/dj-vevr-se/` | Native CLI over [gomidi](https://gitlab.com/gomidi/midi) + rtmidi (CoreMIDI on macOS, ALSA on Linux). |
| `internal/capture/` | Captures as `[{t, d, port}]` — the exact shape `web/jog/replay.js` reads, so a native capture replays in the browser demo and feeds `analyze-capture.mjs`. |
| `web/jog/` | The browser lab as it was in beats: device profile, mock Web MIDI, simulator, adapter, Petri clock, calibration wizard. See its README and ROADMAP. |
| `web/lib/bjorklund.js` | The one function the lab borrowed from beats, vendored. |

## Device maps

`web/devices/` draws all three controllers from their profile JSON (via the
`web/profiles` symlink), coloured by binding: bound / parked / no entry / jog /
sends no MIDI. In Chrome it listens over Web MIDI: moving a control lights it
with its value and logs the bytes and what the app does with them; clicking a
control shows its MIDI numbers and binding and can flash its LED on the device.
Each card also lists profile controls the diagram doesn't draw. Physical
positions are traced from product photos (Inpulse MK3 and MPK mkII from
Sweetwater, APC mini mk2 from Akai) — approximate, not measured.

## Build dependencies

- **Xcode Command Line Tools** with Swift 6.2+ (`xcode-select --install`) — enough
  for everything above. With only the CLT, swift-testing's framework is off the
  default search path; the Makefile adds `-F` flags for `swift test`
  automatically, so always test via `make swift-test`.
- **Full Xcode (optional, App Store)** — needed later for Instruments (audio
  thread profiling), AUv3 extensions, and notarized distribution. After
  installing: `sudo xcode-select -s /Applications/Xcode.app`.
- Go 1.25+ and node (for the Go CLI and the web lab tests).

## Data and attribution

- `Sources/DJCore/Resources/beats/grooves.json` (the groove templates, `make groove-templates`)
  is derived from the [Groove MIDI Dataset](https://magenta.tensorflow.org/datasets/groove)
  by Jon Gillick, Adam Roberts, Jesse Engel, Douglas Eck and David Bamman (Google Magenta),
  licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/): per-position timing and
  velocity averages only, no MIDI from the dataset is in this repo. Gillick et al., "Learning
  to Groove with Inverse Sequence Transformations", ICML 2019.
- `Sources/DJCore/Resources/beats/melody-bigrams.json` (the melody degree bigrams, `make
  melody-bigrams`) is derived from the [RS200 melodic transcriptions](https://rockcorpus.midside.com/)
  by Trevor de Clercq and David Temperley, licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/): scale-degree counts only, no
  transcription from the corpus is in this repo. de Clercq & Temperley, "A Corpus Study of Rock
  Music", Popular Music 30/1, 2011.

## Native ↔ browser bridge

The learner (`web/jog/learn.js`) is still JavaScript. The Go CLI records raw
bytes and the JS tooling interprets them:

```bash
./dj-vevr-se capture -o cap.json inpulse      # scratch, Ctrl-C
# open http://localhost:8765/jog/demo.html → "replay capture" → cap.json
```

Device values live in `Sources/DJCore/Resources/profiles/*.json`. If Go ever
needs them, read that JSON — don't hand-copy.
