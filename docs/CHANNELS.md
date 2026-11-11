# Channels: continuous mixes of one or more genres and instruments (design)

Status: **design, being built** (2026-10-21). Decisions taken with the user: all four phases of §6; the wheel changes
channel and push toggles mixing (§3); LLM-composed tracks come from an agent outside the app, the app never calls a model (§5).

A **channel** is a named, saved definition of a kind of music ("deep trance", "rave + industrial",
"bossa on nylon guitar and flute") that the app mixes continuously. You tune to a channel the way
you tune a radio: the two decks keep handing off tracks that fit it, until you tune away or stop.
Anything you can ask for in electronic music is a channel; so is a non-electronic one.

It joins what the app already does into one idea:

| today | in a channel |
|---|---|
| `dj_generate` (genre, seed, structure) | a **generated** source: the generator, constrained to the channel's genres and instruments |
| `dj_compose` / `dj_inspired` (LLM-written raw tracks) | a **composed** source: a pool of saved rolls the channel draws from and a producer keeps topped up |
| `dj_import`, saved compositions, sets | a **library** source: anything saved, filed under the channel |
| Wander (one deck, one move per phrase) | steering inside the channel |
| Auto-mix (two decks, phrase-boundary hand-off) | the engine that plays the channel |
| `dj_set auto` / the `dj` agent | one way to fill and steer a channel, not the only one |

## 1. What a channel is

```
Channel {
  id, name
  genres:       [genre ids]            // the pool of families it hops between (Wander.neighbours inside it)
  instruments:  {role: [instrument]}   // allowed picks per role; one entry = locked (the existing instruments lock)
  palette:      palette id?            // optional, the existing palette
  tempo:        {min, max}             // hand-offs stay inside it; the mix's ±6 % window still applies
  key:          free | fifths | pinned(root, scale)
  energy:       flat | arc(bars) | rise // shape over a run of tracks (SetPlanner's cost already scores energy)
  structure:    structure ids?         // generator structures it may use
  sources:      [generated, composed, library]  // with weights
  layers:       bool                   // loop layers (vocal/riser/impact) on raw tracks, the existing feature
  pool:         set slug               // where its composed and library tracks live (a DJSet)
}
```

A channel is data, stored beside sets (`…/dj-vevr-se/channels/<slug>.json`, `$DJ_CHANNELS_DIR`), and
a request in words becomes one: "any trance and psytrance on supersaws, fast" → genres
`[trance, …]`, instruments `{melody: [supersaw]}`, tempo 138–150. The `dj` agent (or this session) does that
translation and writes the channel; the app only reads channels.

## 2. How it plays

- **Tune** is a poke (`DeckAction.tune(channel)`), journaled and replayed like every other. Tuning sets
  the channel on the mixer (like `AutoMixState.settings`) and turns auto-mix on with the channel as its
  rule. Tuning away (or `tune(nil)`) leaves auto-mix as it was configured by hand.
