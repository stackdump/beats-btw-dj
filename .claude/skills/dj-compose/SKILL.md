---
name: dj-compose
description: Write music for the dj-vevr-se app and play it on a deck — an original track from a genre or style brief, a piece "inspired by" an artist, a song in a chosen form, a score file imported from disk, or a whole pre-rolled set queued and mixed on an energy curve. Use for "compose / write / make me a <genre> track", "pre-roll / queue a set", "mix into the next", "<artist>-style", "inspired by …", "push/load … to A or B", "hard techno / trance / house …", "import this .mid / MusicXML", or "what have we made / reload that one". Gives the one vocabulary, the style-brief card, the roll format and the genre cheat sheet the dj_compose, dj_inspired, dj_import and dj_compositions tools expect.
---

# dj-compose

You write the notes; the app plays exactly those notes on a deck as a Petri-net track (a raw-nets
share). You cannot hear it: read `dj_state` (roles on, level), say what you wrote, not how it sounds.

## 1. The words (settled vocabulary)

| The user says | You do |
|---|---|
| "**inspired by** X", "X-style", "something like X" | `dj_inspired` — original piece, `inspiredBy: "X"`, a `brief` |
| "compose / write / make a <genre> track" (no artist) | `dj_compose` |
| "import / play this file" (.mid .midi .musicxml .xml .mxl) | `dj_import` (`inspect: true` first if unsure of the roles) |
| "what have we made", "reload the daft punk one" | `dj_compositions` (list, then `load {deck, id}`) |
| "**pre-roll / queue up a set**", "a set of N tracks", "plan a night" | `dj_set` plan → compose each track with `load: false` into the set → `sequence` → `start` → `mix` (section 9) |
| "**mix into the next**", "swap A to B", "bring in the next one" | `dj_set mix` (the beat-matched, bass-swapped crossfade) |
| "random / generate me some <genre>" (no notes from you) | `dj_generate` (the generator's own seeds); add `structure` |
| "**push / load / send** … to **A** or **B**" | load it on that deck. In this app "push" is never git push |
| "**play** / start it" | `dj_perform` play. Loading does not start a deck (a deck already playing keeps playing) |
| "**standard**" (or minimal / extended) | the generator's song structure: intro, buildup, drop, breakdown, buildup, drop, outro. For *your* rolls it means: write the whole form out (section 5), don't leave a 4-bar loop |
| "hard" | tempo and weight, not a different engine: faster (140–160), harder kick, rolling or wub bass |

Name tracks `<Genre> <Descriptor>` or `<Artist>-style (original)`. Never "push" to git unasked.

## 2. Originality (non-negotiable)

- Inspired-by means the artist's **general style**: tempo, key/mode, progression type, groove, sound
  palette, form. Never transcribe or closely paraphrase their melody, hook, bassline or lyric, and
  don't take a famous progression note-for-note together with its rhythm.
- Asked for "the actual song": decline that part, say why in one line, and write the inspired
  original. Same for any copyrighted track named by scene or film.
- Imports only for files the user owns or that are public domain / Creative Commons. Pass the origin
  and licence in `source`. Nothing here publishes; a share of a CC BY-SA / NC piece carries those terms.

## 3. The style card (put it in `brief`, one line, always in this order)

`BPM · key/mode · progression (chords, one bar each unless said) · feel (swing, groove) · drums · bass · harmony · lead/arp · form (what enters when)`

> 122 BPM · F major · Gm7–C7–Fmaj7–Bbmaj7 · swing 18 · four-on-the-floor, open hats on offbeats, 16th closed hats · octave-bounce bass · offbeat electric-piano stabs · robotic 8th arp · 4-bar entries (hats+stabs, +kick/bass/claps at bar 5, +arp at bar 9)

`dj_inspired` records it in the share's note; with `dj_compose` put it in `name`/your reply.

## 4. The roll

**Grid**: sixteenth-note steps. 16 steps = one bar of 4/4, step 0 = bar 1 beat 1, a beat = 4 steps,
offbeat eighths = 2, 6, 10, 14, the "e/a" 16ths = odd steps. Bar n starts at step 16·(n−1). `tempo`
(BPM, top-level), `swing` 0–100, `steps` = the roll's total length (default: the longest part, to
whole bars; max 1024 = 64 bars). Everything loops over `steps`.

**A note**: `[step, midi, dur?, vel?]`. `dur` in steps (default 2 tonal, 1 drums), `vel` 1–127
(default 100), middle C = 60. Drum parts may omit the pitch: `[4]` = a hit on step 4.

**Parts are keyed by role** (the only keys the deck understands):

| role | channel | default instrument | register / default note | velocities |
|---|---|---|---|---|
| kick | 10 | drums | GM 36 | 110–125 |
| snare | 11 | drums | GM 38 | 95–115 |
| hihat | 12 | drums | 42 closed, **46 open** (omit = 42) | 50–90, accent the beat |
| clap | 13 | drums | GM 39 | 95–110 |
| bass | 6 | sub-bass | MIDI 28–52 | 95–120 |
| melody | 4 | square-lead | 60–96 | 90–110 |
| harmony | 7 | warm-pad | 48–72, ≤ 3 notes a chord | 55–75 |
| arp | 5 | electric-piano | 60–90 | 70–100 |

