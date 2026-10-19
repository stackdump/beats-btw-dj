# dj-vevr-se — the manual

*Written 2026-10-18 against commit `c36dc78` on `integrate/roadmap`. It describes that build,
which is ahead of `main`. Anything marked **experimental** works in the app but has not been
checked by ear (or, for visuals, on a live screen). Controller bindings marked **not yet
verified on the hardware** come from another unit's mapping or an assumption, and have not been
seen on the real device.*

## Contents

1. [What it is](#1-what-it-is)
2. [Getting started](#2-getting-started)
3. [Decks](#3-decks)
4. [The deck sections](#4-the-deck-sections)
5. [The loops row](#5-the-loops-row)
6. [The FX unit](#6-the-fx-unit)
7. [Visuals](#7-visuals)
8. [Controllers](#8-controllers)
9. [Sessions, the journal and notes](#9-sessions-the-journal-and-notes)
10. [Sound and levels](#10-sound-and-levels)
11. [Files and settings](#11-files-and-settings)
12. [Controlling it from Claude or scripts](#12-controlling-it-from-claude-or-scripts)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. What it is

dj-vevr-se is a two-deck DJ app for the Mac. Each deck plays either an audio file (a **sample
deck**, a scratchable turntable) or a **live net**: a track that is composed on the spot from a
genre and a seed number and played by the app as it goes.

The idea behind the live decks:

- **Every track is a known configuration.** Genre, seed, structure, sound palette, instrument
  picks, muted parts and the deck's knobs together name one piece of music. The same
  configuration always sounds the same, so you can come back to it, star it, or share it.
- **You poke; the app moves to a nearby configuration.** Turning the seed wheel, pressing Next,
  picking another instrument, muting a part, firing a macro or jumping to a section are all
  small moves. The app recomposes and lands the change on a musical boundary — the next beat,
  bar or phrase — instead of cutting the audio wherever you happened to press.
- **Your choices stick.** A part you disabled stays out of every new track, an instrument you
  picked keeps being used, and a palette carries into the next seed.
- **Everything is recorded.** Every press, from the screen, a controller or a script, goes into
  a journal. A run can be replayed, rewound to an earlier point, or recorded as a set and
  exported to WAV.
- **Wander** is the same walk made automatic: the deck makes one move per phrase on its own,
  within limits you set, while you steer.

---

## 2. Getting started

### Launching

Open `DJApp`. The window opens dark, at a size that shows both decks with their sections. Both
decks start with the built-in demo loop loaded. Closing the window quits the app (a deck keeps
playing only while the app runs).

The bottom-right corner shows the status line (sample rate, or what the app is doing), the last
MIDI message received, and the build id.

### The window

| Area | What it holds |
|---|---|
| **Deck A** (left) and **Deck B** (right) | Each deck's core — title, platter, position and tempo, transport, hot cues, the song (for a net), the channel strip — and its **sections** (Perform, Wander, Master FX, …). |
| **Mixer** (centre) | Master level and meter, headphone level and cue/mix, the Sync panel, the crossfader. |
| **Panels under the decks** | Shown when switched on: the FX unit, the Soundboard, the loops row, the controller views, the scopes. |
| **Bottom bar** | Connected controllers, panel toggles, Record / Export WAV… / Publish…, status. |

**Wide and narrow windows.** In a wide window each deck has two columns: its core next to the
mixer, its sections on the outer side (deck A's on the left, deck B's on the right). In a
narrower window the sections stack under each deck's core. When the content is taller than the
window it scrolls; the bottom bar stays put. The minimum window is 720 × 460.

**Arrow keys.** Hover the mouse over any row of choices (genres, palettes, paces, stock loops,
favorites, reverb presets…) and the arrow keys step through it without clicking. They are not
taken while you type in a text field.

**Keyboard.** `A` and `B` play / pause decks A and B. `⇧⌘B` (View ▸ Soundboard) shows the
Soundboard.

### The bottom bar

| Control | Does |
|---|---|
| Controllers list | `● <device>` for each connected controller; "none — plug in …" when there is none. |
| **Controllers** | Draws every supported controller as it looks, each control labelled with what it does (Section 8). |
| **Map** | The connected devices' controls as a list, with live LED state; the last control you touched is highlighted. |
| **Soundboard** | Every loop as a big pad (Section 5). |
| **FX unit** | The hands-on FX panel (Section 6). Shows `FX unit ●` while any target's unit is changing the sound. |
| **Check \<device>** | One per connected controller: a guided walk through every control (Section 8). |
| **Pads** | An on-screen copy of the APC mini mk2 grid. If no APC is connected, a virtual one appears and works like the real thing. Shift-click a pad for its SHIFT layer. |
| **Awake** | Keeps the screen from sleeping while the app is open. Remembered between launches. |
| **Scopes** | The analysis panel (Section 7). |
| **Stage** | Opens the Stage window (Section 7). Greyed out until the audio engine has started. |
| **Record** / **● REC** | Records a set (Section 9). |
| **Export WAV…** | Renders the last recorded set to a WAV file. |
| **Publish…** | Publishes the last recorded set (Section 9). |

### Loading a first track

Open a deck's **Generate** section, pick a genre, and press **Generate now**. The track is
composed in the background and starts on the deck (if the deck is already playing, at the next
bar). Other ways in, all in the deck's sections:

- **Load ▸ Audio file…** — any audio file from disk (a sample deck). Its tempo is measured in the
  background.
- **Load ▸ Paste share link** — a beats share link (or its envelope JSON) from the clipboard.
- **Load ▸ Demo loop** — the built-in loop.
- **Load ▸ Stock loops** — the Apple Loops installed on this Mac (GarageBand / Logic content).
- **★ Favorites** — anything you starred earlier.

### Playing and mixing

- Press **▶** (or `A` / `B`) to play and pause.
- Each deck's channel strip has **Vol**, **Filter** (one knob: below centre a low-pass, above it
  a high-pass) and **Pitch** (±8 %).
- The **crossfader** sits at the foot of the mixer: left is A, right is B.
- **Cue** on a deck sends it to the headphones (pre-fader listen). **Phones** is the headphone
  level, **Cue ↔ Mix** blends the cued decks with the master in the headphones.
- The **Sync** panel in the mixer shows each deck's BPM and four beat lamps (the downbeat's lamp
  is wider), and how far the two tempos are apart ("A +2.0 BPM" or "in sync").

The 3-band EQ and the gain trim have no on-screen controls; they are on the controllers (the
Inpulse's EQ knobs and SHIFT + HIGH for gain).

---

## 3. Decks

### Net decks and sample decks

| | Net deck | Sample deck |
|---|---|---|
| Plays | A composed track, live | An audio file, a stock loop or a captured loop |
| Header | "live net · *n* sections" (or "live net · loop") | "audio · *length*" |
| Readout | Time, "bar *x* of *y*", BPM | Time, length, BPM once measured; the playback rate when it is off 1× |
| Shown | The song timeline and the net's rings | A waveform strip |
| Sections | All ten | Perform, Wander and Sound are hidden |

### The deck's core

- **Title and ☆ / ★** — the star adds what the deck plays to your favorites (a net track, or a
  sample that came from a file; the demo loop and captured loops can't be starred).
- **Platter** — turns with the deck; shows the beat in the bar.
- **Transport row** — ▶ / ❚❚, **Cue** (headphones), **LOOP** (record a loop, Section 5).
- **Second row** — the **tap *n*** chip and **⟲ 1 2 4** (Section 5), then hot cues **1–4**.
- **SCRATCH** appears above the transport while the jog wheel holds the deck.

**Hot cues.** Press an empty cue to set it at the playhead; press a set one (lit in the deck's
colour) to jump there. Right-click ▸ **Clear cue *n***. On a net deck a hot cue is a point in the
song, and jumping replays the song's arrangement up to it.

**Disable (lock) a button.** Right-click most deck buttons (play, cue, hot cues, macros, Hits,
Wander, Sync, Q, Next, Panic) ▸ **Disable**. The button greys out and so do the controller
buttons bound to the same action, until you right-click ▸ **Enable**. Locks are remembered
between launches.

### The song (net decks)

- **Song** timeline: the track's sections as coloured blocks, the current one lit, a playhead
  across them. **Click a section to jump to it**; the jump lands at the next bar.
- Beneath it, a row of timeline dots and the **rings**: each ring is one part's one-bar pattern
  as a Petri net, with its tokens moving as it plays.

### Generate, the seed and Next

A net track is genre + seed (+ structure, + how cohesive the parts are). See
[Generate](#generate) for the panel. Ways to move to a nearby track:

| Move | How | Lands |
|---|---|---|
| Next version (same settings, the next seed) | **Next** in Perform when it shows **Next ▶︎**; the Inpulse **LOAD** button; the APC **next track** scene button | Hands over to the track composed in the background |
| A new version at once | APC **regenerate** scene button | At the next bar |
| Seed ± 1 per click | The Inpulse **browser wheel** (not yet verified on the hardware) | At the next bar; a song keeps its place in time, a loop starts from its top |
| Any genre / seed / structure | Generate ▸ **Generate now** | At the next bar if playing |
| Play this next | Generate ▸ **Queue next** | When the song ends (with Auto-next) or on **Next** |

**Next** reads **…** while the next track is still being composed and is greyed out until one is
ready. **Auto-next** (in Generate, or the APC's auto-next scene button) plays the next version
automatically when the song ends.

Your sound choices — the palette, a drum kit you picked, per-part overrides — carry into every
new track the deck makes, by any of these routes.

### Mix in and mix out (net decks)

In **Perform**:

- **Mix out** — at the next bar the deck jumps to the song's outro (or plays on where it is if
  there is none), plays 16 bars of drums and bass, then stops on a bar line.
- **Mix in** — drums and bass only for 4 bars from the next bar, then the melodic parts come
  back.

Each button is lit while it is playing out.

### Sync and tempo

- **Sync** (Perform, net decks) matches this deck's tempo to the other deck and lines up the bar.
  It will take half or double the other tempo if that is closer, and it stays inside the pitch
  fader's ±8 %.
- On the Inpulse, **SYNC** matches tempo and beat, **SHIFT + SYNC** tempo and bar (SHIFT + SYNC is
  not yet verified on the hardware). Its LED is lit while the two decks run at the same tempo.
- **Q: off / beat / bar** (Perform) cycles quantize for cues: a cue set or jumped to snaps to the
  beat or bar grid.
- The Inpulse jog ring and the MPK joystick nudge the tempo for as long as you hold them; the
  deck shows "nudge ±x %".

Sample decks measure their tempo in the background after loading; stock loops use the tempo the
loop declares, so sync works at once.

### Scratching

With the Inpulse, touch the jog top to hold the deck and turn it to scrub — a net deck's clock
runs backwards and forwards with your hand. Let go and it runs on. Turning the outer ring bends
the tempo. **SHIFT + jog** seeks four times as fast.

### Keys (net decks)

The MPK mini's keyboard plays the track's live voice on the focus deck (the one a controller
touched last, or the one the APC is aimed at), snapped to the track's scale, so every key is in
key.

### Copy to deck

**Sound ▸ Copy to deck A / B** loads the same track, with its palette and sound changes, onto the
other deck from its start. (Live sound-panel tweaks and played state don't come with it.)

---

## 4. The deck sections

Under each deck is a strip of toggle buttons; each one folds its panel open or shut. Several can
be open at once, and which ones are open is remembered per deck. A label gets a dot while
something in it is active (**Wander ●**, **Master FX ●**, **Reverb ●**), and Favorites and Notes
show counts (**★ 12**, **✎ 3**).

| Section | Net deck | Sample deck |
|---|---|---|
| Perform | ✓ | — |
| Wander | ✓ | — |
| Master FX | ✓ | ✓ |
| Reverb | ✓ | ✓ |
| Sound | ✓ | — |
| ★ Favorites | ✓ | ✓ |
| Generate | ✓ | ✓ |
| Load | ✓ | ✓ |
| ✎ Notes | ✓ | ✓ |
| History | ✓ | ✓ |

### Perform

**Parts.** One button per part of the track (kick, snare, hihat, bass, melody, …). Click to mute
or unmute it. Right-click ▸ **Disable *part* (stays off through new tracks)** to keep it out of
every track this deck makes until you right-click ▸ **Enable** it; a disabled part shows as
"⊘ *part*", struck through. Disabled parts are remembered between launches. A part glows while a
macro is holding it.

**Net macros** — moves made on the net itself, lit while running:

| Macro | Does | Length |
|---|---|---|
| Drop | Everything but the drums drops out | 1 bar |
| Breakdown | The drums drop out | 2 bars |
| Solo Drums | Only the drums | 2 bars |
| Cut | Everything silent for a moment | two sixteenths |
| Double Drop | Two short cuts, the second just after the first | — |
| Beat Repeat | A stutter (the kick keeps going under it) | 1 bar |
| Half Time | The tempo held at half | 2 bars |
| Tape Stop | The tempo winds down | 1 bar |
| Anchor | The tempo held at the track's own | 2 bars |
| **Panic** | Ends every running macro now | — |

**Hit 1–4** — stingers. Each Hit is chosen for the track from its genre family, sound palette,
seed, key and tempo. Hits 1 and 2 are one-shot sounds (air horn, laser, rave stab, FM bell,
orchestra hit, …); Hit 3 is a macro gesture (a riser, an HP sweep, a tape stop, …) or a one-shot;
Hit 4 is a short sound-effect loop from the stock loops on this Mac (launched on the loops row in
time with the deck) when one fits, else a gesture or a one-shot. A Hit with nothing that fits
plays the track's own stinger part. The same
configuration always gets the same four Hits; hover a Hit to see what it fires. *(Experimental:
the curation is new and has not been checked by ear.)*

Also in Perform: **Wander**, **Mix out**, **Mix in**, **Sync**, **Q: …**, **Next**.

### Wander

Wander makes the deck walk by itself: one move per phrase, drawn from where the track is now.

- **Wander** on/off. Wander starts off at every launch; its pace and locks are remembered.
- **Pace: 4 · 8 · 16 · 32 bars** per move (default 16).
- The status shows "next move in *n* bars", "paused — you're steering (back in *n* bars)", or why
  it stands still.

**When moves land.** A move is taken as the deck enters the last bar of a phrase. A mute or a
macro happens over that bar; a move that changes the track (a new seed, an instrument, a
structure, a genre, a palette) is composed a bar ahead and swapped in at the first bar of the
next phrase, with the transport still running.

**What it can do**, roughly from most to least often: mute or unmute a part; a net macro over the
phrase's last bar; a nearby seed (±1…7); a master FX gesture (sweep, riser, wash, crush); another
instrument on one part with a nearby seed; a STEMS change; a stinger; a neighbouring genre (same
family, nearest tempo); the same seed in another structure; the same song in a neighbouring
palette. About two moves in three change the mix of the track playing; about one in three moves
to another track.

**Lock** — chips for what the walk must leave alone:

| Lock | Means |
|---|---|
| Genre | No genre hops |
| Tempo | Genre hops stay within ±6 % of the tempo playing when you set the lock |
| Key | Keep the scale and root playing when you set the lock |
| Structure | No structure moves; genre hops stay in the family |
| Instruments | No instrument changes; every new seed keeps these instruments |
| Arrangement | No mutes or STEMS changes |
| Fx | No macros, FX or stingers |
| Palette | No palette hops |

**Keep** — one chip per part: its instrument comes with every new seed and no move mutes it or
re-picks it. For a part with a line of its own (bass, drums, melody, arp) the line is kept too, as
long as the walk stays in the same genre.

With everything locked, Wander says so and stands still. It never touches a disabled part or a
button you have disabled. Sample decks don't wander.

**Steering.** Turning the Inpulse browser wheel steps the seed and pauses the walk; it resumes
once a whole phrase has passed without a turn. **SHIFT + wheel** sets the pace, and pushing the
wheel turns Wander on or off for the focus deck. (The browser wheel, its push and SHIFT + wheel
are not yet verified on the hardware.)

**The log.** The moves so far, newest first: number, bar, what it did ("bass off", "drop",
"seed 41 → 44", "techno → house · seed 512"). Moves that changed the track are in the deck's
colour. **☆** on a row stars the track that move led to; click **★** again to unstar it.

### Master FX

The deck's master chain, in three groups. Each button runs a timed gesture and is lit while it
runs; the chain returns to where it was afterwards.

| Group | Macros |
|---|---|
| FX | Sweep LP, Sweep HP, Reverb Wash, Riser, Bit Crush, Phaser Drone, Res Ping |
| Pitch | Octave Up, Octave Down, Pitch Bend, Vinyl Brake |
| Feel | Chill, Drive, Ambient, Euphoric, Build Up, Wind Down, Reset |

- Reverb Wash only does its high-pass move and Riser its high-pass and phaser moves here (the
  reverb part of those gestures is not in this app).
- **Vinyl Brake** slows the deck like a turntable losing power, falls silent for the last quarter,
  then the deck comes back in where it would have been.
- Feel macros move the feel (filter and tempo) toward a corner; **Reset** eases everything back to
  the genre's defaults.
- Sample decks run the same chain: a macro fired on a sample deck starts at the deck's next bar.

### Reverb

Each channel has its own reverb, after the EQ and before the fader.

- Presets: **Off**, **Room**, **Plate**, **Hall**, **Wash**.
- **Wet**, **Size** (shown in seconds), **Tone** (dark … bright).
- LOOP-record takes are always taken dry.

### Sound

**Palette.** A card per sound palette — the sound world the whole track is played with. The
current one is lit. Picking one changes every part at the next bar on the same song, and new
tracks on this deck keep it. A card is greyed out, with the reason, when this Mac doesn't have
what it needs.

| Palette | Sound |
|---|---|
| 🎛️ Studio (default) | Each instrument's own sound: the sampled instrument this Mac has for it, else the synth voice |
| ⚡ Synth | The synth voices and synth kits only, no samples |
| 🌆 Synthwave | Analog polysynths, warm pads, rubbery FM bass, 808 / CR-78, a long bright hall |
| 👾 8-bit | Square and pulse waves, a tight dry room, a little machine kit |
| 🎸 Acoustic band | Piano and guitars, electric or upright bass, organ, a real drum kit |
| 🎻 Orchestral | Strings and brass, harp and pizzicato, timpani, a big hall |
| 📼 Lo-fi tape | Rhodes and Wurli, mellow bass, tape flutes and mallets, a small dark room |
| 🎷 Jazz club | Upright bass, piano or Rhodes, sax / muted trumpet / jazz guitar, brushes |
| 🪩 Club | Acid and reese basses, rave stabs, organ chords, plucks, 909 / 808 drums |
| 🌌 Ambient | Evolving pads and choirs, bells, sub bass, soft drums, long room and echo |
| 🏮 World strings | Guzheng, koto, pipa, erhu, sitar, banjo, flutes, harp |
| 💾 90s sound card 🔒 | Apple's General MIDI bank. Local only |
| ⛏️ Minecraft 🔒 | Note blocks, bells and goat horns built from your own game install. Local only (Section 11) |

🔒 **Local only**: a set that plays these sounds is not published (Section 9).

**Fine-tune *palette*** (folded by default). One row per part: what it "plays" now, the palette's
other options for it, and **instruments…** (for drums, **all kits…**) to override it with any
instrument or installed drum kit. A part you overrode says **your pick** and gets **↺ palette**
to go back. Overrides stay through Next, new seeds and Wander until you reset them. All changes
swap in at the next bar.

**The sound panel.** Hold an instrument button for half a second (or right-click ▸ **Edit
sound…**) to open its sound:

- **Level**, **Attack**, **Decay** (× note, and a max), **Brightness**, **Drive**, **Vibrato**
  (rate and depth), and a **Pitch sweep** (from, to, time — zaps and drops).
- For a sampled instrument these shape its synth voice; **Use synth voice** / **Use sample**
  switches between them. A drum kit only takes a level; a plucked string has no pitch sweep.
- Changes are live on the song playing, no reload. They last for this song on this deck; a new
  song, a relaunch or picking another instrument on that part starts from the instrument's own
  sound. They are never part of a share or a favorite.
- **Reset** returns to the instrument's own voice.
- **Save as variation…** keeps the setting under a name. Saved variations appear as chips after
  their instrument ("laser · short zap"); clicking one picks the instrument (if needed) and
  applies the setting. Variations can be renamed or deleted in the panel and are kept between
  launches. A tweaked instrument without a saved name shows "✎".

**Copy to deck A / B** — see Section 3.

### ★ Favorites

Everything you starred, as chips (a waveform icon for a sample, a net icon for a track). Click to
load onto this deck. A favorite with notes shows "✎*n*", and hovering shows them. Right-click ▸
**Tags…** to tag it, or **Remove from favorites**. With tags in use, a row of **All** / **#tag**
chips filters the list.

A favorite names the exact configuration (by its content id), not just the title, so loading it
plays the same track.

### Generate

- **Genre**: techno, house, jazz, ambient, dnb, edm, speedcore, dubstep, country, blues,
  synthwave, trance, lofi, reggae, funk, bossa, trap, garage, metal.
- **Structure**: **loop** (one looping pattern), **minimal**, **standard**, **extended**.
- **Palette row**: the palette the new track plays from (the deck's own unless you pick another
  here). Greyed-out palettes say why.
- **shared motif** / **free-form**: with shared motif every part shares one theme, chord plan and
  groove; free-form lets each part write its own line.
- **Seed** field, **🔒** (keep the seed after Generate, so pressing it again remakes this track;
  unlocked, the seed moves on to the next version), **Roll** (a random seed).
- **Auto-next**, **Queue next**, **Generate now** — see Section 3.

### Load

- **Audio file…**, **Demo loop**, **Paste share link**.
- **Crates** — your own lists of stock loops. **+ Crate** makes one; drag stock-loop rows onto a
  crate's chip to add them; click the chip to list them (click again for the stock loops);
  right-click ▸ **Delete crate** (the loops stay starred). In a crate's list, right-click a loop ▸
  **Remove from *crate***.
- **Stock loops** — the Apple Loops installed on this Mac: a search field (name, pack, genre),
  category chips, and the list sorted nearest the other deck's tempo first. Each row shows name,
  BPM, key and category; click to load it, or hover the list and use the arrow keys to audition
  through it. **Show *n* more** extends the list.
- **Auto level** — play loaded samples at the same loudness as generated tracks (Section 10). On
  by default; your last choice becomes the default for both decks.

The first scan of the stock loops takes a few seconds ("scanning…"); after that an index is kept.

### ✎ Notes

Notes on what this deck plays, at the bar it is on.

- One-tap notes: **drop**, **build**, **break**, **mix in**, **mix out**, **★**.
- A field "Note at this bar…" and **✎ Note** for your own text.
- The list of this track's notes in track order; right-click ▸ **Edit…** or **Delete note**.

A net track's notes are tied to its configuration, so they come back whenever the same track
(same genre, seed and settings) plays again. A sample's notes follow the file.

### History

The journal's latest lines, newest first (a fader sweep is folded into one row; notes in yellow).

- **Notes only** filters to notes.
- **⟲ Rewind** turns the list into a picker of points you can go back to: marks, notes,
  checkpoints, and regular actions, then older checkpoints from the file. Pick one, read the
  confirmation ("Rewind to *time* — *what happened*? Everything after it is undone; the journal
  keeps it."), and confirm. See Section 9.

The journal's file name is shown at the foot.

---

## 5. The loops row

The loops row appears under the decks as soon as you take your first loop. Every loop is a
**clip**: audio taken from a deck, kept between launches.

### Taking loops

- **Hold LOOP** on a playing deck to record its bars; let go and the take finishes its bar and
  starts looping on the row. The button shows the bar count while it records.
- **Tap LOOP** to record exactly the number of bars on the **tap *n*** chip, from the downbeat.
  Click the chip to step it through 1, 2, 4, 8 (right-click to pick one); it is remembered.
- **⟲ 1 2 4** grabs the last 1, 2 or 4 bars the deck already played, after the fact (from about
  the last 21 seconds).
- The Inpulse **LOOP** button works the same way (hold or tap).

Takes are recorded after the deck's EQ but dry of its reverb.

### The row's header

| Control | Does |
|---|---|
| **Join *n*** | Select loops (○ on each tile), then join them into a sequence, in row order |
| **Stop all** | Every loop out on the next downbeat |
| **Mute** | Mutes the loop channel |
| **Loop vol** | The loop channel's level |
| **Reverb *n* %** | The loop channel's reverb (the takes themselves stay dry) |
| **Fade: off · 10 ms · 1 beat · 1 bar** | How loops come in and go out (10 ms only takes the click off) |
| **🔒 key** | Key lock for every loop without its own setting |
| **Master FX** | Folds open the loops' master FX strip (below) |

Second line: **Launch on: beat · bar · 2 bars · 4 bars · 8 bars** (when loops and scenes come in
and go out; default a bar), **Tempo: louder deck / own deck** (every loop follows the tempo of the
louder playing deck, or each follows the deck it came from; "→ A" says which deck they follow
now), then the scenes.

Third line: **SHOW** filters — **A**, **B**, **Seq** (sequences), **≈ *n* bpm** (only loops within
±5 % of the playing tempo), a search over titles and genre, **Clear** — then **Removed (*n*)** and,
just after a removal, **Undo**.

### A loop tile

- **Click the waveform** (or ▶ / ■) to bring the loop in or out on the next launch boundary.
  A loop waiting to switch shows a countdown ring and "in 3" (or "in 2 bars"); amber while going
  out.
- **Drag either edge** of the waveform to crop it to the beat.
- **Level** slider, **→A** / **→B** to move it onto a deck (it plays there as a sample;
  **↩ back to Loops** on the deck returns it). You can also drag a tile onto a deck, or back onto
  the row.
- **M** mute (it keeps playing silently, in time), **S** solo, **🔒 key** (at another tempo it
  plays a time-stretched copy instead of going sharp or flat: "stretching…", then "stretched"),
  **FX** (its own effects, below).
- **ⓘ** where it came from: the deck and track, the bar and section, tempo, knobs, muted parts,
  macros — plus rename and colour.
- **✕** takes it off the row. It is never deleted: **Undo** for 8 seconds, or **Removed (*n*)** to
  **Restore** it where it was or **Delete forever**.
- **A1…B4** on a tile is the Inpulse pad that switches it in LOOP pad mode (the first eight loops).
- **✎** leaves a note on the loop.
- Drag a tile onto another to put it just before that one; onto a sequence to add it as a step.
  Drag a tile out to Finder to get a WAV.

Right-click a tile: **Rename…** (or double-click the name), **Colour**, **FX** presets, **Load
source on A / B** (reload the track it came from at its section), **Export WAV…**, **Remove**.

**Sequences.** A sequence plays its steps in turn. Each step is a chip: tap it for ×1 → ×2 → ×4
repeats; right-click to move or remove it.

### Loop FX

Effects played on top of a loop, never into it — the recording stays dry. Open them from a tile's
**FX** button or the right-click **FX** menu.

- Presets: **Off**, **Warm drive**, **Crunch**, **Fuzz**, **Crush**, **Loud**.
- **Bypass**, **Auto-level** (keeps the loop's level steady while drive pushes it; on by default).
- **Drive** (0 … +24 dB), **Shape**: clean, soft, hard, tube, fold, crush, with **Amount** (for
  crush: **Bits** and **Rate**), **Tone**, **Mix**, **Trim**.
- A safety limiter on the loop channel keeps the extra gain from clipping. A loop with FX on shows
  an **FX** badge.
- A loop moved onto deck A or B keeps its FX. Scenes recall a loop's FX if it had any when saved.

### Scenes

**Save scene** keeps the loops playing now (with their levels and FX) as a chip. Tap a chip to
launch it: exactly its loops come in and the others go out, on one boundary. A chip is lit while
exactly its loops play. Right-click: **Rename…**, **Overwrite with the loops playing now**,
**Delete**. Scenes are saved with the row.

### The loops master FX (channel L)

The loops are a third channel, **L**, after they are mixed together. Its **Master FX** strip
(**LOOPS MASTER FX**) offers the same FX, Pitch and Feel macros as a deck, applied to all the
loops at once, landing on the next launch boundary (at most a bar). Feel macros only move the
filter here (no tempo change).

- **Link to decks** — a master macro fired on deck A or B also fires on the loops, at once, and a
  deck's Panic releases them.
- **Panic** — stops every master macro on the loops.
- On the APC, SHIFT + either aim button aims the controller at L (Section 8).

### The Soundboard

**Soundboard** (bottom bar, or View ▸ Soundboard, ⇧⌘B) shows the loops as big pads, with three
pages:

- **Row** — every loop on the row, with the scenes above. Click a pad to bring it in or out on the
  next launch boundary; **⌥-click** solos it, **⇧-click** mutes it. Hover the board and use the
  arrow keys to move between pads, Return or Space to toggle. Right-click for **Play / Stop**,
  **Rename…**, **Colour**, **Mute**, **Solo**, **Key lock**, **Launch on / Fade / Tempo (this
  loop)** — a loop can have its own rules instead of the row's — **Fade (all loops)**, **Move to
  deck A / B**, **Back under the mixer**, **Settings…** and **Remove**.
- **Stock** — the Apple Loops on this Mac nearest the decks' tempo. Click one to put it on the row
  (it comes in on the next launch boundary); click again to take it out.
- **Crate** — a crate's favorites as pads. Click to load onto a deck; ⌥-click for the other deck.

**Settings…** opens everything about a loop in one place: name and colour, a sequence's steps,
**Edges** (crop), **Sound** (level, mute, solo, key lock), **FX**, **This loop** (its own launch,
fade and tempo — "row" follows the loop channel's), **All loops**, **Where it plays**, **Where it
came from**, and **Tune its instruments**: for a loop taken from a net, **Retune this loop** picks
other instruments for its parts and renders its bars again with them (it keeps its place, level
and FX, and carries on in phase).

### Stock loops on the row

A stock loop put on the row plays like any other loop, but a set with one on the row can't be
published (Apple's licence covers playing them in your music, not distributing them).

---

## 6. The FX unit

**FX unit** in the bottom bar opens a hands-on FX panel under the decks. It controls one target
at a time: **A**, **B** or **L** (the loops, after they are mixed). Until you pick one it follows
the focus deck ("· follows focus"). A target shows "●" while its unit is changing the sound.

| Control | Does |
|---|---|
| **Filter** (big knob) | One bipolar filter: left low-pass, centre off, right high-pass |
| **XY pad** | Across: the filter. Up: the control picked under it — **Crush**, **Drive**, **Phaser**, **Room** or **Echo**. Double-click: both off |
| **HP**, **LP** | High-pass and low-pass cutoff |
| **Phaser**, **Depth**, **Rate** | Phaser mix, depth (octaves), rate (Hz) |
| **Pitch** | ±12 semitones |
| **Crush**, **Drive** | Bit crusher, distortion |
| **Room**, **Echo**, **Feedback** | A net deck's own room and tempo echo (up to 4× the genre's level) |
| **On beat** | Kill and Reset wait for the target's next beat |
| **Kill** | Bypass the unit (its knobs stay where they are); again to bring it back |
| **Reset** | Every knob back to neutral |
| **MACROS** | The FX, Pitch and Feel master macros for the target |

**Using the knobs.** Drag a knob up or down; double-click it to reset. Every move glides over
about 30 ms and is not quantised (only Kill and Reset can wait for a beat).

**Which controls work where.** The chain controls (filter, HP, LP, phaser, pitch, crush, drive)
work on every target. **Room**, **Echo** and **Feedback** are only on net decks — and only when
the song has a room or the genre has an echo; otherwise they are greyed out and say why ("this
song has no room", "this genre has no echo"). Sample decks and the loops use the Reverb section
instead.

**With the macros.** A master macro rides on top of the unit's setting and returns to it: the
chain hears the more processed of the two (the higher HP, the lower LP, the larger phaser / crush
/ drive), and pitch adds. With the unit at neutral, macros behave exactly as they do without it.

The unit's settings are part of the deck's state, so recorded sets and journal replays play them
back.

An APC fader layout for the FX unit is planned (faders → filter, HP, LP, phaser mix, crush,
drive, pitch, room; master unchanged) but not built yet.

---

## 7. Visuals

*Experimental: the scopes and the Stage are tested by rendering them off screen but have not
been checked in a live window yet.*

### On the decks and mixer

- **Platter**, **waveform strip** (sample decks), **song timeline** and **rings** (net decks).
- The **master flame** under the Master slider: equalizer bars of the master output, a flat line
  while nothing plays.

### Scopes

**Scopes** in the bottom bar opens the analysis panel:

| View | Shows |
|---|---|
| **Scope** | The waveform and the fired notes on one time axis (rolling 4 bars) |
| **Spectro** | A log-frequency spectrogram of the model; with **measured**, the real audio below it |
| **Bands** | Per-bar energy in each band; with **measured**, the real audio's |
| **Raster** | A score of the whole arrangement, sections marked |

Pick the source: **A**, **B** or **Master**. The **◐ Visuals** menu sets the quality: **Auto**
(reduce when the app lags), **Full**, **Reduced** (15 fps scopes), **Minimal** (8 fps, no
flashes), **Paused** (4 fps). When Auto reduces the visuals a notice appears at the foot of the
window, with **Keep full visuals** to pin them.

### The Stage

**Stage** opens a full window that draws the playing nets: each part is a panel (a ring of its
one-bar pattern) around one big loop. Click **•** (top left) for the menu:

- **Source**: **A**, **B** or **Master** (both decks).
- **Visualizer**: **Constellation**, **Corona**, **Sonar**, **Petal**, **Blocks**, or **🔀
  Shuffle** (changes every so often). **← / →** cycle through them.
- Layers (Constellation only): **◌** Flow, **◎** Pulse, **▼** Flame, **⊝** Tilt, **⇄** show all
  slot variants, **■** panel backgrounds, **A** labels, **⚡** lightning during macros,
  **∿ Wander**.
- **✎** flashes the share card on every track change (**T** toggles it).
- **Background**: Void, Stars, Aurora. **Scale**: Fit, S, M, L, XL.
- **?** — "What am I looking at?", a guide to reading the Stage.
- **Esc** closes the help, then the window.

**∿ Wander on the Stage.** On a wandering deck, an arc round the centre fills through the phrase
up to its next move (dashed while the browser wheel holds the walk); each move flashes its caption
at the top, and the last four trail down the bottom left.

**Blocks** is a blocky side-on world driven by the track's arrangement, read ahead of the music:
each section has its own biome and time of day (dawn plains for an intro, night for a drop, a
torch-lit cave for a breakdown…); a buildup lights a TNT fuse that burns down to the drop and
explodes on its first beat; each part is a creature or object that appears and disappears as it
is muted and unmuted (bass a pulsing cube, melody birds, pads clouds, hats fireflies…); fills
break blocks, stingers set off fireworks, macros bring rain; the camera pans to new terrain each
phrase. It is drawn from the song's seed, so the same track draws the same world.

---

## 8. Controllers

Supported: **Hercules DJControl Inpulse 200 MK3**, **Akai APC mini mk2**, **Akai MPK mini mk2**.
All can be connected at once and hot-plugged. When two controls drive the same thing, the last
one moved wins, with soft takeover: a knob has to reach the current value before it takes over.

**The focus deck.** Controls that don't belong to a deck (the MPK keys and joystick, the browser
wheel, everything on the APC) act on the **focus deck**: the deck a controller touched last, or
the one the APC's aim buttons picked.

**Seeing the bindings.** **Controllers** (bottom bar) draws each device with every control
labelled by what it does, in its LED colour; hover a control for all its bindings (per pad mode
and SHIFT layer). A dashed outline means parked on purpose; "?" means not yet verified on the
hardware. **Map** lists the connected devices' controls with live LEDs. **Check *device*** walks
you through every control in turn (move it, or **Skip (silent)**; **Back**, **Stop**) and writes
a report when done (Section 11).

### Hercules DJControl Inpulse 200 MK3

SHIFT and the pad-mode buttons (HOT CUE, FX, SHIFT + HOT CUE for LOOP) are handled by the
controller itself. Pads are numbered 1 2 on the top row, 3 4 on the bottom.

**Each deck**

| Control | Action | Notes |
|---|---|---|
| Jog top (touch + turn) | Hold the deck and scratch / scrub | |
| Jog outer ring | Bend the tempo while turning | |
| SHIFT + jog | Fast seek (4×) | |
| PLAY | Play / pause | |
| CUE | Playing: back to the cue point and pause. Paused: set the cue point here | |
| SHIFT + CUE | Back to the start | Not yet verified on the hardware |
| SYNC | Match tempo and beat to the other deck | |
| SHIFT + SYNC | Match tempo and bar | Not yet verified on the hardware |
| Headphone button | Cue this deck in the headphones | Deck B not yet verified on the hardware |
| LOAD | Next track (lit when one is ready) | Deck B not yet verified on the hardware |
| LOOP | Hold: record the deck's bars as a loop. Tap: record the tap length | |
| STEMS (music) | Mute the non-drum parts; again to bring them back (net decks) | |
| STEMS (mic) | Mute the lead; again to bring it back (net decks) | |
| SHIFT + LOOP (VINYL) | No action yet | |
| Volume fader | Volume | |
| FILTER knob | Filter | |
| LOW / MID / HIGH | EQ | |
| SHIFT + HIGH | Gain | Not yet verified on the hardware |
| Pitch fader | Pitch ±8 % | |

**Pads**

| Pad mode | Pads 1–4 | Notes |
|---|---|---|
| HOT CUE | Hot cues 1–4 | Pads 1 and 3 on deck A verified; pads 2 and 4, and all of deck B, not yet verified on the hardware |
| SHIFT + pad in HOT CUE | Clear hot cue 1–4 | Not yet verified on the hardware |
| FX | Pad 1 Cut, pad 2 Beat Repeat, pad 3 Drop, pad 4 Breakdown | Net decks |
| LOOP (SHIFT + HOT CUE) | Deck A: loops 1–4 on the row; deck B: loops 5–8. In / out on the next launch boundary, lit while playing | Deck B not yet verified on the hardware |
| SAMPLER (SHIFT + FX) | Hit 1–4 | Not yet verified on the hardware (the notes this mode sends are unknown) |

The profile also maps a set of pad notes to part mutes (kick, hihat, snare, bass), but those
numbers come from the original Inpulse 200 and the MK3 has not been seen sending them.

**Centre**

| Control | Action | Notes |
|---|---|---|
| Crossfader | Crossfader | |
| MASTER knob | Master level | Which centre knob is master and which is headphones is not yet verified on the hardware |
| HEADPHONES knob | Headphone level | As above |
| Browser wheel | The playing net's seed ± 1 per click, swapped in at the next bar; pauses Wander | Not yet verified on the hardware |
| SHIFT + browser wheel | Wander pace (4 / 8 / 16 / 32 bars), focus deck | Not yet verified on the hardware |
| Browser push | Wander on / off, focus deck | Not yet verified on the hardware |
| ASSIST/PREP, MASTER, BEATMATCH GUIDE buttons | No action yet | |

**LEDs.** PLAY, the headphone button, SYNC (while tempos match), LOAD (while a next track is
ready), LOOP (while recording), STEMS (while muted), set hot cues and playing loop pads light up.

**Audio out.** With the Inpulse's own audio interface present, the mixer shows **Inpulse out (1/2
master, 3/4 cue)**: master on outputs 1/2, the headphone cue on 3/4. Not yet verified on the
hardware.

### Akai APC mini mk2

Use the **Control** port (macOS shows "APC mini mk2 Control" and "APC mini mk2 Notes"; only
Control is used). The APC is an FX surface acting on the **aimed deck**: scene buttons 4 and 5 aim
at A or B; otherwise it follows whichever deck a controller touched last.

**Grid** (rows counted from the bottom; pads light in their group's colour, bright while running)

| Row | Pads (left to right) |
|---|---|
| 1 | Drop, Breakdown, Solo Drums, Cut, Beat Repeat, Double Drop, —, — |
| 2 | Sweep LP, Sweep HP, Reverb Wash, —, Riser, —, —, — |
| 3 | Bit Crush, Phaser Drone, —, —, Res Ping, —, —, — |
| 4 | — (pan macros, not in this app) |
| 5 | Octave Up, Octave Down, Pitch Bend, Vinyl Brake, Half Time, Tape Stop, Anchor, — |
| 6 | Chill, Drive, Ambient, Euphoric, Build Up, Wind Down, Reset, — |
| 7 | — |
| 8 (top) | Hit 1, Hit 2, Hit 3, Hit 4, —, —, —, — |

"—" pads are dark: either a gap in the layout or a macro of the original web app that this app
doesn't have. On a sample deck only the master macros (the FX, Pitch and Feel pads) work; the net
macros (row 1, Half Time, Tape Stop, Anchor) and the Hits are dark.

**Track buttons** (red, below the grid): mute kick, snare, hihat, clap, bass, melody, harmony,
arp on the aimed deck (lit while the part plays).

**Scene buttons** (green, top to bottom)

| # | Action |
|---|---|
| 1 | Play / pause |
| 2 | Regenerate: the next version, at the bar |
| 3 | Auto-next on / off (lit while on) |
| 4 | Aim at deck A |
| 5 | Aim at deck B |
| 6 | FX reset (Feel Reset) |
| 7 | Next track |
| 8 | Panic |

**SHIFT + scene 4 or 5** aims at the loops (L): the faders and macro pads then act on the loops'
master FX, and the A / B aim lights blink. Not yet verified on the hardware.

**Faders**

| Fader | Controls |
|---|---|
| 1 | Phaser wet |
| 2 | Distortion |
| 3 | Reverb wet (the aimed deck's channel reverb) |
| 4 | Reverb size |
| 5 | LP |
| 6 | HP |
| 7 | Master pitch |
| 8 | Crush |
| 9 (master) | Master level |

**SHIFT + grid = the loop page.** Hold SHIFT and the grid becomes loops 1–64, read like text from
the top-left (top row 1–8, the next row 9–16, …). Press a pad to bring that loop in or out on the
next launch boundary. Pads are violet while their loop plays and blink on the way in or out (the
blink is not yet verified on the hardware).

DRUM mode (SHIFT + a scene button on the device) sends notes that are not mapped yet.

### Akai MPK mini mk2

These bindings match the preset measured on the test unit (knobs on CC 1–8, pads as Program
Change). If your MPK's preset differs, they won't line up.

| Control | Action |
|---|---|
| Keys | Play the focus deck's live voice, snapped to the track's scale (net decks) |
| Joystick left / right | Tempo nudge on the focus deck |
| Knob 1 | Unbound (it shares CC 1 with the joystick's up/down; reprogram it in the MPK Editor to use it) |
| Knob 2 / 3 | Deck A / B volume |
| Knob 4 | Crossfader |
| Knob 5 / 6 | Deck A / B filter |
| Knob 7 / 8 | Deck A / B pitch |
| Pads 1–4 (PROG CHANGE) | Deck A hot cues 1–4 |
| Pads 5–8 (PROG CHANGE) | Deck B hot cues 1–4 |
| Pads 1–8, bank A (NOTE mode) | Mute kick, snare, hihat, clap, bass, melody, harmony, arp on the aimed deck — not yet verified on the hardware |
| Pads 1–8, bank B (NOTE mode) | Loops 1–8 in / out (pads 1–4 the bottom row) — not yet verified on the hardware |

---

## 9. Sessions, the journal and notes

### Recording a set

Press **Record** in the bottom bar; it turns into **● REC**. Everything you do on the decks, the
mixer and the loops is recorded. Press it again to stop: the set is saved, the status line says
how long it was, and its content id shows under the status.

- **Export WAV…** renders the last set to a WAV file you choose. A set renders the same every
  time, except where a sampled instrument varies on purpose (some guitars and tape-style sounds
  have round-robin or modulation); synth voices and General MIDI sounds render identically.
- Headphone and cue settings are not part of a set: they don't change what the master plays.

### Publishing

**Publish…** uploads the last recorded set and a WAV render to cdn.stackdump.com. It asks first,
with a title and a **Draft** box (hidden from the CDN feed and search, but still reachable by its
id). While it runs the bottom bar shows each step; when done it shows the public link with a
**Copy** button ("mirror syncing — the link works once it lands" if the mirror hasn't caught up).

Publishing refuses:

- **A set with stock loops on the loops row** — refused outright.
- **A set that plays local-only sounds** (the Minecraft and 90s sound card palettes, and anything
  from Apple's own GM bank) — not published unless you tick **Publish anyway**.

Publishing is only possible from the app's own button; it is deliberately not available to scripts
or Claude.

### The journal

Every run of the app is recorded in a journal: every press from the screen, a controller or a
script, and every change to your favorites, crates, sound variations and notes. Nothing extra is
needed; it is always on. Journals are kept per run (Section 11 for where).

- **History** (a deck section) shows the latest lines.
- **⟲ Rewind** in History puts the app back to a chosen point in this run: the decks, the loops
  row, scenes, locks, settings and your stores go back to how they were. Everything after that
  point is undone in the app but stays in the journal, and the rewind itself is noted.
- A rewind replays the journal live, so what comes back may differ slightly from what you heard
  (renders, sampled sounds, loop takes); the status line says so when it does.

With the repository at hand, `djctl journal list | show | replay` reads, replays and renders
journals offline, and `djctl journal export-session` turns a slice of a journal into a normal set.

### Notes

Notes can go on a net track (tied to its configuration), a sample (tied to the file), or a loop
(✎ on its tile). They are kept between launches, travel with favorites, and are part of the
journal. See **✎ Notes** in Section 4.

---

## 10. Sound and levels

### Where a track's sound comes from

A net track's parts are played by synth voices, or — when the palette asks for it and this Mac
has them — by sampled instruments: the Logic / GarageBand instruments installed here and any
SoundFonts in the SoundFont folder (Section 11). Each palette picks per part from its options,
seeded by the track, so the same configuration gets the same sounds on the same Mac. A sound that
isn't installed is skipped and the next option used; if a part has no option left, the palette
greys out with the reason.

Sampled instruments are level-matched and tuning-checked when loaded; one that is silent or more
than 30 cents out is turned away and the next choice is used.

Beyond the composer's notes, the app plays every net track with a set of musicality changes —
groove and swing, voicing, fills, buildups and drops, a room and echo per genre, a mix balance
and more — none of which changes the track's identity. *Experimental: these have been measured
but none has been confirmed by ear.* A track loaded from a raw-nets share link gets only the
changes that don't rewrite its notes.

### One loudness

Everything you can play is brought to the same level at unity knobs: **−12 LUFS** (integrated),
before the EQ and fader.

- **Net decks** are gained to it and run through a limiter that keeps peaks under −1 dBTP.
- **Sample decks** with **Auto level** on (Load section; on by default) are measured on load and
  gained toward −12 LUFS by up to ±12 dB, never pushing the peak past −1 dBFS. A one-band loop
  (only bass, kick or hats) is aimed 4 LU lower. Turn Auto level off to hear files at their own
  level.
- **Loops** keep the level they were taken at.
- The **loop channel** starts 3 dB down, so loops sit level with the decks at the centred
  crossfader.

---

## 11. Files and settings

### Where things live

| What | Where |
|---|---|
| Loops row (clips, scenes) | `~/Library/Application Support/dj-vevr-se/loops/` |
| Removed loops | `~/Library/Application Support/dj-vevr-se/loops/removed/` |
| Recorded sets | `~/Library/Application Support/dj-vevr-se/sessions/` |
| Journals (one per run) | `~/Library/Application Support/dj-vevr-se/journal/` |
| Favorites and crates' loops | `~/Library/Application Support/dj-vevr-se/favorites.json` |
| Notes | `~/Library/Application Support/dj-vevr-se/notes.json` (the journal wins if they disagree) |
| Saved sound variations | `~/Library/Application Support/dj-vevr-se/voices.json` |
| Stock loop index | `~/Library/Application Support/dj-vevr-se/stock-loops.json` |
| SoundFonts | `~/Library/Application Support/dj-vevr-se/soundfonts/` |
| Controller check reports | `~/Library/Application Support/DJApp/walk-<device>.txt` |
| Screenshots (scripts) | `~/Library/Application Support/DJApp/shots/` |
| Control socket | `~/Library/Application Support/DJApp/control.sock` |

Stock loops are read from `/Library/Audio/Apple Loops` and `~/Library/Audio/Apple Loops`.

### SoundFonts

Drop `.sf2` files into the SoundFont folder to add sounds and drum kits. With the repository,
`make soundfonts` downloads MuseScore_General.sf2, which the app uses as the floor when nothing
better is installed. Restart the app after installing sounds so palettes check again.

### The Minecraft palette (local only)

With your own Minecraft installed through PrismLauncher, `make minecraft` (in the repository)
builds a SoundFont of its note blocks, bells and goat horns into the SoundFont folder. It is for
personal use on this Mac only: the game's files and the built bank never leave it, its sounds
never stand in for other instruments (you only hear them by choosing the Minecraft palette), and a
set that plays them isn't published unless you say so.

### Remembered between launches

- Which deck sections are open, per deck, and whether Fine-tune is unfolded.
- Locked (disabled) buttons, disabled parts per deck, Wander's locks and pace per deck (Wander
  itself starts off).
- The tap length, launch boundary, loop tempo follow, Auto level, the Generate seed lock.
- Awake, and whether the FX unit and Soundboard panels are open, the Soundboard page and crate.
- The visual quality setting.
- Crates you made (empty ones are kept by name).

---

## 12. Controlling it from Claude or scripts

While the app runs it listens on a local control socket (see the table above). Everything sent
there goes through the same path as the app's own buttons and controllers, so it is recorded in
the journal and in a set like any other press. With the repository, `djctl ctl <method> [json]`
sends one request, and `djctl mcp` is the **dj-vevr-se** MCP server (`make mcp-install` registers
it), which lets Claude read the decks' state and generate, load, perform, manage favorites, stock
loops, notes and the journal, and take screenshots. Publishing is not available there.

---

## 13. Troubleshooting

**A controller does nothing.** Check it is listed in the bottom bar. Only one program can hold a
MIDI port reliably: quit a browser tab that uses Web MIDI (the controller lab) before blaming the
app, and the other way round. For the APC use the Control port. If the MPK's knobs and pads don't
match the table, its preset differs from the measured one.

**A palette or an option is greyed out.** Hover it: it says what's missing on this Mac ("can't
play here: …"). Install the sounds (GarageBand / Logic content, or a SoundFont in the SoundFont
folder) and restart the app. 90s sound card and Minecraft need Apple's GM bank and your own
Minecraft bank respectively.

**A part sounds like a synth instead of a sampled instrument.** Its sampled sound isn't installed,
failed the load check, or all sampler slots are in use; the app falls back to the synth voice.
Some GarageBand copies of Logic instruments lack samples, and a few newer-format instruments
don't load at all.

**Room, Echo or Feedback is greyed out in the FX unit.** The target is a sample deck or the loops,
or this song has no room / this genre has no echo. Use the Reverb section.

**Next is greyed out or shows "…".** The next track is still being composed.

**"Load source on A / B" is greyed out.** The loop came from a sample that is no longer in memory.

**Publish is refused.** A stock loop is on the loops row, or the set plays local-only sounds
(tick **Publish anyway** for the latter).

**The visuals dropped quality.** Auto reduces them when drawing slows the app; click **Keep full
visuals** or pick a level in the ◐ menu.

**The Stage button is greyed out**, or the status says "audio/MIDI error". The audio engine has not
started; check the audio output device and restart the app.

**A replay or rewind doesn't sound exactly like the original.** Some sampled instruments vary
between renders on purpose; a live rewind is as exact as live timing allows.
