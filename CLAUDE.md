# dj-vevr-se

Native DJ-controller tooling for Petri-net music. Private repo
(`stackdump/dj-vevr-se`), developed on **the MacBook** (`~/Workspace/dj-vevr-se`)
because the hardware — a Hercules DJControl Inpulse 200 MK3 — is plugged in
there. Not on valoper, not deployed to pflow.dev.

## Origin and boundary

Split from beats-bitwrap-io `public/jog/` at `b7704ba` (2026-10-07). beats keeps
its copy; the two are now independent. Rules inherited from that split:

- beats' determinism contract (same genre + seed = same CID) does **not** bind
  this repo — live performance state is the point here. If something built here
  is ever upstreamed to beats, it must still stay out of beats' share payload.
- No npm, no bundler for `web/` — vanilla ES modules, same as the ecosystem.
- The device profile is data and lives in one place:
  `Sources/DJCore/Resources/profiles/*.json`. The JS lab still has its own
  object, guarded by `web/jog/profile-parity.test.mjs` — edit both or neither.
- **Swift is the app language** (chosen 2026-10-07): SwiftPM, no `.xcodeproj`,
  macOS 15+, swift-testing, `swift format` (2-space default). Keep CoreMIDI
  callbacks short and hop to the main actor for UI; AVAudioEngine render
  blocks (when they arrive) must not allocate or lock at all.
- Makefile-driven: `make swift-test`, `make run-app`, `make test` (Swift + Go
  + node), `make fmt lint`. Run tests through make — under Command Line Tools
  only, bare `swift test` cannot find the Testing framework.
- Resources in `DJApp.app` go in `Contents/Resources`, not via SwiftPM's
  generated `Bundle.module` (it only checks the .app root, which codesign
  rejects). Load bundled files `Bundle.main` first, `Bundle.module` second.
- Go CLI (`cmd/`) and `web/jog` remain as capture/calibration tools.
- Audio thread rules: `Turntable.render` is the only code on it. Main → audio
  goes through `SPSCRing<TurntableCommand>`; buffers cross as retained
  `Unmanaged` pointers and come back through the retire ring to be freed on
  the main thread. Nothing on the audio thread allocates, locks or releases.
- Main-thread state that the audio thread applies later (e.g. `turntable.length`)
  lags by one render; decide UI/controller logic from `Deck`'s own state.
- Controllers: jog wheels are `JogProfile` + `JogAdapter`; everything with
  pads/faders is a `SurfaceProfile` JSON (`groups` + `layout` + optional
  `leds`). Add a device = add a JSON and list it in `SurfaceProfile.all`.
  MIDI routing must go through `DispatchQueue.main.async` (FIFO), not `Task`.
- Coverage contract: every control in a profile has a layout entry — bound, or
  `"action": "unbound"` with a `reason`. Values come from the real hardware:
  re-capture with `djctl monitor <device> > captures/<device>.log`, regenerate
  `Tests/DJCoreTests/Fixtures/captured-messages.json`, and keep the replay test
  green. Mark values not yet seen on a unit `[MIXXX]`/`[UNVERIFIED]`.
- Tests use `DJEngine(offline: true)` (manual rendering) — never the speakers.

## Live net decks (Phase 3)

