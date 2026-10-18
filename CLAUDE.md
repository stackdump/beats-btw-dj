# dj-vevr-se

Native DJ-controller tooling for Petri-net music. Private repo
(`stackdump/dj-vevr-se`), developed on **the MacBook** (`~/Workspace/dj-vevr-se`)
because the hardware — a Hercules DJControl Inpulse 200 MK3 — is plugged in
there. Not on valoper, not deployed to pflow.dev.

## The theme: a random walk on a music generator

The app is a **random walk over the generator's space of known configurations**. A
configuration is everything that names a piece of music — genre, seed, structure, cohesion,
the share overrides (instrument picks, initial mutes), the deck's knobs and role filter — and
each one renders to the same audio every time (beats' determinism, content-addressed by CID).
The performer **pokes**; the app answers by **recomputing to a nearby known configuration**,
under structural rules, rather than editing audio freely.

- **Pokes are moves in configuration space**: the seed wheel (±1 seed), Generate / Next /
  auto-next (`TrackSpec.nextVersion`: same song settings, the next seed), an instrument pick
  (a `tracks` override), a role disabled (`roleFilter`), STEMS / role mutes, macros, a section
  jump, a loop taken from the stream. Each is a `DeckAction` (or recorded MIDI), so a session
  replays the same walk.
- **Rules keep the walk musical**:
  - **Time:** every move lands on a structural boundary. Swaps at the next bar, sections on
    the bar, loops in and out on the downbeat or launch quantum. Loops follow the louder
    deck's tempo.
  - **Memory:** the user's choices survive the recompute. A disabled role stays out of every
    new compile, a picked instrument keeps choosing its sound by name, and favorites, tags,
    crates and the loop library persist.
  - **Derivation:** anything the app chooses for itself (the next version's seed, a sampler
    pick, a loop's phase) is a pure function of the current configuration. Never wall-clock
    randomness at run time.
  - **Provenance:** what a move produced records where it came from (`LoopProvenance`, a
    favorite's descriptor, a session's events), so the walk can be retraced or walked back.
    The **journal** is the system of record for all of it: every poke and every store change
    of a run, from a checkpoint, so any run can be rebuilt (`Journal.replay`). A state change
    that is neither a `DeckAction` nor a `JournalEvent` is a bug.
- **Wander is the walk made autonomous** (`Wander.swift`, the deck's Wander section): a net deck
  with wander on takes one move per phrase (pace 4/8/16/32 bars, default 16) on its own bar
  clock, entering the phrase's last bar: a role mute, STEMS, a net macro over that bar, a master
  FX macro, a stinger (small, ~62 %), a nearby seed (±1…7), a seed with another instrument on
  one tonal role, the same seed in another structure, or a neighbouring genre (same family,
  nearest tempo: `Wander.neighbours`) — weights in `WanderMoveKind.weight`. Swaps land at the
  next phrase's first bar with the transport still running (`PreparedTrack(startTick:)`,
  `SwapStart`). The move is `Wander.plan(context, step)`: seeded from the spec's share CID + the
  deck's step counter, so moves are **derived, never recorded**; only the pokes are
  (`DeckAction.wander` / `.wanderPace` / `.wanderLock`, the controller's MIDI), plus the walk's
  settings in a session's starting `DeckParams.wander`, so a replay walks the same path
  (`WanderReplayTests`). Moves never touch disabled roles or locked buttons
  (`DJEngine.lockedActions`). **Locks** (per deck, remembered in the app's defaults): genre,
  tempo (genre hops within ±6 % of the tempo at lock time), key (genre hops keep the scale and
  root; every new spec pins `extra["keyOffset"]` = `TrackSpec.pinnedKeyOffset`, which a pass
  that moves keys per seed must honour), structure (no structure moves; hops stay in the
  family), instruments (no instrument moves; every new spec carries the deck's instruments in
  its `tracks` override), arrangement (no mutes / STEMS), fx (no macros / stingers), palette
  (no palette hops; the instruments lock stops them too), and
  `keep:<role>` (its instrument rides along, never muted or re-picked; its notes still change
  with the seed until beats has per-part seeds). Everything locked: wander says so and stands
  still. **Steering**: the browser wheel steps the seed (loops and now songs, swapped at the
  next bar) and pauses a wandering deck until a whole phrase passes with no turn; SHIFT + wheel
  sets the pace, the browser push toggles it (both `[MIXXX]`, uncaptured). Sample decks don't
  wander. The log (newest first, ★ stars the track a move led to) is in the panel and
  `dj_state.decks.X.wander`.
- **Coordinates vs moves**: beats' `compose()` is the coordinate system and stays
  byte-identical (Origin and boundary, GO-DIVERGENCE.md). dj's moves and rules live in
  `DJMusicality.apply`, the share overrides, the runner and the engine.

New features fit the theme as three things:
1. **A kind of poke:** a `DeckAction` with codec, dispatch and round-trip test, or a controller
   binding.
2. **The rule that picks the configuration it lands on:** deterministic, seeded from the
   current one.
3. **The boundary it lands at:** beat, bar, phrase or section.

If a feature can't say all three, question it.

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
  audio thread (hand them back through the retire ring), AUSampler building its
  AUParameterCache on the render thread at the first note-on after any AVAudioMixerNode is
  connected in the process (`SamplerInstrument.init` pre-builds it with a throwaway parameter
  listener; `samplersDoNotAllocateWhenAnotherEngineIsBuilt` guards it).
- Projects are composed and compiled off the audio thread (`TrackSpec` →
  `PreparedTrack`), handed over whole through a command ring, installed at the next bar.
- Generated data tables are checked in as `Resources/beats/tables.json` (regenerate with
  `make beats-tables`). The JS generator is canonical (GO-DIVERGENCE.md), except where dj deliberately
  differs: there dj keeps its behaviour and the improvement is backported to beats
  (GO-DIVERGENCE.md §5).
- Controllers address net decks with `section`, `roleMute`, `macro`, `stinger`, `keys`,
  `sync`, … bindings; deck-less ones (keys, joystick) act on `DJEngine.focus`.

## Master chain (ROADMAP 3.3)

- A net deck ends in beats' `&fx=tone` master inserts (`MasterFx/`: HP → phaser → LP → crusher →
  distortion → pitch shift), run in `WaveDeckSource.render` **after** `runner.process` (the net and
  its samplers), so sampled voices go through it. FX / pitch / feel macros are `MasterMacro`
  (kept apart from `NetMacro`: `MacroMirror` is sized by `NetMacro.allCases`), fired over the
  same command ring (`masterMacro`, `masterFx`) and animated by `FxAutomation` on the deck's
  transport clock (stops while paused) — beats' offline 120 / 200 ms grid, flushed per instant.
- Same audio-thread rules, measured (`MasterChainRealTimeTests`, `renderDoesNotAllocate`). The
  pitch shifter's Chrome wavetables (`PeriodicWave`) are built once per sample rate by whoever
  creates the chain: never make a `MasterChain` / `WaveDeckSource` on the audio thread.
- `vinyl-brake` on a project prepared with `WaveOptions.turntableBrake` (`.extended`; off in
  `WaveOptions()`, which keeps beats' octave-down compound) is a turntable brake
  (`TurntableBrake.swift`, GO-DIVERGENCE.md §5): varispeed on the runner's output, *before* the
  chain (the chain is the mixer's insert and keeps real time), r = 1 − t / (¾ D), silent for the
  last quarter, then `WaveRunner.catchUp` puts the tick clock where an unbraked deck would be
  and it fades in over 5 ms. Panic releases (5 ms fade), stop / freeze cancel. Master macros are
  net-only on A/B (`Deck.fire(MasterMacro)` guards `mode == .net`), so sample decks never brake;
  on "L" they go to the loops' master bus (below).
- **Loops master FX** (`Audio/LoopMasterBus.swift`, `LoopMasterFx.swift`; not a clip's "Loop
  FX"): the same chain + `FxAutomation` on the loop channel "L", after the 16 voices are summed:
  voices → Σ → [vinyl brake] → MasterChain → limiter (the limiter stays last; it also runs while
  the bus is engaged). Clocked by the loop channel's frames; each fire carries the loop clock's
  BPM (`loopClock(for: nil)`) and lands on its next launch line (launch quantum, at most a bar;
  `loopMasterFireFrame`), so N bars are N loop bars. Pokes are the decks' own:
  `.macro(deck: "L", id:)` (master ids only; net macros do nothing), `.panic(deck: "L")`, the
  APC aimed at L (SHIFT + either aim scene button, `focusDeck` slot 2 [UNVERIFIED]; the A/B aim
  LEDs blink while aimed at L), and `.loopFxLink(on:)` (a net deck's master macro also fires on
  L at once, its panic releases L; in `loopSettings` when on). Feel macros keep only their
  filter on L (tempo events dropped). `vinyl-brake` on L is `TurntableBrake` with the bank as
  its `BrakeSource`: the summed voices varispeed together, then each voice `Turntable.skip`s
  its own lag, so loops land back to the byte where unbraked ones would be. At rest the bus is
  bit-transparent. UI: the Loops row's "Master FX" fold (`LoopMasterFxStrip`).
- A neutral chain is bypassed and bit-transparent (decks without FX render the runner's exact
  bytes). `restBypass = false` / `solo` exist only for `MasterChainChromeTests`.
- Parity: `macro-fx.json` (beats' macro code + Tone's Param timeline; `make fixtures-beats` runs
  scripts/beats-macro-fx.mjs, which fetches Tone 15.1.22 into `.build/tone`, SRI-checked) and
  `master-chain-chrome.json` (Chrome rendering Tone's nodes; `make fixtures-chrome`,
  needs Chrome). Tone facts that matter: `rolloff: -48` is three biquads; CrossFade leaks −56 dB
  at wet 0; the HP / LP setters' cancel-then-ramp jumps back.

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
- A per-note pitch envelope (`VoiceSpec.pitchFrom` / `pitchTo` / `pitchTime`) makes zaps:
  `laser` is beats' stinger one-shot (12.2× → 0.42× over 0.4 s); the band-limited table
  steps down as the note falls; measured allocation-free (`laserSweepsDoNotAllocate`).
- An instrument the user picked (a `tracks` override) marks the net's `Track.picked` (never
  encoded: CIDs stay beats'); its sampled sound is then chosen by the name
  (`VoiceCatalog.sources(picked:)`: a sound whose name fits first, else the name in the pick
  hash). The composer's choices keep the category pick, so generated tracks sound as before.
- Roles beats lists no instruments for (harmony) get `Deck.fallbackOptions` in the panel.
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
- **Sampled drum kits** (`DrumKits.swift`, `SamplerSource.kit`, GO-DIVERGENCE.md §5.6):
  drums default to beats' synth kits; a track may pick a kit (`Track.kit`, the `tracks`
  override `kit` on every drum channel, the poke `DeckAction.setKit` → `Deck.setKit`: same
  song, rebuilt from the next bar's tick, swapped at the bar). Kits are every bank-128 preset
  and every melodic preset named "… Kit" in the SoundFont folder, plus Apple's
  `gs_instruments.dls` kits; ids are `file#bank:program` (resolved by file name, so a share
  names the same kit on any Mac with the bank). The drum lanes stay gate lanes with their
  synth voice as fallback, and send their kind's GM key (`DrumKits.gmNote`) to one kit slot,
  held `holdMs` (cymbals ring); a closed hat ends the open hat's notes (`.choke`). Kits load
  through `normalizeKit` (level to `kitTargetRMSdB` = the synth kit on `kitPhrase`; kick, snare
  and hat must sound; no tuning check) and follow `.balance`'s kick trim as a velocity scale.
  dj-only track fields (`picked`, `kit`, `palette`) are lost in the JSON a `WaveGraph` compiles
  from: `buildLanes` reads them from the project itself (`geometry`). `SampledKitTests` (levels,
  parity, deck swap), `SampledKitRealTimeTests` (a mid-render switch allocates nothing).
- Sampled content never enters the repo or the CDN: Apple's licence covers playing it in
  your music, not redistributing the samples. `SamplerTests` re-measure pitch and level.
- **Minecraft palette — local only.** `make minecraft` (`djctl minecraft import`) builds
  `minecraft-local.sf2` + `minecraft-local.json` (asset index, per-sample SHA-1) in the SoundFont
  folder from the user's own PrismLauncher assets (`MinecraftAssets`: newest index,
  `$DJ_MINECRAFT_ASSETS` overrides; `MinecraftBank` fixed programs, kit at 0:127; decoded,
  44.1 kHz/16-bit, tuned, steady tones crossfade-looped). Personal use only: the .ogg files and
  the .sf2 never enter the repo, a release or the CDN (`*.sf2`, `minecraft-local.*` ignored), it
  never joins the GM pools (`localOnlyBanks`), and `music/*` / `records/*` are never read.
  Publishing refuses any set that plays it (`Session.localOnlySounds`; `djctl publish
  --allow-local-sounds` / the Publish… checkbox override); local renders are fine.
- **Palettes are how a track chooses its sound** (`SoundPalette`, `Resources/voices/palettes.json`,
  `PaletteSound.swift`): 13 named sound worlds (Studio = each instrument's own sound, the
  default, never written into a share; Synth = beats' voices only; Synthwave, 8-bit, Acoustic
  band, Orchestral, Lo-fi tape, Jazz club, Club, Ambient, World strings, 90s sound card (Apple
  DLS, local only), Minecraft (local only)). Per role (`kit`, bass, melody, harmony, arp,
  stinger, `*` = any other tonal role; Minecraft also has `pad`) a pool of options — `own`, `synth`, `synth:<instrument|drums-kit>`,
  `cat:<category>`, `gm:<n>` (SoundFont floor), `dls:<n>`, `bank:<bankCategory>`, `inst:<name>`,
  kit ids — plus `hints` (another genre's room/echo, `WaveOptions.forPalette`) and Wander
  `neighbours`. `Project.applySound(seed:)` (run in `TrackSpec.finish`, the raw-nets prepare and
  after every sound poke) resolves each net to `Track.sound` (`TrackSound`: override, option,
  palette kit, the composer's instrument) from the seed + role over the options installed here;
  a `synth:` option swaps the instrument itself, so balance/loudness probes see it. Pokes:
  `setPalette` (the `tracks` override `palette` on every role channel, `minecraft@32` with its
  asset version), `setRoleVoice` (fine-tune: `tracks` `voice` on the role's channels; nil =
  "reset to palette", also dropping an instrument or kit picked for it), `setKit` — all next bar,
  same song (`Deck.retarget`). **Memory:** the deck's palette, kit pick and role overrides carry
  into every new track (`TrackSpec.carryingSound`: `nextVersion`, the seed wheel, Generate,
  every Wander swap; beats puts each role on the same channel in every genre). Wander's
  `palette` move (weight 2) hops to a playable neighbour on the same song (`Wander.carry`
  pins kept roles to their option); the `palette` and `instruments` locks stop it. A palette
  whose sounds aren't installed greys out with the role and reason (`unavailableReason`, cached
  per option, `PaletteCard.unavailableHere` once per launch; `SoundPalette.rescan` after an
  install). Local-only banks are level-checked on load but skip the tuning check (their importer
  tuned them). Publish refuses palettes, options and kits from `SamplerSource.localOnlyFiles`
  (Minecraft bank, Apple's `gs_instruments.dls`). UI (`SoundChoices.swift`): the deck's
  **Sound** section — palette cards on top (`.arrowKeys`), "Fine-tune" folded below (`Deck.roleSounds`: each role's pick, options, ↺ palette, instruments
  / all kits, long press = VoiceEditor); Generate has a palette row. `dj_palettes`, `dj_generate
  palette`, `dj_state.decks.X.sound`. `PaletteTests` hold every palette to resolving here (or
  saying why), Synth = the no-sampler render bit for bit, and ±4 dB LUFS of Synth
  (`IntegratedLoudness`, BS.1770; `djctl render --palette ID` prints `lufs` and each role's
  option).

## Musicality (docs/musicality-notes.md)

- `compose()` stays beats' byte for byte; what a deck plays is `PreparedTrack.played` =
  `DJMusicality.apply(project, spec:)`: rewrites bindings and initial markings only (never
  places / transitions / arcs), a pure function of (project, spec). `.groove` and `.loudness`
  live in the runner. All on in `WaveOptions.extended`, off in `WaveOptions()` (parity).
- `djctl render <genre> <seed> [--fixes none|all|key,…] [--synth] [--out f.wav] [--notes f]`
  renders offline and prints `MusicalityReport` + `AudioMetrics`; `scripts/
  musicality-matrix.py OUTDIR [--sampled]` / `--compare A B` is the 24-track before/after.
- Part C adds `.fills`, `.voicing`, `.energy` (`EnergyCurve`: section level + tonal lowpass,
  measured per section at prepare and reused on section jumps via `WaveOptions.trackEnergy`),
  `.duck` (`WaveOptions.duckDepth`, set by `PreparedTrack` from the genre), `.contour`,
  `.color` (the pass may bind free pad steps). New flags go in `Fixes.all` and `Fixes.named`.
- Part D adds `.arpeggio` (rebinds arp slots), `.buildup` / `.crash` (bind on `fill-N` chains,
  which span the song from tick 0 to their boundary, so any bar before it can carry a drum
  hit; the runner voices note 49 there as a crash), `.bassLine`, `.openHats` (note 46 → open
  hat in the runner) and `.stereo` (mid/side pan per lane in the runner, `stereoPlacement`; the
  sampler bus's side highpassed at 150 Hz). Stereo only renders with a right channel: mono
  callers get the old mix.
- Part E adds `.legato` (melody notes held to the next, ≤ a beat), `.cadence` (phrase ends —
  half a bar of rest, or the last note before a 2-bar line — on a chord tone), `.approach`
  (a moving bass line steps into the next root; not offbeat-bass genres or jazz), and in the
  runner `.dropGap` (kick / snare / hats / bass skip the last beat of a buildup into a drop:
  `DJMusicality.dropGaps`, `WaveProject.gaps`), `.choke` (a net's closed hat chokes its open
  hat) and `.space` (`Space.swift`: an 8-line FDN send reverb per runner, allocated at init;
  room by genre `SpaceSpec.forGenre`, set by `PreparedTrack` like `duckDepth`; per-lane
  `send`; sampled slots that send render as their own group and reach the room a block late
  through `sendFifo`; input highpassed at 200 Hz, return side at 300 Hz). `djctl render
  --room` measures the return against a dry render. Tests that A/B an earlier note-level fix
  leave `.cadence` / `.approach` out of both sides (`playedWithout` in MusicalityTests).
- Part F adds sound design in the runner — `.subtractive` (`SynthVoice.swift`: `MipTables`,
  band-limited per octave with beats' fundamental level, and `FilterEnvelope`, a per-voice SVF
  lowpass opened by velocity²), `.unison` (detuned pairs; a pad's pair spreads under `.stereo`,
  its side highpassed at 300 Hz), `.echo` (`Echo.swift`: `PingPong`, tempo-synced, set by genre
  like the room, synth lanes only), `.kickTune` (`KickTuning`: root or fifth nearest 50 Hz) — the
  pass's `.motif` (bar 2 of each 4-bar melody phrase restates bar 1 as a diatonic sequence; runs
  after `.cadence`) and `.balance` (`MixBalance`: each part soloed at prepare, trimmed ± 6 dB
  toward `targetDB`; `WaveOptions.trackBalance` reused on section jumps; `djctl render
  --balance` prints the levels). `Loudness.voiceFixes` are the fixes its probe must hear.
  Per-genre settings come from `WaveOptions.forGenre`.
- Part G adds `.variety` (`TrackVariety.swift`): beats draws only the melody from the seed, so
  every seed of a genre had the same key, chords, bass and drums. Seeded from the track's seed
  (`varietyRandom(name, genre, seed)`, one stream per decision): a key offset −5…+6 (notes and
  `rootNote`, so `.kickTune`, the keys and later fixes follow) and, in cohesion v2 with a
  seven-note key, a progression from `progressionTable` (beats' own `chordProgs` first in the
  pool; pad and bass moved along the key, a walking bass's chromatic approach re-aimed, melody /
  arp beat notes snapped to the new chord) before `.register` (`varyHarmony`); after
  `.bassLine`, a bass figure (rhythm × line; each bar's first and last notes stay the root,
  figure notes under the pad and above E1; walking / bossa basses untouched) and drum detail
  (ghost hats / snares / kicks, hats thinned or moved an eighth; no extra kick in
  four-on-the-floor) (`varyFigures`). `.arpeggio`'s figure is seeded too (`ArpFigure`: shape,
  span, start, rate, from the seed and the slot's variant letter). `VarietyTests` count distinct
  4-bar patterns per part across 30 seeds.
- Beats generator bugs found this way go on GO-DIVERGENCE.md §5.

## Visuals (Phase 5)

- SwiftUI lives only in `Sources/DJViews` (and the `DJApp` shell). DJCore has models
  (`WaveformOverview`, `NetSnapshot`, `SectionTimeline`, `PadLight`, `DeviceMapRow`) and never
  imports SwiftUI; a view that needs data the core doesn't expose adds a model there first.
- Views are tested by rendering them (`renderPixels` in `Tests/DJViewsTests/Render.swift`) and
  asserting pixels / geometry. `DJ_SHOT_DIR=/path swift test --filter …` also writes PNGs
  (`savePNG`) to look at.
- Anything the UI does to a deck goes through `DJEngine.perform` (recorded); on-screen pad
  presses go through `ControllerRouter.press` (recorded as MIDI).
- No dropdowns on the deck: its controls beyond the core are `DeckSections` — a strip of toggle
  buttons folding panels open (Perform, Wander, Master FX, Reverb, Sound, Favorites, Generate,
  Load, Notes, History); which are open is `fold.<deck>` in the app's defaults. Choices are `ChoiceButton`s,
  lit when current.
- A wide window (`ViewThatFits`) gives each deck two columns: core beside the mixer, sections on
  the outer side (A left, B right); narrower stacks the sections under the core.
- Favorites (`FavoritesStore`, `~/Library/Application Support/dj-vevr-se/favorites.json`) keep
  the deck's `DeckSourceDescriptor` in the session encoding, named by share CID — never just the
  title (43×43 names, so ~540 seeds per name in the Generate range).
- Instrument changes (`Deck.roleVoices`, `withInstrument`) are the share envelope's `tracks`
  override keyed by MIDI channel, so they record, star and share; applying one reloads the track
  from its start. Copying a deck loads the same descriptor on the other one.
- **The sound panel** (`VoiceEditor.swift`): a long press (0.5 s, `InstrumentButton`; the click
  that ends it does not pick) or right-click ▸ Edit sound… on an instrument opens its channel's
  voice: level (dB on the instrument's), attack, decay (× note, max), brightness (post lowpass, 0
  = off), drive, vibrato, and a pitch sweep (one group: setting any sets all three). A
  `VoiceTweak` (only the fields set; empty = the instrument) is the poke `DeckAction.voiceTweak`
  (params inline); `voiceSynth` makes a sampled channel play its synth voice (AUSampler params
  are not shaped). **Live, no reload**: the main thread makes `VoiceLaneParams` (coefficients,
  a mask; a clear bit restores the lane's own prepared value, so Reset is bit-exact) and sends
  `WaveCommand.voice`; `WaveRunner.setVoice` sets every lane on that channel of the current and
  pending projects at the next block (`voiceTweaksDoNotAllocate`). Every wavetable lane has its
  pitch multipliers, lowpass coefficients and (saw / square) `MipTables` from prepare, so all of
  it is live; what prepare decides from the instrument's own voice stays (engine, wave,
  `.subtractive` filter envelope, `.unison`, stereo spread — a live lowpass or drive collapses a
  spread lane to one pan). Strings take no sweep.
- Voice settings are **session-only** (`WaveDeckSource.voiceSettings`, per channel, with the
  instrument they were made for): applied to every project the deck loads (`load`, before the
  hand-over: section jumps, relocations) and kept across an instrument pick on another channel
  (`Deck.keepsVoiceSettings`: same share but its `tracks`); a new song, auto-next, a favorite or
  the same song loaded again, a new instrument on that channel, or a relaunch start from the
  instruments' own voices. Never in the share, a favorite or a CID; Copy to deck doesn't carry
  them. Saved **variations** (`VoiceVariationStore`, `~/Library/Application
  Support/dj-vevr-se/voices.json`, instrument → [{name, params, useSynth}]) show as chips after
  their instrument ("laser · short zap"); a chip is the same `voiceTweak` (picking the
  instrument first if needed), so sessions replay without the library.

## Loop FX (after effects per clip)

- `LoopFX` (`Audio/LoopFx.swift`) is a value on each clip (`LoopClip.fx`), set by one poke,
  `DeckAction.clipFx(id:fx:)` (the whole value, so a replay needs nothing else). **Non-destructive**:
  the clip's audio, id, WAV, crops and sequences stay dry; the loop-bank voice plays it through an
  insert after the turntable, before level × fade: drive 0…+24 dB → shaper (clean | soft tanh |
  hard | tube = Tone.Distortion's curve biased | fold | crush = the master chain's quantiser +
  sample-and-hold, clipped at full scale first) with amount 0…1 → tone (TPT 2-pole lowpass, 1 =
  open) → auto-level (1 / drive + slow RMS followers, on by default) → mix → trim −24…+12 dB.
  The waveshapers run 2× oversampled (47-tap halfband, 23 samples late, the dry side delayed to
  match). Then a safety limiter on the loop channel (−0.5 dBFS, instant attack, 120 ms release).
- **Off is exact**: an inactive `LoopFX` (`isActive`: bypassed, or nothing set) never enters the
  chain, and the limiter only runs while some voice has FX on (or its gain is still releasing), so
  a row without FX renders the bank's old bytes (`noFxIsBitIdenticalToNoChain`). Params cross as
  `LoopBankCommand.fx` (the clip-gain path), one-pole smoothed; on/off, mode and hold changes
  crossfade through dry over 10 ms. Measured allocation-free (`LoopFxRealTimeTests`).
- Persistence: library.json entries (`fx`, only when set), removed/, the journal checkpoint's
  clips (the run's FX win over the library's on restore). A crop keeps its clip's FX; a new
  sequence starts off (its steps' audio is dry), an edited one keeps its own; a clip on deck A/B
  plays dry; scenes don't recall FX. UI: the pad's right-click ▸ FX presets (Off, Warm drive,
  Crunch, Fuzz, Crush, Loud), Settings… ▸ FX, the tile's FX popover; an FX badge when active.

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

## The journal and notes (DJCore/Journal)

- One append-only JSONL file per app run, `~/Library/Application Support/dj-vevr-se/journal/
  journal-<UTC start>.jsonl` (`$DJ_JOURNAL_DIR` overrides; tests pass a directory). Line 0 is a
  checkpoint (`JournalState`: decks' sources + `DeckParams`, playing, follow, voice settings,
  mixer, the loop row by clip id with gains/mute/solo/key lock, scenes, removed clips, row
  settings, locks, and the stores: favorites, crates, variations, notes); then one event per
  line: `{"v":1,"seq","t" (ISO ms, metadata only — never read back),"f" (engine frame),"k",…}`.
- It is a second sink beside `SessionRecorder` at the same hooks (`perform`, the router's
  MIDI, the tempo grid), so UI, controllers, MCP and the socket all land in it; the app adds
  the store events (`favorite.*`, `crate.*`, `variation.*`, `note.*`, `library.restore`,
  `sample.file`, `mark`). Encoded and written on the journal's own queue, never the audio
  thread (`JournalRealTimeTests`); one `write` per line, `fsync` ≤ 1/s; a torn last line is
  dropped on read. New state that persists or changes what a replay does needs an event.
- `Journal.replay` stands a fresh offline engine on the checkpoint (clip audio from the loop
  library by id, samples via `sample.file` paths) and applies the events at their frames with
  `OfflineConductor`, as `SessionPlayer` does; the stores replay through the stores' own pure
  edit functions (`FavoritesStore.adding`…). Deterministic offline; a live journal replays as
  exactly as live timing allows (async composes and sampled round robin can shift a take —
  then clip events fall back to the library's clip by id). `djctl journal list | show |
  replay [--to SEQ|--at S] [--render f.wav] | export-session --from --to` (a slice → a normal
  `Session`, starting at rest: playheads and the row at `from` are not in it).
- **Notes** (`TrackNote`): text + target + optional bar/beat. A net track is keyed by its share
  CID (same genre + seed + settings = same track, so the note returns whenever that
  configuration plays again), a sample by content id (+ file, so starred samples carry them),
  a clip by id. Journal events are their source of truth; `notes.json` is the projection for
  launch, replaced by the newest journal's if they differ. UI: the deck's ✎ Notes section
  (one-tap notes at the current bar, a field, the list; right-click edits), History (the
  journal's latest lines, notes in yellow), ✎ on clip tiles and favorites; `dj_notes`,
  `dj_journal`.

## Hardware notes (macOS)

- `./dj-vevr-se ports` is the native replacement for `amidi -l`;
  `make monitor MATCH=inpulse` for `aseqdump`. CoreMIDI needs no permissions.
- Chrome's Web MIDI needs `localhost` or https; `make serve` uses :8765.
- Only one app should hold the port if behaviour looks odd — quit Chrome's
  lab tab before blaming the CLI, and vice versa.

## Commits

Signed with GPG key `624DDC38A40EF01D` (`commit.gpgsign=true` on this box).
