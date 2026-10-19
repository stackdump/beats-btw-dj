# dj-vevr-se roadmap

Written 2026-10-07. Visuals are deliberately last (Phase 5). Every phase ends
with something that runs on the Mac with the three controllers plugged in.

Status legend: **done** · **in progress** · **next** · later.

## Where we are (2026-10-14)

Phases 1–5 are on `main` (Phase 3 landed there directly; `phase5-scopes` merged in 69f8431).
README's "Where we are" says what the app does; this is what each phase still has open.

- **Phase 1** — done. Open: the Inpulse hardware pass (checklist below), MPK pad NOTE mode.
- **Phase 2** — done, 2.1–2.8, including share links (composed and raw-`nets`) on a deck from
  the app / MCP. Open: nothing; short `?cid=` links need the caller to fetch the payload (2.8
  "Left out"). The counterMelody deviation is kept and goes back to beats (GO-DIVERGENCE.md §5).
- **Phase 3** — done, 3.1–3.5; in 3.3 the send FX (reverb / delay), Pan and Shape macros are
  not ported and each needs a design call. Which master macros go on Inpulse pads is open.
  (Phase 6 has since added dj's own send reverb and tempo echo under `WaveOptions.extended`;
  porting beats' Tone sends for parity is still the open 3.3 item.)
- **Phase 4** — done. Open: the Inpulse headphone-knob mapping.
- **Phase 5** — done, 5.1–5.7 (5.7: beats' scopes and Stage, [SCOPES.md](SCOPES.md)). Open:
  the scopes and Stage have not been checked in a live window ("Needs a person" in SCOPES.md).
- **Phase 6** — **in progress**, on the Mac only. Parts A–F (32 `DJMusicality.Fixes` flags,
  [docs/musicality-notes.md](docs/musicality-notes.md)) are merged on `main`. Every fix is measured on the 24-track matrix; **none has been
  confirmed by ear**. 6.0 (landing them) is done; 6.1 is the listening loop; 6.2–6.7 are what the
  measurements and [docs/research/realism-2026-10.md](docs/research/realism-2026-10.md)
  (branch `research/realism`) still rank as unmusical.


## Testing integrate/roadmap (2026-10-18 → 19)

`integrate/roadmap` = `main` + the 2026-10-18 roadmap run (125 tasks merged compile-checked only),
curated Hit 1–4 stingers, the Blocks and Dig Stage scenes, the FX unit (`roadmap/fx-unit`), the
product manual ([docs/MANUAL.md](docs/MANUAL.md)) and the test fixes below. `main` is untouched
(everything on it is merged in); the user decides when to fast-forward and push.

**Full debug runs** (`make swift-test`, whole suite, one process):
- **#1 (b368387): killed by jetsam at 31.6 min**, test helper at 142.7 GB. Cause: a failing
  `#expect(a == b)` on large collections makes swift-testing build a diff for the message (8.4 GB
  from one failing 200k-sample compare). The same happened to the morning's RestSchedule runs.
  Fixed in c36dc78: 251 sites in 63 files compare through `sameSamples(a, b) == .identical`
  (`Tests/*/SampleCompare.swift`); CLAUDE.md has the rule. 27 failures seen before the kill, all
  fixed in round 1 (fix-debug-r1-0…5).
- **#2 (c36dc78): no result** — a leftover make from the stopped first workflow took the lock and
  was killed; the full run then ran in a fix agent's worktree (slow: ~3 h on a loaded machine).
- **#3 (round 2 merged): finished** — "Test run with 2825 tests in 479 suites failed after
  10400.667 seconds with 259 issues (including 1 known issue)", 56 failing tests, peak helper
  memory ~5 GB. All 56 went to round 3 (fix-debug-r3-0…7), merged; their union rerun on 8784e54:
  "403 tests in 64 suites … 16 issues (including 13 known issues)", parity green on bff663e.
- **#4: not planned.** From 2026-10-19 the user's rule is fast spot checks with the test MCP
  instead of full regression (CLAUDE.md): changes are verified by their filtered suites, parity
  when near compose / shares, and short renders. Full `make swift-test` / `swift-rt-test` only
  on request. The spot measurements still to take: `djtest_level_check` (−12 LUFS ±1.5 LU,
  a few genres × seeds), a render compared with itself, `make testmcp-test`.

**Real bugs the rounds fixed** (beyond tests whose premises never held): `.shape` turned melody
steps into thirds; `.layerBudget` skipped beats' harmony pad; SlotWindows attributed a part change
one step late when a control net comes before its target (raw-`nets` shares; made a breakdown
silent); cadence / hook / motif aimed at `.color`'s sevenths (rubs); `unrubColor` heard only the pad;
the hook used out-of-key chord tones; BeatTracker read dnb at half tempo; SectionSegmenter's frames
slid against the bar; crate pads came out newest first; MasterFx session replays loaded without
the deck's options; sampled parts are balanced against their own synth voice; the loudness probe
hears the section's energy gain.

**Open after round 3**
- `BalanceTests.chillFamiliesMeetTheirTargets(lofi)` vs `HFTiltTests` — **needs a decision**: with the
  hats trimmed after `.hfTilt`, lofi balances (1.52 ≤ 2) but synthwave / bossa get a 16 kHz bump;
  with untilted trims (HEAD) the bump passes and lofi is 2.56 > 2. One hat trim can't meet both.
- `LevelMatchTests.aSampledTrackPlaysAtTheReference` lofi −13.06 LUFS (1.06 off), bossa 1.12 off,
  bound 1 LU (was 3.2 / 2.05 before round 3).
- Loudness spreads pass at 1.9 LU against 2.0: thin margin.
- AUSampler ceiling: a process past ~106 AUSamplers loads them silent. A blocking per-process cap
  deadlocked the parallel sampler tests and was reverted (8784e54); r3-0's reload-once-if-silent
  only partly covers it. Needs a design (holders reserve up front, or a test-side gate).
- Still failing at the end of round 3, unowned: `RoomShimmerTests.theShimmerAddsTheOctaveAbove`,
  `SectionMelodyTests.bridgeAgreesWithItsChords`,
  `FixesUnderGesturesTests.aStopWithoutTheBrakeLetsTheRoomRingOut`; run #4 will say.
- Debug suites are slow: sampled-loudness tests take up to ~31 min each in debug
  (`sampledSongsSpreadWithinTwoLU`); a full run is ~3 h. Candidates for release-only, like the
  sampler load-time bounds.

**User decisions recorded**: lofi pentatonic test relaxed to "no worse than the composed track"
(beats' lofi bass is ~9 % out of key; the bass is not changed). Funk keeps sevenths on 0.45 of
chords (vs ≥ 0.6 elsewhere) — an ear call. `.shape` targets still unmet (leap recovery 0.21 vs
0.8, peak 0.44 vs 0.55–0.8). `.arpDensity` / the trance pluck rarely act on composed tracks.

**Test tooling**: the test MCP takes `worktree`; the shared lock is only for full / RT runs
(`make swift-test`, `swift-rt-test`, `swift-rt-test-filter` take it via `djtest_mcp/locked.py`);
filtered debug runs go in parallel.

**Queued after testing**: the APC mini faders → FX unit layout (`.dj-wt/APC-FXUNIT-HANDOFF.md`),
auto-mix — a two-deck autopilot on Wander + mix-in / mix-out (`.dj-wt/AUTOMIX-HANDOFF.md`, design
first). Side work: a seeded progressive-house share generator (local, `.dj-wt/shares/`, not in
the repo).

## Open work (2026-10-17)

Everything below is what was left when the 2026-10-17 session stopped. `main` (f9aa3a8 and
after) has, merged and tested: per-seed variety, the APC as an FX surface, the sound editor,
the journal + notes, the turntable vinyl brake, Wander + locks, the Soundboard, sampled drum
kits, the Minecraft palette, per-loop FX, loops master FX (checkpoint), palettes (checkpoint),
the MPK bank-A part mutes, and two fixes (live decks now get the extended runner options;
the echo / pluck read that crashed the audio thread). The user is reviewing these and may
revert any by its merge commit.

**Unfinished branches**
- `sound/level-match` (worktree `dj-vevr-se-wt-levels`, WIP 805de18, not merged, tests not
  run to the end). Problem: generated tracks are ~10 dB under loops (60 s renders −17…−22
  LUFS; Apple loops −11…−14; a recorded loop −11.2) plus −3 dB on A/B from the centred
  equal-power crossfader, which the loop channel skips. WIP has `LevelMatch.swift`,
  `PeakLimiter.swift`, a net-deck target, sample auto-gain. Left: finish and test (target
  ±1.5 LU for six genres, peaks < 0 dBFS, parity untouched, limiter RT test), sample
  auto-gain clamps and off switch, decide the loop channel's default (−3 dB?), before/after
  measurements, then merge.
- `sound/palettes` merged as checkpoint 1537f30; WIP 855c781 (CLAUDE.md palettes notes) is
  on the branch only. Left: merge or redo the CLAUDE.md notes, a full test run, repo lint.
  Renders of every palette: `build/agent-renders/palettes/` (house seed 11).
- `sound/loop-master-fx` merged as checkpoint 947b5ec. Left: the agent's full-suite run
  (the RT run on main passed). APC SHIFT + aim → L is `[UNVERIFIED]`.

**Release checks**
- One clean full `make swift-test` and `make swift-rt-test` on main with nothing else
  running (only filtered runs since the merges).
- Push main after the next merges (pushed through this roadmap on 2026-10-17).
- Known failing tests: `tracksPlayAtOneLoudness`, `theKickNoLongerIsTheMix(funk)`,
  `theWindowInTheDark`, `theHeaderLeavesRoomForTheStatusAtTheWindowsMinimumWidth`. Flaky
  only under parallel load: `sampledInstrumentsDoNotAllocate` (the background sampler load
  times out: slot −2), `aNewTrackRebuildsTheLanesAndTheirKernels`,
  `WanderTests.aReplayWalksTheSamePath`, occasional RT frees in
  `switchingTheTapOnAndOffAroundTheBlocksDoesNotAllocate` / `voiceTweaksDoNotAllocate`.
  Give the slow ones longer waits or serialise them.

**Hardware to verify on the units**
- MPK mini bank A pads 1–8 = part mutes on the aimed deck (note numbers `[UNVERIFIED]`).
- APC SHIFT + aim button → loops; the APC FX layout generally.
- Inpulse browser wheel / push / SHIFT+wheel for Wander (`[MIXXX]`, uncaptured).
- Headphone mix is now unbound on every controller (the APC's fader 5 became the LP).

**Planned, not started**
- Python test MCP harvesting the test harnesses (renders, LUFS/levels, pitch, replay
  checks, screenshots) for agents to drive.
- Audit the app MCP so every control is reachable (`dj_perform` ops, views, palettes,
  notes, journal, loop FX, Wander).
- Show the Wander walk on the Stage.
- **Curated stingers for Hit 1–4** (asked 2026-10-18): each Hit button should fire something that belongs to the
  track. Today the four `hit1`…`hit4` nets play the genre's `stingerInstrumentSet` voiced through
  the palette's `stinger` pool by seed + net; nothing curates them. Curate effects and loops for
  assignment to Hit 1–4 by the generated genre and the sound palette: a data table of candidates
  (one-shots like `laser`, master-FX / net macro gestures, loop-library and stock-loop clips),
  each tagged by genre family, palette, key fit and tempo fit; the four Hit slots resolved from
  (genre, palette, seed) as `applySound` resolves sounds, so the same configuration always gets
  the same hits; loops quantised and tempo-matched to the deck. Theme check: the poke is the
  existing Hit / `stinger` binding, the rule is a pure function of the configuration, the
  boundary is the stinger's beat / bar quantise. Wander's stinger move draws from the same
  table. Apple loops stay local-only (never in a share or on the CDN).
- **Per-role seeds** — so `keep:<role>` keeps a role's *notes*, not just its instrument, and a
  Wander seed move can re-roll some roles and leave the rest (the Masterpiece Generator model:
  lock a part, reroll the others, recall by seed). Today one seed drives every role: `compose()`
  draws each role's sub-seed in a fixed order from one `Mulberry32` stream (chords
  `Composer.swift:359`, bass `:382`, melody `:417`, arp `:464`, instruments `:472`, stingers
  `:582` / `:608`), and the techniques derive their own from the same seed (`Techniques.swift:88`
  bass-follow, `:115` hook).
  - **The poke:** a `roleSeeds` share override (`extra["roleSeeds"] = {role: seed}`), set by
    `keep:<role>` (pins the role's current sub-seed when the lock goes on) and by a new Wander
    move, *reroll one role* (the role's seed ±1…7, everything else held). A `DeckAction` with
    codec, dispatch and round-trip test, plus a journal event.
  - **The rule:** at each draw, take the value from the stream as now, then use the override if
    one is set. Consuming the draw keeps every other role byte-identical, and no override means
    the same CID as today, so parity and every published share are untouched. A reroll's seed is
    derived from the spec CID + the deck's step counter, like every other Wander move.
  - **The boundary:** the next phrase, the same as any Wander swap (`PreparedTrack(startTick:)`).
  - **Open design call — harmony.** The chord progression comes from the master seed. A kept
    melody played over a new seed's chords will clash. Either chords stay on the master seed and
    kept roles re-voice to them (bass and arp already follow the chords; melody would need
    chord-snapping), or keeping any tonal role also pins the chord draw (that's the key lock
    plus a new chord pin). Decide by ear on the 6.1 panel.
  - **Boundary with beats:** `roleSeeds` is a dj-side override around beats' `compose()` and
    belongs in GO-DIVERGENCE.md §5. Backporting it to beats is a separate decision, since it
    changes the share format.
  - Exit: with `keep:bass` on, a Wander seed move changes every role except the bass, whose
    note events stay byte-identical (a test on the project JSON), and a replay walks the same
    path (`WanderReplayTests`). No `roleSeeds` = fixtures unchanged.

**Follow-ups noted by the features**
- Journal: in-app rewind (mid-file checkpoints for seeking, a live-engine reset path, store
  `replaceAll`, a picker).
- Wander: per-part seeds (a kept role's notes still change with the seed; planned above as
  **Per-role seeds**); a swap composed
  after its phrase boundary lands a bar late live; the pitch fader isn't compensated on genre
  hops.
- Variety: lofi / ambient chords only transpose (pentatonic genres); some house sevenths rub
  more on the new progressions.
- Soundboard: fade / launch quantize / tempo follow are per loop channel, not per clip;
  tuning a loop's instruments means taking it again; ↑/↓ step one pad, not a row; the
  board's open state isn't remembered; stock loops and crates aren't pads; sequences are
  edited only on the Loops row.
- Loop FX: a clip moved onto a deck plays dry; scenes don't recall FX; a new sequence starts
  with FX off.
- Minecraft: gameplay-driven stingers via val's `mc_recent_events`; ±1-octave pre-shifted
  zones for range. Publishing any local-only palette (Minecraft, Apple DLS) is refused
  unless overridden.
- Master macros are net-only on A/B (sample decks never brake).
- Old branches not on main, to merge or drop: `layout/use-width`,
  `integrate/main-plus-layout`, `plan/musicality-roadmap` (Phase 6 roadmap), `feat/browser-seed`,
  `favorites`, `wip/djctl-mix`; old checkouts `dj-vevr-se-{compose,favorites,integrate,layout,
  realism,ipad}`.

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
  record; 0x09 STEMS music, 0x0A STEMS mic, bound to `stemMute`):
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
1 bar, with fxHold's default tail 0.6 — the parity path keeps that; the app plays a turntable
brake instead (`WaveOptions.turntableBrake`, GO-DIVERGENCE.md §5.5); Tone's Distortion curve has 1024 points, not 4096; Tone's
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

## Phase 6 — Tracks that sound like music **(in progress; parts A–F merged, 6.1 next)**

Goal: a `standard` song of any catalogue genre, any seed, played on a net deck with
`WaveOptions.extended`, is something a listener calls a track and a DJ can mix — form on
4 / 8 / 16-bar lines with intros and outros long enough to blend, a hook you can hum after one
play, harmony that goes somewhere and comes back, a rhythm section in every genre that has
one, and a mix that translates to monitors, headphones and a phone. The 4-bar loop was already
music ([realism audit](docs/research/realism-2026-10.md), verdict); the track was not.

Where this phase stands (2026-10-14): six parts in two days
([docs/musicality-notes.md](docs/musicality-notes.md)) turned the audit's top gaps into 32
`DJMusicality.Fixes` flags — key, grid, register, groove, loudness (A); fills, voicing, energy
arc, ducking, contour, sevenths (C); the arp playing the chords, snare rolls, crashes, bass
motion, open hats, stereo (D); legato, cadences, approach notes, the drop gap, hat choke, a
room (E); band-limited filtered voices, unison, echo, a tuned kick, bar-2 motif, part balance
(F). Each has a before / after on the 24-track matrix and a test that proves the "before" was
wrong. **None has been heard by a person.** The notes say so at every level that was set
("by measurement, not by ear"). Two things decide the order below: the ear comes first (6.1),
and the biggest remaining gaps — form, harmony, the chill family's beat — are things a
binding-rewriting pass cannot reach, because they need other section lengths, a slotted pad
and other role tables: beats' generator (6.2, 6.3, 6.5 each have a beats half).

How the pass and the generator divide the work, so each stage knows where it lives:

| Where | What it may change | CID | Used for |
|---|---|---|---|
| `DJMusicality` pass (`PreparedTrack.played`) | bindings and initial markings of the composed nets; never places / transitions / arcs | unchanged | wrong notes, timing, register, dynamics, voicing, drum gestures on the fill chains |
| runner, `WaveOptions.extended` | how a binding sounds: voices, lanes, sends, stereo, levels, gaps | unchanged | sound design, mix, section-edge gestures |
| beats' generator, a new `cohesion` / `structure` value | nets, section lengths, role tables, the chord plan | **new** (an old share plays as it did) | form, harmony per section, roles per section |
| `compose-experiments` techniques (`TrackSpec.extra` → `traits`) | compose-time notes, stored in the envelope | new | A/B by ear only; not a product path (6.0 decides each) |

### 6.0 Land parts A–F **(done: merged on main)**

- Run part F's listen checklist on `val/run-1b7960bf` (`make run-app-release`; `djctl render
  <g> 42 --out`), write the first [listening log](#61-listen-then-measure) entries, then merge
  to `main` and **push**. 47 signed commits on one laptop disk is the risk; the fixes are all
  behind `WaveOptions.extended` and every parity fixture is green, so `main` can take them.
- Commit or drop the uncommitted `Deck.tempoMatch` refactor and `Session/SessionMix.swift`.
- Decide each `compose-experiments` technique: `keyLock` is `.key`; `chordSnap` is what
  cohesion v2 + `.contour` / `.cadence` already do; `hook` and `layerBudget` are real ideas and
  move into the pass as 6.4 and 6.2 items (notes unchanged → CID unchanged). The branch stays as
  the A/B lab (`--options`, `--mute` / `--solo` stems are worth keeping on `djctl render`).
- Open the beats issue / branch for GO-DIVERGENCE §5 item 4 — drift, fills, tension key, the
  chill-family table, the arp built from the motif — as `cohesion: "v3"` so published v2 shares
  keep their sound. The audit's M1 / M2 / M5 are the JS tests that would have caught all of them.
- Exit: `main` plays part F; `docs/musicality-notes.md` has a "heard" column for parts A–F.

### 6.1 Listen, then measure **(next, with 6.0)**

Everything so far is a number. This stage puts a person in the loop and gives the numbers their
targets.

- **A fixed listening panel.** `make listen` renders 12 genres × seed 42 (plus the seeds the log
  names), 90 s each, `--fixes all` and the previous part, to named WAVs in `.build/listen/`
  (never committed), plus a stem set (`--solo`) per genre. A short script plays A / B blind and
  records the pick — the matrix compares runs; this compares the two things a person can hold
  in their head.
- **A listening log** (`docs/listening-log.md`): one line per (genre, seed, build): a verdict in
  three words — *track*, *loop*, *broken* — then the first thing wrong, in the audit's
  dimensions (form, harmony, melody, groove, arrangement, sound, mix), and on which device
  (monitors, headphones, phone). The log's top complaints rank 6.2–6.6; a stage that fixes
  nothing the log names is dropped.
- **References, not rules of thumb.** Three to five tracks per family Matt actually plays, as
  local files (`$DJ_REFERENCES`, never committed, never published): run them through the same
  tooling — integrated LUFS, LRA, true peak, long-term spectrum and slope, side / mid, section
  lengths from beat tracking — and write the per-family bands into `Resources/beats/targets.json`
  with the measurement they came from. `Loudness.targetDB`, `MixBalance.targetDB`,
  `SpaceSpec.forGenre` levels, `stereoPlacement` widths and the hat level all become table
  entries that name their reference instead of a number in a Swift file.
- **A nightly trend, not a gate**: the audit's M8 — Yang & Lerch pitch-class / inter-onset /
  note-length overlap of the matrix against the previous build and against the references'
  MIDI (Basic Pitch on the stems). It is a regression alarm; it never decides a merge.
- Exit: every catalogue genre has a log entry at seed 42 with a verdict and a first complaint;
  the reference table exists and at least the loudness, width and spectral-slope targets name
  it.

### 6.2 Form a DJ can mix

Audit rank 1 and still the largest gap: `standard` sections are 4 or 12 bars, intros and
outros 4 bars, songs ~110 s. `.phrases` splits a 12-bar section 4 + 4 + 2 + 2 so phrase changes
land on 2 / 4-bar lines, but the section is still 12 bars and the song still ends before a DJ
could mix out of it.

- **beats half** — a `structure: "dj"` (or an extended family) in beats' structure tables:
  intro / outro 16–32 bars, drums-forward and mixable (kick, hats, bass; no lead); buildup
  8–16; drop / chorus 16–32; breakdown 8–16; phrases 4 or 8 bars, so A-B-A-B is 4 × 4 or 4 × 8;
  songs 4–6 min. Distil P(next section) and P(length | section) per family from the Harmonix
  Set (912 annotated pop / EDM tracks) and check the tables in like `tables.json`, hash in the
  version. Ships as `cohesion: "v3"` with the 6.0 bug fixes.
- **dj half** — the pass keeps the grid (`.timing`, `.phrases` already hold any section
  length); `layerBudget` from `compose-experiments` becomes a pass stage (at most N melodic
  roles per section, by muting slots in the control nets: intro 1, drop 3, breakdown 1 …);
  `.dropGap` grows a song-family form — a band stop (everything but the lead) before a chorus
  — and the buildup gets the audit's remaining gestures: a noise riser on a stinger lane and the
  kick out for the last bar, not only the last beat.
- **Performable form.** Matt's live decks were endless loops (audit §1); sections exist but a
  set is mixed from loops. Add to the deck a *mix-in / mix-out* control: on `section next` into
  an outro the deck plays the drums-forward tail for 16 bars and stops on a bar line; `sync`
  already aligns bars. This is what makes 6.2's intros and outros a DJ tool rather than a longer
  song.
- Exit: M1 — every structure event at `tick % 64 == 0`, phrases 4 or 8 bars, intro and outro
  ≥ 16 bars in the dance families; songs 4–6 min; the log says *mixable* for techno, house,
  trance and edm at seed 42.

### 6.3 Harmony that goes somewhere

Audit rank 5; "section harmony and cadences" has been the open item at the end of parts C, D
and E. One 4-chord loop at one chord per bar plays for the whole song; the pad is a single
unslotted ring, so the bridge and solo melody (`harmonic` +5 / +4) move away from a pad that
does not.

- **dj first, cheap**: a per-section harmony plan applied where `EnergyCurve` already knows
  the section edges — the runner transposes the pad / bass / arp lanes by a per-section
  interval table (bridge +5, solo +4, breakdown to the relative minor / major), so the parts
  move together and the melody's offsets stop fighting the pad. A pass-level cadence: the
  pad's chord at bar 4 / 8 of a phrase resolves (V → I, ♭VII → i in minor dance genres) by
  rebinding that bar's pad steps; `.voicing` then re-voices it. Harmonic rhythm per section —
  2 bars per chord in intros / breakdowns, 1 in drops, 2 per bar into a chorus — by rebinding
  the pad ring (the ring is 64 steps; the plan repeats within it).
- **beats half**: the pad becomes slotted (`harmony-N`) so a section can carry its own
  progression; progressions drawn per family from a chord-transition table (McGill Billboard,
  CC0; RS200, CC BY) with the cadence as a Markov constraint at bar 4 / 8; 7ths and 9ths per
  genre at compose time (`.color` already adds the seventh after the fact). `cohesion: "v3"`.
- Exit: ≥ 2 distinct progressions in song-form genres; a cadence at every phrase end
  (`phraseEndsOnChordTones` extended to the pad: *harmonic* phrase ends); pad motion per change
  stays ≤ 4 semitones (`padMotion`); semitone rubs do not rise; the log stops naming *harmony*
  first for jazz, lofi, house and trance.

### 6.4 A hook, and an answer

Melody is one 4-bar cell; `.motif` makes bar 2 restate bar 1, `.cadence` closes phrases,
`.contour` stops the hammering. Still missing: anything at 8 bars, a hook that survives the
section change, and a step-dominated interval profile.

- **Question and answer across 8 bars**: rings repeat every 4 bars, so bars 5–8 cannot answer
  bars 1–4 without new slot topology. Runner-side first: alternate cycles of a melody ring play
  transposed to the dominant / a step up and end open, then the home cycle closes (the same
  mechanism as 6.3's per-section transposition, per cycle). A pass-side version later, if beats
  v3 gives slots an 8-bar ring.
- **The hook** (`compose-experiments`' best idea, as a pass stage): one 1–2 bar chord-tone hook
  per track from (genre, seed), played in every melodic section, varied per section — Fragment
  in intros / breakdowns, Transposed in buildups, Play in drops / choruses, Inverted in
  bridges, Augmented in solos — by rebinding the melody ring's first bars; its notes snap to
  each bar's chord so it survives the chord plan.
- **Contour by corpus**: replace the uniform −2…+2 degree walk's result with a degree-bigram
  table per family (RS200 melodies, CC BY) at the pass (rebinding passing tones toward the
  table's likely next degree); reverse direction by step after a leap; aim the phrase's peak
  near two-thirds of its length. Target the interval histogram at steps ≥ 0.45, repeats ≤ 0.3
  (audit: 54 % repeats today).
- **The other parts get a motif too**: the bass's bar 2 echoes bar 1's rhythm; arp patterns per
  genre (trance up-down sixteenths, synthwave eighths with octave jumps, house off-beat stabs)
  and an arp that follows the phrase's density curve rather than a fixed rate.
- Exit: `melodyIdeaRepeats` stays 1.0 and a new `answerPhrases` (8-bar pairs whose second half
  ends closed after an open first) ≥ 0.9 in song-form genres; repeats ≤ 0.3; in the log,
  *hummable* for at least half the genres at seed 42.

### 6.5 A beat in every genre, with a human drummer's hands

- **The chill family's missing beat** (found in part F): lofi, jazz and bossa `standard` songs
  never play a kick or snare, because the theme table activates them only in buildup / drop /
  pre-chorus / solo. beats half: fix the table (verse / chorus unmute kick and snare: boom-bap
  with swing for lofi, brushes for jazz, bossa clave). dj half, until then: the pass rewrites
  those roles' control-net unmutes for the chill family.
- **Groove templates**: per family, a 16-position table of (offset ms, velocity scale) per drum
  voice distilled from the Groove MIDI Dataset / E-GMD (CC BY 4.0), checked in like
  `tables.json` — how MPC and Ableton grooves work. Swing becomes a tempo-scaled ratio
  (Friberg & Sundström; Linn's 54–66 %), not a fixed share of a sixteenth; `humanize` becomes
  seeded 1/f noise keyed by `(seed, net, tick)` so a CID renders the same twice (this also
  fixes the farm's `Math.random()` humanize once backported). Velocity, not microtiming, is
  where the groove lives (Senn 2018; Davies 2013): keep the shifts to a few ms.
- **Buildup gestures the fills chain can carry**: a resonance sweep — the voices' own filters
  (`FilterEnvelope`) follow `EnergyCurve`'s opening lowpass through a buildup; snare density
  doubling per 2 bars is `.buildup` already.
- Exit: every catalogue genre at seed 42 has a kick and snare where its style has one
  (`MusicalityReport.hasBeat` per section); M6 — distinct velocities per hat position > 1,
  groove consistency 0.9–0.99, measured swing within 2 % of the family's table.

### 6.6 Sound and a mix that translate

Part F balanced the synth lanes and gave the voices filters. The sampled path — what the app
plays by default — has none of it, and nothing has been checked on a second speaker.

- **Sampled instruments inside the fixes**: per-slot `.balance` (the bank already renders slots
  as groups for ducking and the room), an echo group, per-category stereo width (keys and pads
  wide above 300 Hz, bass mono outright), and the loudness probe hearing the samplers (lofi /
  jazz / bossa are ~2 LU hot when they load).
- **Sound design, by ear from the log**: balance targets per family (jazz and lofi want bass
  and keys forward and hats down; the dance targets are one rule of thumb); a sub-octave sine
  under dnb / dubstep basses; the filter envelope on the arp (a trance pluck); pad shimmer and
  room level set from 6.1's references; narrower ambient pads (its low side is −26 dB).
- **Mastering, allocation-free**: a true-peak ceiling at −1 dBTP (a lookahead limiter on the
  deck's master, measured like every other runner stage), an integrated target per the
  reference table (so two decks crossfade without a level jump: ≤ 2 LU across genres on both
  paths), and a long-term spectral-slope check per family (falling, no 16 kHz bump; hats are
  the usual offender).
- **Translation test** in the log: each genre on monitors, headphones and a phone speaker;
  fold to mono and nothing disappears (`StereoTests` holds the sum; only ears hold the rest).
- Exit: M7 — LUFS spread ≤ 2 LU across genres, synth and sampled; true peak ≤ −1 dBTP; slope
  inside the family's reference band; `balanceErrorDB` ≤ 2 dB on the sampled path; the log's
  *mix* complaints gone for the dance genres.

### 6.7 Live, shared and upstream

- **The fixes under performance**: every pass / runner fix across section jumps (`trackEnergy`,
  `trackBalance` are reused; check the rest), role mutes, macros, scratching and a swap; loop
  (endless) decks and raw-`nets` share decks get the runner fixes (stereo, room, balance, voices)
  and not the pass — say so in the deck state and SCOPES, or give them the pass's runner-only
  subset explicitly.
- **The first published set** (Phase 4.5 is still unused): a 10-minute two-deck set with part F
  or later, published to cdn.stackdump.com, listened to outside the app. The CDN copy is the
  "does it hold up elsewhere" check.
- **Upstream**: beats' `cohesion: "v3"` PR with the 6.0 bug fixes and the 6.2 / 6.3 / 6.5
  tables; M1 / M2 / M5 as JS tests in beats; the fixture set regenerated at the new beats commit
  and the matching GO-DIVERGENCE §5 entries dropped. `cohesion: "v2"` stays byte-identical for
  every published share.
- Exit: one set on the CDN; beats v3 merged or open with the three bug fixes; the pass's
  `Fixes.all` and `WaveOptions.extended` documented as the product path in README's "Where we
  are".

### Order

6.0 and 6.1 first and together — nothing else merges without a log entry. Then 6.2 and 6.5's
beats halves start (they are one `cohesion: "v3"` branch in beats with a table each) while
6.3's and 6.4's dj halves land here, since those are pass and runner work the matrix already
measures. 6.6 runs throughout, driven by the log. 6.7 closes the phase. Every stage ships one
flag at a time, matrix before / after, "before was wrong" test, release allocation count,
listen checklist, log entry — the part A–F discipline, plus the ear.

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
- A musicality change is a `DJMusicality.Fixes` flag (or a `WaveOptions.extended` setting),
  off on the parity path, with a before / after on the matrix, a test that shows the "before"
  was wrong, and a release-build allocation count if it touches the runner. **Measured, then
  heard**: from 6.1 on it also needs a listening-log entry before it merges — the numbers say a
  fix did what it set out to; only ears say it sounds better.
- Targets come from references, not rules of thumb: a level, width, length or spectral target
  written into code names the reference measurement it came from (6.1).

## Verification notes (2026-10-08)

- Inpulse 200 MK3 audio interface verified on hardware: one 4-channel output stream
  (Front L/R, Back L/R). `djctl audio` lists it; `djctl cue-test` routes master → 1/2 and
  cue → 3/4 and the engine accepts it. Headphone jack audibility confirmed by ear (2026-10-08).
  Still `[UNVERIFIED]`: the headphone-fader mapping.
- Full-window layout is covered offscreen by `AppLayoutTests` (`app-full.png`,
  `app-default.png` in `DJ_SHOT_DIR`). `ImageRenderer` draws AppKit-backed controls
  (Slider/Toggle/Button) as yellow placeholders; that is a renderer limit, not a layout bug.
- Fixed: `AppModel.poll` exclusivity crash on net decks (found by the layout test).
