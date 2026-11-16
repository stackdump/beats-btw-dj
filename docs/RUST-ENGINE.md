# Rust engine embed

> 2026-11-14: the crate copy described below is gone: the XCFramework is built from djandroid's
> own crate at pinned revs, and the djandroid port (DJRustUI, the iPad app) is the way forward.
> See docs/ANDROID-PORT.md. The DJApp toggle below still works.

Runs the Rust DJ engine ([stackdump/djrust-vevr-se], private) inside this Swift app, the way
`djandroid-vevr-se` nests it behind a native shell (Kotlin there, Swift here). Spike: nothing
pushed, nothing published.

## Architecture

```
SwiftUI (DJViews / DJApp)           unchanged
   │  AppModel.useRustEngine  (View ▸ Rust Engine ⌥⌘R, or DJ_ENGINE=rust; default OFF)
   ▼
DJRust (SwiftPM target)             Sources/DJRust/RustEngine.swift   thin Swift face
   │                                Sources/DJRust/djmobile.swift     UniFFI-generated bindings
   ▼
djmobileFFI.xcframework             rust/dist/ (gitignored, built by script)
   │   macos-arm64_x86_64 · ios-arm64 · ios-arm64_x86_64-simulator   (static libdjmobile.a)
   ▼
djandroid-vevr-se rust/ (djmobile)  built as-is from a pinned snapshot (rust/PINS, rust/upstream/)
   ▼
djrust-vevr-se + djrust + windwheel  snapshots at the same pins (docs/ANDROID-PORT.md)
```

- **Surface = djandroid's.** `Player` (decks "A"/"B": `compose`, `set_playing`, `state`, pitch,
  volume, roles, tricks/macros, auto-next, TD-3 loops, crossfader/mix, vocoder, stage feed, HEOS)
  is the UniFFI object Kotlin drives over JNA; Swift gets the identical API via
  `uniffi-bindgen --language swift`. Android's JNI `NativeInit` is dropped (Apple needs no
  `ndk_context`). Added here: `render_offline()` (sound-card-free smoke) and `DJ_AUDIO_DEVICE`.
- **Rust owns its audio**: `Player::new` opens the default output through cpal → CoreAudio and runs
  the engine tick itself. So Rust *replaces* DJEngine's AVAudioEngine graph per deck, never mixes
  with it. With the toggle on, a **net track** loaded on a deck (generate / share) is composed and
  played by Rust and the Swift deck is paused; play/pause and the crossfader follow.
- **Toggle off (default): the Rust engine is never created**, nothing changes.
- **Package.swift is conditional**: DJRust, `djrust-smoke` and the `DJ_RUST` flag exist only when
  `rust/dist/djmobileFFI.xcframework` is present, so a plain checkout still builds Swift-only.

## Build

```
scripts/build-rust-xcframework.sh     # ~4 min cold; 5 targets, lipo, hand-built XCFramework,
                                      # regenerates Sources/DJRust/djmobile.swift
swift build --product DJApp           # DJ_RUST on
swift build --product djrust-smoke && .build/debug/djrust-smoke house 42     # smoke
```

Needs `rustup` (targets are added by the script) and the CLT. **No Xcode on this Mac**:
`xcodebuild` is unavailable (`xcode-select` points at CommandLineTools), so the XCFramework is
assembled by hand (it is a directory + `Info.plist`) and the app is built with `swift build`.
`xcodebuild -create-xcframework` / an iOS app target need Xcode (below).

## iPad mini sideloading

- The iOS slices (device + simulator) compile and are in the XCFramework, but **nothing links them
  yet**: linking an iOS binary needs the iOS SDK, which ships only with Xcode. The slices are
  untested on a device.
- Static lib ⇒ no dylib/JIT, so a free Apple-ID sideload (7-day profile; AltStore/Sideloadly) is
  fine. cpal's CoreAudio backend works on iOS (AudioUnit); the app must set an `AVAudioSession`
  category (`.playback`) before `Player()`; add `AudioToolbox`/`CoreAudio`/`AVFAudio` frameworks.
- `dj-vevr-se-ipad` is the iPad shell: consume this XCFramework from its Xcode project (local
  binary target). CoreMIDI stays Swift (the crate is built without djhost's `midi` feature, as
  on Android).
- Size: the device slice is 157 MB as `.a` (universal macOS/sim slices ~300 MB; debuginfo stripped); the linked app dead-strips far
  smaller. Measure in an Xcode archive.

## What works (verified)

| | |
|---|---|
| Rust → static lib | 5 slices build: macOS arm64/x86_64, iOS, iOS-sim arm64/x86_64 |
| XCFramework | 3 libraries, `plutil -lint` clean, consumed by SwiftPM `binaryTarget` |
| UniFFI Swift | `Player`, `DeckState`, `MixState`, `VocoderState`, … generate and link (Swift 5 mode) |
| `djrust-smoke` | composes `house:42` through Swift→Rust; **offline render** 8 s @ 48 kHz: 124 BPM, peak 0.71, RMS 0.19, 99.98% non-silent, **bit-exact repeatable** (FNV checksum) |
| DJApp | builds with the toggle; the Swift-only package still builds |

## Not verified: live CoreAudio

`djrust-smoke` and the toggle's live path open the default output. **This session had no working
audio**: the MacBook is in clamshell sleep state, `afplay` fails (`AudioQueueStart -66681`), and the
engine's own `djctl play` (existing build) also sees zero output callbacks; `djhost`'s heartbeat
stays 0 on every device. The live phase therefore reports SKIP (use `--require-live` to make it
fail). It needs a run with the lid open / a GUI session.

## Gaps vs the Swift engine

- Only **net tracks** route to Rust. Samples/files, the recorded **loop row**, stingers, scopes,
  the **waveform/net/ring views** (they read `Deck` state, not `DeckState`), **hardware control**
  (Inpulse jog/pads → DJEngine), cue/headphone routing, FX unit, auto-mix, wander, journal/replay,
  and the `dj_*` MCP catalog all still act on the Swift engine, so they do nothing for a Rust deck.
- Two audio engines at once: separate outputs/clocks, no shared master, meter or recorder; the
  Swift deck is only paused. `Player` has no cue bus and no loop bank (Android has none either).
- UI state: the deck strip reads Swift `Deck`; Rust state is shown only in the status line
  (`RustEngine.summary()`). Mapping `DeckState` → `AppModel.DeckState` is the next step.
- Rust is lean-by-design for mobile: no input-capture (`history_beats = None`), no EXS sampler
  (SF2 only; drop `.sf2` in `~/Library/Application Support/beats-btw-dj/soundfonts`), no CoreMIDI.
- Parity: `djrust` claims byte-parity with Swift's generator (CIDs, canonical JSON); that wasn't
  re-run here, and wave-engine audio is numerically close, not sample-identical, to AVAudioEngine.
- Dependency: the crate path-depends on a sibling `djrust` worktree (`../../.djrust-embed-wt`);
  pin by git rev before this leaves the spike.
- 765 MB `dist/` (not committed); `swift build` links in a few seconds, release size unmeasured.
