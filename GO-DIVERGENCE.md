# Go vs JS generator divergences (follow-up for beats-bitwrap-io)

**Decision (2026-10-08): the JS generator is canonical.** Shipped share links were
composed with `public/lib/generator/*.js`; Swift in this repo follows the JS
byte for byte (`ComposerGateTests`). beats' Go generator (`internal/generator`)
is *not* identical, so it cannot regenerate a JS-composed share exactly.
Nothing here modifies beats-bitwrap-io; this is the list to take to that repo.

Evidence: `make fixtures-go` composes all 542 JS-fixture cases in Go
(`scripts/beats-go-oracle.mjs`, data in `Tests/DJCoreTests/Fixtures/beats/go.json`).
Go's model CID equals JS's for **0 of 542**. Re-measured against beats `668978e`.
`BeatsGoOracleTests` documents this as known-diffs and pins what *does* agree, so a
fix in beats shows up as a failing "known divergence" test to update.

## 1. Drum MIDI channels

Go gives every drum voice channel 10. JS gives kick 10, snare 11, hihat 12, clap 13
(`composer.js`; the `edm` clap is this same difference, not a separate bug). The
channel is part of the canonical model JSON, so this alone changes the CID of every
project. Everything else in the kick, snare, hihat (non-ghost) and clap nets is
identical. With JS channels 11–13 mapped to 10, 24 whole projects (ambient,
synthwave, metal loops and their override variants) match Go exactly.

## 2. RNG: `math/rand` vs mulberry32 / the variety LCG

Go's `Compose` and `GhostNoteHihat`, `WalkingBassLine`, `CallResponseMelody`, markov
and friends draw from `rand.New(rand.NewSource(seed))`. JS draws from `mulberry32`
(composer, markov, riffs) and from the 31-bit LCG in `variety.js`. The streams are
unrelated, so every net whose notes or rests come from a draw differs: v1 bass and
melody, ghost-note hihats, walking bass, call/response, instrument choice, chord
progression pick, structure blueprint pick, drum-fill and stinger seeds. Cohesion-v2
bass/melody/harmony/arp nets agree because they come from `BuildTrackTheme`, which
*is* held in lockstep (`theme_parity_test.go`) — except two v2 bass nets in genres
not yet identified.

## 3. Structure control nets: linear chains vs accumulator nets

In song mode Go emits the `struct-*` control nets as linear chains (one place and
transition per tick, ~40 KB each for a 320-tick `minimal` song). JS
`structure.js::buildAccumulatorNet` emits compact countdown/gate nets (~2–5 KB).
Different nets, so different CIDs even for identical sections. (Go also produced
fewer slot nets in the one case inspected, which follows from the RNG-driven
blueprint pick in #2.)

## 4. JS-internal: a share's counterMelody overlay never plays in the browser

Not a Go/JS difference, but one for the same list. On the composer path
`lib/backend/index.js` runs `arrangeWithOpts(el._project, …, { overlayOnly: true, … })` on
the worker's project-sync JSON. `injectCounterMelody` simulates the source nets, which are
plain objects there, so `nb.resetState()` throws (`nb.resetState is not a function`) whenever an
entry's section exists. The catch only logs, and since the throw comes after `fadeIn` /
`drumBreak` / `feelCurve` mutated `el._project` in place but before `project-load`, the worker
plays none of the overlay. Full arranges hit the same throw on cloned variant nets
(`cloneBundle` is a JSON round trip). Swift deliberately runs the overlay on parsed nets, so the
counter-melody plays (ROADMAP 2.8, "Deliberate deviation"); fixtures hold Swift to what the JS
function does with `NetBundle`s, and `wireProbe` records the browser throw.

## What to decide in beats

Either align Go to JS (channels, a mulberry32/LCG port, accumulator nets), or
declare Go output non-canonical and keep Go away from share regeneration. Until then nothing
in the Swift app depends on Go. For #4, either parse the nets before simulating (then shares
with a counter-melody start to sound different in the browser) or drop the directive.
