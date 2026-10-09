# dj-vevr-se roadmap

Written 2026-10-07. Visuals are deliberately last (Phase 5). Every phase ends
with something that runs on the Mac with the three controllers plugged in.

Status legend: **done** · **in progress** · **next** · later.

## Where we are (done)

- Swift app (SwiftPM, no Xcode project): two scratchable decks, mixer
  (volume, filter, ±8 % pitch, crossfader, master), 4 hot cues per deck.
- Real-time audio path: `Turntable` on the audio thread, fed by a lock-free
  ring; offline `AVAudioEngine` rendering for tests.
- Controllers, hot-pluggable: Inpulse 200 MK3 (jog wheels only), APC mini
  mk2 (default layout + LEDs), MPK Mini Mk II (factory map, unverified).
- Decks can play beats tracks rendered by the JS wave engine
  (`scripts/wave-render.mjs` → WAV → load).

---

## Phase 1 — Every control on all three devices **(done 2026-10-07)**

Goal: every physical control on every device produces a decoded event, and
every event has either a binding or an explicit "unbound" entry. Nothing a
hand can touch is silently dropped.

Coverage today:

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
open: identify Inpulse centre knobs CC 0x03/0x04 and buttons 0x01/0x02 on
channel 1; verify the `[MIXXX]`-only Inpulse entries (FX/sampler pads, PFL,
load, browser); pad NOTE mode on the MPK. A `djctl learn` wizard is deferred —
re-capture + fixture regeneration covers preset changes for now.

## Phase 2 — Native music generation with CID equivalence **(next — JS read, no Swift yet)**

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
2.4 **(done — `Sources/DJCore/Beats/Generator/`; arrangeWithOpts / counter-melody / macros deferred, see below)** Port the composer in dependency order: core → theory → euclidean →
markov → riffs → variety → countermelody → arrange → theme → groove →
structure → composer. Gate each on fixtures.
2.5 **(done — `Sources/DJCore/Beats/Share.swift`; URL/gzip decoding and raw-`nets` envelopes deferred)** Share envelope → params (`shareFromPayload`), including tempo / swing /
humanize overrides, cohesion pin (v1 for envelopes without the field),
traits, `macroCurve`.
2.6 **(done — `Sources/DJCore/Beats/Wave/`; parity form, real-time hardening is 3.1)** Port the wave engine (`net.js`, `synth.js`, `runner.js`): trace exact,
audio within 1e-5 (bit-exact where libm agrees), same as beats-py.
2.7 **(done — `make fixtures-go`, `Tests/DJCoreTests/BeatsGoOracleTests.swift`; finding: Go ≠ JS end to end; JS is canonical, see GO-DIVERGENCE.md)** Second oracle: run the Go generator (`tools/parity`) on the same inputs
for model CIDs.
Later in this phase: raw-`nets` envelopes + `arrangeWithOpts`, overlay
directives (fadeIn, drumBreak, feelCurve, counterMelody), `tracks`/`fx`
overrides.

Done when: every genre × {loop, minimal, standard, extended} × cohesion
{v1, v2} × N seeds matches project JSON and model CID, share CIDs match, and
renders match the JS engine.

## Phase 3 — Live Petri decks **(done on branch `phase3-live-decks`)**

Goal: a deck can play a *generated net live*, not just a WAV, and the
controllers perform on the net.

3.1 **(done — `WaveDeckSource`, `Deck.loadNet`; `make swift-rt-test` measures zero allocation in render)** `WaveRunner` as a deck source (real-time safe port, same contract as the
JS runner: no allocation in `process`).
3.2 **(done — `Deck.generate/queueNext/advanceToNext/service`, `TrackSpec`)** Generate on a deck: genre + seed (+ structure) → compose → play; next
track pre-composed in the background.
3.3 **(done — `DeckPerform`, `WaveMacros`, profiles; FX/pan/shape/pitch/feel macros need a wave master chain, not ported)** Controls drive the net: section jump / slot activate (APC grid), role
mutes (APC track buttons), macros (port beats' macro catalog), live tempo,
MPK keys into a scale-locked live net, stingers on pads.
3.4 **(done — `BeatGrid`/`BPMAnalyzer`, `DeckBeat`: sync, follow, quantized cues and loops)** Beat-aware mixing: both decks know BPM and bar phase (from the net
clock or WAV analysis) — sync, quantized cues and loops to bars.
3.5 **(done — `WaveHistory`, `WaveRunner.freeze/scrub/release`, Deck JogClock)** Scratching a live net: freeze/scrub/reverse the tick clock (the jog lab's
reversible Petri clock), and the WAV path stays for imported audio.

## Phase 4 — Performance capture and sharing

Goal: a set is reproducible and content-addressed, like a beats track.

Status: 4.1–4.3 done and proven by test (a scripted set across all three controllers
and the UI replays bit-identical to the live render; two renders are byte-identical).
4.4: headphone cue (per-deck PFL, post-EQ pre-fader; cue/master mix; level) feeds a
channel router that puts the master on outputs 1/2 and the cue on 3/4 of a multichannel
device — verified offline on a 4-channel engine. **Not verified on the Inpulse**: that
its interface exposes ≥ 4 outputs with the headphones on 3/4, that the device accepts
the channel layout, and how the hardware headphone knobs map (`mixer.faders[2]` →
headphone level is from the sweep order, and the mix knob is on APC fader 5 for lack of
one on the Inpulse). Pressing "Inpulse out" in the app is the first real test; if it
fails the stereo path is restored. 4.5: sessions are saved as `<cid>.json` (verified on
load) under Application Support and exported to WAV; uploading to the beats share store
or CDN needs an endpoint/credentials decision and is not built.

4.1 **(done)** Record every controller event (time, device, decoded control, value)
against the deck clocks.
4.2 **(done)** A session envelope: the decks' share envelopes + the event log →
canonical JSON → CID.
4.3 **(done)** Offline re-render of a session to WAV (same engine, same events) and a
determinism test (two renders, same bytes).
4.4 **(done in software; hardware unverified — see below)** Cue/headphone output through the Inpulse's built-in audio interface
(pre-listen mix on outputs 3/4).
4.5 **(local part done: `SessionStore`, Record/Export in the app; publishing needs a decision)** Optional: publish sessions to the beats share store / CDN.

## Phase 5 — Visuals

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

## Verification notes (2026-10-08)

- Inpulse 200 MK3 audio interface verified on hardware: one 4-channel output stream
  (Front L/R, Back L/R). `djctl audio` lists it; `djctl cue-test` routes master → 1/2 and
  cue → 3/4 and the engine accepts it. Still `[UNVERIFIED]`: audibility on the headphone
  jack and the headphone-fader mapping (needs ears/hands).
- Full-window layout is covered offscreen by `AppLayoutTests` (`app-full.png`,
  `app-default.png` in `DJ_SHOT_DIR`). `ImageRenderer` draws AppKit-backed controls
  (Slider/Toggle/Button) as yellow placeholders; that is a renderer limit, not a layout bug.
- Fixed: `AppModel.poll` exclusivity crash on net decks (found by the layout test).
