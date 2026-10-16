# dj-vevr-se roadmap

Written 2026-10-07. Visuals are deliberately last (Phase 5). Every phase ends
with something that runs on the Mac with the three controllers plugged in.

Status legend: **done** · **in progress** · **next** · later.

## Where we are (2026-10-11)

All of it is on `main` (Phase 3 landed there directly; `phase5-scopes` merged in 69f8431).
README's "Where we are" says what the app does; this is what each phase still has open.

- **Phase 1** — done. Open: the Inpulse hardware pass (checklist below), MPK pad NOTE mode.
- **Phase 2** — done, 2.1–2.8, including share links (composed and raw-`nets`) on a deck from
  the app / MCP. Open: nothing; short `?cid=` links need the caller to fetch the payload (2.8
  "Left out"). The counterMelody deviation is kept and goes back to beats (GO-DIVERGENCE.md §5).
- **Phase 3** — done, 3.1–3.5; in 3.3 the send FX (reverb / delay), Pan and Shape macros are
  not ported and each needs a design call. Which master macros go on Inpulse pads is open.
- **Phase 4** — done. Open: the Inpulse headphone-knob mapping.
- **Phase 5** — done, 5.1–5.7 (5.7: beats' scopes and Stage, [SCOPES.md](SCOPES.md)). Open:
  the scopes and Stage have not been checked in a live window ("Needs a person" in SCOPES.md).

---

## Phase 1 — Every control on all three devices **(done 2026-10-07; Inpulse hardware pass open)**

Goal: every physical control on every device produces a decoded event, and
every event has either a binding or an explicit "unbound" entry. Nothing a
hand can touch is silently dropped.

Coverage when this phase started (2026-10-07; README has the bindings now):

| Device | Bound | Not bound / not decoded |
|---|---|---|
| Inpulse 200 MK3 | jog touch, jog scratch/bend (both decks) | play/cue/sync, pads (4 modes × 4 per deck), volume faders, crossfader, EQ/filter knobs, gain, loop, browser encoder, shift, headphone cue buttons, vinyl, mode buttons — **unmeasured** |
| APC mini mk2 | 9 faders (8 used), grid rows 0–1, scene 1–2, track 1 & 8 | grid rows 2–7, scene 3–8, track 2–7, shift; faders 5 unused |
| MPK Mini Mk II | 8 knobs, 8 pads (bank A) | 25 keys, joystick (pitch bend + mod CC), sustain, pad bank B, CC/PC pad modes, arp/tap tempo — **unverified factory map** |

1.1 **Measure** — a `djctl learn <device>` walk-through (port of the lab's
calibration wizard idea): prompts "move control X", records the message,
writes the observed groups into the profile JSON. Seed the Inpulse profile
from Mixxx's Inpulse 200 mapping, mark every value `[UNVERIFIED]` until
measured, same discipline as the jog lab.
1.2 **Profile schema** — extend `SurfaceProfile` with: shift layers (APC
shift note, Inpulse shift channel +3), pitch-bend (0xEn, 14-bit) and 14-bit
CC pairs, relative encoders, note-on-velocity-0 release, LED output groups
for the Inpulse (it lights pads/buttons by note-on, like the APC).
1.3 **Merge jog + surface** — the Inpulse becomes one profile with a
`jogs` section plus ordinary groups, so it gets faders/buttons/LEDs like the
others.
1.4 **Default layouts** for the full surfaces (data, not code):
  - Inpulse: native deck control (play, cue, sync, pads = hot cues/loops,
    faders/crossfader/EQ = mixer) — it is the "DJ" device.
  - APC mini mk2: the *Petri* surface — grid = section/slot launcher and
    macros (as beats does), track buttons = role mutes, faders = per-role
    levels/FX.
  - MPK Mini: the *instrument* — keys play into the current key/scale on a
    live net, pads = stingers/one-shots, knobs = FX, joystick = pitch/filter.
1.5 **Conflict rule** — when two devices drive the same parameter, last
writer wins and LEDs/UI resync; soft-takeover for faders/knobs so a
physical fader doesn't jump the value until it crosses it.
1.6 **Unbound log** — `ControllerHub` reports every decoded-but-unbound
event (and every undecoded message) so gaps are visible, plus a test that
fails if a profile has a control group with no layout entry and no explicit
`unbound` marker.

Done when: `djctl monitor` shows a decoded name for every control on all
three devices, and the default layouts bind or explicitly park each one.

**Outcome.** Measured by sweep capture (`captures/*.log`, gitignored) rather than
a step-by-step `learn` wizard; the distinct messages are a test fixture
(`Tests/DJCoreTests/Fixtures/captured-messages.json`). Findings that differ from
expectations: the Inpulse sends every knob/fader as 14-bit CC pairs, its SHIFT is
note 0x04 *and* a hardware channel shift (+3), pad modes 0x0F/0x10 select note
ranges; the MPK preset on this unit sends knobs on CC 1–8 (knob 1 collides with
the joystick's CC 1) and pads as Program Change — not beats' factory map. Still
open: the Inpulse hardware pass below; pad NOTE mode on the MPK. A `djctl learn`
wizard is deferred — re-capture + fixture regeneration covers preset changes for now.

**Inpulse hardware pass (open; checked 2026-10-11).** The 2026-10-07 capture settles the
pad modes — after FX (0x10) the pads send 0x10–0x13 (group `rollPads`, a Mixxx name kept
for sessions and tests; bound to macros), after HOT CUE (0x0F) 0x00–0x03 — but leaves two
kinds of gap. Captured but not named (parked): LOOP + the two STEMS buttons (0x03 / 0x09 /
0x0A) on each deck and the centre buttons 0x01–0x03; `SurfaceProfileTests.
inpulseCapturedButParkedIsTheKnownSet` lists them. Never captured: every shifted button,
the browser, pads 0x08+ / 0x20+ / 0x30+, pad bend, deck B PFL / LOAD / hot-cue pads;
`inpulseUncapturedControlsAreMarked` keeps each tagged `[MIXXX]` / `[UNVERIFIED]`. One
session with `djctl monitor inpulse > captures/inpulse-<date>.log` (keep the 2026-10-07
log), saying each control's panel name as it is pressed:

- [ ] Name the centre buttons 0x01–0x03 (deck buttons named 2026-10-16: 0x03 LOOP, bound to LOOP
  record; 0x09 STEMS music, 0x0A STEMS mic, parked until their role groups are chosen):
  ASSIST/PREP, MASTER, BEATMATCH GUIDE.
- [ ] Turn the browser encoder both ways and push it, with and without SHIFT.
- [ ] Turn MASTER, then HEADPHONES, on its own (which one is CC 0x03 / 0x04).
- [ ] Hold SHIFT and press every deck button (LOOP, both STEMS, HOT CUE, FX, SYNC, CUE,
  PLAY, PFL, LOAD) and turn HIGH/GAIN, on both decks.
- [ ] Each pad mode — HOT CUE, LOOP (SHIFT + HOT CUE), FX, SAMPLER (SHIFT + FX) — × all
  4 pads, with and without SHIFT, on both decks.
- [ ] Deck B PFL and LOAD.
- [ ] Add the new distinct messages to `Tests/DJCoreTests/Fixtures/captured-messages.json`
  (no script yet: notes on + off, one value per CC, as now), fix the profile's names and
  comments and drop the tags that are now measured, bind what has an obvious action, and
  shrink the known-parked set in the test.

Open decision: the FX-mode pads carry the net macros (cut, beat-repeat, drop, breakdown).
The master-chain macros (3.3) bind through the same `macro` action; which four go on
which pads — or on the LOOP / SAMPLER pad modes once their numbers are known — is a choice
to make, not a measurement.

## Phase 2 — Native music generation with CID equivalence **(done, 2.1–2.8; what is left out, and why, at the end of 2.8)**

Goal: the Swift app composes and renders beats tracks itself, and for the
same share envelope produces the **same CIDs** as beats.

2.1 **(done — `Sources/DJCore/Beats/`)** Foundation: order-preserving JSON (JS key order rules), JS number
formatting (`JSON.stringify`), mulberry32 / `Math.imul` / ToInt32 helpers,
stable sort, Go-escaped canonical JSON, CIDv1 (dag-json, sha2-256,
base58btc) and model CID (sha256 of `canonicalProjectJSON`).
2.2 **(done — `make fixtures-beats`, `Tests/DJCoreTests/BeatsFoundationTests.swift`)** Parity harness: node script imports beats' JS (`BEATS_PUBLIC`) and
writes fixtures — share envelope → canonical bytes + CID; (genre, seed,
structure, cohesion) → project JSON + model CID; module-level vectors (RNG,
bjorklund, motif, structure). Swift tests compare byte-for-byte.
2.3 **(done — `Sources/DJCore/Beats/PFlow.swift`; layout recompute and runtime fire/isEnabled deferred to 2.6)** Port `pflow.js` (NetBundle, parse, `projectToJSON`, durations, CID) —
go-pflow `petri` semantics where JS leaves gaps.
2.4 **(done — `Sources/DJCore/Beats/Generator/`; arrangeWithOpts and counter-melody are 2.8; macros are Phase 3)** Port the composer in dependency order: core → theory → euclidean →
markov → riffs → variety → countermelody → arrange → theme → groove →
structure → composer. Gate each on fixtures.
2.5 **(done — `Share.swift`, `ShareURL.swift`, `ShareCodec.swift`; raw-`nets` envelopes with a `structure` and the overlays are 2.8)** Share envelope → params (`shareFromPayload`), including tempo / swing /
humanize overrides, cohesion pin (v1 for envelopes without the field),
traits, `macroCurve`.
Follow-up slice, all proven by `share-urls.json` (`scripts/beats-share-url.mjs`, real JS):
`ShareLink.parse` = `parseShareFromUrl` (`?cid=&z=` verified against the CID and refused on
mismatch; legacy `?p=` and `?g=&s=&structure=&t=`; short `?cid=` links come back as
`.needsFetch` with the legacy fallback, and the fetched text goes through `Share.decode`,
which re-hashes); `ShareCodec` = base64url + gzip on the Compression framework's raw deflate
(RFC 1952 header / CRC-32 / ISIZE added by hand, no zlib dependency; the JS CompressionStream
and node zlib streams, stored blocks included, all inflate, damaged ones throw);
`ShareLink.forms` builds short / full URLs; `Share.rawNetsProject()` = the `_bootGenerate`
raw-`nets` branch (name via `deriveShareName`, tempo / swing / humanize / initialMutes from
overrides) with model CID, doc sha and bytes equal to JS. Reverse direction: `make
share-url-check` has JS's own `parseShareFromUrl` accept the URLs Swift built. Left out, on
purpose: (1) raw-`nets` + `structure` ≠ "loop" (`needsArrange`) is arranged since 2.8 —
share-urls.json still records only the boot project before arrange, arrange.json proves the
rest; (2) fetching short links (network; the caller does it); (3) Swift's deflate
output is not byte-identical to CompressionStream's, so only the decoded text, CID and
envelope are compared, never the `z` bytes; (4) `fx` in a raw-nets envelope is carried in
`overrides` but `Project` has no fx model; (5) a `#fragment` link is read as a Swift-only
extension (JS reads `location.search` only).
2.6 **(done — `Sources/DJCore/Beats/Wave/`; parity form, real-time hardening is 3.1)** Port the wave engine (`net.js`, `synth.js`, `runner.js`): trace exact,
audio within 1e-5 (bit-exact where libm agrees), same as beats-py.
2.7 **(done — `make fixtures-go`, `Tests/DJCoreTests/BeatsGoOracleTests.swift`; finding: Go ≠ JS end to end; JS is canonical, see GO-DIVERGENCE.md)** Second oracle: run the Go generator (`tools/parity`) on the same inputs
for model CIDs.
2.8 **(done — `Generator/Arrange.swift`, `Generator/CounterMelody.swift`, `Share.project()` /
`rawNetsProject()`, `TrackSpec.layers`; `make fixtures-beats` runs `scripts/beats-arrange.mjs`,
`Tests/DJCoreTests/BeatsArrangeTests.swift`)** The deferred composer features: `arrangeWithOpts`
(full and `overlayOnly`), the overlay directives (`fadeIn`, `drumBreak`, `feelCurve`,
`macroCurve`, `counterMelody`), raw-`nets` envelopes with a `structure`, and the `tracks` /
`fx` / `initialMutes` overrides. Proven on fixtures from the real JS at beats `668978e`: node
count, canonical bytes, model CID and the sha of the serialized document must all match, and
where the JS throws the Swift must throw. arrange.json holds 252 overlays on composed projects
(8 genres × seeds × {minimal, standard, extended} × {v1, v2}; 26 add a counter-melody net),
343 full arranges (6 genres × v1/v2 × 9 sizes plus Object.prototype names × parsed / wire input
× option sets incl. authored `sections`, `maxVariants`, `velocityDeltas`, counter-melody; 82 of
them are JS throws), 12 hand-written wire documents, 23 whole share envelopes (composer +
overrides + overlay, and raw `nets` + arrange + overrides, with their share CIDs; 11 raw) and 27
override cases run through the real `applyShareOverrides`. Every overlay directive completes in
≥ 1 v1 and ≥ 1 v2 case per genre, and every arrange option per genre, cohesion and input form
(`fixturesCoverTheDirectives`). The arrange tables are lifted from the JS source into the
fixture and compared. Debugging a mismatch: `node scripts/beats-arrange.mjs --dump
arranges:12` prints the JS document, `DJ_ARRANGE_DUMP=<dir>` makes the test write the Swift one.

What the port reproduces, found by the fixtures rather than assumed:

- `expandArrangeVariants` clones through JSON and the counter-melody net is a plain object, so
  those nets lack `resetState`; `simulateMusicNotes` then throws (`nb.resetState is not a
  function`). A full arrange with a counter-melody therefore throws unless nothing it simulates
  was cloned (`of` a single-slot net such as `snare`, or `maxVariants: 1`); a second unscoped
  entry throws on the first entry's net. Swift tracks the "plain" nets (`ArrangeContext`).
- A share's raw `nets` reach arrange as unparsed wire JSON: `velocityDeltas` finds no
  `bindings` to tweak, and the closing `stampDurationSteps` stamps only bindings whose JSON
  has a finite positive `duration` and no positive `durationSteps`, from the raw (possibly
  fractional) ms. `ArrangeOpts.wireForm`, `Project(wireJSON:)`.
- Object.prototype names (`constructor`, `toString`, `__proto__`, …): as a `size` the
  blueprint lookup finds a function and the arrange throws; as a genre it gets song blueprints
  without family archetypes; a curve entry naming one keeps its point (the net is built) at a
  tick that never matches, and a section with such a name never gets a start. `null` entries
  in `fadeIn` / `sections` / curves / `counterMelody` throw where the JS reads them.
- `toFixed(6)` in the counter-melody seed rounds the exact binary value half up; `drumBreak`
  bars can be fractional (the unmute then lands on no transition); fractional velocity deltas
  are rounded by the re-parse.
- Order: overrides before the overlay on the composer path (`_applyProjectSync`, then the
  pending overlay); on the raw path arrange first, overrides once the worker answers. A throw
  in the raw-path arrange is caught and the project loads as far as it got (stamped); a throw
  in the composer overlay leaves the composed project (the browser never sends the half-built
  one). `counterMelody` is never passed to the raw-path arrange.
- `fx` never touches the project (a fixture checks the document is unchanged); `tracks` is
  keyed by channel through `parseInt`; `initialMutes` from an override replaces the list.

The app: `TrackSpec(share:)` keeps the overrides and overlay directives in `layers`, and
`PreparedTrack` plays `compose` → overrides → overlay through the same `Share.finishComposed`;
`TrackSpec.payload` writes them under their envelope names and `init(payload:)` reads them
back, so recorded sessions replay the same project (payloads without them are unchanged).
Compose overrides (`extra`: traits, `bpm`, …) go under `payload.traits`, where
`shareFromPayload` reads them (an array `macroCurve` at the top level, as beats writes it), so
beats composes a deck's payload with the same params the deck does: `specPayloads` in
share-urls.json has the real JS read that form and compose it, and records that the old
top-level form loses the traits there. `init(payload:)` still reads the old form (sessions
recorded before 2026-10-12) to the same spec (`TrackSpecPayloadTests`). A stored session
verifies against its own text, so its CID holds; only re-encoding one whose net decks carry
extras writes the new form and a new CID. None were saved or published before the change.

Raw-`nets` shares play on a deck too: `DeckSourceDescriptor.rawNets(payload:)` carries the
envelope payload (`TrackSpec(share:)` stays nil for them), `PreparedTrack(rawNets:)` builds
`Share.rawNetsProject()` off the audio thread like a composed track (the payload read in
canonical key order, as a share URL decodes it; voicing seeded by the payload's `seed`, else
0), and a session records it as `{"kind":"rawNets","share":…,"cid":…}` so a replay builds the
same project (`RawNetsSessionTests`: byte-identical replay with a mid-set load and a section
jump on an arranged share). Older session payloads decode unchanged.

Loading a share: `DeckSourceDescriptor.share(_:)` takes a share link (`ShareLink.parse`: full
URL or its query, CID verified; legacy `?p=` / `?g=`) or an envelope payload as JSON and gives
`.net(TrackSpec(share:))` or `.rawNets(payload:)`. The control socket's `loadShare {deck, link}`
(MCP `dj_load_share`, `djctl ctl loadShare`) and the deck's Load ▸ "Share link from clipboard"
prepare it off the main thread and load it through `DJEngine.perform`, so it is recorded
(`ShareSourceTests`, `AppControlTests`, on the links and payloads of share-urls.json and
envelopes.json).

**Deliberate deviation — counterMelody on the composer path (kept, 2026-10-12; to backport to
beats, GO-DIVERGENCE.md §5).** In
the browser the overlay runs on `el._project`, the worker's plain JSON, so any counter-melody
entry whose section exists throws (`nb.resetState is not a function`, caught and logged;
`wireProbe` fixtures) and the browser then drops the *whole* overlay — fadeIn and drumBreak
included — because the half-built project is never sent to the worker. `Share.project()` and the
decks run the overlay on the parsed project instead, which is what the JS function produces
when given `NetBundle`s: the counter-melody plays. Parity is held on that function-level
behaviour. See GO-DIVERGENCE.md for the beats-side bug.

Left out, and why:

- Short `?cid=` links (no `&z=`) are refused by `loadShare`: their payload is on a server and
  the app does no fetching (2.5 (2)); the full link or the payload loads.
- The browser's `_normalizeProject` adds stinger nets (`isStingerTrack`) to `initialMutes`
  before the overrides land; not modelled (as in 2.5), so a raw-`nets` share whose stingers are
  not already muted differs in `initialMutes`.
- `feel`, `autoDj`, `macrosDisabled`, `note`, `ui`, `hits`, `loop` overrides: UI state, no
  model effect.
- JS coercions on inputs no envelope should carry: non-string `genre` / `name` / `structure`
  (a non-string structure arranges as an unknown size; JS looks it up by `String(value)`),
  fractional or non-numeric authored section `steps`, a non-array `active`, non-numeric
  `velocityDeltas`, net IDs that are Object.prototype names, sibling `bindings` in wire nets
  (tweak / channel), `null` `tracks` entries. Curve points naming Object.prototype keys mixed
  with same-tick points assume V8's sort keeps the numeric ones in order (it does for the
  fixtures; the comparator returns NaN for them).
- No Go oracle for any of this (`make fixtures-go` covers compose only; JS is canonical).

Done when: every genre × {loop, minimal, standard, extended} × cohesion
{v1, v2} × N seeds matches project JSON and model CID, share CIDs match, and
renders match the JS engine.

## Phase 3 — Live Petri decks **(done on `main`; 3.3 partial — send FX, Pan and Shape macros not ported)**

Goal: a deck can play a *generated net live*, not just a WAV, and the
controllers perform on the net.

3.1 **(done — `WaveDeckSource`, `Deck.loadNet`; `make swift-rt-test` measures zero allocation in render)** `WaveRunner` as a deck source (real-time safe port, same contract as the
JS runner: no allocation in `process`).
3.2 **(done — `Deck.generate/queueNext/advanceToNext/service`, `TrackSpec`)** Generate on a deck: genre + seed (+ structure) → compose → play; next
track pre-composed in the background.
3.3 **(done — `DeckPerform`, `WaveMacros`, profiles; the master-chain FX / pitch / feel macros
since 2026-10-11 — `MasterChain`, `FxAutomation`, `MasterMacro`; pan, shape and the send-only FX
macros NOT ported, see "3.3 master chain")** Controls drive the net: section jump / slot activate
(APC grid), role mutes (APC track buttons), macros (port beats' macro catalog), live tempo,
MPK keys into a scale-locked live net, stingers on pads.

**3.3 master chain (2026-10-11).** beats has no wave-engine master chain, but its `&fx=tone`
routing (lib/backend/wave.js `connectOutput`) feeds the wave worklet into Tone's master inserts,
and that is what the FX macros move. Ported, per deck, after the net and its sampled instruments
(`Sources/DJCore/Beats/Wave/MasterFx/`):
- **The chain** (`MasterChain`): HP → phaser → LP → bit crusher → distortion → pitch shift, as
  tone-engine.js `init` builds them, with tone-engine.js's setters and build.js `applyFx` on top
  (`MasterParams`) and Tone 15.1.22's own Param timeline under them (`ToneParam`).
- **The macros** (`MasterMacro`, `FxAutomation`, beats' effects.js / runtime.js / feel/axes.js):
  `sweep-lp`, `sweep-hp`, `reverb-wash` (its HP move), `riser` (its HP and phaser moves),
  `build-crush`, `phaser-drone`, `filter-res`, `octave-up`, `octave-down`, `pitch-bend`,
  `vinyl-brake`, `feel-chill`, `feel-drive`, `feel-ambient`, `feel-euphoric`, `feel-build`,
  `feel-wind-down`, `feel-reset`. Fired from the deck's "FX" menu, any controller binding or MCP
  `dj_perform` by beats id, recorded and replayed by sessions (the format is unchanged).
- **Proven by**: `macro-fx.json` (scripts/beats-macro-fx.mjs runs beats' real macro code against
  a stubbed Tone Transport and real Tone `Param`s; 666 cases: every ported macro × its durations
  and 0 (permanent) × 120 / 174 BPM × start {defaults, sliders moved, re-fire at half, panic at
  30 %} + 26 overlaps): every slider and tempo dispatch at the same time (1e-9) and value, the
  same end state, every Tone-level call and 29 392 parameter values Tone read back mid-run.
  `master-chain-chrome.json` (scripts/master-chain-chrome-reference.html: Chrome rendering beats'
  real Tone nodes moved by its setters): LP, HP, crusher, distortion within 4.2e-5 of Chrome sample
  for sample, phaser 2.1e-4, pitch shifter 7.9e-4. Closed forms in `MasterChainTests`;
  `make swift-rt-test` measures the chain, the automation and the deck with every macro: zero
  allocations, zero frees.

**Not ported — nothing of theirs reaches wave audio in beats; each needs a design call:**
`delay-throw`, `cathedral`, `dub-delay` and the reverb part of `reverb-wash` / `riser` (Tone's
reverb and delay are sends fed only by Tone channel strips, which the wave worklet bypasses);
the Pan macros (`ping-pong`, `hard-left`, `hard-right`, `auto-pan`, `mono`) and the Shape macros
(`tighten`, `loosen`, `pulse`), which act on Tone channel strips / instrument decay. A Swift
reverb, delay, panner or decay control here would be new design, not a port.

**Deviations (by decision; kept in dj, the improvements go back to beats — GO-DIVERGENCE.md §5):**
a neutral chain is bypassed and bit-transparent, like beats' default
lean wave path, not the `&fx=tone` chain at rest (HP 20 Hz, LP 20 kHz and the pitch shifter's
fixed taps colour the sound); HP / LP / pitch fade in and out of bypass over 5 ms; no compressor
(beats ends in Compressor(-12, 3)). Timing is beats' offline grid (`audioAnimLoop`: 120 ms FX,
200 ms feel), not requestAnimationFrame; the slider flush is at the dispatch instant (build.js
throttles it to 33 ms wall time); Tone's lookAhead and the Transport's tick quantisation are not
modelled; the automation runs on the deck's transport clock (stops while paused), feel tempo
writes reach the runner at block resolution. The phaser's LFO starts at Tone's initial 1 Hz;
beats' reset value for its slider (0) means 0.1 Hz, so after any macro restores it the rate is
0.1 Hz — as in beats. Genre BPM for feel = the project's tempo (as `tempo-anchor` here). FX
macros survive a project hand-over (beats' project-sync on regen / swap cancels them). The
master-volume slider is not modelled (no ported macro moves it).

**Found on the way (beats / Tone facts, kept):** `vinyl-brake`'s tape-stop step does nothing
(`runCompound` fires only mute and FX sub-macros), so it is octave-down 60 ms later, for its own
1 bar, with fxHold's default tail 0.6; Tone's Distortion curve has 1024 points, not 4096; Tone's
`rolloff: -48` cascades three biquads (scope-model.js models four — kept there for parity);
Tone.CrossFade leaks the wet in at −56 dB at wet 0 (GainToAudio's curve); the HP / LP setters'
cancel-then-ramp jumps a cut ramp back to its start; pitch-down plays grains backwards at
|ratio| ≈ 0.5 (`intervalToFrequencyRatio(interval - 1) + 1`).

3.4 **(done — `BeatGrid`/`BPMAnalyzer`, `DeckBeat`: sync, follow, quantized cues and loops)** Beat-aware mixing: both decks know BPM and bar phase (from the net
clock or WAV analysis) — sync, quantized cues and loops to bars.
3.5 **(done — `WaveHistory`, `WaveRunner.freeze/scrub/release`, Deck JogClock)** Scratching a live net: freeze/scrub/reverse the tick clock (the jog lab's
reversible Petri clock), and the WAV path stays for imported audio.

## Phase 4 — Performance capture and sharing **(done; Inpulse headphone-knob mapping unverified)**

Goal: a set is reproducible and content-addressed, like a beats track.

Status: 4.1–4.3 done and proven by test (a scripted set across all three controllers
and the UI replays bit-identical to the live render; two renders are byte-identical).
4.4: headphone cue (per-deck PFL, post-EQ pre-fader; cue/master mix; level) feeds a
channel router that puts the master on outputs 1/2 and the cue on 3/4 of a multichannel
device — verified offline on a 4-channel engine, and on the Inpulse on 2026-10-08 (one
4-channel stream, `djctl cue-test` routes cue → 3/4, heard on the headphones; see
"Verification notes"). Still unverified: how the hardware headphone knobs map
(`mixer.faders[2]` → headphone level is from the sweep order; the mix knob is on APC
fader 5 for lack of one on the Inpulse). 4.5: sessions are saved as `<cid>.json` (verified on
load) under Application Support and exported to WAV, and publish to cdn.stackdump.com over
ssh (4.5); one set ("Obsidian Signal", 101 s) is public.

4.1 **(done)** Record every controller event (time, device, decoded control, value)
against the deck clocks.
4.2 **(done)** A session envelope: the decks' share envelopes + the event log →
canonical JSON → CID.
4.3 **(done)** Offline re-render of a session to WAV (same engine, same events) and a
determinism test (two renders, same bytes).
4.4 **(done; on the Inpulse verified 2026-10-08 except the headphone-knob mapping)** Cue/headphone output through the Inpulse's built-in audio interface
(pre-listen mix on outputs 3/4).
4.5 **(done — `SessionBundle`/`SSHTransport`/`publishSession`, `djctl publish`, app “Publish…”)** Publish sessions to cdn.stackdump.com the way beats-builder's `publish.cdn.publish_to_cdn` does: stage `blobs/<cid>/{session.json,audio.wav,index.md}` on the CDN master (valoper, over ssh — no new credentials), `POST /admin/reload?cid=`, and only with `--mirror` run `mirror-push.sh` (the step that makes it public). The directory name is the session CID; `index.md` is written last. Verified against the CDN's own indexer (`cdn-stackdump-cli index` on a scratch tree: 1 indexed, 0 errors). The app's Publish… asks for a title and a draft switch, narrates each step (render, upload i/n, index reload, mirror push, waiting for the mirror) under the bottom bar, then shows the public URL as a link with Copy — or the error; `PublicProbe` polls `index.md`/`audio.wav` at the public URL until they answer (the mirror runs in the background), and `djctl publish --mirror` does the same. ssh runs with `ConnectTimeout=10`, and the stdin feed ignores SIGPIPE (an unreachable valoper used to be able to kill the app mid-write). Verified 2026-10-14 against the live master: a staged draft is indexed (`draft: true`, hidden from feed/search), and a re-render of the already-public "Obsidian Signal" set (published 08:06 UTC that day) came out byte-identical (audio.wav, session.json) to the copy on the mirror.

## Phase 5 — Visuals **(done, 5.1–5.7; scopes / Stage not yet checked in a live window)**

Platter and waveform rendering, net/marking view, section timeline, APC grid
mirror, device-map UI. Deferred earlier by decision, started once the core was done;
the core still does not depend on it: models live in DJCore (no SwiftUI), views in the
`DJViews` target, the app composes them. Views are tested by rendering them to pixels
(`ImageRenderer`) and asserting on the pixels; `DJ_SHOT_DIR=… swift test` also writes
PNGs for a human to look at.

5.1 **(done)** Waveform strip: min/max overview (`WaveformOverview`), playhead / loop / hot-cue /
bar-line overlay (`Deck.waveformOverlay`), `WaveformStrip`.
5.2 **(done)** Platter and beat strip (DJViews).
5.3 **(done)** Net / marking view for net decks.
5.4 **(done)** Section timeline.
5.5 **(done)** APC grid mirror.
5.6 **(done)** Device-map UI (`SurfaceProfile.deviceMap()` rows, `DeviceMapView`, the touched control highlighted).
5.7 **(done — merged 69f8431; status per mode in [SCOPES.md](SCOPES.md))** beats' scopes and
Stage, fed by the engine's deck / master taps and live net state: Scope, Spectro (model and
measured), Bands, Raster; the Stage window (Constellation, Corona, Sonar, Petal, Shuffle with
flow / pulse / flame / tilt / bolts and backgrounds); main-window extras (ring, timeline dots,
structure strip, LED mirror, macro chase, master flame meter). Not ported: card flash (no share
card), legacy wave / spectrum (absent from the pinned source), fingerprints / feel pad.

Not verified by eye in the running app: the sandbox can't capture other apps' windows
(`screencapture` returns the desktop only), so each view is checked through
`ImageRenderer` pixels instead. The first time the full window is opened on a real
display is the check that layout (sizes, spacing, the 3-way deck column) looks right.

---

## Standing rules

- Profiles and layouts are data (`Sources/DJCore/Resources/profiles`), one
  source of truth; JS lab copy guarded by a parity test.
- The audio thread never allocates, locks or releases.
- Generation parity is proven by fixtures from the real JS (and Go), never
  by eyeballing.
- Unverified hardware values are tagged until measured.
- Where dj and beats' JS differ by design (decided 2026-10-12), dj keeps its behaviour and the
  improvement is backported to beats; the list is GO-DIVERGENCE.md §5. Fixtures still hold
  every other path to the JS.

## Verification notes (2026-10-08)

- Inpulse 200 MK3 audio interface verified on hardware: one 4-channel output stream
  (Front L/R, Back L/R). `djctl audio` lists it; `djctl cue-test` routes master → 1/2 and
  cue → 3/4 and the engine accepts it. Headphone jack audibility confirmed by ear (2026-10-08).
  Still `[UNVERIFIED]`: the headphone-fader mapping.
- Full-window layout is covered offscreen by `AppLayoutTests` (`app-full.png`,
  `app-default.png` in `DJ_SHOT_DIR`). `ImageRenderer` draws AppKit-backed controls
  (Slider/Toggle/Button) as yellow placeholders; that is a renderer limit, not a layout bug.
- Fixed: `AppModel.poll` exclusivity crash on net decks (found by the layout test).
