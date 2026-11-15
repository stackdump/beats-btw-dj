# beats-btw-dj on an iPad (sideload from this Mac)

The iPad app is `apps/ipad/BeatsBTWDJ.xcodeproj`: one iPadOS app target (`beats-btw-dj`, bundle
id `io.bitwrap.beats-btw-dj`, iPadOS 18+, arm64) that shows the djandroid pages (`DJRustUI`)
over the djrust engine — the `ios-arm64` slice of `rust/dist/djmobileFFI.xcframework`, linked
statically (no dylibs, so a free 7-day profile is fine). Signing is **Automatic**; the team is
left empty for you to pick.

## State of this Mac (workbit)

- 2026-11-14 (milestone 1): Xcode was not installed; the project was hand-written.
- Since then: Xcode is installed (`xcode-select -p` → `/Applications/Xcode.app/…`), signed in to
  the paid team `CKP6564QUM`, and Matt's iPad mini (A17 Pro) is paired. The app has run on it
  (milestone 1) and on the iPad Pro 13-inch (M5) simulator.
- The project still leaves the team empty; pass it on the command line (below) instead of
  writing it into the project.

## From the shell (what the port's milestones use)

```
# simulator
xcodebuild -project apps/ipad/BeatsBTWDJ.xcodeproj -scheme BeatsBTWDJ \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath .build/xcode-sim build
xcrun simctl install booted .build/xcode-sim/Build/Products/Debug-iphonesimulator/beats-btw-dj.app
SIMCTL_CHILD_DJ_AUTOPLAY=1 SIMCTL_CHILD_DJ_PAGE=Effects xcrun simctl launch booted io.bitwrap.beats-btw-dj
xcrun simctl io booted screenshot .build/port-shots/x.png

# the iPad (plugged in, unlocked)
xcrun devicectl list devices
xcodebuild -project apps/ipad/BeatsBTWDJ.xcodeproj -scheme BeatsBTWDJ \
  -destination 'id=<device id>' -derivedDataPath .build/xcode-dev \
  DEVELOPMENT_TEAM=CKP6564QUM -allowProvisioningUpdates build
xcrun devicectl device install app --device <device id> .build/xcode-dev/Build/Products/Debug-iphoneos/beats-btw-dj.app
```

Launch environment (debug aids, read by `DJRustUI`): `DJ_AUTOPLAY=1` plays deck A once its first
track is loaded; `DJ_PAGE=<tab label>` ("Mix", "Effects", …) opens on that page;
`DJ_LOCAL_ONLY_PALETTES=1` shows the local-only palettes.

## Background play and the lock screen

The app keeps playing with the screen locked or another app in front (`UIBackgroundModes:
audio`). The lock screen, Control Centre and a headset's buttons show and drive the **lead
deck** (the one the crossfader favours, unless only the other plays): pause stops every deck
that plays, play starts them again, ⏭ is the next version, ⏮ the deck's own ⏮. A call or Siri
silences it; it comes back by itself when the call ends (a few seconds late: the engine retries
its output on a back-off). Pulling headphones pauses. Plugged in, the screen stays on while the
app is open.

## One-time setup (Matt)

1. Install Xcode 16 or newer (App Store, or developer.apple.com/download). Open it once and let it
   install the iOS platform/simulator it offers.
2. `sudo xcode-select -s /Applications/Xcode.app` (so `swift`/`xcodebuild` use it), then
   `sudo xcodebuild -license accept`.
3. Xcode › Settings › Accounts › **+** › Apple ID: sign in. It shows "Personal Team" (free) or
   your team's name (paid).
4. Build the engine once (already done on this Mac; again after `UPDATE=1` re-pins):
   `scripts/build-rust-xcframework.sh`.

## Each time: run it on the iPad mini

1. Plug the iPad into the Mac with USB-C; unlock it; tap **Trust** this computer.
2. First time only — enable **Developer Mode**: it appears on the iPad only after Xcode has seen
   the device, so do step 3 once, then on the iPad: Settings › Privacy & Security › Developer Mode
   › On › Restart › confirm after the restart.
3. `open apps/ipad/BeatsBTWDJ.xcodeproj`. Xcode resolves the local package (the repo root) on
   first open. Select the **BeatsBTWDJ** target › Signing & Capabilities › Team: your team
   (Automatically manage signing is already on).
4. Pick the iPad in the run-destination menu at the top and press **Run** (⌘R).
5. Free account, first launch only: the iPad refuses the app until you trust the developer:
   Settings › General › VPN & Device Management › your Apple ID › Trust.

SoundFonts (optional; synth voices play without them): Files app › On My iPad › beats-btw-dj ›
soundfonts — drop `.sf2` banks there and relaunch.

## Simulator

Pick any iPad simulator and Run; the XCFramework has `ios-arm64_x86_64-simulator`. From the
shell: above.

## If something fails

- *"No such module DJRustUI"* / package won't resolve: `rust/dist/djmobileFFI.xcframework` is
  missing (Package.swift only declares the Rust targets when it exists): run the build script,
  then File › Packages › Reset Package Caches.
- Link errors for `_AudioUnit…` / `_AudioComponent…`: the frameworks come from DJRust's
  `linkerSettings` (AudioToolbox, CoreAudio); report it, it means SwiftPM didn't carry them.
- The project file is hand-written (no Xcode here when it was made, Xcode 16 format with a
  synchronized `BeatsBTWDJ/` folder). If Xcode refuses it, File › New › Project › iOS App
  `BeatsBTWDJ` in `apps/ipad`, add `BeatsBTWDJ/BeatsBTWDJApp.swift`, add the local package (repo
  root) product `DJRustUI`, set `Info.plist` = `apps/ipad/Info.plist`, iPad only — five minutes.
