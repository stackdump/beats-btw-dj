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

## Where we are (2026-10-11)

Phases 1–5 of [ROADMAP.md](ROADMAP.md) are done on `main`; what is still open is listed
there. In short:

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
- **Sessions** — every control event is recorded; a set is a content-addressed `<cid>.json`
  that re-renders to the same bytes, exports to WAV and publishes to cdn.stackdump.com
  (`djctl publish`, or Publish… in the app, which shows the public URL).
- **Visuals** — waveform, platter, net / marking view, section timeline, APC grid mirror,
  device map, and beats' scopes and Stage ([SCOPES.md](SCOPES.md)). All tested by rendering
  offscreen; the scopes and Stage have not been looked at in a live window yet.
- **Remote control** — the running app listens on a local socket; `djctl mcp` is the
  `dj-vevr-se` MCP server over it.

Open: the Inpulse hardware pass (controls captured but unnamed, or never captured; which
centre knob is headphones); reverb / delay / pan / shape macros are not ported; the scopes
need a look on a real display.

## Controllers

All at once, hot-pluggable:

| Device | Profile | Bound | Parked |
|---|---|---|---|
| Hercules DJControl Inpulse 200 MK3 | `inpulse-200-mk3.json` (jogs) + `inpulse-200-mk3-surface.json` | Jogs (scratch / bend / shift-seek), PLAY, CUE, SYNC (beat; SHIFT+SYNC bar), SHIFT+CUE rewind, PFL, LOAD (next track), hot-cue pads + SHIFT clear, FX-mode pads 0x10–0x13 (macros cut / beat-repeat / drop / breakdown), pads 0x20+ (6 role mutes, section prev/next), pads 0x30+ (stingers 1–4), volume, filter, EQ low/mid/high, SHIFT+HIGH gain, pitch, crossfader, master, headphone level, LOOP (hold: record the deck's bars as a clip on the loop row), browser wheel (the playing loop's seed ± one per click, recomposed at the next bar); LEDs. `[MIXXX]`/`[UNVERIFIED]` (not yet seen on this unit): every SHIFT+control but the jog (SYNC, CUE, gain, hot-cue clear), hot-cue pads 2/4 on deck A and all on deck B, deck B PFL/LOAD, pads 0x20+/0x30+, the browser wheel, which centre knob is master vs headphones | the STEMS music / mic buttons (named, not bound yet); the three centre buttons (captured, not yet named); SHIFT+LOOP (VINYL, captured, no action yet); browser push and SHIFT+browser (not captured); SHIFT+PLAY, SHIFT+LOOP/STEMS, pad bend (not captured). SHIFT and the HOT CUE/FX mode buttons are hardware layers |
| Akai APC mini mk2 (Control port) | `apc-mini-mk2.json` | Faders: A vol / filter / pitch, crossfader, fader 5 = headphone cue mix, B pitch / filter / vol, master. Grid (rows from the bottom): row 1 hot cues (A 1–4, B 1–4), row 2 clear cue, rows 3–4 deck A sections 1–16, rows 5–6 deck B sections 1–16, row 7 macros drop / breakdown / cut / beat-repeat (A left, B right), row 8 half-time / tape-stop / double-drop / panic. Track 1 / 8 play A / B (SHIFT: quantize), track 2–7 role mutes kick / snare / hihat / bass / melody / harmony on A (SHIFT: on B). Scene 1–2 play A / B, 3–4 section prev / next A, 5–6 the same for B, 7–8 next track A / B. SHIFT (software); LEDs | DRUM mode pads (notes 64–79, ch 10) — instrument mode, pad positions not mapped yet |
| Akai MPK Mini Mk II | `mpk-mini-mk2.json` | Keys → the focus deck's net, snapped to its scale; joystick X = tempo nudge (focus deck); knobs 2–8 (A / B vol, crossfader, A / B filter, A / B pitch); pads in PROG CHANGE = hot cues (A 1–4, B 1–4); pads in NOTE mode, bank A = stingers 1–4 on A / B `[UNVERIFIED]` | knob 1 (CC 1 is also the joystick's Y axis in this preset); NOTE-mode bank B / pads 9–16 `[UNVERIFIED]` |

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

## Native ↔ browser bridge

The learner (`web/jog/learn.js`) is still JavaScript. The Go CLI records raw
bytes and the JS tooling interprets them:

```bash
./dj-vevr-se capture -o cap.json inpulse      # scratch, Ctrl-C
# open http://localhost:8765/jog/demo.html → "replay capture" → cap.json
```

Device values live in `Sources/DJCore/Resources/profiles/*.json`. If Go ever
needs them, read that JSON — don't hand-copy.
