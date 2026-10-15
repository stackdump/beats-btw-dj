# A/B kit: edm · seed 4242 · structure standard

Rendered offline (no app) with `djctl render` from the `compose-experiments` branch:
one deck, played from the first frame to the end of the song plus a 2 s tail, 44.1 kHz,
16-bit stereo, through the same `SessionPlayer` path as the app's Export. Options are
described in [COMPOSE-OPTIONS.md](../../COMPOSE-OPTIONS.md). Re-render with `./render.sh`
(after `swift build -c release --product djctl`); `render.log` is the last run.

Song: intro 64 · verse 192 · buildup 192 · drop 192 · breakdown 64 · drop 192 · outro 64
steps at 138 BPM.

| file | `--options` | render flags | share CID | length | peak dBFS | RMS dBFS |
|---|---|---|---|---|---|---|
| 00-baseline.wav | `{}` | | z4EBG9jCwTkTjJNAK4dXaooZH8xPC9q9NuBmEZUJxoX59jMLYcB | 106.35 s | -4.54 | -19.37 |
| 01-hook.wav | `{"hook":true}` | | z4EBG9j9MvXADd4hZpJerAFBj6NsN6d6esGZZnWeZgaVim9zicd | 106.35 s | -4.07 | -19.39 |
| 01b-chordSnap.wav | `{"chordSnap":"strong"}` | | z4EBG9j7YyVKxpJjWoRg6bQquLBSG4j3DuLsXG3f4faa5ECRReX | 106.35 s | -4.48 | -19.37 |
| 01c-keyLock.wav | `{"keyLock":true}` | | z4EBG9jFszVppzu4bP29YVv9DVL2TLoDb7qrf4mSDLy8nXwTfE3 | 106.35 s | -4.52 | -19.38 |
| 02-hook+chordSnap.wav | `{"hook":true,"chordSnap":"strong"}` | | z4EBG9j44GJVfgZMNRrc4vfxqoLryCTJfx8TkngxUd3B8aLLjDa | 106.35 s | -4.07 | -19.39 |
| 03-hook+chordSnap+layerBudget-auto.wav | `{"hook":true,"chordSnap":"strong","layerBudget":"auto"}` | | z4EBG9j2GqNwFMgAQAquJEVV5jr3jb4Gh3yrazETjB2P1c5Rn2c | 106.35 s | -4.07 | -19.47 |
| 04-all.wav | `{"hook":true,"chordSnap":"strong","layerBudget":"auto","melodyDensity":0.35,"ghostNotes":0.1,"bassFollow":true}` | | z4EBG9j8CLGVUD8BcvXQ9FRpZsBJRCBKWXfnTUkUwHrh4XKama1 | 106.35 s | -4.84 | -19.51 |
| 04-stem-drums+bass.wav | as 04 | `--solo drums,bass` | (04's) | 106.35 s | -4.36 | -19.60 |
| 04-stem-drums+bass+melody.wav | as 04 | `--solo drums,bass,melody` | (04's) | 106.35 s | -4.44 | -19.57 |
| 04-stem-no-melody.wav | as 04 | `--mute melody` | (04's) | 106.35 s | -4.59 | -19.55 |

Stems apply role mutes at render time (`RoleFilter`): the spec and its CID are 04's.

## Things to know while listening

- **02 is byte-identical to 01.** Every hook note is already a chord tone, so `chordSnap` has
  nothing to move in the melody (it does not touch the arp unless `chordSnapArp` is set).
  `01b-chordSnap` is chordSnap alone, on the cohesion-v2 motif.
- **01c-keyLock** is an extra: beats' tension curve shifts B/C phrases by +2 / −3
  *semitones* (`registerShift` moves the scale root), so in this track those melody and arp
  phrases play in B minor / F♯ minor over the A-minor bass and pad. `keyLock` keeps them in
  key. The hook (01–04) and `bassFollow` (04) already avoid it.
- **The melodic roles are quiet.** Solo levels from this render path: drums RMS −19.7 dBFS,
  melody −37.2, bass −36.7, harmony −35.3, arp −45.1 dBFS. So the whole mix is mostly drums,
  and the RMS column above hardly moves between files. Listen to the stems, or turn it up.
- **Not quite bit-stable:** repeated renders of the same spec sometimes differ by ±1 LSB in
  a few thousand samples (seen on the no-options baseline, so not from these options; the
  cause isn't tracked down). It's inaudible.
