# Porting djandroid to Apple platforms

Goal: the Android app's feature set and layout (`stackdump/djandroid-vevr-se`, Kotlin + Compose
over the `djmobile` UniFFI crate) on iPadOS first, then macOS, on the **djrust engine**, so that
djrust becomes this repo's default engine instead of a toggle. Started 2026-11-14.

## Shape

```
apps/ipad/BeatsBTWDJ.xcodeproj    iPad app (Xcode; automatic signing)      ─┐
Sources/DJRustApp                  Mac app (`swift run DJRustApp`)           ├─ same pages
                                                                             ─┘
Sources/DJRustUI    the port: RustDJModel (= PlayerViewModel.kt) + SwiftUI pages (= ui/*.kt)
Sources/DJRust      UniFFI Swift bindings (generated) + RustEngine (used by the old toggle)
rust/dist/djmobileFFI.xcframework   macOS arm64+x86_64 · ios-arm64 · ios-sim arm64+x86_64
   ▲ scripts/build-rust-xcframework.sh
rust/upstream/…     read-only `git archive` snapshots at the revs in rust/PINS:
                    djandroid-vevr-se (its rust/ crate, built as-is), djrust-vevr-se, djrust,
                    windwheel — laid out as the crate's path deps expect
```

- **One crate, no fork.** The spike (cc54c91) carried a copy of djandroid's `rust/` here; that
  copy is gone. The XCFramework is now built from djandroid's crate exactly as Android builds it,
  pinned by commit in `rust/PINS` (`UPDATE=1 scripts/build-rust-xcframework.sh` re-pins to every
  repo's `origin/main`). The crate is `cdylib + lib`; `cargo rustc --crate-type staticlib` gives
  the `.a` without touching its `Cargo.toml`. Nothing is written into the sibling repos.
- **Same surface, same model.** `RustDJModel` is `PlayerViewModel.kt` line for line where it can
  be: the 30 Hz deck poll that publishes a "slow" `DeckState` (tick floored to the bar, playhead
  and level zeroed) so pages re-render per bar, a `PlayClock` the ring extrapolates per frame,
  one serial queue for every engine call (a fast slider never lands out of order), the same
  `UserDefaults` keys as djandroid's `SharedPreferences` (`auto_next_on`, `B.sound_lock`, …).
- **Design rules are djandroid's** (`docs/DESIGN.md` there): only playable controls on the seven
  play pages, one page per feature, utilities behind the top bar's menu in a sheet, tokens in one
  file (`DJRustUI/Theme.swift`: Accent `#F08A3C`, Surface0/1/2, Dim, Danger, section colours),
  cards (`Card`), 48 pt touch targets, fine sliders, square-law faders, disabled controls say why.
- **The old Swift engine stays** (DJApp, DJCore) until the port covers what the Mac app is used
  for; the djrust toggle in DJApp is unchanged. "djrust is the default" means: the iPad app has
  only djrust, and the Mac's DJRustApp grows into the main app (see Order of work).

## Inventory: djandroid → Apple

Status: ✅ ported · 🟡 partly · ⬜ not yet. "Engine" = what `djmobile`'s `Player` (and free
functions) already expose to Swift through the same bindings; "Swift app" = the existing macOS
DJApp on the Swift engine (DJCore), for reference — the port does not use it.

### The shell