- **Next track** is `AutoMix.plan` generalized to `ChannelPlan`: pick a source by weight; a *generated*
  pick is Wander's seed / instrument / genre move restricted to `genres` and `instruments`; a *composed* or
  *library* pick is the next unplayed entry of the pool whose tempo/key fit the playing track
  (SetPlanner's cost, reused). A pool miss falls back to *generated* so a channel never goes quiet.
- **Hand-off** is auto-mix's: prepared a phrase ahead on the idle deck, started on a phrase boundary,
  mix-in/mix-out, crossfade over `bars`, deck roles swap. Nothing about the hand-off changes.
- **Determinism:** the pick is a pure function of (channel id, playing track's CID, hand-off counter), as
  auto-mix's is. Composed tracks are content-addressed files, so a replay loads the same CIDs.
- **Tempo outside the window:** a pool track too far from the playing tempo is not picked for a blend;
  the channel may take it only as a **cut** at a phrase end (the outgoing deck brakes or drops out, the
  incoming starts clean). Channels with a wide tempo range say so (`cuts: true`).

### Lessons from live use that this must get right
These were found by running a hand-rolled version of this from outside the app (2026-10-21):

1. **State hygiene on every hand-off.** A deck left flagged "mixing out" had its rhythm parts muted on the
   next load, so a track played without drums. A hand-off must end with the outgoing deck's mix flags,
   role mutes, pitch, EQ and FX in a known state, and a load must start from one.
2. **Pitch and EQ carry over.** Sync leaves the deck's pitch at its stretch. The next load inherits it, so
   a 125 BPM track played at 134 and a 100 BPM track at 108. A channel resets pitch to 0 and EQ to flat
   on the idle deck before its track starts, unless the performer moved them since the last hand-off.
3. **A controller touch means "hands on".** A fader, pitch, EQ or FX touch pauses the channel's moves for a
   phrase (auto-mix's existing steering rule), and a channel never writes a control the performer holds.
4. **No probes.** Reading state must never move a control. (`dj_state` is the read.)
5. **Timing is the app's clock,** never an agent polling: hand-offs were late and macros missed their bar
   whenever an agent fired them.

## 3. Controller

Reuses the browser section that Wander already owns (`mixer.browserPush`, `mixer.browser`,
`mixer.shiftBrowser`, `Wander.swift`). All of it is `[MIXXX]`, never captured on this unit, so the same
caveat applies (verify live before leaning on it).

| control | tuned to a channel | today (no channel) |
|---|---|---|
| browser **wheel** | **tune**: next / previous channel, like a radio dial (the new channel takes over at the next phrase boundary; the wheel pauses the channel's own moves for a phrase, as it pauses a wandering deck) | `seedStep` on the playing net |
| browser **push** | channel on/off: the same "autonomous or not" toggle as wander | wander on/off on the focus deck |
| **SHIFT** + wheel | hand-off length (4 / 8 / 16 / 32 bars), like it sets wander pace | `wanderPace` |
| **SHIFT** + push | skip: hand off to the channel's next pick now (`autoMixNow` for the channel) | unbound |

Decided with the user 2026-10-21: the wheel changes channel; push toggles mixing. With no channel tuned the
wheel keeps its seed-step job, so tuning is also what changes the wheel's meaning (the strip shows which).

The mixer foot gets a channel strip beside AUTO: the channel's name, its source and the next pick
(`B: trance · seed 512 · ready`), prev/next channel.

## 4. MCP and the agent

- `dj_channel`: `list`, `show`, `save {definition}`, `delete`, `tune {id}`, `status`, `skip`, `queue`
  (the pool's unplayed picks), `add {composition id}` (file a track under a channel).
- `dj_perform` gains `tune {channel}` and `channelStep {delta}` (documented, per
  `ControlTests.everyPerformOpIsDocumented`); `dj_state.channel` reports the tuned channel and its next pick.
- `dj` agent: gains the channel tools. Its job moves from driving hand-offs to **defining channels and
  topping up their pools**; the app does the timing.

## 5. Producing tracks for a channel ("any electronic music")

Three tiers, cheapest first, so a channel never depends on the expensive one:

1. **Generated** (free, deterministic): the generator's 19 genres, locks and instruments. Covers most requests.
2. **Composed** (an LLM writes a roll): for what the generator can't say (a specific mood, an instrument
   set, "Matrix-style"). A **producer** — the `dj` agent, or a small process — writes rolls into the
   channel's pool ahead of need. Every roll passes a checker before it is filed: schema, notes in key, bass
   root matching the chord on each downbeat, a build before each drop, roles all sounding (the checks in
   `llm-harness/trackgen`, which also found the lower-cost models close on schema and chords but weaker on
   staying in key; **nobody has listened to those results**, so treat them as a filter, not a verdict).
   The roll is repaired once with the checker's findings, then filed or dropped.
3. **Library** (already saved): compositions, imports, sets, filed under a channel.

The producer runs outside the app (a long-running agent, the "next step" noted in CLAUDE.md), reads the
pool depth through `dj_channel queue`, and writes with `load:false`. The app never calls a model.

## 6. Build order

1. `Channel` model + store + `tune` poke + journal replay; `ChannelPlan` over the *generated* source only
   (genres and instruments constraints); state-hygiene fixes in the hand-off; tests (determinism,
   replay, locks, the §2 lessons as regression tests).
2. Browser bindings and the mixer-foot strip; `dj_channel`, `dj_perform` ops, `dj_state.channel`.
3. Pool sources (composed + library) in `ChannelPlan`; tempo/key fit; the cut transition.
4. Producer: agent definition update, the roll checker as a reusable tool, queue depth policy.

## 7. Open questions
- Does tuning replace auto-mix's own settings or stack on them? Proposed: stack; the channel supplies the
  rule, the performer's bars/every settings still apply.
- Should a channel be allowed to be non-electronic? Proposed: yes; the genre list is the generator's, and
  a channel with only composed/library sources has no genre constraint.
- A channel that uses both decks' locks: proposed that a channel's `instruments` are applied as the
  existing instruments lock on both decks for the length of the tune, restored on tune-away.
