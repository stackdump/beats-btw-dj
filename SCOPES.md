# Scopes — beats' scope and stage visualizations in the native app

Branch `phase5-scopes` (from `main` 71cac0d). Ports the scope and stage visualizations of
beats.bitwrap.io — `public/lib/ui/scope.js`, `scope-model.js`, `stage.js` and the pieces of
`canvas.js`, `feed.html`, `perf/monitor.js` that the task names, all at beats-bitwrap-io
**`095d030`** — per deck and on the master, fed by the engine's own audio taps and live net
state. **Not merged, not pushed: for review.**

> `095d030` (the spring auto-gain commit) exists only in valoper's clone of beats, not in
> the checkout on this Mac (which stops at its parent 668978e). The sources were read from
> valoper at that commit.

## Try it

`make run-app`, load or generate a track on a deck, press play. (Nothing in this branch has been
run in a real window — see "Needs a person".)

* **Scopes** toggle (under the decks) → the panel: **Scope / Spectro / Bands / Raster**, source
  **A | B | Master**, a **measured** toggle for Spectro and Bands, and the visual-quality menu.
* **Stage** button → the Stage window: constellation of live net panels, toolbar behind the
  round "•" burger (visualizer select: Constellation / Corona / Sonar / Petal / Shuffle,
  flow / pulse / flame / tilt / bolts toggles, expand variants, backgrounds, scale, help).
  Arrow keys cycle visualizers, Esc closes.
* The main window also gained: dimmed ring + persistent playhead + hand-over spin (22), rolling
  timeline dots (23), structure-strip colours and phrases (24), LED dots in the device map (25),
  macro chase glow (26), the master flame meter under *Master* (28).

`make test` (≈ 5 min on a quiet machine: 1638 Swift tests / 258 suites, 25 real-time tests, Go,
web) and `make lint` are clean at the last commit. `make swift-test-filter FILTER='Regex'` runs a subset.

## Modes

Commit = the `Scopes N:` commit on this branch. Everything "ported" is selectable in the app,
fed from the engine (never re-derived in the view), unit-tested against literals computed
from the pinned JS (node oracles in `scripts/`), and render-tested offscreen.

| # | Mode | Status | Commit |
|---|------|--------|--------|
| 1 | Scope / Live (waveform, lanes, spring gain) | ported | bf25333 |
| 2 | Spectro — model columns | ported | 62a0e00 |
| 3 | Spectro — measured | ported | 0adba4e |
| 4 | Model engine (kernels, FX response, deposit/decay) | ported (DJCore; used by 2 and 5) | 3dba00b |
| 5 | Bands (digits, residual, stats) | ported | 152ef14 |
| 6 | Raster | ported | f457481 |
| 7 | Constellation (+ live tokens from the engine marking) | ported | ec70348 |
| 8 | Meta-net overlay, Expand variants | ported | 86a891c |
| 9 | Corona | ported | e14b058 |
| 10 | Sonar | ported | d3d965f |
| 11 | Petal | ported | 7f9e84a |
| 12 | Shuffle + arrow-key cycling | ported | 44c952d |
| 13 | Flow drift | ported | d75edf6 |
| 14 | Pulse | ported | 139da9b |
| 15 | Flame | ported | 0dfabd4 |
| 16 | Tilt | ported | bf3138c |
| 17 | Bolts / seeds / halo | ported | b4b34d8 |
| 18 | Backgrounds (void / stars+planets / aurora) | ported | 643dc35 |
| 19 | Card flash | **not ported** — the app has no share card (see below) | — |
| 20 | Track spin | ported | d75edf6 |
| 21 | Legacy wave / spectrum | **not ported** — absent from the pinned source | — |
| 22 | Main ring extras | ported | b9be491 |
| 23 | Rolling timeline dots | ported | 44510d1 |
| 24 | Structure strip | ported (loop markers n/a: nets have no loop region) | 7639ab2 |
| 25 | Device-map LED mirror | ported for what was missing; the APC pad mirror already existed | b7c7296 |
| 26 | Macro chase pulse | ported (the four mute macros, as the JS) | bed0032 |
| 27 | Perf viz-level degrade | ported | 7901d58 |
| 28 | Feed flame meter | ported | 318b605 |
| 29 | Fingerprints / jog lab / feel pad | **not ported** — see below | — |

Foundation commits (`Scopes F1.1`–`F2a.6`, `Scopes: AnalyserFFT`): lock-free rings, the
deck and master taps, fire/anchor streams, the marking mirror, colours, lanes, `ScopeFeed` /
`ScopeHub`, the host. Plus four small test-hygiene commits (`savePNG` only with `DJ_SHOT_DIR`,
three load-sensitive tests made deterministic) and one dead-code removal.

