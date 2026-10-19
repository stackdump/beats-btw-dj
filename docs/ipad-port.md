# iPad port: scope

How much of dj-vevr-se runs on an iPad, what has to change in this repo, and in what order.
Written 2026-10-18 from a read of `80b465d`, without building anything: this Mac has
Command Line Tools only (`xcode-select -p` → `/Library/Developer/CommandLineTools`;
`xcrun --sdk iphoneos` finds no SDK). Every "compiles" below is a reading of the code. The
real error list comes in milestone 1.

This doc covers the **engine side**: the changes in dj-vevr-se. The iPad **app shell** and
its roadmap live in `stackdump/dj-vevr-se-ipad` (`ROADMAP.md`, 2026-10-17). This doc agrees
with that roadmap's shape and adds what the code read turned up: the CoreAudio/`Process`/
`homeDirectoryForCurrentUser` compile breaks, audio configuration changes the engine
doesn't handle today, the main-thread timer that drives swaps and wander, the Inpulse's
44.1 kHz audio interface, the licence check, and how this fits the target split and the
Rust fork. Where the two disagree, update the iPad roadmap to match this doc. The Android
scope in beats-vevr-se (`SCOPE.md`) is separate and not touched here.

## Summary

- **Most of DJCore ports as is.** It is 48k lines of Swift on Foundation, AVFAudio,
  AudioToolbox, CoreMIDI, Accelerate, CryptoKit, Compression, Synchronization and
  Observation, and all of those exist on iPadOS. About ten files touch something
  macOS-only. One file in DJApp and about fourteen in DJViews touch AppKit.
- **The Apple sample content doesn't come along.** The files aren't on an iPad, and
  bundling them would be redistribution, which the licence forbids. The iPad pool is
  SoundFonts (MuseScore_General, MIT) plus the synth voices. The task assumed "same
  platform, should be licensed": it isn't. See §2.4.
- **The real audio work is the session**, not the graph: AVAudioSession, interruptions,
  route and sample-rate changes, and background mode. The engine does none of this today,
  not even on the Mac (no `AVAudioEngineConfigurationChange` handler anywhere).
- **The Inpulse 200 MK3 should work over USB-C.** Retailers list it as iOS-compatible, its
  MIDI is class-compliant, and the existing profile JSON applies unchanged. Its built-in
  audio interface runs at 44.1 kHz only, which makes a sample-rate change on plug-in the
  normal case on the iPad.
- **Structure:** keep SwiftPM here and add `.iOS(.v18)`. DJCore and DJViews become
  multiplatform; `djctl` and DJApp stay macOS-only. The iPad app is an Xcode project in
  dj-vevr-se-ipad that consumes this package. When the planned DJEngine / DJHostMac split
  happens, split in three: AVAudioEngine/CoreMIDI go in a shared Apple host, not in
  DJHostMac.
- **Effort:** about 6–9 weeks of focused work to a TestFlight build playable on stage with
  the Inpulse. Touch UI is the largest single piece. Before anything builds, Matt needs to
  provide full Xcode, an Apple Developer team, and an iPad (§5).

---

## 1. What carries over, and what doesn't

### 1.1 Frameworks

| Framework (imports) | On iPadOS | Notes |
|---|---|---|
| Foundation (135) | yes | except `Process`, `homeDirectoryForCurrentUser`, `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)`; see 1.2 |
| SwiftUI (50), Observation (2) | yes | iPadOS 17+ for `@Observable`; `Window` scenes, `.commands` and `NSViewRepresentable` differ (1.3) |
| Synchronization (21) | **iOS 18+** | `Mutex` / `Atomic` set the floor: **iPadOS 18**, which matches the Mac's macOS 15 |
| AVFoundation / AVFAudio (10) | yes | AVAudioEngine, manual (offline) rendering, `AVAudioUnitSampler`, `AVAudioUnitReverb` all exist. Add AVAudioSession (§2) |
| AudioToolbox (7) | yes | `AUAudioUnit.registerSubclass` (`ChannelRouterAU`), hand-rendered AUSamplers, `kMusicDeviceProperty_StreamFromDisk` are all available |
| CoreAudio (2) | **no** (HAL) | `AudioObject*` / `AudioDeviceID` / `kAudioOutputUnitProperty_CurrentDevice` are macOS-only: `AudioDevices.swift`, `CueRouting.swift` |
| CoreMIDI (2) | yes | `MIDIClientCreateWithBlock`, `MIDIInputPortCreateWithProtocol`, `MIDISendEventList` all available (iOS 14+) |
| Accelerate (4) | yes | vDSP in `PeriodicWave`, `AnalyserFFT`, `ModelEngineKernels`, `TimeStretch`. Same results as on the Mac (same Apple silicon) |
| CryptoKit (3), Compression (1) | yes | CIDs and `?z=` share links are byte-identical across devices |
| CoreGraphics, CoreText, QuartzCore, UniformTypeIdentifiers | yes | |
| Darwin (3) | mostly | `socket(AF_UNIX)` compiles, but nothing outside the app can reach the socket (1.2) |
| AppKit (14) | **no** | DJApp and DJViews only; DJCore never imports it |

