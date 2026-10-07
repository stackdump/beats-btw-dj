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

## Hardware notes (macOS)

- `./dj-vevr-se ports` is the native replacement for `amidi -l`;
  `make monitor MATCH=inpulse` for `aseqdump`. CoreMIDI needs no permissions.
- Chrome's Web MIDI needs `localhost` or https; `make serve` uses :8765.
- Only one app should hold the port if behaviour looks odd — quit Chrome's
  lab tab before blaming the CLI, and vice versa.

## Commits

Signed with GPG key `624DDC38A40EF01D` (`commit.gpgsign=true` on this box).
