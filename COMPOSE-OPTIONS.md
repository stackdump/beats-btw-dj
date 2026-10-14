# Composition options (dj-only, opt-in)

Techniques for A/B-ing generated tracks by ear. All of them are **off by default**: a spec
without them composes exactly what beats composes (the parity fixtures run that path), and
its share / session CID is unchanged. Code: `Sources/DJCore/Beats/Generator/Techniques.swift`
(the techniques), `Sources/DJCore/ComposeOptions.swift` (validation, storage).

## Where they go

- **Control socket / `djctl ctl generate` / MCP `dj_generate`**: an `options` object, or the
  same keys flat next to `deck`/`genre`/`seed`/`structure`. Values are validated; unknown keys
  are an error. The deck's state shows them under `options`.

  ```sh
  djctl ctl generate '{"deck":"A","genre":"edm","seed":4242,"structure":"standard",
                       "options":{"hook":true,"chordSnap":"strong","layerBudget":"auto"}}'
  ```

- **Offline, no app**: `djctl render <genre> <seed> <out.wav> --structure standard
  --options '{"hook":true}' [--mute r,…] [--solo r,…]` composes and renders on one deck and
  prints the share CID and peak/RMS.

- **Share payload / session**: options live in `TrackSpec.extra`, which `TrackSpec.payload`
  writes under the envelope's `traits` object — e.g.
  `{"genre":"edm","seed":4242,"structure":"standard","cohesion":"v2","traits":{"hook":true}}`.
  So the share CID (and a session's CID) reflects them, and a session replays them.
  Options that are off are not written.

### Compatibility

`traits` is an object of compose params every loader already spreads into `compose`'s
overrides, and `compose` ignores keys it does not know: an older dj build or beats loads such
a share without error — **but plays the track without the technique** (same envelope, other
notes). `ghostNotes` and `syncopation` are stored under beats' own keys (`ghost-notes`,
`syncopation`), so beats honours those two.

## The options

| key | values | what it does |
|---|---|---|
| `hook` | bool | One 1–2 bar hook per track (its own rng, seeded by genre + seed), built as chord-tone targets and played against the chord plan: each bar moves its targets onto the nearest tone of the chord sounding there, so the shape stays and every note is a chord tone. Melody plays it in **every** section it is active in, varied per section: intro/pre-chorus/breakdown/outro Fragment (first half), buildup Transposed (a third up, still on chord tones), verse/drop/chorus Play, bridge Inverted, solo Augmented (half speed). The arp plays it too where the energy table gives the arp a motif mode. The hook ignores the tension curve's register shift (which would put it in another key). |
| `hookBars` | 1 \| 2 | Hook length (default 2: a call, then an answer that repeats the call's first half and comes home to the root). |
| `chordSnap` | off \| strong \| all | Melody notes on beats 1 and 3 (`strong`) or on every beat (`all`) move to the nearest pitch of the chord sounding there (`theme.plan`; with cohesion off, the plan cohesion v2 would build). A ring shorter than the plan cycle is first tiled out to it, so it can follow the chords. `true` = `strong`. |
| `chordSnapArp` | bool | Snap the arp as well (only with `chordSnap`). |
| `layerBudget` | `"auto"` \| 1–8 | At most N melodic roles per section (keep order: bass > melody > harmony > arp). `auto`: intro 1, verse 2, pre-chorus 2, buildup 2, drop 3, chorus 3, breakdown 1, bridge 2, solo 2, outro 1. Done in the section template after the slots are composed: dropped roles get no slot there (the structure nets mute them); no nets are removed and nothing else changes. Song mode only. |
| `bassFollow` | bool | Bass repeats one pattern per chord-plan cycle across all sections. Cohesion v2: every bass slot is the same chord-root ring (no per-phrase tension register/velocity changes). Otherwise: one seeded Markov bass bar played on each chord's root, instead of a new random line per slot. |
| `keyLock` | bool | The tension curve's per-phrase `registerShift` is in semitones and moves the scale's root, so B phrases play a whole tone up and C phrases a minor third down — in another key than the bass and pad. With `keyLock` they stay in key (velocity and density changes remain). |
| `melodyDensity` | (0, 1] | Overrides the genre's melody density. Also thins motif cells (cohesion v2's motif ignores density) to `density × 16` notes per bar, strongest steps kept, and sets the hook's notes per bar. |
| `bassDensity` | (0, 1] | Overrides the genre's bass density (Markov bass lines). |
| `ghostNotes` | 0–1 | The hi-hat ghost-note density (beats' `ghost-notes`). |
| `syncopation` | 0–1 | beats' `syncopation` (base bass/melody lines). |
| `humanize` | 0–100 | The project's humanize (genre default otherwise). |

None of them draws from `compose`'s own rng, so switching one on does not reshuffle the
other roles' seeds.

## Stems for listening tests

`djctl export <cid> <out.wav> --mute melody,arp` / `--solo drums,bass` (and the same flags on
`djctl render`) leave roles out of the render without touching the session or its CID: each
net deck compiles with `WaveOptions.roleFilter`, which drops the matching nets' note
bindings and leaves the nets running. Names match a net's id, its riff group (`bass` for
`bass-3`) or its mixer group (`drums`, `bass`, `melody`, `arp`, `harmony`, `stinger`);
drum fills count as `drums`.