Other drum notes (toms, crashes, rides) are not mapped by the deck: use the five above.
**Instruments** are beats' names; omit for the role default. Drums: drums, drums-808, drums-v8,
drums-lofi, drums-cr78, drums-breakbeat. Bass: bass, sub-bass, acid, reese, fm-bass, drop-bass, 808-bass,
rubber-bass, duo-bass, wobble-bass (**the wub**). Leads: lead, square-lead, pwm-lead, sync-lead, supersaw,
detuned-saw, trance-lead, big-saw, hoover, scream-lead, screech, wobble-lead, tape-lead, chiptune,
distorted-lead, duo-lead. Keys/plucks: piano, electric-piano, organ, rave-organ, harpsichord, clavinet,
marimba, vibes, kalimba, music-box, fm-bell, am-bell, pluck, bright-pluck, muted-pluck, edm-pluck,
edm-stab, rave-stab. Pads/other: warm-pad, dark-pad, glass-pad, am-pad, pad, strings, choir, brass,
sax, trumpet, flute, acoustic-guitar, electric-guitar, distorted-guitar, sitar, steel-drum, laser.
Put `instrument` on the part's first segment.

**Chords**: notes on the same step play together (the app spills them into `harmony-b`, `-c`… under
the same role). Keep ≤ 3 per step; more is dozens of rings.

