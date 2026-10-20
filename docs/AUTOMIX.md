# Auto-mix: a two-deck autopilot (design)

Status: **built** on `roadmap/auto-mix` (2026-10-19), every recommended default in §10 accepted.
Where the build differs from this design, §11 says so; the rest is as written below.

Auto-mix is Wander across two decks. Wander walks one deck through configuration space one move
per phrase; auto-mix walks **the mix**: the playing deck plays, a phrase ahead the idle deck is
given a nearby configuration, and on a phrase boundary the two hand over — the incoming deck
comes in drums-forward (`mixIn`), the outgoing deck goes out drums-forward (`mixOut`), the
crossfader steps across bar by bar, and the decks swap roles. The theme's three parts:

1. **Poke:** `DeckAction.autoMix(on:bars:every:)` (and `.autoMixNow`), a toggle at the
   mixer's foot, a controller button. Steering is the user's ordinary pokes: they pause it.
2. **Rule:** the incoming configuration is `AutoMix.plan` = Wander's swap moves (seed,
   instrument, genre) over the playing deck's configuration, seeded from its share CID and a
   hand-off counter, with both decks' locks, inside the mix's tempo window, in a compatible key.
3. **Boundary:** a hand-off starts on a phrase boundary (8 bars) of the playing deck's song
   clock; everything in it lands on bar lines; it lasts exactly `bars` bars.

Nothing about a hand-off is recorded except the poke that set auto-mix up (and, live only, a
late compose — §6). The crossfader motion, the mix-in and mix-out, the start and the swap of
roles are derived, as Wander's moves are.

## 1. What the player sees

- **Mixer foot**, beside the crossfader (`AppViews` crossfader row, ~line 2138): an **AUTO**
  toggle (lit when on, pulsing while a hand-off runs), `ChoiceButton`s for the mix length
  (**4 / 8 / 16 / 32** bars) and how long a track plays (**outro / 4 / 8 / 16** phrases), a
  **Mix now** button, and one status line:
  - `A playing · → B in 23 bars` (counting to the hand-off),
  - `B: house · seed 512 (genre move) · ready` (from the prep point on; the idle deck's header
    says **NEXT · auto** and shows the track like any loaded one, so it can be pre-listened on
    the headphone cue),
  - `mixing A → B · bar 3/8`,
  - `paused · resumes after 8 quiet bars (6 to go)`,
  - `waiting: B holds a sample — cue a net or turn auto-mix off` (idle reasons, §3.6).
- **What happens**, with auto-mix on and one net deck playing: the deck plays until its outro
  (or `every` phrases); 8 bars before the hand-off the other deck loads the next track, stopped;
  at the hand-off bar it starts from its top, synced, its melodic lanes resting; the playing
  deck jumps to its outro (if not there yet) and plays drums-forward; the crossfader walks across
  in `bars` steps; at the end the old deck stops on a bar line and the new deck's melody, chords
  and arp come in on that same bar. Then the new deck is "playing" and it starts again.
- **Steer:** load the idle deck yourself (that track is used as-is instead of a derived one);
  turn the browser wheel on the playing deck (new seed, pauses the countdown as it pauses
  Wander); set Wander locks (they hold the mix too); **Mix now** starts a hand-off at the next
  phrase boundary that leaves 4 bars to prepare.
- **Interrupt:** a steering poke on either deck (§5) pauses it until a whole phrase passes with
  no input; touching the crossfader during a hand-off takes the fader (auto-mix stops moving it,
  the rest of the hand-off completes). Pressing play/stop or loading either deck during a
  hand-off aborts the rest of it (what was already done stays done, as if performed by hand).
- **Stop:** AUTO off. A hand-off in progress stops being driven where it is (the crossfader
  stays where it is; mix-in / mix-out already applied play out as by hand).
