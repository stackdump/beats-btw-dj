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

Two decks (scratchable turntables ported from the lab's scrub worklet), a
mixer (volume, one-knob filter, ±8 % pitch, crossfader, master) and 4 hot cues
per deck. Supported controllers, all at once, hot-pluggable:

| Device | Profile | Bound now | Parked for later phases |
|---|---|---|---|
| Hercules DJControl Inpulse 200 MK3 | `inpulse-200-mk3.json` (jogs) + `inpulse-200-mk3-surface.json` | Jogs (scratch / bend / shift-seek), PLAY, CUE, LOOP IN/OUT, shift+loop halve/double, hot-cue pads + shift-clear, volume, filter, EQ low/high, gain, pitch, crossfader; LEDs | sync, roll/FX/sampler pads, PFL, load, browser, two unidentified centre knobs |
| Akai APC mini mk2 (Control port) | `apc-mini-mk2.json` | Faders (A vol/filter/pitch, crossfader, B pitch/filter/vol, master), hot-cue + clear rows, play buttons, SHIFT (software); LEDs | grid rows 2–7, track 2–7, scene 3–8, fader 5 — Phase 3 section launcher |
| Akai MPK Mini Mk II | `mpk-mini-mk2.json` | Knobs 2–8 (A/B vol, crossfader, A/B filter, A/B pitch), pads (PROG CHANGE) = hot cues | keys, joystick, pad NOTE mode — Phase 3 instrument; knob 1 shares CC 1 with the joystick |

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
make run-app                              # build build/DJApp.app (ad-hoc signed) and open it
make fmt lint                             # swift format (bundled with the toolchain)

make build && ./dj-vevr-se ports          # Go CLI: list MIDI ins/outs
make monitor MATCH=inpulse                # print messages live (Ctrl-C to stop)
./dj-vevr-se capture -o jog-capture-native.json inpulse   # record, Ctrl-C writes
make test                                 # swift + go + node --test web/jog
make serve                                # browser lab on http://localhost:8765/jog/
```

## Layout

| Path | What |
|---|---|
| `Package.swift` | SwiftPM manifest, macOS 15+. |
| `Sources/DJCore/` | `Turntable` (real-time DSP, fed by a lock-free `SPSCRing`), `DJEngine`/`Deck` (AVAudioEngine graph, mixer, cues), `JogAdapter`, `SurfaceProfile`/`SurfaceController` (pads/faders + LEDs), `ControllerHub` (matches ports to profiles, hot-plug), `MIDIIn`/`MIDIOut`. |
| `Sources/DJCore/Resources/profiles/*.json` | **Device profiles — single source of truth.** `web/jog/profile-parity.test.mjs` fails if the JS copy drifts. |
| `Sources/djctl/` | Swift CLI for hardware checks. |
| `Sources/DJApp/` | SwiftUI app; `scripts/bundle-app.sh` wraps it in `build/DJApp.app`. |
| `Tests/DJCoreTests/` | swift-testing tests. |
| `cmd/dj-vevr-se/` | Native CLI over [gomidi](https://gitlab.com/gomidi/midi) + rtmidi (CoreMIDI on macOS, ALSA on Linux). |
| `internal/capture/` | Captures as `[{t, d, port}]` — the exact shape `web/jog/replay.js` reads, so a native capture replays in the browser demo and feeds `analyze-capture.mjs`. |
| `web/jog/` | The browser lab as it was in beats: device profile, mock Web MIDI, simulator, adapter, Petri clock, calibration wizard. See its README and ROADMAP. |
| `web/lib/bjorklund.js` | The one function the lab borrowed from beats, vendored. |

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