### Not ported, and why

* **19 Card flash** — the pinned code flashes the *share card* (title, seed, QR). This app has no
  share card, no QR encoder, no per-track share URL. The Stage toolbar button exists and is
  disabled with a tooltip. Inventing a card was out of scope.
* **21 Legacy wave / spectrum** — the pinned `stage.js` has no such renderer; the words survive
  only in a stale comment above `scopeCanvas`. Corona replaced it.
* **29** — *ring-dot fingerprints* exist in beats only for the share card; a place for it exists
  (next to the deck title, from `Deck.currentSpec.seed`) but it would be new UI in a layout that
  is already tight, so it is left for a decision. *Jog lab* is already in this repo (`web/jog`,
  `PlatterView`, `JogAdapter`). *Feel pad* is a control surface whose axes (tempo ×0.6–1.4, Tone
  FX slots) don't map onto this app's ±8 % pitch and single DJ filter.
* Small: no structure select in the Stage toolbar (it regenerates the track in beats; the Stage
  window here is a read-only view of the decks); on-disk kernel persistence for the model
  (optional in the task; a kernel renders in ~55 ms); the monitor's audio-note inputs and HUD.

## Architecture in one paragraph

Audio thread: a per-deck tap (mono mixdown, pre-EQ/pre-fader) pushed from the deck's source-node
block into an overwrite ring, a master tap fed from an output-unit render notification, a
`FireEvent` stream and a per-tick `TickAnchor` stream written by `WaveRunner.doTick`, a
seqlock marking mirror of every net's tokens and mutes, and a macro mirror — all
preallocated, all off (one relaxed load per block) until a view subscribes, and all measured
allocation-free by `make swift-rt-test`. Main thread: `ScopeHub` hands out one `ScopeFeed` per
source (`.deck("A")`, `.deck("B")`, `.master`); the feed drains the rings once per frame and
exposes sample history, fire log, anchors (frame ↔ step), lanes, sections, marking, clock, and a
process-unique `generation` that every mode resets on. Models and numbers live in `DJCore`;
SwiftUI `Canvas` drawing lives in `DJViews`; the Stage is a registry of layer slots
(`StageLayerRegistry`). The headers of `ScopeFeed.swift`, `ModelEngine.swift`,
`MeasuredReader.swift`, `AnalyserFFT.swift`, `StageContext.swift` and `StageLayerModels.swift`
are the contracts.

## Deviations that matter (the code comments and commit messages carry the rest)

* **Real dt** for the spring and decays (the JS mixes `performance.now` with audio time).
* **Engine anchors**: beats derives its step anchors from fires; here the engine publishes one
  per tick (exact frame, tempo, `.swap`/`.discontinuity`). Anchor ring is 128, sample history
  32 768 (the 8192 / 256-sample blocks of the JS are built from it).
* **Stopped transport**: beats stops its loops and keeps the last picture; here the engine
  clock keeps running, so waveforms scroll as measured time and only the grid/bars stop at the
  song's last step; measured frames below −120 dB are "no data" (else an idle deck autoscales
  to solid yellow) and bar accumulation is gated on the lead transport.
* **Measured reads** follow the JS: the hub reads the analyser on every pump while the panel's
  measured box is ticked, in every view (`ScopeHub.setMeasured`, kept by the panel through
  `ScopeSubscription.syncMeasured`), so a visit to Scope/Live or Raster leaves no hole in the
  bars. What differs is a stalled UI: a >1 s pause between two reads restarts the coverage
  window (`MeasuredReader.gapSeconds`; the JS has no such rule). A source without a net is
  read too (spectrogram frames only, no bars), as the JS reads whatever it is given.