| djandroid | Apple port | Engine | Swift app (DJCore) | Missing / notes |
|---|---|---|---|---|
| Pager of 7 tabs (`DeckScreen`, `PageTabs`): Deck A · Mix · Deck B · Perform · Wheel · Vox · Effects (the Inserts tab folded into Effects, 2026-11-18); dot above the label when playing / on | ✅ `RootView.swift`: paging `ScrollView` (`.scrollTargetBehavior(.paging)`), tabs with dots (`RustDJModel.isLit`: decks, Perform, Wheel, Vox, Effects: a throw on any target or any insert on). `DJ_PAGE=Inserts` opens Effects. **Wide** (≥ 1100 pt: the Mac's window, which now opens 1240 wide; an iPad Pro in landscape): Deck A · Mix · Deck B fold into one "Decks" page of three columns, five tabs | — | Deck columns + `DeckSections` folds; no pager | djandroid has no wide layout (a phone) |
| Top bar: "djrust" wordmark, indicators (HEOS live, update, identity), menu icon | 🟡 wordmark + menu icon; "HEOS live" (opens the HEOS page) and "output lost, reopening" (Danger, `audioStatus().live` false, opens About) indicators | `audioStatus`, `heosState` | — | Update and identity indicators come with those features (an iPad can't self-update). The output one is the port's own (djandroid has none) |
| "starting the engine…" while `Player()` opens | ✅ | `Player(soundfontDir:)` | — | |
| Error dialog ("Something went wrong", never stops playback) | ✅ `.alert` | `DjError` | — | |
| Engine is the process's (`DeckHost`), survives a rotated/recreated screen | ✅ model owned by the `App`, not the view | — | — | iPad: also survive scene disconnect (below) |
| Background playback (`PlaybackService` + `DeckPlayer`: Media3 session, lock-screen + headset buttons follow the lead deck) | ✅ `MediaSession.swift` (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`: play / pause / toggle / stop / next / previous on the lead deck, pause = every playing deck, play = the decks pause stopped, else the lead; title, "djrust · deck X · genre", structure, duration, elapsed + rate) and `AudioSessionHost.swift` (iOS: interruptions, route changes, media-services reset, preferred rate pinned to the engine's) | `state`, `mix`, `setPlaying`, `nextTrack`, `previousTrack`/`restart`, `audioStatus`; stream reopen in `keep_output` | — | Previous = the deck's ⏮ rule (top past 2 bars), not Media3's 3 s. iPad pauses on a pulled headphone (`oldDeviceUnavailable`, Apple's rule; djandroid has no "becoming noisy" handling). An interruption that ends without "should resume" pauses the decks and leaves the session inactive until a deck is played. Recovery speed and idle background → Engine changes 3, 6 |
| Keep screen on (charging, or Settings › while playing) | ✅ Settings toggle → `isIdleTimerDisabled` (iOS) / `beginActivity(.idleDisplaySleepDisabled)` (macOS); on iOS the charger rule (`UIDevice.batteryState` charging / full → screen on while in front), said in Settings | — | — | macOS has no charger rule (a Mac is not a deck display on a stand) |
| Fine sliders (`FineSlider`), tapers (`Taper.kt`: Log, Pow, Fader) | ✅ `FineSlider`, `Fader`; `Taper.swift` (`LogTaper` with its off stop, `PowTaper`, `LinearTaper`, `FaderTaper`) | `wheel::sweep` informs tapers | — | |

### Deck A / Deck B (the first milestone)

| djandroid card | Apple port | Engine call(s) |
|---|---|---|
| Platter: ring of sections, gliding playhead, level glow, centre play/BPM/bar | ✅ `Platter` (TimelineView + Canvas) | `state` (`sections`, `position`, `level`, `tempo`, `bar`) |
| Now playing: title, genre · seed · structure, section chip, message | ✅ | `state` |
| Transport ⏮ ⏯ ⏭ (back = top within 2 bars, else previous track) | ✅ | `restart`, `previousTrack`, `setPlaying`, `nextTrack` |
| Roles: tap pause, long-press lock out | ✅ (`onTapGesture` / `onLongPressGesture`) | `setRole`, `setRoleDisabled` |
| Next track: genres, dice seed + generated title, structure, Compose & load, Surprise me | ✅ | `compose`, `genres()`, `structures()`, `trackTitle()` |
| Auto-next every N bars (4/8/16/32/64), "Next in n/N" | ✅ | `setAutoNext`, `autoNextLeft` |
| At the end: the next seed | ✅ | `setAutoAdvance`, `nextVersionSeed` |
| Acid Bass / loop bank on a deck (`Td3DeckCard`): groups 1–9, A/B pads, drums switch (`td3_drums`) | ✅ `Td3Card.swift` | `td3Loops()`, `loadTd3` |
| Sound: palettes, lock; release build hides local-only ones (`ReleaseCatalogue`) | ✅ (`DJ_LOCAL_ONLY_PALETTES=1` shows them) | `palettes`, `setPalette`, `setSoundLock` |
| Keep on every track: key, feel, genre locks | ✅ | `deckKey`, `keyLabel`, `setKeyLock`, `deckFeel`, `feelLabel`, `setFeelLock` |
| Tempo & volume: tempo lock, pitch + fine (±1 %), range ±8/16/50, double-tap 0, Sync, square-law volume | ✅ | `setPitch`, `setPitchRange`, `setTempoLock`, `tempoLock`, `sync`, `setVolume` |

### The other pages and the menu

| djandroid | Apple port | Engine | Missing / notes |
|---|---|---|---|
| **Mix**: crossfader (all A / centre / all B, lead deck), deck strips (play, title, BPM · section · bar · auto dB, level meter, volume, Sync), auto level | ✅ `MixPage.swift` | `setCrossfader`, `mix`, `setAutoLevel` | |
| Mix: Acid Bass pairs (`Td3PairCard`, drums switch, the playing group's description) | ✅ `Td3Card.swift` | `loadTd3Pair` | |
| **Wheel** (windwheel tonewheel: 9 instruments on their drawings, Play/Pause, motor, drops, auto-drop, note sequence + Wind, key/transpose, brightness, level, trigger, tempo vs decks + Sync, gear, fine sliders, feed diagnostics line; `PickerAnchor`; `WheelLog`) | ✅ `WheelPage.swift` (the drawing: path, winding bars, note names in a static Canvas, magnets in a per-frame one; one `DragGesture` drives / slides / drops / plucks as Kotlin's pointer loop; Play, Tempo + Sync ×, Instrument with the sequence editor and build knobs, Key, Sound with the feed line), `WheelModel.swift` (re-winds in order on their own queue; knobs / brightness / rung drags coalesced to the latest; `wheel_preset`, `wheel_follow`, `wheel_sequence/<id>`, `wheel_knobs/<id>`, `wheel_gear/<id>` kept), `MagnetTracker.swift` (straight port). The drawing's frame loop rests while every magnet is still and the last jump has eased out (the poll's `wheelStill`), as Compose's loop waits for a poll; a finger on the drawing holds the pager and the page's scroll still (`wheelTouching`). The Vox's Wheel modulator and the Inserts' Wheel target now have something to play. `PickerAnchor.swift`: Kotlin's anchor line for line (hold at the tap, re-place for 800 ms once the new instrument lays out, absolute target), fed by `onGeometryChange` (the picker's top in the page) and `onScrollGeometryChange`, moving the page's `ScrollPosition`. `WheelLog.swift`: the field log's lines, word for word (`app.start`, `switch.restore/start/routes/load/sequence/knobs/done` + `.fail`, `wheel.job.skip/fail`, `wheel.sequence`, `wheel.preset_notes`, `wheel.playpause`) to `os.Logger` (subsystem `io.bitwrap.beats-btw-dj`, category `wheel`; INFO → `.notice`, WARN → `.error`, both kept on disk) instead of logcat + a file. Tests: `Tests/DJRustUITests` (Kotlin's PickerAnchorTest and WheelLogTest) | `wheelPresets`, `wheelLoad`, `wheelMotion` (~80×/s while the drawing shows), `wheelState` (30×/s), `wheelKnobs`, `wheelBrightness`, `wheelKey`, `wheelSequence`, `wheelParseSequence`, `wheelDrive`/`Hand`/`Release`/`Pluck`, `wheelMotor`, `wheelInterval`, `wheelTrigger`, `wheelVolume`, `wheelSync`/`Step`/`Rung`, `wheelPause` | The anchor checked in the simulator with `DJ_PICK=<id>` (a picker tap two seconds in): Marble run → Hoop looper adds the Tempo card above and the picker stays put. Touch untested in the simulator; `DJ_AUTOPLAY=wheel[:<id>[:A]]` checks the engine path |
| **Vox** (vocoder): modulator A/B/Wheel, 7 chord pads in the deck's key (hold / latch), 10 sounds, knobs (5 + More), only-the-vocoder, meters, auto level | ✅ `VoxPage.swift`, the Wheel as modulator included (since milestone 6). Multi-touch: each pad its own `DragGesture`; the held pads' notes sound as one chord (union, lowest first, the synth's 8 voices). Latched: pads pressed together latch together, a new touch replaces them, a tap on the one sounding stops it | `setVocoder`, `vocoderNotes`, `chordPads`, `vocoderPresets`, `vocoderPreset`, `vocoderSet`, `vocoder` (10×/s), `setVocoderAutoLevel`, `wheelInMix` | Each change of the held set calls `vocoderNotes` with the whole set, which the engine plays as all-off + note-ons: adding a second pad retriggers the first chord's notes (Engine changes 7). Not yet pressed by a finger here — the simulator can't touch; `DJ_AUTOPLAY=vox:0` checks the engine path |
| **Effects**: one target A/B/Wheel/Master shared with the inserts (kept as `fx.target`, carried over once from `inserts.target`; until picked, the lead deck), PANIC (this target's throws, and its four inserts off), length 1–4 bars / Latch, every trick and macro by category, hold pads for transitions, sweeps, filter knob, Acid Bass tricks on an acid loop | ✅ `FxPage.swift` (pads lit / outlined while waiting / ringed when latched; hold pads are one `DragGesture` each, so two hands hold two; VoiceOver "fire" holds for 1 s, as TalkBack's) | `fxCategories`, `fxCatalogue`, `engage(mode:)`, `fxRelease`, `fxUnlatch`, `fxState` (polled 10×/s), `trickKnob`, `fxAcid`, `panic` | On the Wheel and the Master the `decksOnly` pads are dimmed (`DimPad`) and the Acid Bass card hides. `FxInfo.needsNet` is unused, as in Kotlin: an effect a loop can't take is refused by `engage` with the reason (the error dialog) |
| **Effects › held effects** (the Inserts tab before 2026-11-18): after the Effects pads, under "After the Vox tap: held effects", filter / bitcrush / delay / reverb chains on the Effects target, knobs persisted, switches not | ✅ `FxPage.swift` (`InsertCard`: the switch in the card header, the first knob and Mix always shown, the rest under More / Fewer; the target segments' dot lights for a throw or an insert on; the delay's tempo line at the top of the section; no ALL OFF: PANIC switches the target's inserts off; a refusal shown in place, stepped delay time, the bitcrush's fine slider; knobs saved 400 ms after the last move as `inserts.chains`, restored at start with the switches off) | `insertStates` (500 ms while the page shows), `insertOn`, `insertParam`, `insertsOff`, `insertsSave` / `insertsRestore` | The Wheel target works in the engine but has nothing to play until the Wheel page |
| Menu › **Share** (deck A, B, the whole mix: sign, QR, share sheet) | ⬜ (the section says it needs the wallet) | `trackShare`, `mixSnapshot` | Signing is the **vevr-wallet** (separate repo, Android Keystore + BiometricPrompt). Apple needs its Secure Enclave / LocalAuthentication counterpart — a wallet decision, not an engine one |
| Menu › **Output › HEOS** (find zones, volume/mute/transport, group, Play the mix as FLAC) | ✅ `HeosPage.swift`, `HeosModel.swift` (address typed or found, ticked zones kept as `heos_ticked`, `heos_host` kept, Play / Stop with their reasons, per-zone transport + volume + mute, groups, the log; polled 2×/s once opened); `NSLocalNetworkUsageDescription` in Info.plist | `heosStart`, `heosState`, `heosDiscover`, `heosVolume`, `heosGroupVolume`, `heosMute`, `heosTransport`, `heosGroup`, `heosUngroup`, `heosStream`, `heosStreamStop` | Found and connected to the LAN's zones from the simulator (which may multicast). On the iPad the engine's SSDP / mDNS can't work (raw multicast needs `com.apple.developer.networking.multicast`), so a blank host is found by Bonjour (`HeosBonjour.swift`, `NSBonjourServices` `_heos-audio._tcp`) and passed as an address; a refused local-network permission ("os error 65") and a stream no zone fetches within 10 s are said on the page. Playing the mix to a zone from the iPad: not yet heard working (Engine changes wanted 9) |
| Menu › Output › TV stream (Stage receiver) | ⬜ | `tvStreamStart/Stop/Listeners`, `stagePoll`, `stageProject` | Chromecast is out of djandroid's build too |
| Menu › **Identity** (address, start over) | ⬜ (the section says it needs the wallet) | — (wallet) | as Share |
| Menu › **Charts** opt-in | ✅ the switch (`charts_on`) and djandroid's wording; `ChartReporting.swift`: `PlayCounter` (30 s heard, once per track per UTC day, a stalled poll counts ≤ 1 s, memory only, forgotten when switched off) fed by the deck poll with `heard` (playing, volume up, crossfader not all the way over), into the `NotSent` sink as in every Android build; tests are Kotlin's `PlayCounterTest` | `state`, `mix` | Nothing is sent on Android either yet: sending needs the network build, the charts service's address and non-prompting signatures (the wallet) |
| Menu › **Update** (self-update from the CDN) | n.a. — the section shows the version and says where builds come from | — | Not possible on iOS: Xcode (docs/IPAD.md) or TestFlight. macOS: Sparkle-style later |
| Menu › **Library** (SoundFonts, saved/signed items: load on A/B, share, forget) | 🟡 SoundFonts (count, the folder the engine read, how to add via the Files app); saved items say they need the wallet | `info`; `loadSavedTrack`, `loadSavedMix` (with the wallet) | SoundFonts go in the app's Documents/soundfonts (Files app, `UIFileSharingEnabled`) |
| Menu › **Settings** (keep screen on while playing) | ✅ | — | |
| Menu › **About** (version, sample rate, SoundFonts) | ✅ | `info` | |

## Engine changes wanted (not made here: other sessions own djrust and djandroid)

1. **An offline render in `djmobile`.** The spike's crate had `render_offline()` (compose + render
   N seconds through the engine's mixer, no sound card), which `djrust-smoke` used for a
   headless, bit-exact check. djandroid's crate has none, so the smoke test now only has its
   live phase. Wanted: `render_offline(genre, seed, structure?, seconds, sample_rate) ->
   {frames, peak, rms, checksum}` (or bytes) — useful for Android CI too.
2. **`staticlib` in `crate-type`** (or an `apple` feature) so Apple builds don't need
   `cargo rustc --crate-type`. Optional; the script works without it.
3. **iOS audio session lifecycle.** cpal's iOS backend opens RemoteIO; on an interruption (a
   call, Siri, another app taking the session) the unit stops. Read at 3abb5bb: `keep_output`
   *does* notice a stopped-but-not-errored unit — no callback for `STALL_REOPEN` (3 s) counts as
   lost — and reopens the default output with djhost's back-off (1 s, doubling to 8 s). What the
   app can do it does (`AudioSessionHost`): reactivate the session when the interruption ends,
   pin `preferredSampleRate` to the engine's, re-set up after a media-services reset. Still
   wanted from the engine:
   - **`audio_restart()`** (reopen now, back-off reset): after an interruption the sound comes
     back on the next retry, up to ~8 s + the 3 s stall later; the app knows the exact moment.
   - **A different hardware rate**: `keep_output` refuses an output that opens at another rate
     ("opened at X Hz, the engine runs at Y Hz") and retries forever. A route whose hardware rate
     the session can't pin (some Bluetooth / USB interfaces) leaves the decks silent until the
     app restarts. Resample, or rebuild the engine at the new rate.
   - Not verified on hardware yet: whether cpal's RemoteIO reports the interruption as an error
     (then it's `Faulted`, reopened sooner) or just stops calling back.
4. **Release catalogue in the engine.** `ReleaseCatalogue` (which palettes a public build hides)
   is duplicated in Kotlin and now Swift; a flag on `palettes()` (or `Palette.releasable`)
   would keep the rule in one place.
5. **Wording.** Palette descriptions say "this Mac" (Kotlin rewrites it to "this phone", Swift to
   "this iPad"); a host-neutral wording upstream would drop both rewrites.
6. **Idle in the background.** The engine's stream runs (silence) while every deck is paused,
   so iOS never suspends a backgrounded app that isn't playing: a paused djrust drains the
   battery as if it played. Android's service goes idle on pause. Wanted: `audio_suspend()` /
   `audio_resume()` (stop/start the output without counting a loss), so the app can stop the
   unit and deactivate its session when it is in the background with nothing playing.

7. **Vocoder note deltas.** `vocoder_notes(notes)` → `vocoder_set_notes` sends `AllOff` then a
   note-on per note, so changing the held set (a second hand joining a chord) restarts every
   note's envelope. Wanted: diff against the held set (note-offs for the gone, note-ons for the
   new), or `vocoder_note_on(n)` / `vocoder_note_off(n)`.

8. **Controls the hardware binds that djmobile can't play** (milestone 8's controllers): the
   Inpulse 200 MK3 / APC mini / MPK mini profiles bind EQ low / mid / high, gain (trim), cue and
   PFL with the headphone level and mix (needs a cue output), hot cues and their clear, the jog
   wheels (nudge / scratch / touch), stem mutes, clip launch and loop record, Wander and its pace,
   master level. `Player` has none of them, so the Mac's djrust app leaves them unbound
   (`RustControllers.action`). Wanted, most played first: `set_eq(deck, band, gain)`,
   `nudge(deck, amount)` (+ a jog touch / scratch), `set_gain(deck, db)`, a cue bus.

9. **HEOS on the iPad** (2026-11-15, Kitchen played nothing from the iPad while djandroid works):
   - **Discovery by Bonjour, or an address passed in.** djhost `heos::discover` sends SSDP to
     239.255.255.250 and mDNS to 224.0.0.251 from raw UDP sockets; iOS refuses multicast without
     `com.apple.developer.networking.multicast` (TN3179), so `Target::Auto` finds nothing there. The
     app finds a zone itself (`HeosBonjour`, `_heos-audio._tcp`, `NSBonjourServices`) and passes its
     address to `heos_start`. Nothing more is needed unless the engine wants to own it: e.g.
     `heos_discover_with(hosts)` taking the platform's answers.
   - **Say why a zone stopped.** The service ignores `event/player_playback_error` (`service.rs`
     `event`, `_ => {}`), so a zone that took `browse/play_stream` and gave up (Kitchen sat on "Url
     Stream", state `stop`) leaves no trace in `HeosState.log`. Wanted: log it as a failure line
     (`✗ Kitchen: playback error: <error>`), and the stream server's last few clients
     (`StreamStats.recent`, already kept) in `HeosState`, so "never fetched" and "fetched, then
     refused" can be told apart on the device.

10. **The Loops A / B readout over the FFI.** djrust-vevr-se 2a192bf moved djandroid's "Loops A / B"
   card into shared Rust (`djhost::loop_collections::{held_here, pair_readout, PairReadout}`), but
   djmobile (djandroid 6cdb7e5) neither exports it nor uses `djhost::loop_collections` (its own
   `loopsets.rs` has the per-genre collections), so the iPad keeps its Swift `Td3PairCard` (Acid Bass
   only, as djandroid at 3abb5bb). Wanted: `loop_pair_readout(spec, held_a, held_b) -> PairReadout`
   in djmobile; then the card reads it, with djandroid's collection picker.

## Order of work

1. ✅ **Milestone 1** — XCFramework from djandroid's crate at pinned revs; the page shell (top
   bar, 7 tabs, pager, menu sheet with Settings/About); Deck A, Deck B and Mix on djrust; Mac
   app `DJRustApp`; iPad Xcode project with automatic signing (docs/IPAD.md).
2. ✅ **Background audio & media controls** — Now Playing, remote commands on the lead deck,
   interruptions and route changes (engine items 3, 6 for what the app can't do), the charger
   rule for the screen.
3. ✅ **Effects** page, then the **loop bank** (Td3 deck card + Mix pairs, Acid tricks).
4. ✅ **Vox** (vocoder) — pads, sounds, knobs; multi-touch on iPad.
5. ✅ **Inserts** (folded into the Effects tab, 2026-11-18).
6. ✅ **Wheel** — the drawing + touch, magnets via `wheelMotion`, every card, the picker anchor,
   the field log (`os.Logger`, category `wheel`).
7. 🟡 **Menu utilities**: HEOS ✅, Library (SoundFonts ✅, saved items with the wallet), Charts ✅,
   Update n.a.; Share / Identity wait on the wallet question (an Apple side for vevr-wallet:
   Secure Enclave key, LocalAuthentication).
8. 🟡 **Mac as the default**: ✅ hardware controllers (`Sources/DJRustMIDI`: DJCore's CoreMIDI
   input and device profiles → `ControllerAction` on the model: play, sync, next / back, role
   pads, effect pads (held for transitions), volume (square law), pitch (DJApp's 2 % dead zone),
   filter, crossfader, the browser encoder stepping the lead deck's seed, PANIC, auto-advance,
   DJApp's regenerate as ⏭, the APC's aim buttons (A / B: what its "*" pads act on, else the
   lead deck); the rest → Engine changes 8; mapping tests in `Tests/DJRustMIDITests`); ✅ their
   LEDs (`RustLEDs.swift`: DJCore's `ledFrame` / `lights` rules and the profiles' status bytes
   over the model's `controllerLights` snapshot, ~20×/s to the output of the controller's name,
   dark on quit: play blinks while playing, sync lit at the other deck's tempo, ⏭ blinks while
   composing, role pads show the role (on / paused / locked out), effect pads the APC's group
   colour full while on and blinking while waiting for the bar, dark where djrust has no such
   effect; every control djmobile can't play is dark; `Tests/DJRustMIDITests/ControllerLEDTests`.
   Not tried on hardware yet: no controller was plugged in); ✅ the wide layout;
   ⬜ retire the toggle and make DJRustApp the app `make install-app` installs — Matt's call: DJApp
   still does far more (Wander, auto-mix, the journal, the MCP server, sessions, loops).

9. ✅ **Perform and the vocoder routing** (branch `ipad-perform`, pins djandroid 6cdb7e5 /
   djrust-vevr-se 2a192bf / djrust b41da9d): the 8th tab **Perform** (djandroid's "Moves", being
   renamed "Perform" there too) over djmobile's `moves_*` (`djhost::perform`): bass swap, phrase sync,
   vocoder handoff, filter exit, echo out, loop roll, each a pad with deck and bars chips, its
   armed / running light and one caption; Cancel all; the two decks' keys (read-only). The page's rules
   are `PerformRules` (Perform.swift, djandroid's Perform.kt; `PerformRulesTests`); a wide iPad puts the
   Transitions and Exits cards side by side. Vox: the Modulator / ⇄ Swap / Carrier row over
   `vocoder_sources` / `vocoder_route` / `vocoder_swap` (`voc_routing.rs`), the switch on
   `set_vocoder_on`; the list is a popover on the iPad. The re-pin renamed djmobile's effect calls'
   `deck:` to `target:` (same names accepted). Not ported: the Loops A / B readout from the engine
   (Engine changes 10), djandroid's per-genre loop collections, sound packs, the Desktop page and Menu ›
   Output's device picker.

## Build and run

```
scripts/build-rust-xcframework.sh          # ~6 min cold (5 slices); regenerates Sources/DJRust/djmobile.swift
swift build --product DJRustApp && swift run DJRustApp                     # Mac
swift build --product djrust-smoke && .build/debug/djrust-smoke house 42   # live smoke
open apps/ipad/BeatsBTWDJ.xcodeproj                                         # iPad: docs/IPAD.md
```