- **`dj_state.autoMix`** (new top-level key, `AppControl` state builder, beside `crossfader`):

  ```json
  {"on": true, "bars": 8, "every": 0, "phase": "preparing", "playing": "A", "incoming": "B",
   "handoffs": 3, "handoffInBars": 6, "handoffBar": 64,
   "next": {"genre": "house", "seed": 512, "cid": "bafy…", "kind": "genre",
            "move": "techno → house · seed 512", "cued": false},
   "fader": "auto", "paused": false, "idle": null,
   "log": [{"n": 2, "from": "B", "to": "A", "bar": 72, "move": "seed 41 → 44", "cid": "bafy…"}]}
  ```

  `phase` ∈ `off | idle | playing | paused | preparing | armed | mixing`; `idle` is the reason
  string when it can't act; `fader` is `auto` or `user` (taken this hand-off); `log` is the last
  12 hand-offs, newest first (★ on a row stars that track, as Wander's log does).

## 2. The poke

### DeckAction cases (SessionModel.swift)

```swift
/// Auto-mix on or off with its settings, the whole value at once (`DJEngine.setAutoMix`):
/// `bars` the hand-off length (4 | 8 | 16 | 32), `every` how many 8-bar phrases a track plays
/// before the next hand-off (0 = until its outro; 4 | 8 | 16). Hand-offs are derived.
case autoMix(on: Bool, bars: Int, every: Int)
/// Hand off at the next phrase boundary at least 4 bars away (`DJEngine.autoMixNow`).
case autoMixNow
/// Live only, recorded by the engine (as `.grid` is when an analysis lands): hand-off `n`'s
/// incoming track was not composed by its arm point, so it moves one phrase later. A replay
/// (inline compose) never defers by itself; it applies this.
case autoMixDefer(handoff: Int)
```

- **Codec:** `{"op":"autoMix","on":true,"bars":8,"every":0}`, `{"op":"autoMixNow"}`,
  `{"op":"autoMixDefer","handoff":3}`; decode clamps `bars` to `AutoMixSettings.lengths`
  (default 8) and `every` to `{0,4,8,16}` (default 0). Append all three to `jsonOps`; document
  them in `dj_perform`'s description (`MCPBridge`, `ControlTests.everyPerformOpIsDocumented`);
  `AppControl` validates bars / every (as it does `wanderPace`) and refuses `autoMixDefer` from
  the socket (engine-only, like publishing it is not a tool).
- **Dispatch:** `applyAction` → `setAutoMix(on:bars:every:)`, `autoMixNow()`,
  `deferAutoMix(handoff:)`. One action for the whole value, as `clipFx` does: changing the
  length mid-set is one event and a replay needs nothing else.
- **Journal:** `.action(...)` like every DeckAction; `JournalEvent` describe lines
  (`auto-mix on · 8 bars · to the outro`, `mix now`, `auto-mix deferred #3`).

### Where the settings and the walk's state live

Auto-mix belongs to the mixer, not a deck: `DJEngine.autoMix: AutoMixState`.

```swift
public struct AutoMixSettings: Equatable, Sendable {   // the poke's value
  public static let lengths = [4, 8, 16, 32], everies = [0, 4, 8, 16]
  public var on = false, bars = 8, every = 0
}
public struct AutoMixState: Equatable, Sendable {
  public var settings = AutoMixSettings()
  public var handoffs = 0            // the counter: hand-off n draws from (spec CID, n)
  var phase: AutoMixPhase = .off     // + playing deck, H, P, c0, plan, quietBars, faderTaken…
  public internal(set) var log: [AutoMixHandoff] = []
}
```

- **Session start** (`Session.mixer.autoMix`): settings + `handoffs`, written **only when
  on or not default** (as `mixer.loopGain` is), so every older session keeps its text and CID.
  A session starts with the decks at rest, so no hand-off is ever in flight at its start.
- **Journal checkpoints** (`JournalState.mixer.autoMix`): settings, counter, and the in-flight
  phase (playing deck, H, P, c0, the plan's spec, fader owner, quiet bars), only when on. A
  mid-file checkpoint taken during a hand-off resumes it; `reset(to:)` restores it.
- **App defaults:** `autoMix.bars` and `autoMix.every` are remembered and sent through
  `perform(.autoMix(on: false, …))` at launch (as `wanderPace.<deck>` is); **on** is not
  remembered — an autopilot does not start itself at launch (question 10.12).
- **Controller:** new `SurfaceAction.autoMix` (press: toggle) and `.autoMixNow`. Candidate:
  the Inpulse 200 MK3's **ASSIST** button — one of `mixer.buttons` 1–3 (0x90 01–03), captured
  but not yet named (ASSIST/PREP, MASTER, BEATMATCH GUIDE in unknown order): press each on the
  unit, name them, bind ASSIST → `autoMix`, SHIFT + ASSIST → `autoMixNow` (`[UNVERIFIED]` until
  captured), LED lit while on. The controller handler calls `dj.setAutoMix` directly (recorded
  as MIDI, replayed through the router, as `.wander` is). Not the APC (its spare pads are being
  laid out for the FX unit on `apc-fx-unit`).

## 3. The rule: which configuration comes in

### 3.1 The draw

At the prep point P of hand-off `n` (§4), with `out` the playing deck:

```
c        = out.wanderContext(lockedActions:)        // spec, roles, voices, palette, kit, …
c.locks  = out.wander.locks ∪ in.wander.locks         // a lock on either deck holds the mix
c.spec   = out.seedTarget ?? out.currentSpec          // where the deck is heading (a swap still
                                                      // composing live = what replay has loaded)
rng      = WanderRandom(base: WanderRandom.base(c.spec) ^ AutoMix.salt, step: n)
plan     = Wander.plan(c, random: &rng, kinds: [.seed, .instrument, .genre])
spec     = plan.swap; AutoMix.pinKey(&spec, from: out, &rng)   // §3.3, same stream
```

- **Reuse, not a copy:** `Wander.plan` gains an overload taking the random stream and the
  kinds it may draw (today's `plan(_:step:)` becomes a one-line call into it, so Wander's draws
  are byte-for-byte unchanged — `WanderTests` hold that). Kind weights are Wander's renormalised:
  seed 20 / instrument 9 / genre 5 → 59 % / 26 % / 15 %. `AutoMix.salt` (a fixed 64-bit
  constant) keeps hand-off `n` from drawing what Wander's step `n` draws on the same spec.
- **New tracks only:** role / stem / macro / fx / stinger moves are not hand-offs; structure
  and palette moves are the same song (same seed), so they stay Wander's (on the playing deck).
  Seed moves are Wander's nearby seed (±1…7, same genre, structure, cohesion, extra).
- **Pure function:** (playing deck's configuration, both decks' locks, `n`) → spec. Nothing
  reads the clock or the wall time. The counter increments when the plan is taken at P, so a
  deferred hand-off keeps its plan; an aborted one has used its `n` (as a Wander step is used).
- **Memory** (all through `Wander.carry`, which every swap kind already calls): the deck's
  palette, kit pick and role overrides (`carryingSound`), `keep:<role>` (instrument always, part
  seed on same-genre swaps), the instruments lock (every voice pinned), the key lock
  (`keyOffset`). Disabled roles: the incoming deck takes the outgoing deck's
  (`setRoleDisabled`, derived at P, logged) so a role the user disabled stays out across the
  hand-off (question 10.10).
- **Context carried over:** `c.palette`, `c.kit`, `c.channels`, `c.voices` are the outgoing
  deck's (what plays now). The incoming compiles with its own `waveOptions` (its sampler bank,
  its voicing seed = the spec's).

### 3.2 Tempo

- The mix has one tempo: the outgoing deck's `effectiveBPM` at P (`mixBPM`).
- Genre options are `Wander.genreOptions(c)` (neighbours, the structure / tempo / key locks)
  **further filtered** to genres whose tempo the incoming deck's pitch fader can reach:
  `Deck.tempoMatch(base: genre.bpm, target: mixBPM).clamped == false` (±8 %, half / double time
  allowed). Same-genre moves always qualify (same base tempo, `extra["bpm"]` copied).
- At the start the incoming deck is synced (`sync(to: out, align: .bar)`: pitch, phase) and
  follows the outgoing deck for the length of the hand-off (`leader = out`, restored to what it
  was after), so a hand on the outgoing pitch fader carries both.
- After the hand-off the new deck **keeps the mix tempo** (its pitch fader stays where sync put
  it); the set holds one tempo, drifting only by genre hops inside the ±8 % window around it
  (question 10.7). A tempo lock narrows the window to ±6 % of its anchor, as for Wander.

### 3.3 Key

beats' `.variety` gives every seed its own key (offset −5…+6 from the genre root), so two seeds
of one genre are usually in different keys. The melodic lanes never overlap in a hand-off (both
rest, §4), but the basses do. `AutoMix.pinKey`:
- deck key lock on → `carry` already pinned the locked key; nothing more.
- otherwise, when the incoming genre's scale equals the outgoing's, pin `extra["keyOffset"]` so
  the incoming root pitch class is the outgoing's (`out.wanderKey`) **or a fifth either way**,
  drawn 2 : 1 : 1 from the same stream; a scale mismatch leaves `.variety`'s draw (question 10.5).
- Pinning goes through `TrackSpec.pinnedKeyOffset`, the path the key lock already uses, so the
  pin is part of the spec (and its CID), and a replay pins the same.

### 3.4 A deck the user loaded by hand

If the idle deck's source changed by a user poke since the last hand-off (a load, Generate, a
favorite, a copy — anything through `perform(.load)` / `generate` that auto-mix did not issue),
it is **cued**: at P auto-mix takes it as the incoming track as-is (no draw, the counter still
increments, the log says `cued`). That is the user's choice of the next configuration and it
survives (the theme's memory rule). Derivation resumes from it at the next hand-off.

### 3.5 Wandering decks

- The outgoing deck's walk goes on until P; the draw reads `seedTarget ?? currentSpec`, so a
  Wander swap landing at P is what the hand-off derives from.
- From P to the end of the hand-off Wander is **held on both decks** (`Deck.wanderHeld`, a
  derived flag `advanceWander` checks before anything else; not `wander.paused`, which is the
  user's): no moves, no look-ahead, so no swap can drop the mix-out tail and no macro lands on the
  crossfade. The held bars do not count as quiet bars and do not advance `wander.step`.
- After the hand-off each deck's Wander does what its own setting says; auto-mix does not turn
  Wander on or off on either deck (question 10.11). The incoming deck's first Wander move comes
  at its first phrase end after the hand-off (its clock started at tick 0 on H).

### 3.6 What it cannot derive from (idle reasons)

- Nothing playing: `idle: "start a deck"`. Both decks playing at turn-on: the louder one by
  crossfader gain (`DJEngine.dominantDeck` rule) is "playing"; auto-mix waits for the other to
  stop (`"B is playing too"`).
- The playing deck is a sample deck or a raw-`nets` share (no `TrackSpec`): no draw;
  `"A plays a sample: cue the next deck by hand"`. A cued net deck still hands off (it gets a
  crossfade + mix-in; the outgoing sample deck gets the crossfader ramp and is stopped on the
  last bar line — `mixOut` is net-only). From the new net deck derivation resumes.
- A sample on the idle deck: v1 does not start samples (`"B holds a sample"`); question 10.10.
- Every swap kind locked (`keepsEverything`, all locks): `"every move is locked"` — nothing to
  hand off to; a cued deck still works.

## 4. The boundary and the transition

### 4.1 Clocks and phrases

- Bars are the playing deck's song clock, `wave.tick / 16` (0-based), the clock Wander uses.
  A **phrase** is 8 bars (`AutoMix.phraseBars`): a phrase boundary is a bar `b` with
  `b % 8 == 0`, or a section start (`Deck.sections`, `startTick / 16`).
- The incoming deck starts at its tick 0 on H, so after the hand-off its song clock and its
  phrases line up with the music it plays.

### 4.2 When: the hand-off bar H and the prep point P

- **every = 0 (default), a song:** H = the outro's first bar (`sections.last{name=="outro"}`);
  without one, the last phrase boundary `≤ songEnd − bars`. **A loop, or every > 0:** H = the
  first phrase boundary at least `every × 8` bars after the deck came fully in (H_prev + bars;
  the bar auto-mix was turned on, or resumed from a pause, for the first one).
- H must be ≥ now + `prepBars` + 1 (`prepBars` = 8; `.autoMixNow`: 4); else the next boundary.
- **P = H − prepBars.** At P: draw (or take the cued deck), increment `handoffs`, compose.
- H is recomputed whenever the playing deck relocates (a section jump, a new seed by the
  wheel: that is also a pause, §5), never while `phase ≥ preparing`.

### 4.3 Preparing ahead (P … H−1)

- **Incoming:** the plan's spec is composed onto the idle (stopped) deck with its mix-in built
  in: `PreparedTrack(spec:, opts: in.waveOptions + rest RestSchedule.mixIn(fromTick: 0, bars:))`
  (a `WaveOptions.extraRest` joined to the song's schedule, the same entry `Deck.mixIn` makes;
  `mixInEndTick = bars × 16`). Live through `Deck.generate`'s path (`Task.detached`, installs at
  once on a stopped deck); `deterministic` replay inline. One prepare, no relocation later.
- **Outgoing mix-out, ahead:** `Deck.mixOut` relocates (re-prepares the song) at the next bar;
  issued live in bar H−1 its prepare could land a bar late, and a replay (inline) would not.
  So the mix-out project is prepared at P too, off-thread — exactly what `mixOut(bars:)` issued
  in bar H−1 would prepare (`movedOptions(…, tail: MixOutTail(fromTick: H′, bars:))`, start tick
  = the outro's start if it is still ahead, else H) — held in a `MixOutAhead` slot keyed like
  `LookAheadSlot.Key` (trackSerial, start tick, tail, role filter, kit / palette), and
  `wave.load`ed in bar H−1 so it takes over on H. A key mismatch at H−1 (the user changed the
  song meanwhile — which also pauses, §5) drops it and prepares inline / async as `mixOut`
  does. Test: byte-equal to a hand `mixOut` performed in bar H−1.
- **Late compose (live only):** if the incoming is not installed when the arm point comes, the
  engine performs `.autoMixDefer(handoff: n)` (recorded): H and the mix-out move one phrase
  later, the plan is kept. A replay applies the recorded defer at the same frame, so it walks the
  same path even though its compose was inline (§6).

### 4.4 The start

- **Arm** in bar H−1, at the first service tick past beat 3.5 (0.5…1.5 beats before H):
  `in.setPlaying(true)` + `in.sync(to: out, align: .bar)` + `in.leader = out`. With the
  incoming at tick 0 and the outgoing ½…1½ beats short of H, the bar-phase error wraps to a
  negative shift: `align` **holds the incoming clock back** (never skips ticks forward), so its
  tick 0 falls on H. Existing commands only (`play`, `tempo`, `align`).
- **Exactness:** offline the main thread runs between render blocks and both decks' tick
  atomics come from the same block, so the start is exact. Live, the commands can land a block
  after the state they were computed from (a few ms). Correction: in bar H the crossfader is
  still at c0 (§4.5), which after the first hand-off is the outgoing's full side, so the
  incoming is silent; during that bar auto-mix reads both decks' **tick anchors** (exact
  (frame, tick) pairs, `WaveDeckSource.anchors`, in each deck's `renderedFrames`, which tick
  together on one engine) and sends one `align(ticks:)` for the residual. Acceptance: the
  incoming's ticks within ±1 sample of the outgoing's from bar H+1 (measured offline with a
  one-block delay injected between arm and commands). If that fails in the build, the fallback
  is one audio-thread addition, `WaveCommand.playAt(frame:)` (a compare per block, no
  allocation), measured by `AutoMixRealTimeTests` — not planned unless needed (question 10.15).

### 4.5 The transition (H … H+N), N = `bars`

- **Outgoing:** the mix-out project from H: jumps to its outro if it is still ahead, plays its
  drums-forward lanes (melodic classes rest, `MixOutTail.restMask`), stops on H+N's bar line;
  the room and echo ring out after it. The `MixOutTail` stop is the transport's: `service()` sees
  the end; auto-next is suppressed on a deck auto-mix is mixing out (§5).
- **Incoming:** from its tick 0 (its intro) with the same mask resting until tick N×16, so its
  melodic lanes enter on H+N — the bar the outgoing stops on.
- **Melodic lines never overlap** (no key clash in the leads, pads or arps); the drums and
  basses carry the hand-off (question 10.4 offers a staggered shape instead).
- **Crossfader, derived:** `x(k) = c0 + (x_end − c0) · k / N` for `k = 0 … N` bars into the
  hand-off, set on each bar line of the outgoing clock (`k = bar − H`), `x_end` = 1 for A → B,
  0 for B → A, c0 = the crossfader at H. The engine's equal-power law (`crossfadeGain`: cos /
  sin) is the curve; the steps are linear in position, so equal power at every step. Written
  straight to `dj.crossfader` (not `perform`: not recorded) with `owners["crossfader"] =
  "automix"`, so a hardware crossfader must pick up (soft takeover) before it moves anything.
- **No EQ / filter / volume moves** (question 10.8): the gain law alone, and the knobs stay the
  user's.
- **End (H+N):** the outgoing has stopped (tail end); `in.leader` restored; Wander released;
  the incoming is "playing"; log row appended; the next H computed; the old deck sits stopped at
  its tail end (it is the next idle deck).

### 4.6 Timing (N = 8, prep 8; bars of the outgoing deck A)

```
bar      H-9    H-8=P          H-2    H-1            H     H+1 …     H+7    H+8=H+N
A        full   full ……………… full   full  [mixOut   drums+bass, outro ……………   stopped
                Wander held →                   loaded]                       (tail end)
B        idle   compose spec   (stopped, loaded)  arm   tick 0  bars 1…7 of    melodic in;
                (mixIn baked)               @beat 3.5   intro   intro, drums   B "playing"
fader    c0     c0 ……………………………… c0     c0             c0    c0+Δ/8 …  c0+7Δ/8 x_end
A Wander walks  held ……………………………………………………………………………………………………… released
B Wander –      held ……………………………………………………………………………………………………… released (own setting)
```

## 5. Interaction rules

- **Touches.** One hook, `DJEngine.noteTouch(deck:steering:)`, called from `applyAction` (UI,
  socket, MCP) and from `SurfaceController.handle` / the jog adapter (hardware; replayed through
  the router, so a replay sees the same touches). Auto-mix's own commands never call it.
- **Steering pokes pause** (either deck): play / cue / rewind / hot cue / loop in-out / sync /
  nudge, load / Generate / queue next / next track / regenerate / seed wheel, section launches,
  kit / palette / role voice, mixOut / mixIn by hand, a jog touch (`JogAdapter.touching`) or
  scratch. Paused = no countdown, no new prep; resumes after `phraseBars` quiet bars of the
  playing deck (as `grabWander`), then H is recomputed. A load on the **idle** deck is a cue
  (§3.4), not a pause.
- **Expression pokes don't pause** (question 10.9): volume, gain, EQ, filter, pitch, reverb,
  role mutes, STEMS, net and master macros, stingers, FX unit, master FX sliders, live keys,
  voice tweaks, the loops row, headphone cue. They are playing the mix, not steering it.
- **During a hand-off** (P … H+N) a steering poke on the outgoing before H cancels the start
  (H moves to the next eligible boundary after the pause, the incoming stays loaded, the plan is
  kept unless the outgoing's spec changed — then re-derived with the next `n`). From H on: the
  crossfader → `fader: user` for the rest of this hand-off; play / stop / load on either deck or
  AUTO off → abort (nothing undone, as if done by hand); anything else → the hand-off completes.
- **Never touched:** EQ, filter, volume, trim, master, reverb, FX units, master FX, macros,
  role mutes, STEMS, locks, wander on/pace, the loops row and channel L, focus, headphones.
  Touched, derived and listed: crossfader (in hand-offs), the incoming's pitch / phase (sync)
  and `leader` (during a hand-off), its disabled roles (copied at P), its transport, its loaded
  track, the outgoing's mix-out, Wander's hold.
- **Wander** on either deck: held P … H+N (§3.5); otherwise unaffected.
- **Auto-next** (`autoAdvance`): on a deck auto-mix mixed out, `service()` does not advance
  when the tail ends (else the old deck would restart its next version under the new one); a
  derived check (`autoMix.isMixingOut(deck)`), the recorded setting untouched. If the playing
  deck's song ends with no hand-off (paused, idle), auto-next does what it always did.
- **Loops row:** untouched. The loops follow the louder deck (`updateDominantDeck`, 3 dB
  hysteresis), which changes hands during the crossfade; both decks are at the mix tempo, so the
  loops' tempo does not jump.
- **FX unit:** per deck, untouched; an FX unit left engaged on the idle deck plays on the
  incoming track (the user's). Master macros fired before P ring out as usual.

## 6. Replay, journal, determinism

- **Recorded:** `.autoMix(on:bars:every:)`, `.autoMixNow`, and the engine's
  `.autoMixDefer(handoff:)`; every user poke as before (the touches that pause it are recorded
  pokes or MIDI). Session start: `mixer.autoMix` (settings + counter).
- **Derived** (never recorded): H, P, the plan (spec CID + counter + locks), the cue decision
  (from recorded loads), the prepare, the arm, the phase correction, the crossfader steps, the
  mix-out / mix-in, Wander's hold, the role swap, the counter's increments.
- **Why a replay walks the same path:** every derived step is a pure function of the engine's
  state at a service tick, and `OfflineConductor.step` (replay) and `ControllerHub.tick` (live)
  both call `dj.serviceAutoMix()` right after `dj.serviceWander()`, at the same housekeeping
  frames in replay; recorded pokes arrive at their frames before it. The only live-timing input
  — a compose that is late — becomes a recorded event (`autoMixDefer`), as an analysis result
  becomes `.grid`. Composes in `deterministic` mode are inline (as Wander's).
- **Not byte-identical live-vs-replay** in general (the arm lands a block apart live; corrected
  musically, not to the sample), exactly as Wander and hand sync are today; replay-vs-replay is
  byte-identical (synth voices; round-robin samplers vary on purpose, as documented).
- **Journal:** mid-file checkpoints carry `mixer.autoMix` with the in-flight phase and the
  crossfader value; a replay from one resumes the hand-off. A rewind (`reset(to:)`) restores it.
  `exportSession` slices start at rest: auto-mix's settings come along, an in-flight hand-off
  does not (a session starts with stopped decks).

## 7. Audio-thread impact

- **None new.** Everything is main-thread work through existing commands: `WaveCommand.load`
  (prepared projects, handed over whole), `play`, `tempo`, `align`, the strips' output volume
  (crossfader). Composes and the mix-out prepare run on `Task.detached` (inline in
  `deterministic`), off the audio thread; projects leave through the retire ring.
- Allocation rules hold by construction; measured anyway: `AutoMixRealTimeTests`
  (`countAllocations` over a whole hand-off — compose landing, mix-out swap, arm, align,
  crossfader steps, tail stop, a defer — release build). Only if §4.4's acceptance fails does
  `WaveCommand.playAt` appear, and then it is measured in the same test.
- CPU: two net decks render during a hand-off (already the case when mixing by hand); one extra
  compose + one extra prepare per hand-off, off-thread, a phrase ahead.

## 8. Test plan (fast spot checks)

New suites (debug unless marked), all `DJEngine(offline: true)` + `OfflineConductor`, synth
voices, short `every` / `bars` to keep them seconds long:

| Test (file `AutoMixTests.swift` unless noted) | Holds |
|---|---|
| `theActionsRoundTripThroughJSON` | codec, defaults, clamping, `jsonOps` |
| `theIncomingIsAPureFunctionOfTheOutgoingAndTheCounter` | same (spec, n, locks) → same spec; n+1 differs; ≠ Wander's step n |
| `wandersDrawsAreUnchanged` (`WanderTests`) | the `plan` overload leaves Wander byte-equal |
| `aHandOffBringsANewTrack` | kinds ⊂ {seed, instrument, genre}; spec ≠ outgoing |
| `genreHopsStayInTheTempoWindow` | 200 draws: `tempoMatch` never clamped; tempo lock ±6 % |
| `locksHold` | genre / instruments / key / keep:bass (part seed) / palette carry; union of decks |
| `theKeyIsCompatible` | root PC same or ±7 when scales match; key lock pins the lock's |
| `aHandOffStartsOnAPhraseBoundary` | H % 8 == 0 or a section start; outro by default |
| `theIncomingStartsOnTheBarLine` | its first anchor frame == outgoing's H anchor frame |
| `aLateArmIsCorrectedBeforeItIsHeard` | one-block delay injected: ±1 sample from H+1 |
| `theCrossfadeCoversExactlyNBars` | x(k) per bar, c0 at H, x_end at H+N, changes only on bar lines |
| `melodicLanesHandOverOnOneBarLine` | hit logs: outgoing melodic stops at H, incoming starts at H+N |
| `theMixOutAheadEqualsAHandMixOut` | byte-equal to `mixOut` performed in bar H−1 |
| `rolesSwapAndItGoesOn` | two hand-offs: A→B then B→A, counter 0, 1 |
| `steeringPausesExpressionDoesNot` | wheel / load pause for 8 quiet bars; EQ / macro don't |
| `aCueIsUsedAsIs` | a hand-loaded idle deck is the incoming, no draw |
| `theCrossfaderTouchTakesTheFader` / `playStopAborts` | §5 |
| `autoNextDoesNotRestartTheOutgoingDeck`, `wanderIsHeldThroughAHandOff` | §5, §3.5 |
| `idleReasons` | sample / raw / both playing / all locked |
| `aSetWithAutoMixReplaysToTheByte` | record 2 hand-offs, replay twice: `sameSamples` |
| `aDeferIsRecordedAndReplayed` | slow compose hook → `.autoMixDefer` recorded; replay defers at the same bar |
| `aCheckpointMidHandOffResumes` (`JournalCheckpointTests`) | state from a checkpoint inside H…H+N == full replay's |
| `AutoMixRealTimeTests.aHandOffAllocatesNothing` (release) | §7 |
| `AutoMixViewTests` (`djtest_shots`) | the mixer control renders, lit / pulsing |

Existing filtered suites to run (`djtest_swift_test`, debug): `WanderTests`, `WanderKeepTests`,
`WanderPaletteLockTests`, `WanderSwapTimingTests`, `MixOutActionTests`, `MixOutTailTests`,
`ControlTests`, `SessionTests`, `JournalTests`, `JournalCheckpointTests`, `JournalRewindTests`,
`LevelMatchTests`, `ControllerLayoutTests` (+ the captured-message replay if the profile
changes); DJViews `AppControlTests`. Release: `MixOutRealTimeTests`, `JournalRealTimeTests`,
`AutoMixRealTimeTests`. No parity run (nothing near `compose()` / `WaveOptions()` / shares).

**Loudness through a hand-off (measured, not guessed).** A new `djctl automix <genre> <seed>
[--bars N] [--every P] [--handoffs K] [--crossfade-only] [--out f.wav]` renders an offline set
(the same engine path as the tests) and prints, per hand-off: `before` = integrated LUFS of the
outgoing alone over [H−8, H), `after` = the incoming alone over [H+N, H+N+8), the short-term
(3 s, `LoudnessMeter`) curve per beat over [H−8, H+N+8], `dipLU` = min(short-term in [H, H+N])
− min(before, after), `bumpLU` (the max side), and the mix's sample / true peak. A `djtest`
wrapper (or `djtest_measure` on the WAV) runs it from a session. Matrix: techno, house, trance,
dnb, lofi, jazz × 2 seeds, N = 8, every = 4 (≈ 50 bars each). Two runs:
- **`--crossfade-only`** (no mix-in / mix-out rests: the gain law alone): acceptance is the
  existing `LevelMatch.crossfadeToleranceLU` (1.0 LU) on both dip and bump.
- **full hand-off:** the drums-forward overlap is a planned dip. Record the 12 dips; `X` =
  the worst, rounded up to 0.5 LU, written as `AutoMix.maxDipLU` with its source
  (`"djctl automix matrix 2026-10-xx, n=12, worst …"`, as targets.json names sources), and the
  test asserts it from then on. Peaks: no sample over 0 dBFS (each deck is limited to −1 dBTP;
  two at −3 dB can still sum higher — report the true peak, and if it clips, that is a finding
  for the master, not a reason to touch the decks).

## 9. Build plan

1. **The rule** — `Sources/DJCore/AutoMix.swift`: `AutoMixSettings`, `AutoMixState`, phases,
   `AutoMix.plan` (the `Wander.plan(_:random:kinds:)` overload, the tempo-window filter on
   `genreOptions`, `pinKey`), log type. Tests 1–7 of the table. ~250 lines + ~250 test.
2. **The poke** — DeckAction cases, codec, `jsonOps`, `applyAction`, `Session.mixer.autoMix`,
   `JournalState.mixer.autoMix`, `JournalEvent` lines, MCP `dj_perform` / `dj_state` docs,
   `AppControl` validation. ~150.
3. **The engine** — `DJEngine.serviceAutoMix()` (state machine: H, P, prepare, arm, correct,
   step the fader, end), wired after `serviceWander` in `ControllerHub.tick` and
   `OfflineConductor.step`; `WaveOptions.extraRest` for the baked mix-in; `MixOutAhead`;
   `Deck.wanderHeld`; the auto-next guard; `.autoMixDefer` emission. ~450 + the replay /
   timing tests.
4. **Touches** — `noteTouch` from `applyAction`, `SurfaceController.handle`, the jog path; the
   steering / expression table. ~60.
5. **UI + state** — mixer-foot control, idle deck's NEXT badge, `dj_state.autoMix`, app
   defaults. ~200 + view test.
6. **Measure** — `djctl automix`, the level matrix, pick `X`, `AutoMixRealTimeTests`. ~150.
7. **Controller** — name the Inpulse's three mixer buttons on the unit (user), bind ASSIST,
   re-capture, coverage / replay tests. ~40 + capture.
8. **Docs** — CLAUDE.md (theme bullet + a Wander-adjacent "Auto-mix" section), MANUAL.md
   section, ROADMAP status.

Total ≈ 1.3–1.5 k lines with tests. Order 1 → 2 → 3 is the critical path; 4–6 follow; 7 needs
the user at the hardware.

**Risks**
- *Live start phase* (§4.4): the anchor correction is new reasoning on existing commands; if the
  measured residual misses ±1 sample, `WaveCommand.playAt` is the fallback (audio-thread code).
- *Compose time vs one phrase:* a cold sampled palette (EXS loads, `normalize`, part probes) can
  take longer than 8 bars at 174 BPM (~11 s); the defer path covers it but a set full of defers
  plays tracks a phrase longer. Mitigation if measured: compose at P − 8 for sampled palettes.
- *Mix-out ahead keying:* a missed key falls back to `mixOut`'s own (possibly late) relocation —
  a bar late live, on time in replay. Keep the key wide enough to catch every input of
  `movedOptions`.
- *Songs without an outro / short songs:* H falls back to `songEnd − bars`; a song shorter than
  P allows hands off at the first eligible boundary (log says so).
- *Bass clash:* basses overlap for N bars; key pinning reduces it; an EQ bass swap is
  deliberately left out (question 10.8).
- *Sampler banks:* the incoming deck's bank loads new instruments at P while the outgoing's bank
  plays; eviction already handles pinning (24 slots per deck).

## 10. Open questions for the user

Each with the recommended default.

1. **Mix length default** — 4 / 8 / 16 / 32 bars. *Recommend 8* (≈ 15 s at 128 BPM): with both
   decks drums-forward, 16 bars of drums and bass alone is long; `mixOut`'s own default (16)
   stays for hand mixing.
2. **How long a track plays** — *Recommend "to the outro" for songs* (the outro becomes the
   mix, no jump), *8 phrases (64 bars) for loops*; options 4 / 8 / 16 phrases for both.
3. **May it change genre?** *Yes*: Wander's neighbours, only those the pitch fader reaches
   (±8 %, half / double), ≈ 15 % of hand-offs; the genre lock stops it.
4. **Transition shape** — *Recommend "same bars"*: incoming mixIn N and outgoing mixOut N on the
   same bars, melodic lanes swapping on one bar line (no melodic overlap, so no key clash).
   Alternative "staggered": the outgoing plays whole for N/2, then mixOut N/2 (melodic overlap
   in the first half, more continuity, needs compatible keys).
5. **Key** — *Recommend "compatible"*: pin the incoming to the outgoing's root or a fifth either
   way (same scale only). Alternatives: "same key" (every track in one key until a genre hop) or
   "free" (beats' per-seed key; the basses may clash).
6. **Crossfader** — *Recommend the engine's equal-power law, linear in position, one step per
   bar* (the theme's boundary, ~N gain steps). Alternative: a step per beat (smoother, 4N steps,
   still derived).
7. **Tempo after a hand-off** — *Recommend "hold"* (the set keeps the mix tempo; genre hops stay
   within ±8 % of it). Alternative "home": ease the new deck back to its own tempo over the next
   phrase in bar steps (moves the pitch fader the user may be holding).
8. **EQ / bass swap** — *Recommend none in v1* (never touches the user's knobs); revisit after
   listening to the matrix renders (a derived low-EQ swap at H + N/2 is the classic move).
9. **Which pokes pause it** — *Recommend steering pauses (transport, loads, seeds, sections,
   sound changes, jog), expression doesn't (knobs, mutes, macros, FX)*; a phrase (8 bars) of
   quiet resumes it.
10. **Hand-cued and sample decks** — *Recommend*: a net the user loads on the idle deck is
    used as-is; v1 does not start samples (idle reason), and from a sample deck it waits for a
    cue. Also: the incoming deck *takes the outgoing's disabled roles* (one walk) — yes?
11. **Wander across a hand-off** — *Recommend no transfer*: each deck's Wander setting stays its
    own (turn it on on both to wander the whole set); auto-mix only holds it during hand-offs.
12. **Remember "on" across launches?** *Recommend no* (settings yes): an autopilot that starts
    by itself at launch would surprise.
13. **Controller** — *Recommend the Inpulse ASSIST button* (toggle; SHIFT + ASSIST = mix now).
    Needs you to press 0x90 01–03 on the unit once to say which is ASSIST.
14. **Mix now / re-roll** — *Recommend only "Mix now" in v1*; to change the next track, load the
    idle deck by hand (a cue). A "re-roll" poke (draw again with n+1) can come later.
15. **Start mechanism** — *Recommend existing commands + anchor correction*, with
    `WaveCommand.playAt` (one audio-thread compare per block) only if the measured residual
    misses ±1 sample. OK to add audio-thread code if it comes to that?

## 11. As built (differences from the design)

- **Genre hops only at the same beat**: `tempoMatch` must reach the mix tempo with multiplier 1
  (unclamped); half / double time is left out, so the bar lines of both decks always coincide.
  A cued deck that needs ½ / 2 still starts on the bar line but is not phase-corrected.
- **The point of no return is the mix-out load** (the first service tick in bar H − 1), not the
  arm: a late compose is deferred there (`.autoMixDefer`), before the outgoing deck gets its
  tail. Steering before it cancels the start (plan kept); after it, play / stop / load end the
  hand-off and anything else lets it complete.
- **Start exactness**: the arm works from both decks' published clocks at the end of one block
  (`renderedFrames` equal), counting the swap slot of a pending mix-out (a relocation prepared
  from `nextSwapTick` plays one slot late); the correction in bar H uses the same published
  positions instead of the anchor rings. Measured: the incoming's first tick and every bar line
  of the hand-off within ±1 sample offline, and a start held back 512 frames corrected before bar
  1 (`aLateArmIsCorrectedBeforeItIsHeard`). No `WaveCommand.playAt` was needed (question 10.15).
- **The hand-off bar is fixed per countdown** (recomputed after a pause, Mix now, new settings,
  another playing deck, or if it has passed), so a Wander structure move between doesn't move
  it; the mix-out still jumps to an outro that is ahead.
- **The fader steps on the incoming deck's bars** (its tick 0 is the hand-off bar), so they keep
  stepping after the outgoing tail has stopped; a moved fader is detected by value, which covers
  the UI, MCP and the hardware alike.
- **The demo loop (or nothing) on the idle deck is replaced**; only a sample the user loaded
  makes auto-mix wait (the app launches with the demo loop on both decks).
- **A cued deck starts from its top**, rebuilt with the mix-in (tick 0 keeps the phrase grid).
- **From a sample deck with a beat grid**, a cued net hands off at the next phrase boundary ≥ 9
  bars on; the start is worked out from the grid (not to the sample) and the sample deck is
  stopped at the end by the engine.
- **Checkpoints** carry the in-flight run and a restore takes it up; the decks' mix-in / tail
  are not in a checkpoint's sources, so the restored hand-off still ends on its bar line but
  the overlap plays full (as documented for mid-file checkpoints). The full "replay from a
  checkpoint inside H…H+N" comparison was not built; `aCheckpointMidHandOffCarriesIt` checks the
  round trip and the restore.
- **Levels** (`djctl automix`, synth voices, 48 kHz, bars 8, every 4; dip = min short-term
  during the hand-off − the quieter track alone): full hand-off techno −6.3 / −6.6, house −3.0 /
  −4.4, trance −9.4 / −7.3, dnb −6.4 / −7.4, lofi −23.2 / −23.6, jazz −7.1 / −6.8 LU (seeds 42 /
  7); bumps ≤ +1.0 LU; true peak ≤ −1.8 dBTP. Crossfade only (no rests): −0.8 … −4.1 LU except
  lofi 7 −11.6 and jazz 7 −5.8 (the incoming's intro is quieter than its body), true peak ≤
  −0.35 dBTP. `AutoMix.maxDipLU` = 24 LU from the worst full dip.