### 1.2 DJCore: the macOS-only seams

These are the files that won't compile for iOS, or will compile but do nothing useful
there. Everything else in DJCore (generator, wave engine, musicality, master chain, loop
bank, wander, journal, stores, controller decoding) should compile unchanged.

| Where | What | iPad answer |
|---|---|---|
| `Audio/AudioDevices.swift` | Enumerates HAL output devices (`AudioObjectGetPropertyData`) | `#if os(macOS)`. On iPad the route *is* the device: `AVAudioSession.currentRoute` |
| `Audio/CueRouting.swift` | `enableCueOutput(device:)` sets `kAudioOutputUnitProperty_CurrentDevice`; reads the HAL default device | Keep `enableCueRouting(channels:…)` (the `ChannelRouterAU` part is portable). Replace device selection with `setPreferredOutputNumberOfChannels(4)` on the session, plus the output unit's channel map, when the route has ≥ 4 channels (§3.3) |
| `Audio/Sampler.swift` | `gmBank` = `/System/Library/…/gs_instruments.dls`; EXS roots under `/Library/Application Support/{Logic,GarageBand}` | Compiles, but `isAvailable` is false for all of them, so the pools fall through to SoundFont and synth as designed. Make the paths `#if os(macOS)` so the iPad doesn't scan for them |
| `Audio/VoiceCatalog.swift` | Scans the EXS libraries into categories | Gives an empty EXS pool on iPad. The GM step needs a bundled or imported SF2 (§2.4) |
| `Audio/StockLoops.swift` | `/Library/Audio/Apple Loops`, `homeDirectoryForCurrentUser` | **Compile error**: `homeDirectoryForCurrentUser` is unavailable on iOS. Gate it with `#if os(macOS)`; the stock-loop list is empty on iPad |
| `Audio/MinecraftAssets.swift` | Reads PrismLauncher's asset index | Mac-only importer (`djctl minecraft import`). The resulting `minecraft-local.sf2` can be AirDropped to the iPad's SoundFont folder; it stays local-only there too |
| `Control/ControlSocket.swift`, `Control/MCPBridge.swift` | Unix socket in Application Support; stdio MCP | Compiles, but is unreachable: the socket is inside the app container and nothing else runs on the iPad. Off on iOS. An opt-in LAN listener is a later, security-reviewed feature (milestone 7) |
| `Session/SessionPublish.swift` | `Process()` running `/usr/bin/env ssh …` | **Compile error** (`Process` is unavailable). `#if os(macOS)`. Publishing from the iPad would need an HTTPS upload endpoint, which doesn't exist yet. Export the session and publish from the Mac instead |
| Application Support paths (journal, notes, favorites, voices, loop library, sessions, soundfonts, stock-loop index) | `FileManager.urls(for: .applicationSupportDirectory, …)` | Works as is: on iOS it resolves inside the container. Create the directories (iOS doesn't pre-create them) and set `isExcludedFromBackup` on caches (stock-loop index, patched EXS). `$DJ_*` overrides stay harmless |
| `sample.file` journal events, loading a sample by path | Absolute paths | Files picked on iPad are security-scoped: copy them into the container on import (simplest), or keep bookmarks. A Mac path in a journal won't resolve on the iPad, and the reverse is also true |

### 1.3 DJViews and DJApp

DJViews is 11.8k lines of SwiftUI. The AppKit seams are small, but the interaction model is
a mouse-and-keyboard one:

| Seam | Files | iPad |
|---|---|---|
| `NSPasteboard` (copy share link, paste share, clip JSON) | AppViews, DeckSections, ClipSettingsView | `UIPasteboard`, or SwiftUI `ShareLink` / `PasteButton` |
| `NSSavePanel` (export WAV, session, loops) | AppViews, LoopLibraryModel | `.fileExporter` (cross-platform, so use it on both) |
| `NSAlert` with an accessory view (the Publish… modal) | AppViews:1293 | Not needed on iPad while publishing stays on the Mac |
| `NSSound` (audition, `dj_screenshot` paths) | AppViews, AppControl | Play auditions through the engine (`dj_audition` already does) |
| `NSEvent.addLocalMonitorForEvents` (HoverKeys), `NSEvent.modifierFlags` (shift + pad) | HoverKeys, AppViews, SoundboardView | `.onKeyPress` works with a hardware keyboard. Without one, SHIFT needs an on-screen latch (the controller's SHIFT already works) |
| `NSViewRepresentable` (screen-height tracker), `NSScrollView` workaround | Scopes/ScopeScreenHeight, AppViews | `UIViewRepresentable` / `UIScreen`; or drop it and read the window size from `GeometryReader` |
| `NSImage` / `NSAttributedString` text into a CGContext | Scopes (BandsImage, RasterImage, StageBackdropImages) | CoreText attributes work as written; the `NSImage` wrapping becomes `CGImage` → `Image(decorative:)` |
| `NSApplicationDelegateAdaptor`, `setActivationPolicy`, quit on last window, `.commands` menu | DJApp.swift | The iPad shell has its own `App`. The engine stop moves to `scenePhase` / termination. On iPad, the end of a scene must **not** stop audio (§2.1) |
| `Window(StageWindow…)` + `openWindow` | DJApp, AppViews:1613 | `Window` is macOS-only. On iPad use a `WindowGroup(id:)` (iPadOS multi-window) or a full-screen cover |
| `ScreenWakeLock` (`beginActivity(.idleDisplaySleepDisabled)`) | ScreenWakeLock.swift | `UIApplication.shared.isIdleTimerDisabled` |
| `.contextMenu` (13 uses in 6 files), right-click to disable, `.onHover`, `.help` | LoopRowView, DeckSections, … | All compile. On touch, a context menu opens on **long press**, which clashes with `InstrumentButton`'s 0.5 s long press (the sound panel). Decide one gesture per control (iPad roadmap phase 4) |

`DJViewsTests` render views to pixels (`renderPixels`). `ImageRenderer` exists on iOS, so
they can run on the simulator too, but the expected geometry was measured on macOS, so
expect a separate baseline.

### 1.4 What doesn't go to the iPad at all

- **`djctl`.** A CLI: no terminal, no `Process`, no stdio MCP. It stays the Mac's tool for
  `render`, `journal replay`, `publish`, `minecraft import`, `sampler-sweep` and
  capture/monitor. The iPad hands its journal and sessions to it (milestone 7).
- **launchd / background jobs.** There are none in dj-vevr-se itself (the LaunchAgent in
  this workspace belongs to workbit's tmux session, not the app). On iPad, background work
  means one thing, audio background mode (§2.1). No `BGTaskScheduler` work is needed.
- **`make swift-rt-test`'s allocation counter** (`malloc_logger`). It tests shared code, so
  keep it on the Mac. One manual on-device check with Instruments (Allocations on the audio
  thread) per milestone is enough.
- **The Go CLI and `web/jog`**: capture tools, Mac-only.
- **Logic/GarageBand EXS, Apple's GM DLS, Apple Loops**: see §2.4.

### 1.5 A hidden dependency: the main-thread timers

`ControllerHub` runs a 100 Hz `Timer` on the main run loop (`ControllerHub.swift:49`).
`tick()` drains each turntable's **retire ring**, runs `Deck.service()` (pending swaps,
auto-next), `serviceLoopTakes()`, `serviceWander()` and the LED frames. `AppModel` runs
another at 30 Hz for display state. While the app is foregrounded, or backgrounded with
audio playing, iOS keeps the main run loop running, so both keep working. If the process
is ever suspended mid-set, the retire rings stop draining and wander stops moving. That's
why background audio (§2.1) is a correctness requirement, not polish. Check on the device
that the 100 Hz timer holds its rate with the screen locked.

---

## 2. Audio on iPad

### 2.1 Session and background playback

Nothing in the repo uses `AVAudioSession` today. The iPad shell (or a new iOS host file in
DJCore) needs:

- **Category `.playback`**, mode `.default`, no `.mixWithOthers` by default (a DJ app
  should own the output; make mixing a setting later). `.playback` keeps playing with the
  silent switch on and with the screen locked.
- **`UIBackgroundModes: audio`** in Info.plist. With it, the process keeps running while
  the engine renders, so the main-thread timers in §1.5 keep firing. Without it, a locked
  screen stops the set.
- **Activation:** `setActive(true)` before `engine.start()`, and only on play. Deactivate
  when every deck is stopped and the app goes to the background, so the app doesn't hold
  the audio route idle (App Review rejects apps that use the audio mode for idle background
  time).
- **Interruptions** (`AVAudioSession.interruptionNotification`): calls, Siri, alarms, other
  apps taking the route. On `.began` the engine has already stopped; mark the decks
  paused. On `.ended` with `.shouldResume`, reactivate and restart. Transport time is
  render-driven, so decks resume where they stopped and the bar clocks stay consistent.
  Journal it (`mark` or a new `audio.interrupted` event), so a replay doesn't read the gap
  as silence.
- **Media services reset** (`mediaServicesWereResetNotification`): rebuild the engine from
  the journal checkpoint state.

### 2.2 Route changes, sample rate, Bluetooth

This is the biggest engine-side change. `DJEngine.init` reads the hardware rate once
(`engine.outputNode.outputFormat(forBus: 0).sampleRate`, `DJEngine.swift:140`), and
`sampleRate` is a `let`. The decks, `WaveRunner.prepare`, the sampler banks, the master
chain's `PeriodicWave` tables, the reverb FDN and the echo lines are all sized for it. No
code observes `AVAudioEngineConfigurationChange`. On a Mac this rarely bites. On an iPad
it is routine:

| Event | What happens |
|---|---|
| Plug in the Inpulse (its interface is **44.1 kHz / 24-bit only**) | The route changes from the 48 kHz speaker to 44.1 kHz USB, and the engine stops with a configuration change |
| Headphones in or out, AirPods connect | Route change. Usually 48 kHz, but not guaranteed |
| Bluetooth A2DP | Works under `.playback`. Latency is ~150–300 ms: fine to listen with, useless for cueing, jog feel or beat-matching. Show it in the UI. Never use `.allowBluetooth` (HFP: 16 kHz mono) |
| AirPlay | Works (`.playback`, `AVRoutePickerView`). ~2 s latency: listening only |

**Recommendation: pin the engine's internal rate at 48 kHz** and let the
`AVAudioMixerNode` → output connection resample to whatever the route runs at. Then a
route change means restarting the engine (and re-applying the 4-channel cue layout if the
new route has one), not rebuilding every deck, prepared project and sampler. The costs
are one SRC on the output path (cheap, a fraction of a millisecond) and that
`ChannelRouterAU`, which connects straight to `outputNode`, must take the hardware rate
or move before the mixer. The other choice is a full rebuild per rate change, using the
`JournalState` checkpoint to restore. It is correct but slow mid-set, and it would also
change the sampled voices' level normalisation per rate. Offline renders and journal
replays keep using `DJEngine(offline: true)` at 48 kHz, so determinism is unaffected
either way.

Also journal route changes. Engine frame `f` must stay monotonic across an engine restart
(keep an offset), or a replay places events wrong.

### 2.3 Latency and CPU

- Ask for **`setPreferredIOBufferDuration(0.005)`** (~256 frames at 48 kHz). The iPad will
  grant 64–256 frames on built-in and USB routes. The Mac app runs at the HAL default (512).
  Make it a setting (128 / 256 / 512), because a smaller buffer gives less headroom.
- The **render budget is unknown** and is the main technical risk. Two net decks with
  `.extended` options (subtractive voices, unison, the FDN `Space`, ping-pong `Echo`,
  `MixBalance`), up to 24 hand-rendered AUSamplers per deck, the master chain with the
  pitch shifter, the loop bank with 2× oversampled shapers: all of it runs in one render
  callback. M-series iPads have Mac-class cores but tighter thermals. Measure it in
  milestone 2 before building UI: CPU per deck, the worst block time, and glitches across a
  20-minute set with the screen locked. Run `djctl render`'s offline numbers on the device
  as a baseline.
- **Audio workgroups:** the engine renders on the I/O thread only (no worker threads), so
  `os_workgroup` joining isn't needed. If the render is ever parallelised, it will be.

### 2.4 Apple's instrument and loop content: licensing

**Not usable in the iPad app.** It is the same company, but not the same licence grant, and
the files aren't on the device.

1. **The files aren't there.** The Mac app reads Logic/GarageBand EXS instruments from
   `/Library/Application Support/{Logic,GarageBand}/…`, Apple's GM bank from
   `/System/Library/Components/CoreAudio.component/…/gs_instruments.dls`, and Apple Loops
   from `/Library/Audio/Apple Loops` (4.3 GB on this Mac). None of these exist on iPadOS.
   GarageBand and Logic Pro for iPad keep their sound libraries inside their own sandboxes,
   which another app cannot read. iOS has no system GM bank either: Apple's `AVMIDIPlayer`
   docs say that on macOS a nil bank uses the default, while on iOS "you must always pass a
   valid bank file".
2. **Bundling them is what the licence forbids.** The Logic Pro / MainStage terms (Apple's
   support note 101908 quotes them) allow the "Sample Content" to be used royalty-free to
   *create your own original soundtracks* and to distribute those soundtracks. They forbid
   distributing individual assets "on a standalone basis" or repackaging them "as audio
   samples … sound files, sound libraries … or similar assets". Shipping the EXS samples,
   the DLS or Apple Loops inside an `.ipa` (TestFlight included: testers receive the
   files) is that repackaging. This repo already applies the same rule on the Mac: samples
   never enter the repo, a release or the CDN.
3. **Recordings are fine.** A set recorded on the Mac with EXS voices, or a loop taken
   from Apple Loops on the Mac, is the user's own composition. Its WAV can travel to the
   iPad (loop library import, a sample deck) like any other audio. That's the licensed use.

What the iPad gets instead: `MuseScore_General.sf2` (MIT, FluidR3-based; 206 MB) as the GM
floor, plus the synth voices. That is the existing fallback chain, with no new code. Either
bundle it (+206 MB to the app) or download it on first run, sha256-pinned as
`make soundfonts` does (recommended, to keep the app small). Users can import other `.sf2`
banks through Files. The 2026-10-17 decision in the iPad roadmap still holds: CIDs stay
identical (picks are never encoded), and the sound may differ between Mac and iPad.

> **Matt's call (grey area, not recommended):** copying one's own Mac EXS files onto one's
> own iPad by hand (Files import, never in the build) is arguably personal use. The
> licence's grant is written per Apple software installation, and it isn't clearly
> allowed. The sampler also loads samples whole, so ~3 GB of tonal content won't fit an iPad
> process's memory budget anyway. Leave it out unless asked.

### 2.5 Memory

Samples load whole (StreamFromDisk off, on purpose), and the bank holds 24 slots per deck.
iPadOS ends a process long before physical RAM runs out (a few GB, depending on the
device). Size `SamplerBank` from `os_proc_available_memory()` and evict unreferenced slots
on `didReceiveMemoryWarning`. That reuses the existing two-phase eviction. Consider the
`com.apple.developer.kernel.increased-memory-limit` entitlement, which needs a paid team.
SoundFont programs are small next to Logic's pianos, so the SF2-only pool is light. This
matters most for imported banks.

---

## 3. MIDI: the Inpulse 200 MK3 (and APC mini mk2) on iPad

### 3.1 Connection

- The Inpulse has USB-C and is **bus-powered**. Retail listings (Currys, Galaxus) say it
  works with iOS. Its MIDI is class-compliant (it needs no driver on the Mac), and iPadOS
  supports USB MIDI class devices natively.
- Use a **USB-C iPad** (M-series recommended, §5). Connect directly with a USB-C-to-C
  cable. If it browns out (LEDs flicker, disconnects at jog-wheel load), use a powered
  USB-C hub, which also charges the iPad during a set. Lightning iPads need the Camera
  Connection Kit **with** power: not recommended.
- Inpulse **and** APC mini mk2 at once need a hub. Both enumerate as separate CoreMIDI
  sources, as on the Mac.

### 3.2 Code

- `MIDIIn` / `MIDIOut` (`MIDIIn.swift`) and `ControllerHub` use only APIs available on
  iOS 14+, and setup-change notifications work the same way. `SurfaceProfile` /
  `JogProfile` JSON loads through `Bundle.main` first (already the rule), so the profiles
  ship in the iPad bundle unchanged.
- Routing through `DispatchQueue.main.async` (FIFO) is unchanged. The 100 Hz tick drives
  soft takeover and LED frames (§1.5).
- **Port names may differ** on iPadOS (CoreMIDI display names come from the USB
  descriptor, sometimes with a different entity suffix). Profiles match by name. Capture
  on the iPad (a debug "MIDI monitor" screen, since there's no `djctl monitor`), compare it
  against `captures/*.log`, and add an alias if needed. The coverage-contract replay test
  stays Mac-side. Only add an iPad fixture if the bytes differ.
- **LEDs** go out over the same `MIDISendEventList`: no change.

### 3.3 Cue (headphones) through the Inpulse

The Inpulse's interface has master (RCA) and headphones (3.5 mm): a 4-channel USB audio
output, which is exactly what `enableCueRouting(channels: 4, masterPair: 0, cuePair: 2)`
does on the Mac. On iPad, when the Inpulse is the route:
`setPreferredOutputNumberOfChannels(4)`, check `outputNumberOfChannels == 4`, then connect
`ChannelRouterAU` to `outputNode` with the 4-channel discrete layout, as the Mac does. Only
the device selection in `CueRouting.swift` is Mac-specific (§1.2). Without the Inpulse,
the iPad has stereo out only, so cue stays off. This gives the iPad proper pre-listen
with no extra interface. Verify on the device that the iPadOS route reports 4 channels
(likely for a class-compliant device; not yet seen).

---

## 4. Project structure

### 4.1 Recommended: one SwiftPM package, multiplatform libraries, app shell in Xcode

```
dj-vevr-se (this repo, SwiftPM)                 dj-vevr-se-ipad (Xcode, XcodeGen project.yml)
  platforms: [.macOS(.v15), .iOS(.v18)]            DJPad.app (iPadOS 18+)
  DJCore      library  macOS + iOS   ◄──────────     depends on DJCore, DJViews (path or pinned rev)
  DJViews     library  macOS + iOS   ◄──────────     iOS entry point, AVAudioSession host,
  DJApp       exe      macOS only                      Info.plist (UIBackgroundModes audio),
  djctl       exe      macOS only                      entitlements, assets, signing
  tests       run on macOS; DJCore tests also on the iOS simulator via xcodebuild
```

- SwiftPM can't produce a signed iOS `.app` (Info.plist, entitlements, asset catalog,
  provisioning), so the iPad needs an Xcode project somewhere. Putting it in
  dj-vevr-se-ipad, as already decided, keeps this repo's "SwiftPM, no `.xcodeproj`" rule
  and its Makefile flow intact.
- `Package.swift` lists platforms per package, not per target. Adding `.iOS(.v18)`
  doesn't build the executables for iOS, because nothing asks it to. Mark Mac-only code
  with `#if os(macOS)` inside the files (§1.2). Don't fork files per platform.
- `make test` stays the Mac gate. Add `make ios-build` (`xcodebuild -scheme DJCore
  -destination 'generic/platform=iOS Simulator'`) once Xcode is installed, so a Mac-only API
  sneaking into DJCore breaks the build on the Mac too.
- **Alternatives considered:**
  - *One Xcode multiplatform app target* (Mac + iPad): it would replace `bundle-app.sh` and
    the SwiftPM-only build on the Mac for no gain.
  - *Mac Catalyst*: it loses EXS/DLS just as the native app does, and keeps AppKit-ish
    behaviour that a touch app doesn't want.
  - *A `.swiftpm` app package* (Playgrounds-style `iOSApplication` product): fine for a
    demo, but too limited for entitlements and background modes.

### 4.2 Fit with the planned DJEngine / DJHostMac split

No written plan for that split was found in this repo, dj-vevr-se-ipad, djrust-vevr-se or
on valoper, so this section reads it as the Swift mirror of the Rust fork's crates: a pure
`djengine` and a device-touching `djhost`. **For the iPad, the host half has to split
again**, or the iPad duplicates most of it:

| Target | Holds | Platforms |
|---|---|---|
| `DJEngine` | Generator, share codec and CIDs, project model, wave engine and musicality, master FX, loop FX DSP, controller decoding (profiles → actions), wander planning, session and journal models, SPSC rings. No devices, no files | macOS, iOS (and the Rust port's target) |
| `DJHost` (shared Apple host) | `DJEngine` class, decks and AVAudioEngine graph, AUSampler/`SamplerBank`/`VoiceCatalog` (SF2 + synth), CoreMIDI in/out, `ControllerHub`, stores in Application Support, journal writer | macOS, iOS |
| `DJHostMac` | HAL device listing and cue device selection, EXS/DLS/Apple Loops scanning, `ExsNames` patching, Minecraft importer, control socket + MCP, `SessionPublish` (ssh) | macOS |
| `DJHostIOS` (or inside the iPad shell) | AVAudioSession, interruptions and route changes, memory budget, document-picker import, idle timer | iOS |

**Sequencing:** don't make the iPad wait for the split. Milestone 1 adds `#if os(macOS)` at
exactly the seams in §1.2. Those seams are the DJHostMac boundary, so the later split moves
whole files instead of untangling them. If the split is scheduled first anyway, use the
three-way version above.

### 4.3 Fit with djrust-vevr-se

- The Rust fork (`PORTING.md`) is at phase 0: generator, share codec and CIDs are
  ported with parity. Its plan ends with `djffi` (UniFFI): the SwiftUI app runs on the
  Rust engine, generator first, then the wave engine. UniFFI static libraries build for
  `aarch64-apple-ios` and the simulator just as for macOS (an XCFramework), so **the iPad
  doesn't change the Rust plan**. It adds two targets to `djffi`'s build, and `djengine`
  already stays `no_std`, with no clock and no I/O.
- **Don't build the iPad on the Rust engine.** The Rust wave engine is phase 2 and its live
  decks phase 3. The Swift engine works now. The iPad should ship on Swift DJCore and pick
  up Rust pieces behind a flag the same way the Mac app will.
- One overlap to note: Rust's `djhost` uses cpal/midir and rustysynth for SF2. On Apple
  platforms the Swift host (AVAudioEngine, AUSampler, CoreMIDI) stays the host, and Rust
  supplies only `djengine` over FFI. So Rust's `djhost` isn't an iPad dependency, and the
  `DJHost` / `DJHostMac` / `DJHostIOS` targets above are the Swift-side contract the FFI
  engine plugs into.
- The SF2 floor decided for the iPad (§2.4) is the same one Rust's Linux/WASM targets use.
  All three non-Mac platforms then share one sound baseline: SoundFont + synth. The iPad
  roadmap's option (c), a Mac "portable sound" profile, would make the Mac match it too.

---

## 5. Milestones

Effort is in focused working days for one developer with Claude sessions, assuming the
toolchain and devices are in place. Ranges reflect what can't be known before the first
iOS build. Milestone numbers line up with dj-vevr-se-ipad's phases where they overlap.

| # | Milestone | Where | Effort | Exit |
|---|---|---|---|---|
| 0 | **Toolchain and decisions.** Full Xcode on workbit, a developer team, an iPad, a bundle id, answers to the §6 questions | Matt | ½ day + Matt | `xcrun --sdk iphoneos --show-sdk-path` works; a blank app runs on the iPad |
| 1 | **DJCore + DJViews compile for iOS.** `.iOS(.v18)`; `#if os(macOS)` at §1.2 / §1.3 seams; directories created; `make ios-build` | dj-vevr-se | 3–5 d | Both libraries build for the simulator; `make test` still green on the Mac |
| 2 | **Audio host on the device.** Shell app, AVAudioSession, background mode, interruptions, route changes with a 48 kHz internal rate (§2.2), buffer setting, monotonic journal frames. **Measure the render budget** | both | 5–8 d | One net deck plays 20 min with the screen locked, survives a call and a headphone pull; CPU numbers for 1 and 2 decks are written down |
| 3 | **Sound library.** SF2 first-run download (sha256), Files import of `.sf2`, `SamplerBank` sized from available memory, memory-warning eviction | both | 3–5 d | Two decks with sampled SF2 voices, no jetsam over a set; the drift decision holds |
| 4 | **Controllers.** Inpulse + APC over USB-C, port-name aliases if needed, a MIDI monitor screen, 4-ch cue through the Inpulse (§3.3) | both | 3–5 d | A controller-only set works as on the Mac, including headphone cue |
| 5 | **Touch UI.** AppKit swaps (§1.3), gesture plan (long-press vs context menu, SHIFT latch), layout for 11" and 13" plus Split View, Soundboard pads for fingers, Stage as a window or cover, `.fileExporter`/`.fileImporter` | dj-vevr-se (DJViews) | 10–15 d | A full set playable by touch alone; view tests have an iOS baseline |
| 6 | **Data in and out.** Journal / session / loop-library export through the share sheet; Mac `djctl journal replay` of an iPad journal; favorites/crates/notes/voices export-import | both | 3–5 d | An iPad run with SF2/synth voices only replays on the Mac byte-identically (`djtest_replay twice=true`) |
| 7 | **Distribution.** Signing, TestFlight internal group, crash reporting via Xcode Organizer. Optional, later: a LAN control listener with pairing (MCP to the iPad) and HTTPS publishing | shell | 2–3 d + review wait | A TestFlight build installs on Matt's iPad |

**Total:** ~30–45 focused days, i.e. 6–9 weeks elapsed. Milestones 1–2 are the
go/no-go: if the render budget doesn't fit two `.extended` decks on the target iPad,
the answer is per-genre option trims (`WaveOptions.forGenre`) or one live deck plus a
sample deck. Find that out before the UI work.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Render budget: two `.extended` net decks + samplers + FDN + oversampled loop FX don't fit at 256 frames | medium | Measure in M2 first; buffer setting; trim options per device class |
| Sample-rate and route changes mid-set (Inpulse is 44.1 kHz) | **certain** | Fixed 48 kHz internal rate + output SRC (§2.2); restart, don't rebuild |
| Jetsam memory kills with sampled voices | medium | Memory-sized bank, eviction on warning, increased-memory entitlement |
| Inpulse bus power marginal on the iPad's port | low–medium | Powered USB-C hub |
| Inpulse port names or 4-ch output differ on iPadOS | low–medium | Capture on device in M4; alias table |
| Main-thread timers (retire ring, swaps, wander) stall if the app is ever suspended | low with background audio | `UIBackgroundModes audio`; verify with the screen locked; later, move the retire drain off main |
| AUSampler set-up traps (`SamplerInstrument.lifecycle`, the AUParameterCache pre-build) behave differently on iOS | low–medium | Keep the guards; on-device Instruments run in M3 |
| App Review rejects background audio while idle | low (TestFlight internal skips review) | Deactivate the session when nothing plays |
| Licence: someone bundles Apple content "just for testing" | low | §2.4. TestFlight is distribution too |
| Two UIs drift (Mac and iPad layouts diverge in DJViews) | medium | Shared views with platform modifiers; iOS view-test baseline |

---

## 6. What needs Matt's input

1. **Full Xcode on workbit** (App Store or developer.apple.com; ~40 GB of disk). Nothing
   iOS builds until it is installed. Also: switch `xcode-select` to it, or keep CLT as the
   default and pass `DEVELOPER_DIR` in the iPad Makefile? CLT-only is why bare `swift
   test` can't find Testing today, so switching probably helps both.
2. **Apple Developer Program team** ($99/yr) and its team ID. A free personal team can run
   the app on one iPad with 7-day profiles. TestFlight and the increased-memory entitlement
   need the paid team.
3. **Bundle id and app name** (for example `se.vevr.dj` / "dj-vevr-se"). It stays private:
   TestFlight internal only, not the App Store, unless decided otherwise.
4. **The iPad:** model and chip, RAM, iPadOS version, USB-C. M-series is strongly
   preferred for the render budget. Is a powered USB-C hub on hand?
5. **Stage or sketchpad?** Stage makes milestones 2 and 4 hard requirements (zero glitches,
   cue through the Inpulse). A sketchpad can ship with one deck on the speaker.
6. **Apple content:** confirm "no Apple samples on the iPad, SoundFont + synth only" (§2.4),
   and whether to download MuseScore_General on first run (recommended) or bundle it.
7. **When to split targets:** before milestone 1 (the three-way split in §4.2), or after
   the port, with `#if os(macOS)` seams now (recommended)?
8. **Remote control / MCP on the iPad:** wanted at all? If so, it's a LAN listener with
   pairing, and it comes last.
9. **Commit signing for dj-vevr-se-ipad** works as here (GPG `624DDC38A40EF01D`). App
   **code signing** in Xcode uses the developer team's certificates: let Xcode manage them
   ("Automatically manage signing"), or use manual profiles?

## Sources

- Inpulse 200 MK3, USB-C, built-in 24-bit/44.1 kHz interface, Android/iOS compatibility:
  [Currys](https://www.currys.co.uk/products/hercules-djcontrol-inpulse-200-mk3-dj-controller-black-10304219.html),
  [Galaxus](https://www.galaxus.ch/en/s1/product/hercules-dj-control-inpulse-200-mk3-dj-controllers-68198562),
  [Kirstein](https://www.kirstein.de/DJ-Controller/DJControl-Inpulse-200-MK3.html).
  Hercules' own pages weren't checked; confirm on the device in M4.
- Logic Pro / MainStage sample-content terms:
  [Apple support 101908](https://support.apple.com/en-us/101908),
  [Logic Pro SLA](https://www.apple.com/legal/sla/docs/logicpro72.pdf),
  [Logic Pro for iPad SLA](https://www.apple.com/legal/sla/docs/LogicProiOS.pdf).
- No default sound bank on iOS:
  [AVMIDIPlayer init(data:soundBankURL:)](https://developer.apple.com/documentation/avfaudio/avmidiplayer/init(data:soundbankurl:)).
- In-repo: `CLAUDE.md`, `Package.swift`, the files named above at `80b465d`;
  dj-vevr-se-ipad `ROADMAP.md` (`8933040`); djrust-vevr-se `PORTING.md` (`ff44e1a`).
