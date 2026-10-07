# dj-vevr-se

DJ-controller input for Petri-net music, driven **natively** rather than only
through the browser. Private; split out of
[beats-bitwrap-io](https://github.com/stackdump/beats-bitwrap-io)'s jog-wheel
lab (`public/jog/`, commit `b7704ba`) because the goals diverged: beats is a
deterministic, shareable web studio; this is live performance with real
hardware (first target: Hercules DJControl Inpulse 200 MK3).

**The app is Swift** (SwiftUI + CoreMIDI, AVAudioEngine next), built with
SwiftPM — no Xcode project. The Go CLI and the browser lab stay as hardware
and capture tools.

```bash
make swift-test                           # swift-testing suite (DJCore)
make djctl ARGS=ports                     # Swift CoreMIDI: list sources/destinations
make djctl ARGS="monitor inpulse"         # raw bytes + decoded jog events
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
| `Sources/DJCore/` | Profile loading, jog parsing (`JogEvent`), CoreMIDI input (`MIDIIn`). |
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