**Patterns** (write a bar once, don't type 16): a part is a segment or a list of segments
`{from?, every?, until?, instrument?, notes}`. Without `every`, notes sit at `from` + step. With
`every: N`, the notes (steps relative to the pattern) recur every N steps from `from` up to `until`
(default `steps`; a repeat needs `until` or the roll's `steps`). A part enters later with a bigger
`from`. A 4-bar chord loop is one segment with `every: 64` and 4 bars of notes. See `example.json`
here (16-bar house; a test keeps it valid):

```json
{"deck":"A","name":"Example House","tempo":124,"steps":256,"parts":{
  "kick":[{"every":16,"until":256,"notes":[[0],[4],[8],[12]]}],
  "clap":[{"from":64,"every":16,"until":256,"notes":[[4],[12]]}],
  "bass":[{"from":64,"every":64,"until":256,"notes":[[2,45,2],[6,45,2]]}]}}
```

## 5. Form (what "standard format instead of a loop" means for a roll)

A roll **loops** over its `steps`. For a song, write the arrangement into the roll by when parts
enter (`from`) and leave (`until`, or a gap):

| bars | section | typical |
|---|---|---|
| 1–4 | intro | kick + hats (+ pad) |
| 5–8 | build | + bass, clap/snare, arp; snare roll in the last bar (16ths, rising velocity) |
| 9–16 | drop | everything, the hook/wubs, a fill in the last bar |
| 17–24 | breakdown | pad + lead, no kick/bass (drums out 1–2 bars) |
| 25–32 | build → drop 2 | as 5–16, bigger |
| last 4 | outro | strip back to kick/hats |

A 16-bar sketch (build + one drop) is fine for "a track"; for "standard" aim 48–64 bars (≈ the
generator's 112 s). The generator's own `structure: "standard"` (`dj_generate` / `dj_load_share`
with `{genre, seed, structure}`) gives the full seven-section song with no notes from you.

## 6. Genre cheat sheet (starting points, not rules)

| style | BPM | key / mode | drums | bass | harmony / lead | form notes |
|---|---|---|---|---|---|---|
| house | 120–126 | minor 7ths (Am7, Dm7) | 4otf, clap 2&4, offbeat open hat | offbeat 8ths / octave bounce | offbeat stabs, piano riff | 4-bar entries |
| French / disco house | 118–124 | major 7ths, ii–V–I | 4otf, 16th closed hats, swing 15–20 | octave bounce, ghost notes | electric-piano stabs, robotic arp | filter-build loops |
| techno | 128–138 | minor, one chord | 4otf, offbeat hats, rimshot ghosts | rolling 16ths in kick gaps | dark pad, 1–2 bar stab | long builds |
| hard techno | 145–160 | phrygian ♭2 minor | heavy kick, 16th hats, distorted | rolling or reese | industrial stab, siren lead | no breakdown, constant drive |
| trance | 134–140 | minor, i–VI–III–VII | 4otf, offbeat hat, snare roll | offbeat 8ths | supersaw 16th arp, long breakdown | 8-bar build, anthem |
| hard trance | 145–155 | minor | hard kick, 16th hats | rolling / wobble | supersaw anthem, trance-lead arp | short breakdown |
| progressive / festival EDM | 124–130 | major, I–V–vi–IV | 4otf, clap | plucked sub, sidechained | piano/saw chord riff | 16-bar build, drop |
| dubstep / brostep | 140 (half-time) | minor, root-heavy | kick 1 (+3.5), snare 3 | **wobble-bass wubs**: 8ths / 16ths / 3-3-2 | screech stabs, pad intro | 8-bar build, drop |
| drum & bass | 170–176 | minor | kick 1 & 2.5, snare 2 & 4, 16th hats | reese / sub, half-time feel | pad, stabs | 16-bar sections |
| trap | 130–150 (half-time) | minor | sparse kick, snare 3, hat rolls (16ths, triplet-ish) | 808 glides | bell/pluck melody | 8-bar loops |
| lo-fi hip-hop | 70–90 | 7th chords | lazy kick/snare, swing 25–35, soft hats | upright-ish bass | electric-piano, vibes | loop + variation |
| synthwave | 100–118 | minor, i–VI–III–VII | gated snare, 4otf, 16th hats | driving 8ths | arp + pad, lead | 4-bar riff |
| funk / disco | 100–120 | dorian / mixolydian | 16th hats, ghost snares | syncopated 16ths | clavinet, strings | groove loop |
| ambient | 60–90 | modal | none / soft | long sub | pads, bells, slow arp | evolving, long notes |
| jazz / bossa | 110–140 / 130 | ii–V–I, 7ths/9ths | brushes, ride feel (hat), swing | walking quarters | piano comping | head–solo–head |
| speedcore | 180–250 | minor | kick every 8th, distorted | screech | none | blunt, short |

## 7. Procedure

1. **Read the ask** against section 1 (tool, deck, artist vs generic, loop vs standard).
2. **Write the style card** (section 3). Choose key, progression, tempo first, then parts.
3. **Write the roll** with patterns; check chord notes ≤ 3, bass 28–52, one drum role per hit type,
   `steps` a whole number of bars, every part's `until` ≤ `steps`.
4. **Call the tool** with `deck`, `name`, `tempo`, (`swing`), `steps`, `parts` (and `inspiredBy` +
   `brief` for `dj_inspired`). It saves the track automatically (`saved` in the reply; folder
   `~/Library/Application Support/dj-vevr-se/compositions/`, listed by `dj_compositions`).
5. **Report**: what you wrote (tempo, key, progression, form, what enters when), the deck, that you
   haven't heard it, and the `saved` path. If `dj_state` shows a BPM different from `tempo`, the deck's
   pitch fader is off centre (the Inpulse's hardware fader), say so rather than "fixing" it.
6. Start playback only if asked (or the deck was already playing). Don't overwrite a playing deck
   unasked unless the user named it.

## 9. Sets (pre-roll a night, queue it, mix it)

A **set** is a named plan of slots on an energy curve, each slot filled by a saved composition.
Files: `~/Library/Application Support/dj-vevr-se/sets/<name>.json`. Order of work:

1. **Plan the curve.** `dj_set {action:"plan", set:"fri", count:6, shape:"arc", bpm:[124,150]}`
   (shapes: `arc` warm-up → peak → cool-down, `rise`, `plateau`), or explicit
   `slots:[{label, energy 0–1, bpm?, key?, bars?}]`. Tempo steps between neighbours should stay within
   ±8 % (the pitch fader; half/double time also counts) so every hand-off can be beat-matched.
2. **Pre-roll the tracks, don't load them.** Each `dj_compose` / `dj_inspired` / `dj_import` call takes
   `load: false`, `set: "fri"`, `slot: N`, `energy`, `key` ("A minor"). It saves the track, fills the slot,
   touches no deck. Compose to the slot's brief (energy, tempo, key, `bars`). Keep neighbours in
   compatible keys (same, relative, or a fifth apart) and write each track as a full form (section 5)
   with an intro and an outro long enough to mix in and out of (≥ 8 bars each side).
3. **Sequence.** `dj_set sequence` fills the plan from *everything saved* by energy, then tempo, then
   key distance, and returns `gaps` (a slot nothing fits, with the exact brief to compose) and
   `tempoJumps` (neighbours the fader can't match). Compose the gaps, `sequence` again.
4. **Start and mix.** `dj_set start {set, deck:"A", play:true}`, then `dj_set mix {set, fadeBars?}` when
   you want the next track: it loads it on the idle deck with its bass EQ down, starts it, tempo- and
   bar-aligns it, crossfades (default 8 bars) with the bass handed over at the midpoint, stops the old
   deck. It returns at once; `dj_set status` shows phase, progress, warnings (tempo gap) and the bar.
   `wait: true` blocks until done. Mix when the current track is in its outro (`status.bar` vs
   `barsInTrack`); the app does not advance by itself yet.
5. **Report** the plan as a table (slot, label, track, tempo, key, energy), any gaps, and warnings.

Words: "warm-up / build / lift / peak / cool-down" are the plan's slot labels. A set has no hard length;
6–10 tracks of 36–64 bars is a night. Sets never publish anything.

## 8. Not supported yet

Auto-advancing a set without `dj_set mix` (the auto-mix runner is next), tempo changes inside a roll, per-bar time-signature changes, drums beyond kick/snare/hat/clap, vocals,
and lyrics. Live filter sweeps and risers are performed (`dj_perform` macros / FX), not written.
