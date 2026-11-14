# beats-btw-dj on an iPad (sideload from this Mac)

The iPad app is `apps/ipad/BeatsBTWDJ.xcodeproj`: one iPadOS app target (`beats-btw-dj`, bundle
id `io.bitwrap.beats-btw-dj`, iPadOS 18+, arm64) that shows the djandroid pages (`DJRustUI`)
over the djrust engine — the `ios-arm64` slice of `rust/dist/djmobileFFI.xcframework`, linked
statically (no dylibs, so a free 7-day profile is fine). Signing is **Automatic**; the team is
left empty for you to pick.

## State of this Mac (workbit), 2026-11-14

- **Xcode is not installed** — only the Command Line Tools (`xcode-select -p` →
  `/Library/Developer/CommandLineTools`). There is no iOS SDK, no simulator, no Apple ID in
  Xcode, and no signing identity in the keychain (`security find-identity -p codesigning`: 0).
  So the iOS app has **not** been compiled or run here yet, on a device or the simulator; the
  macOS build of the same pages has (`swift run DJRustApp`).
- Free vs paid account: nothing to check until an Apple ID is added to Xcode. With a **free**
  Apple ID ("Personal Team") the profile lasts **7 days** (re-Run from Xcode to renew), at most 3
  apps per device, and the bundle id must be unique to you (change it in Signing & Capabilities if
  Xcode says it is taken). A **paid** team gives 1-year profiles and TestFlight.

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

Once Xcode is installed: pick any iPad simulator (iPad mini (A17 Pro)) and Run. The XCFramework
has `ios-arm64_x86_64-simulator`. Or from the shell:

```
xcodebuild -project apps/ipad/BeatsBTWDJ.xcodeproj -scheme BeatsBTWDJ \
  -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' build
```

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
