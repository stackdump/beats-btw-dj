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

## Log

| genre | seed | build | verdict | first wrong | device | notes |
|---|---|---|---|---|---|---|