- A deck plays either a sample (`Turntable`) or a live Petri net (`WaveDeckSource`, the
  Swift port of beats' wave engine). Only one is rendered at a time (`Deck.mode`).
- **The wave source obeys the same audio-thread rules as the turntable**, and they are
  measured, not asserted: `make swift-rt-test` builds in release and counts malloc/free
  on the render thread (`countAllocations`, a `malloc_logger` hook) across swaps, macros,
  keys and scratching. Debug builds skip those tests (unoptimised Swift allocates: forced on
  in debug they count millions of mallocs, so they could only fail), and `make run-app` is a
  debug build; the app to listen with is `make run-app-release`.
  Traps found so far: a marking array sharing storage with its `initial` copy (CoW on the
  first write), non-escaping closures that became escaping, retiring objects on the
  audio thread (hand them back through the retire ring).
- Projects are composed and compiled off the audio thread (`TrackSpec` →
  `PreparedTrack`), handed over whole through a command ring, installed at the next bar.
- Generated data tables are checked in as `Resources/beats/tables.json` (regenerate with
  `make beats-tables`). The JS generator is canonical (GO-DIVERGENCE.md).
- Controllers address net decks with `section`, `roleMute`, `macro`, `stinger`, `keys`,
  `sync`, … bindings; deck-less ones (keys, joystick) act on `DJEngine.focus`.

## Instruments beyond beats' wave engine

- beats' wave engine folds every tonal instrument into 7 wavetable families (`tonalVoice`).
  `Resources/voices/instruments.json` (`InstrumentTable`) gives an instrument its own voice,
  overlaying its family: `engine: "pluck"` (Karplus-Strong), `lowpass`, `distortion`,
  `vibrato*`. Engine values come from beats' Tone.js presets (`public/audio/tone-engine.js`).
- The parity path ignores it: `WaveOptions()` is beats exactly (what the fixtures run); the
  app prepares with `WaveOptions.extended`. Keep both true — new call sites pass `.extended`.
- `resonance` is the loop feedback per period *at 220 Hz*, scaled per note so every pitch rings
  equally long; the loop lowpass's phase delay is taken off the delay line so strings play in
  tune. String delay lines are allocated at prepare (`pluckedStringsDoNotAllocate`).
- `InstrumentTableTests` hold each entry to: in tune (fundamental partial < 5 cents), rings
  and decays, and within 3 dB of the lead voice — re-run it when adding or retuning one.
  `dj_audition` (or `djctl ctl audition '{"instrument":…}'`) plays one on the Mac's output.
- **Voicing / sampled instruments** (`VoiceCatalog`, `Resources/voices/categories.json`): the
  Logic/GarageBand EXS instruments installed on this Mac are scanned and sorted into
  categories by name rules (bass.electric, guitar.acoustic, keys.epiano, brass, synth.lead…;
  articulation and iOS copies count once). beats' composer still picks its instrument names
  — tracks stay beats-identical — and each name maps to a category; a role (all its riff
  variants) plays a pick from that category's pool seeded by the track seed + role, then the
  rest of the pool, then the category's `gm` programs from each SoundFont, then — `keepSynth`
  categories — its synth voice, else Apple's GM (`gs_instruments.dls`). `keepSynth`
  categories offer the synth voice as a pick beside installed sounds (with none, the
  SoundFont comes first: guitar.distorted, keys.harpsichord). New content
  joins the pools when installed — no code change; picks move when the pool does. Every
  sampler is level-normalised on load (`normalize`, to the lead voice's −27.5 dB on the
  reference phrase), so no per-instrument gains. Each deck owns a `SamplerBank` (`WaveDeckSource.samplers`); its
  AUSamplers are rendered by hand inside the deck's callback (not engine nodes), so MIDI is
  sample-exact and offline rendering works. Compile with the deck's options
  (`Deck.waveOptions` / `.extended(samplers:seed:)`, seed = the track's) or the instrument
  stays a synth voice; a recompile without the seed (section jumps!) would change the picks.
- SoundFonts (`SamplerSource.sf2`, melodic bank 0x79): `.sf2` files in
  `~/Library/Application Support/dj-vevr-se/soundfonts` (`$DJ_SOUNDFONTS` overrides), other
  banks by name, then `MuseScore_General.sf2` (MIT, FluidR3-based) last as the floor. `make
  soundfonts` downloads it from MuseScore's mirror, sha256-pinned; never commit a bank. The
  load-time checks apply as to EXS (SoundFontTests prints what they turn away; the bank's
  Synth Bass 1 dies within 0.1 s, Choir Aahs is +32 cents). Tests skip without the bank.
- Sampler rules: loads happen off the audio thread and every AUSampler set-up/tear-down holds
  `SamplerInstrument.lifecycle` (CoreAudio traps when one initialises while another
  uninitialises). Old EXS files with 31-char truncated sample names are patched into
  `~/Library/Application Support/DJApp/exs/` (`ExsNames`). Samples load whole into memory
  (StreamFromDisk off): a streaming thread that falls behind changed renders under load; the
  cost is RAM (tonal content is ~3 GB in all; a full bank of pianos is a few GB).
- Load-time check (`normalize`): a sound is level-matched, and turned away (marked
  unloadable, the pick falls through) if it is silent on the reference phrase or more than
  `maxDetuneCents` (30) off in whatever octave it speaks. Each catalog sound keeps every
  installed copy as a fallback chain (Logic before GarageBand before iOS copies): GarageBand
  copies of Logic instruments can lack samples, and newer-format EXS (Koto, Toy Piano, Music
  Box) don't load in AUSampler at all. Some sampled instruments vary between renders on
  purpose (guitar round robin, tape/chime modulation): sessions with them are not
  byte-identical on replay; GM programs always are. `make sampler-sweep` runs the sound
  checks over every installed sound (minutes); the default suite takes one per category.
- Sampler eviction: a bank holds 24. `slot(for:)` takes a reference on the slot it returns
  (`release` gives it back); a `WaveProject` holds one per sampled lane until its `deinit`,
  which runs off the audio thread after the retire ring — so current, pending, fading and
  not-yet-loaded projects all pin their slots. A full bank loads the new instrument first,
  then reuses the least recently used slot with no references in two phases: clear its bit
  in the `active` mask (the audio thread drops its MIDI and stops rendering it), wait out any
  block in flight (`epoch` is odd during `beginBlock`…`endBlock`, both seq-cst), then free
  the old AUSampler on the loading thread and publish the new one. Only when every slot is
  referenced does an instrument fall back to its synth voice. Anything else that calls
  `slot(for:)` (auditions, tests) must `release`. `sampledInstrumentsDoNotAllocate` measures
  an eviction landing mid-render.
- Sampled content never enters the repo or the CDN: Apple's licence covers playing it in
  your music, not redistributing the samples. `SamplerTests` re-measure pitch and level.

## Visuals (Phase 5)

- SwiftUI lives only in `Sources/DJViews` (and the `DJApp` shell). DJCore has models
  (`WaveformOverview`, `NetSnapshot`, `SectionTimeline`, `PadLight`, `DeviceMapRow`) and never
  imports SwiftUI; a view that needs data the core doesn't expose adds a model there first.
- Views are tested by rendering them (`renderPixels` in `Tests/DJViewsTests/Render.swift`) and
  asserting pixels / geometry. `DJ_SHOT_DIR=/path swift test --filter …` also writes PNGs
  (`savePNG`) to look at.
- Anything the UI does to a deck goes through `DJEngine.perform` (recorded); on-screen pad
  presses go through `ControllerRouter.press` (recorded as MIDI).

## Control socket and MCP

- The running app listens on `~/Library/Application Support/DJApp/control.sock` (0600;
  `$DJ_CONTROL_SOCKET` overrides): newline-delimited `{"id","method","params"}` →
  `{"id","result"|"error"}`. Methods live in `Sources/DJViews/AppControl.swift` and only call
  what the UI calls (`DJEngine.perform`, `ControllerRouter.press`, …), so they record the same.
- `djctl mcp` is the stdio MCP server (`MCPBridge`): one socket request per tool call, so the
  app can restart under a live MCP session. `make mcp-install` copies it to `build/mcp/` and
  registers `dj-vevr-se` at user scope. `djctl ctl <method> [json]` sends one raw request.
- Publishing is deliberately not a tool (it's public and asks in a modal).
- Build id: `bundle-app.sh` stamps `CFBundleVersion` (short commit, `-dirty` with tracked
  changes) and `DJBuildDate` into Info.plist; `BuildInfo.current` reads them ("dev" unbundled).
  It shows in the app's footer, in `dj_state.build`, and as MCP `serverInfo.version`
  (`djctl` itself is unbundled, so that one says "dev").

## Hardware notes (macOS)

- `./dj-vevr-se ports` is the native replacement for `amidi -l`;
  `make monitor MATCH=inpulse` for `aseqdump`. CoreMIDI needs no permissions.
- Chrome's Web MIDI needs `localhost` or https; `make serve` uses :8765.
- Only one app should hold the port if behaviour looks odd — quit Chrome's
  lab tab before blaming the CLI, and vice versa.

## Commits

Signed with GPG key `624DDC38A40EF01D` (`commit.gpgsign=true` on this box).
