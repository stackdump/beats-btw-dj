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
  keys and scratching. Debug builds skip those tests (unoptimised Swift allocates).
  Traps found so far: a marking array sharing storage with its `initial` copy (CoW on the
  first write), non-escaping closures that became escaping, retiring objects on the
  audio thread (hand them back through the retire ring).
- Projects are composed and compiled off the audio thread (`TrackSpec` →
  `PreparedTrack`), handed over whole through a command ring, installed at the next bar.
- Generated data tables are checked in as `Resources/beats/tables.json` (regenerate with
  `make beats-tables`). The JS generator is canonical (GO-DIVERGENCE.md).
- Controllers address net decks with `section`, `roleMute`, `macro`, `stinger`, `keys`,
  `sync`, … bindings; deck-less ones (keys, joystick) act on `DJEngine.focus`.

## Hardware notes (macOS)

- `./dj-vevr-se ports` is the native replacement for `amidi -l`;
  `make monitor MATCH=inpulse` for `aseqdump`. CoreMIDI needs no permissions.
- Chrome's Web MIDI needs `localhost` or https; `make serve` uses :8765.
- Only one app should hold the port if behaviour looks odd — quit Chrome's
  lab tab before blaming the CLI, and vice versa.

## Commits

Signed with GPG key `624DDC38A40EF01D` (`commit.gpgsign=true` on this box).
