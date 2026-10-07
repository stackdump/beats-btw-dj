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
- The device profile is data and lives in one place
  (`web/jog/inpulse-200-mk3.js` for now). Never hand-copy it into Go.
- Go 1.25, Makefile-driven: `make build`, `make test`, `make serve`.

## Hardware notes (macOS)

- `./dj-vevr-se ports` is the native replacement for `amidi -l`;
  `make monitor MATCH=inpulse` for `aseqdump`. CoreMIDI needs no permissions.
- Chrome's Web MIDI needs `localhost` or https; `make serve` uses :8765.
- Only one app should hold the port if behaviour looks odd — quit Chrome's
  lab tab before blaming the CLI, and vice versa.

## Commits

Signed with GPG key `624DDC38A40EF01D` (`commit.gpgsign=true` on this box).
