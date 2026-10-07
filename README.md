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

| Device | Profile | Does |
|---|---|---|
| Hercules DJControl Inpulse 200 MK3 | `inpulse-200-mk3.json` | Jog wheels: touch + turn = scratch, ring = nudge, SHIFT = coarse seek |
| Akai APC mini mk2 (Control port) | `apc-mini-mk2.json` | Faders 1–3 A vol/filter/pitch, 4 crossfader, 6–8 B pitch/filter/vol, master; bottom grid row hot cues (A left, B right), row above clears them; scene 1/2 and track 1/8 play A/B; LED feedback |
| Akai MPK Mini Mk II | `mpk-mini-mk2.json` | K1–K8: A vol, B vol, crossfader, master, A/B filter, A/B pitch; pads 1–4 A cues, 5–8 B cues. **Factory map, unverified** — check with `djctl monitor mpk` |

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