* **Model FX point (decision for you)**: the deck tap is pre-EQ/pre-fader, so a *deck* feed's
  model defaults to `fxPoint = .matchTap` (blind to that deck's filter sweeps and fader);
  `.deckOutput` applies deck EQ + gain² as the task text says. A *master* feed always uses the
  full per-deck chain. The mode views print which one is in use.
* **Macro running** (bolts, seeds, halo): the deck's flag follows every macro **fired** for its
  whole duration (`WaveRunner.markMacroRunning`, called by `fireMacro` and `fireStinger`), not
  only the mute timers / beat repeat / tempo effect it leaves behind, as beats' `_runningMacro`.
  The catalog's FX, pan, shape, pitch, feel and one-shot kinds **do not exist in this engine**
  (no master chain), so there is nothing of theirs to signal; a kind added later calls
  `markMacroRunning` and bolts follow. The flag is per deck (with two decks a macro on A throws
  no bolts from B's hits); the JS flag is global.
* **Corona** hears the **left** channel (Tone's `Analyser` is `ChannelSplitter(1)` → analyser,
  checked in Chrome), so decks and the master got an optional left-channel tap; smoothing is
  compensated per frame (`τ' = τ^(dt·60)`) so 120 Hz screens look like 60 Hz.
* **Wide band rows under a strong DJ filter** read low with the spec's 4-probe mean (lomid 3.6×
  under a 900 Hz low-pass); kept faithful, pinned by a test, one-line to change.
* **Bands + measured panel is 332 pt, not scope.js's 300**, which clips the residual's last
  row, the axis and the tilt line.
* **Fire flash** follows the pinned CSS cascade: a transition with a note keeps its two-tone
  body and flashes via glow + scale + red border; `StageStyle.firingBodyIsSolid` is the switch
  if you prefer the solid red of the SPEC wording.
* **Live tokens** (not drawn by beats): blue disc, count when > 1 — my choice.
* **Glows** are drawn the way a canvas `shadowBlur` is defined (σ = blur/2 *device* px), checked
  pixel-for-pixel against headless Chrome at dpr 1 and 2 for bolts, seeds, corona, sonar, petal.
* **Panel arrangement** (24): section names other than the five beats names keep their old hue
  where beats paints them all `#888`.
* Pulse cap is 65 live particles (the JS shifts above 64 *before* the push) — the pinned source
  wins over the SPEC text.

## Needs a person (nothing below could be run here)

**Hardware / live window** — none of this was run in a real window or on the Inpulse:
* The **master tap** is an `AudioUnitAddRenderNotify` on the live output unit (offline-tested
  only, incl. the 4-channel cue routing). It now also runs whenever a deck plays and the master
  flame meter is on screen. Quick check: play, open Scopes → Scope → Master and watch it move;
  toggle "Inpulse out"; confirm playback is clean. `DJEngine.outputLatencyFrames` is unverified.
* Open **and close** the Stage window (red button): confirm the feed is released
  (`hub.activeFeeds` empty). Arrow keys / `T` / Esc reach the model in the live window.
* Frame cost on a Retina display: corona (up to 128 blurred layers), bolts/seeds, aurora,
  tilt over five canvases, 40 panels with Expand. The perf monitor (27) should degrade
  gracefully; pin *Minimal* to see the levels.
* Visual check against beats.bitwrap.io side by side: spring bounce (~20–24 % overshoot), the
  spectrogram scroll, Bands panel, Stage look. Text in Live/Spectro/Raster sits ~3 pt lower than
  the JS `textBaseline = 'top'` (Bands matches Chrome).
* Scopes panel height vs a 14-inch screen: the deck row is already ~870 pt, the panel up to
  640 pt, and the Scopes toggle lives in the footer — check it stays reachable (a `ScrollView`
  is the likely fix; same pre-existing layout style as Map and Pads).
* The Stage window hint for Sonar/Petal on a deck without a net is blank (no empty-state text).

**Product decisions** (each is small): the model FX point above; the 332 pt Bands height; Bands residual steps ~4 dB per
halving of tempo (JS parity kept); solid-red fire flash; token look; ring-dot fingerprint;
whether the arc layer on the deck rings (22) stays (one argument turns it off).

**Housekeeping on this machine**: the sub-branches `p5s-*` and their worktrees under the
session scratchpad are merged and can be removed (`git worktree remove`, `git branch -d`);
`/Users/myork/Workspace/dj-vevr-se/.playwright-mcp/` (6 small untracked files) was created in
the **main** checkout by the agents' headless-Chrome comparisons — delete it.

## Real time

`make swift-rt-test` (release, 25 tests): the deck block with taps/rings/mirrors on and off, the
whole engine through its real source-node closures and the master notification, project swaps at
bar boundaries, macros, scrubbing, ring overflow, the analyser, the measured reader, the
kernel lookup, the raster-at-start — all `allocations == 0 && frees == 0` with the rings proven
to have received data. Audio output with taps on equals taps off bit for bit (tested on a deck,
the engine and the master).

## Oracles

`scripts/analyser-reference.mjs`, `scope-model-oracle.mjs`, `scope-spectro-oracle.mjs` run the
pinned beats algorithms in node (no DOM) to print the literals the Swift tests pin;
`scripts/stage-solo-chrome-reference.html` runs the pinned `renderCorona/Sonar/Petal` bodies in
headless Chrome and prints probe pixels (`#dpr=1|2`).
