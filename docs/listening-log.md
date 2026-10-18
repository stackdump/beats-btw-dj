# Listening log

ROADMAP 6.1. The numbers in `docs/musicality-notes.md` say what changed; this log says what a
person heard. One row per (genre, seed, build, device), written by the person who listened —
never by a script or an agent. `scripts/listening-log.py` reads it:

```
scripts/listening-log.py check            # every row well-formed (exit 1 names the line)
scripts/listening-log.py missing          # catalogue genres with no seed-42 verdict yet
scripts/listening-log.py rank             # first complaints → stage order 6.2 … 6.6
scripts/listening-log.py from-picks F     # blind A/B picks (JSONL) → draft rows to fill in
scripts/listening-log.py selftest         # the script's own checks
```

## Columns

| column | values |
|---|---|
| genre | a catalogue genre (`Resources/beats/tables.json` → `genres`) |
| seed | an integer; 42 is the panel seed every genre needs |
| build | the app / `djctl` build id (`BuildInfo`: short commit, `-dirty` allowed), or `dev` |
| verdict | `track` (a listener calls it a track), `loop` (music, but it doesn't go anywhere), `broken` (something is wrong enough to stop listening) |
| first wrong | the first thing wrong, in the audit's dimensions: `form`, `harmony`, `melody`, `groove`, `arrangement`, `sound`, `mix` — or `none` |
| device | `monitors`, `headphones`, `phone` (6.6's translation check: one row per device) |
| notes | free text, no pipes; what it was, the moment it went wrong, what was compared |

`rank` maps the first complaint to the stage that owns it: form and arrangement → 6.2, harmony
→ 6.3, melody → 6.4, groove → 6.5, sound and mix → 6.6. A `broken` counts twice. A stage the log
never names is a candidate to drop (ROADMAP 6.1).

## Translation check

ROADMAP 6.6. `djctl render <genre> <seed> --translate` plays each part soloed through
approximate phone, headphones and monitors curves (each names its source) and folded to mono,
and flags a part more than 12 dB under its full-range level (`Translation`). The numbers say
where to listen; the rows say what was heard. Listen to the same build on each device and add
one row per device, from this template:

```
| <genre> | 42 | <build> | <track/loop/broken> | <first wrong> | phone | flagged by --translate: <parts or none>; <what was heard> |
```

## Pending

Waiting for a listener; an agent never fills these in. Each says what to play and what the
numbers were; the row goes in the log below once someone has heard it.

- **6.7 first set** (not published; publishing waits for the user). Built with
  `djctl mix techno:42 house:42 trance:42 edm:42 … --xfade 24 --report --export
  .build/listen/first-set.wav --publish --dry-run` (add tracks until it runs ≥ 600 s). The bar
  `--report` holds it to: ≥ 600 s, every crossfade step ≤ 2 LU (8 s alone before against
  after), true peak ≤ −1 dBTP. Listen through each crossfade on monitors and headphones; one row
  per (genre, seed) heard, notes naming the transition (`into N`) and its reported step.

## Log

| genre | seed | build | verdict | first wrong | device | notes |
|---|---|---|---|---|---|---|
