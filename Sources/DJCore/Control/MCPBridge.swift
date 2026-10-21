import Foundation

/// The MCP face of the control socket: stdio JSON-RPC in (`djctl mcp`), one control request
/// out per tool call. It knows the tool list and how to phrase errors; the app decides what
/// each request does. Kept free of I/O so it can be tested line by line.
public struct MCPBridge {
  public typealias Call = (_ method: String, _ params: JSONValue) throws -> JSONValue
  public let call: Call
  public var version: String

  public init(version: String = BuildInfo.current.id, call: @escaping Call) {
    self.call = call
    self.version = version
  }

  /// Tool name → control method.
  static let methods: [String: String] = [
    "dj_state": "state", "dj_perform": "perform", "dj_generate": "generate",
    "dj_catalog": "catalog", "dj_load_file": "loadFile", "dj_load_share": "loadShare",
    "dj_compose": "composeRoll", "dj_inspired": "composeRoll", "dj_import": "importScore",
    "dj_compositions": "compositions", "dj_set": "set",
    "dj_press_pad": "pad",
    "dj_record": "record", "dj_screenshot": "screenshot",
    "dj_audition": "audition", "dj_favorites": "favorites", "dj_copy_deck": "copyDeck",
    "dj_set_instrument": "setInstrument", "dj_stock_loops": "stockLoops",
    "dj_notes": "notes", "dj_journal": "journal", "dj_palettes": "palettes",
    "dj_view": "view", "dj_variations": "variations", "dj_loops": "loops",
    "dj_settings": "settings", "dj_minecraft_events": "minecraftEvents",
  ]

  /// One JSON-RPC line in → the reply line, or nil for a notification.
  public func handle(_ line: String) -> String? {
    guard let req = try? JSONValue.parse(line) else {
      return error(id: .null, code: -32700, "parse error")
    }
    guard let id = req["id"], id != .null else { return nil }  // notifications
    let method = req["method"]?.string ?? ""
    switch method {
    case "initialize":
      let asked = req["params"]?["protocolVersion"]?.string ?? "2025-06-18"
      return result(
        id,
        obj([
          ("protocolVersion", .string(asked)),
          ("capabilities", obj([("tools", obj([]))])),
          ("serverInfo", obj([("name", .string("dj-vevr-se")), ("version", .string(version))])),
          ("instructions", .string(Self.instructions)),
        ]))
    case "ping":
      return result(id, obj([]))
    case "tools/list":
      return result(id, obj([("tools", .array(Self.tools))]))
    case "tools/call":
      let name = req["params"]?["name"]?.string ?? ""
      let args = req["params"]?["arguments"] ?? obj([])
      guard let target = Self.methods[name] else {
        return error(id: id, code: -32602, "unknown tool \(name)")
      }
      do {
        let out = try call(target, args)
        // A screenshot comes back as the image itself (the app wrote it on this machine).
        if name == "dj_screenshot", let path = out["path"]?.string,
          let png = FileManager.default.contents(atPath: path)
        {
          return result(
            id,
            obj([
              (
                "content",
                .array([
                  obj([
                    ("type", .string("image")), ("data", .string(png.base64EncodedString())),
                    ("mimeType", .string("image/png")),
                  ]),
                  obj([("type", .string("text")), ("text", .string(out.jsStringified))]),
                ])
              ),
              ("isError", .bool(false)),
            ]))
        }
        return result(id, content(out.jsStringified, isError: false))
      } catch {
        return result(id, content("\(error)", isError: true))
      }
    default:
      return error(id: id, code: -32601, "method not found: \(method)")
    }
  }

  private func content(_ text: String, isError: Bool) -> JSONValue {
    obj([
      ("content", .array([obj([("type", .string("text")), ("text", .string(text))])])),
      ("isError", .bool(isError)),
    ])
  }

  private func result(_ id: JSONValue, _ r: JSONValue) -> String {
    obj([("jsonrpc", .string("2.0")), ("id", id), ("result", r)]).jsStringified
  }

  private func error(id: JSONValue, code: Int, _ message: String) -> String {
    obj([
      ("jsonrpc", .string("2.0")), ("id", id),
      ("error", obj([("code", .int(code)), ("message", .string(message))])),
    ]).jsStringified
  }

  // MARK: tools

  static let instructions = """
    Drives the running DJApp (dj-vevr-se) on this Mac: two decks, A and B, each playing a \
    sample or a live Petri-net track. Call dj_state first. Everything sent here goes through \
    the same path as the app's own buttons, so it is recorded when a session is recording. \
    Audio plays on the Mac's speakers — you cannot hear it; read dj_state instead.

    You can compose, not just select: dj_compose takes a piano roll you write (parts, notes, \
    tempo) and plays exactly those notes on a deck as a Petri-net track — a specific song, not \
    a generator seed. Reach for it when asked for a particular melody, riff, chord progression \
    or arrangement; use dj_generate / dj_load_share to explore the generator's own space.

    Words matter. "Inspired by <artist>" (or "<artist>-style") → dj_inspired: an original piece \
    that reads the artist's general style (tempo, key, progression, groove, sound palette, \
    form), never their melody, hook or lyric. "Import / play this file" → dj_import (a \
    .mid today, MusicXML next; only material the user owns or that is public domain / \
    Creative Commons, whose licence the share records). A request to transcribe or reproduce a \
    specific copyrighted song's melody is declined: offer an inspired original instead.
    """

  static let tools: [JSONValue] = [
    tool(
      "dj_state",
      "Snapshot of the app: per deck (title, mode sample|net, playing, bpm, position, sections "
        + "and the current one, roles and which are on, volume/filter/pitch, quantize, next "
        + "track, fixes {pass: whether dj's musicality pass rewrote the net — false for a "
        + "raw-nets share, which plays the runner-only fixes —, names: the fixes it plays "
        + "with}, level: the deck's short-term / momentary LUFS, autoGain on/off and the "
        + "autoGainDB a sample plays at, the sample's own LUFS when levelled, a net deck's "
        + "limiter), crossfader, master, the LOOP-record clips, the ones removed from the row and the "
        + "loop channel (loops; loops.follow: the Tempo mode and the deck followed), "
        + "connected controllers, recording, status line, locked (buttons disabled by "
        + "right-click, by lock key), headphones (mix, level, pfl per deck), inpulseOutput "
        + "(the Inpulse's audio device and whether it is routed, or null), awake (screen kept "
        + "awake), view (which panels are open), scope (open, kind, source, measured), stage "
        + "(window open and its toolbar settings), crates, saved voice variations by "
        + "instrument, autoMix (the two-deck autopilot: on, bars, every, phase "
        + "off|idle|playing|paused|preparing|armed|mixing, playing / incoming deck, handoffs, "
        + "handoffBar and handoffInBars, next {genre, seed, cid, kind seed|instrument|genre|cued, "
        + "move}, fader auto|user, paused / resumesInBars, idle: why it can't act, log of "
        + "hand-offs newest first), and the "
        + "app's build (id, version, build = git commit, date).",
      [:]),
    tool(
      "dj_perform",
      """
      Apply one deck action, as a button or fader in the app would. `action` is an object \
      with `op` plus fields:
      play {deck, on} · cue {deck} · hotCue/clearCue {deck, slot 0-7} · \
      loop {deck, loop: in|out|halve|double} · \
      param {deck, name: volume|filter|gain|eqLow|eqMid|eqHigh|pitch|reverbWet|reverbSize|\
      reverbTone|autoGain, value} (0…1, 0.5 = centre for filter/gain/eq; autoGain 0/1 = sample \
      loads levelled to the app's loudness; pitch is -1…1 = ±8%, 0 = none; \
      reverb: wet 0 = off, size 0…1 = 0.25…8 s decay, tone 0 dark … 1 bright) · crossfader {value 0…1, \
      0 = A} · master {value} · nextTrack {deck} · autoAdvance {deck, on} · \
      section {deck, index} · role {deck, role, on} · roleDisable {deck, role, on}: on = the \
      role stays off through new tracks too, until disabled again with on false · macro {deck, macro: id from \
      dj_catalog, a net macro or a master-chain FX / pitch / feel one; a sample deck takes the \
      master-chain ones (vinyl-brake too), on its next bar} · panic {deck} · \
      stinger {deck, n 0-3}: Hit n+1, curated from the genre and palette (a one-shot, a macro \
      or a loop on the loop row; dj_state.decks.X.stingers says which) · \
      sync {deck, align: beat|bar|tempo} \
      · quantize {deck, mode: off|beat|bar} · follow {deck, leader: deck or null} · \
      grid {deck, bpm > 0, offset s}: a sample deck's beat grid by hand (the first beat at \
      offset seconds into the sample), replacing the analysis · \
      queueNext {deck, share: {genre, seed, structure?}} · \
      wander {deck, on} (works on dj_compose / dj_import tracks too, on the moves that need no \
      seed: mutes, STEMS, macros, FX, stingers, palette hops): the deck walks by itself, one move per phrase (a mute, a macro, a \
      stinger, the next seed, another instrument, structure or genre, swapped in at the next \
      bar), drawn from its configuration so a recording replays the same walk; \
      dj_state.decks.X.wander shows on, pace, nextMoveInBars, paused (the browser wheel steers \
      and pauses it for a phrase), locks and the log of moves · wanderPace {deck, bars: \
      4|8|16|32} · wanderLock {deck, dimension: genre|tempo|key|structure|instruments|\
      arrangement|fx|palette|keep:<role>, on}: what the walk must not change (tempo: within 6 % \
      of now; palette: the deck's sound palette; keep:bass keeps the bass's instrument and never \
      mutes it) · \
      loopRecord {deck, on, bars?}: LOOP record, held (on true) then let go (on false): the \
      deck's bars from the downbeat before the press to the one after the release become a \
      clip, looping under the mixer (dj_state.loops); with bars (1-64) on the press, a release \
      within 250 ms records exactly that many bars from that downbeat instead (the app's tap \
      length is dj_state.loops.tapBars) · grabBars {deck, bars}: the last bars whole bars the \
      deck already played (up to ~21 s back), ending on the downbeat just gone, become a clip \
      looping at once · clipLoop {id, on}: a clip in or out under the \
      mixer on the next launch boundary (several loop at once; dj_state.loops.clips[].switchIn \
      is the beats until a waiting one switches) · clipGain {id, value 0…1} · \
      loopQuantize {beats: 1|4|8|16|32}: what loops launch on (a beat, a bar, 2/4/8 bars of the \
      reference deck, phrases on its bars 1, 5, 9…; default 4) · loopFollow {mode: \
      louder|source}: which deck the loops' tempo follows (louder: the louder playing deck, the \
      default; source: each loop the deck it was taken from) · sceneSave {name}: the loops \
      playing now (and their levels and FX) as a scene (overwrites one of that name) · sceneLaunch \
      {name}: its loops in, every other out, all on the next launch boundary · sceneRename \
      {name, to} · sceneDelete {name} (dj_state.loops.scenes, .quantize) · \
      clipCrop {id, from, to}: keep its beats from..<to · clipRetune {id, voices: {"<MIDI \
      channel>": instrument}}: a loop taken from a net rendered again with those instruments \
      (the others as taken; channels as dj_state's voices number them), taking its \
      place as a crop does, in phase if it is looping; refused for samples, sequences and takes \
      with macros running · clipSequence {steps: [{clip, repeats}], \
      replacing?}: join clips into a sequence (or rewrite one) · clip {deck: L|A|B, id}: move a \
      clip onto a deck (L = under the mixer) · clipRemove {id}: off the row, its audio kept \
      (dj_state.loops.removed; dj_loops undo puts it back, and has the row's load source, \
      export and stop all) · clipRestore {id, at?}: a removed clip back where it was (or at \
      index at) · clipForget {id}: delete a removed clip for good · clipRename {id, title} · \
      clipColor {id, color: red|orange|yellow|green|teal|blue|violet|pink or null} · clipMute \
      {id, on}: silent but still looping, in phase · clipSolo {id, on}: while any clip is soloed \
      only soloed ones are heard · clipKeyLock {id, on}: at another tempo it keeps its pitch (a \
      time-stretched copy, made in the background; dj_state.loops.clips[].stretched) · \
      clipFx {id, fx: {drive 0…24 dB, mode clean|soft|hard|tube|fold|crush, amount 0…1, \
      bits 1…16, downsample 1…32, tone 0…1 (1 open), mix 0…1, trim −24…12 dB, autoLevel, \
      bypass}}: after effects on a loop under the mixer, on top of its dry audio (missing fields \
      default; {} is off; dj_state.loops.clips[].fx) · \
      clipImport {id, title, bpm, beats, provenance?}: outside audio already in the sample \
      library (by content id) onto the row as a clip, looping from the next launch boundary; the \
      same audio twice is one clip (dj_stock_loops addToRow is the way in for a stock loop; a \
      set with one is never published) · \
      loopKeyLock {on}: the row's key lock, for clips without their own · loopFade {fade: \
      off|10ms|beat|bar}: how loops come in and go out (default 10ms) · clipQuantize {id, beats: \
      1|4|8|16|32 or null}: one loop's own launch boundary (null: the row's loopQuantize; a scene \
      switches on the row's) · clipFade {id, fade: off|10ms|beat|bar or null}: one loop's own \
      fade (null: the row's loopFade) · clipFollow {id, mode: louder|source or null}: whose \
      tempo one loop follows (null: the row's loopFollow) · tapBars {bars: 1-64 or \
      null}: what a quick tap of a controller's LOOP records (dj_state.loops.tapBars is the \
      app's) · voiceTweak {deck, channel, params}: shape a net deck's channel's synth voice \
      live, on the song playing (no reload; channel from dj_state.voices[].channel): params \
      {gainDB -48…24, attack s, decayScale × note length, maxDecay s, lowpass Hz (0 = off), \
      distortion 0…1, vibratoRate Hz, vibratoDepth 0…0.1 of the frequency, pitchFrom / pitchTo \
      × the note, pitchTime s (0 = no sweep)}, each optional (unset = the instrument's own); {} \
      resets to the instrument's voice. Session-only: it lasts for the song on that deck (its \
      section jumps and other instrument picks), not a new track, a favorite or a relaunch; \
      dj_state.voices[].tweak shows it · voiceSynth {deck, channel, on}: a sampled channel \
      (dj_state.voices[].sampled) plays its synth voice (on) or its sample · clipMove {id, \
      before: id or null}: move a clip on the row to just before another (null: the end) · \
      lock {key, on}: lock an action like right-click ▸ Disable (key e.g. "A.play"; locked \
      controller bindings do nothing) · setPalette {deck, palette: id from dj_palettes or \
      null = the default}: the track's whole sound from a palette, at the next bar, kept for \
      every new track on the deck · setRoleVoice {deck, role: kit|bass|melody|harmony|arp|\
      stinger, voice: an option from dj_palettes / dj_state.decks.X.sound[].options (gm:4, \
      synth:pwm-lead, cat:keys.epiano, inst:piano, a kit id…) or null = back to the palette}: \
      one role's sound, kept through new tracks until reset · setKit {deck, kit: a kit id or \
      null} · mixOut {deck, bars? 1-64, default 16}: play the deck out: at the next bar it \
      jumps to the song's outro (or, in it or with none, plays on where it is), plays only its \
      drums and bass for bars bars and stops on a bar line (the room rings out; section jumps \
      keep it, a new track drops it) · mixIn {deck, bars? 1-64, default 4}: bring the deck in \
      drums-forward: from the next bar its melodic parts rest for bars bars and come back on \
      the bar line after · rewind {deck}: back to the start (a sample's first frame, a net's \
      tick 0) · focus {deck: A|B|L}: aim the deck-less controls (keys, joystick, seed, wander) \
      as a controller's deck-select does (dj_state.focus) · stemMute {deck, stem: \
      music|mic, on}: a net deck's STEMS group muted or back (music: all but the drums; mic: the \
      lead) · masterFx {deck, key: hp-freq|lp-freq|phaser-freq|phaser-depth|phaser-wet|\
      crush-bits|distortion|master-pitch, value 0…1}: move a master FX slider by hand, value \
      the fraction of its travel (as a controller fader sends it; master-pitch −12…12 \
      semitones, the rest 0…100), on a net's chain, a sample deck's bus or the loops' (L) · \
      fx {deck, param: \(FxParam.allCases.map(\.id).joined(separator: "|")), value}: the FX \
      unit, live on the deck's chain (A, B or L): smoothed over ~30 ms, not quantised; value in \
      the param's travel (filter −1…1: left LP, right HP, 0 off; pitch −12…12 semitones; the \
      rest 0…1; neutral: lp 1, phaser-depth 0.5, the rest 0); room / echo / feedback are a net \
      deck's sends (its genre's room and echo: 0 = as composed, 1 = 4× the send / feedback \
      0.92), not on sample decks or L; master macros ride on top of the unit and release back \
      to it · fxReset {deck, onBeat?}: every FX unit control to neutral and its kill off \
      (onBeat: on the deck's next beat) · fxKill {deck, on, onBeat?}: bypass the FX unit \
      keeping its knobs, or back (dj_state.fxUnit) · \
      autoMix {on, bars: 4|8|16|32 (default 8), every: 0|4|8|16 (default 0)}: the two-deck \
      autopilot, the whole setting at once: while one deck plays, a phrase before the hand-off \
      the other gets a neighbouring track (the next seed, another instrument, or a neighbouring \
      genre the pitch fader reaches; a compatible key; both decks' wander locks hold; a net you \
      load on the idle deck yourself is used as-is), starts on a phrase boundary synced, comes \
      in drums-forward while the playing deck mixes out over bars bars, the crossfader stepping \
      across bar by bar; every 0 = a song to its outro (a loop 8 phrases), else that many \
      8-bar phrases; steering pokes (play, cue, loops, sync, sections, loads, the seed wheel, \
      the jog) pause it for a phrase, knobs / mutes / macros / FX don't; dj_state.autoMix · \
      autoMixNow {}: hand off at the next phrase boundary at least 4 bars away · \
      autoMixDefer {handoff}: recorded by the app itself when a compose is late; refused here. \
      Deck "L" also takes param volume / mute (1 = muted), \
      and macro (master-chain ids only: the loops' master FX, on the next loop bar) and panic; \
      loopFxLink {on}: a master macro on deck A / B fires on the loops too (dj_state.loops.masterFx).
      Net-only ops (section, role, net macros, stinger, mixOut, mixIn) need a deck in net mode; \
      master-chain macros and panic also work on a sample deck (dj_state's macrosRunning). Use \
      dj_generate, not op load, to put a new track on a deck.
      """,
      ["action": prop("object", "The action, e.g. {\"op\":\"play\",\"deck\":\"A\",\"on\":true}")],
      required: ["action"]),
    tool(
      "dj_generate",
      "Compose a live Petri-net track and load it on a deck (takes a few seconds; returns when "
        + "loaded). Does not start playback — follow with dj_perform play.",
      [
        "deck": prop("string", "A or B"),
        "genre": prop("string", "A genre id from dj_catalog"),
        "seed": prop("number", "Any number; same genre + seed = same track"),
        "structure": prop(
          "string",
          "minimal | standard | extended for a song with sections; omit for an endless loop"),
        "palette": prop(
          "string",
          "A sound palette id from dj_palettes; omit to keep the deck's (it carries to new tracks)"),
        "options": prop(
          "object",
          """
          Opt-in composition techniques (all off by default; part of the track's share/CID): \
          hook (bool: one 1–2 bar chord-tone hook in every melody section) · hookBars (1|2) · \
          chordSnap (off|strong|all: melody notes on beats 1+3 / every beat moved to the \
          sounding chord) · chordSnapArp (bool: snap the arp too) · layerBudget ("auto" or \
          1–8: max melodic roles per section, bass > melody > harmony > arp) · bassFollow \
          (bool: one bass pattern on the chord plan) · keyLock (bool: tension phrases stay in \
          key) · melodyDensity, bassDensity (0–1] · ghostNotes, syncopation (0–1) · humanize \
          (0–100). The same keys are also accepted at the top level.
          """),
      ],
      required: ["deck", "genre", "seed"]),
    tool(
      "dj_catalog", "Genres, song structures, macro ids and deck names the other tools accept.",
      [:]),
    tool(
      "dj_palettes",
      """
      The sound palettes a track can play from (Studio = each instrument's own sound, Synth, \
      Synthwave, 8-bit, Acoustic band, Orchestral, Lo-fi tape, Jazz club, Club, Ambient, …): \
      id, label, description, whether it plays on this Mac (`unavailable` says why not), \
      local-only ones (never published), Wander's neighbours and each role's options. With \
      `deck`, also what each of that deck's roles plays (`sound`). Set one with dj_perform \
      setPalette, one role with setRoleVoice.
      """,
      ["deck": prop("string", "A or B (optional)")]),
    tool(
      "dj_load_file", "Load an audio file from this Mac onto a deck as a sample.",
      [
        "deck": prop("string", "A or B"),
        "path": prop("string", "Absolute path to a WAV/AIFF/MP3/M4A"),
      ],
      required: ["deck", "path"]),
    tool(
      "dj_load_share",
      """
      Load a beats (beats.bitwrap.io) share onto a deck as a live Petri-net track, exactly as \
      the share describes it: a composed share (genre + seed + traits, overrides, overlays) is \
      composed here; a raw-nets share plays its nets as given (arranged if it has a \
      structure; to write your own notes use dj_compose). Takes a few seconds; returns the deck when loaded, with `share` = {kind \
      net|rawNets, cid}. Does not start playback — follow with dj_perform play. A short \
      ?cid= link without &z= can't be loaded (its payload is on a server): pass the full \
      link or the payload.
      """,
      [
        "deck": prop("string", "A or B"),
        "link": prop(
          "string",
          "A full share URL (https://beats.bitwrap.io/?cid=…&z=…, or just its ?query; the CID "
            + "is verified), a legacy ?p= / ?g= link, or the envelope payload as JSON text "
            + "(e.g. {\"genre\":\"techno\",\"seed\":42})"),
      ],
      required: ["deck", "link"]),
    tool(
      "dj_compose",
      """
      Write a song and play it: a piano roll you compose becomes a live Petri-net track on a \
      deck, playing exactly your notes (no generator, no musicality pass). Each part is a \
      step-sequencer net of sixteenth-note steps (16 steps = one 4/4 bar, step 0 = bar 1 beat \
      1; 4 steps = a beat), looping; all parts share one length so they stay in phase. \
      Parts are keyed by role: kick, snare, hihat, clap (drums; `note` may be left out: GM \
      36 / 38 / 42 / 39), bass, melody, harmony, arp. Each takes {instrument?, channel?, \
      notes}; a note is [step, midi, dur?, vel?] (dur in sixteenths, default 2 for tonal \
      parts and 1 for drums; vel 1–127, default 100; middle C = 60). Notes on the same step \
      (chords) are fine: they play together. `steps` defaults to the roll's length rounded up \
      to whole bars (max 1024). A part repeats a pattern with {every, from?, until?, notes}: the \
      notes (steps relative to the pattern) recur every `every` steps from step `from` up to \
      `until` (default `steps`, which a repeat needs if no `until`), so a bar of drums is \
      written once; give a LIST of such segments for an arrangement (a part enters at bar 5 \
      with from 64). Without `every` notes sit at `from` + step. Write the whole form out \
      (8–64 bars) with a clear key and chord plan, not one riff. Takes a few \
      seconds, returns the deck with share {kind rawNets, cid} and `saved`, the file it was kept \
      in (dj_compositions lists and reloads them). Does not start playback — \
      follow with dj_perform play. Roles light up in dj_state like any net deck, so dj_perform \
      (role mutes, macros, FX) and the controllers work on it. A deck that is playing keeps \
      playing on load.
      """,
      [
        "deck": prop("string", "A or B (not needed with load false)"),
        "load": prop(
          "boolean",
          "false = stage it: save the track (and add it to `set`) without loading a deck, so a whole set can be pre-rolled"
        ),
        "energy": prop("number", "How hard it hits, 0–1 (kept for set planning)"),
        "key": prop("string", "Its key, e.g. \"A minor\" (kept for set planning)"),
        "set": prop("string", "Add it to this set (created if new), in `slot` if given"),
        "slot": prop("number", "Plan slot index to fill in `set`"),
        "name": prop("string", "Title shown on the deck"),
        "tempo": prop("number", "BPM, 40–300 (default 120)"),
        "swing": prop("number", "Swing 0–100 (default 0)"),
        "steps": prop("number", "Loop length in sixteenth steps (default: the longest part)"),
        "parts": obj([
          ("type", .string("object")),
          (
            "description",
            .string(
              "{role: {instrument?: string, channel?: 1-16, every?, from?, until?, notes: "
                + "[[step, midi, dur?, vel?], …]}} or a list of such segments, e.g. "
                + "{\"kick\":{\"every\":16,\"until\":256,\"notes\":[[0],[4],[8],[12]]},\"bass\":{\"instrument\":"
                + "\"sub-bass\",\"notes\":[[0,36,4,100],[8,43,4,100]]}}. Instruments are beats' names "
                + "(dj_catalog, dj_set_instrument); omit for the role's default.")
          ),
        ]),
      ],
      required: ["parts"]),
    tool(
      "dj_inspired",
      """
      Compose an ORIGINAL piece inspired by an artist or a track and play it: dj_compose with \
      the convention fixed. First read the style in general terms (tempo, key and mode, chord \
      progression type, groove and drum pattern, bass behaviour, sound palette, section form \
      and energy curve) and put that one-line read in `brief`; then write the notes \
      yourself. Never transcribe or closely paraphrase the artist's actual melody, hook, \
      bassline or lyric, and do not take a chord progression note-for-note together with its \
      rhythm; a generic progression and groove in that genre is the point. `inspiredBy` names \
      who or what it is inspired by; it, and the brief, are recorded in the share's note, and \
      the title defaults to "<inspiredBy>-style (original)". Parts, notes, steps and playback \
      are as dj_compose (read its description). Write a full form (16–64 bars, build and drop \
      by leaving parts out of early bars), not one loop.
      """,
      [
        "deck": prop("string", "A or B (not needed with load false)"),
        "load": prop(
          "boolean",
          "false = stage it: save the track (and add it to `set`) without loading a deck, so a whole set can be pre-rolled"
        ),
        "energy": prop("number", "How hard it hits, 0–1 (kept for set planning)"),
        "key": prop("string", "Its key, e.g. \"A minor\" (kept for set planning)"),
        "set": prop("string", "Add it to this set (created if new), in `slot` if given"),
        "slot": prop("number", "Plan slot index to fill in `set`"),
        "inspiredBy": prop("string", "The artist or track, e.g. \"Avicii\" or \"Avicii – Levels\""),
        "brief": prop(
          "string",
          "Your one-line style read, e.g. \"126 BPM, C# minor, i–VI–III–VII, offbeat bass, "
            + "syncopated saw stabs, 8-bar build into a drop\""),
        "name": prop("string", "Title (default: <inspiredBy>-style (original))"),
        "tempo": prop("number", "BPM, 40–300 (default 120)"),
        "swing": prop("number", "Swing 0–100 (default 0)"),
        "steps": prop("number", "Loop length in sixteenth steps (default: the longest part)"),
        "parts": obj([
          ("type", .string("object")),
          (
            "description",
            .string(
              "As dj_compose: {role: {instrument?, channel?, every?, from?, until?, notes: "
                + "[[step, midi, dur?, vel?], …]}} (or a list of segments) with roles kick snare "
                + "hihat clap bass melody harmony arp.")
          ),
        ]),
      ],
      required: ["inspiredBy", "parts"]),
    tool(
      "dj_import",
      """
      Load a score file from this Mac onto a deck as a raw-nets Petri-net track playing its \
      notes: a Standard MIDI File (.mid / .midi) or MusicXML (.musicxml / .xml / .mxl, partwise; repeats, \
      grace notes and later tempo changes are reported, not played). Quantised to sixteenth \
      steps, the channels sorted into roles (drums by GM note; bass by program or register; \
      chordy channels → harmony; the busiest remaining line → melody), at the file's first \
      tempo. Loads an excerpt of `bars` bars from bar `from` (default 16 from the start, max \
      64); the reply's `import` says what was kept and dropped (tempo changes, drums with no \
      role, over three notes on one step, notes outside the excerpt) and lists every source \
      channel with its role, so you can re-import with `map` to fix a call. Use `inspect: \
      true` to read that summary without loading. Only for material the user owns or that is \
      public domain / Creative Commons: pass its licence and origin in `source` (kept in the \
      share's note). Does not start playback, and never publishes.
      """,
      [
        "deck": prop("string", "A or B (not needed with inspect or load false)"),
        "load": prop(
          "boolean",
          "false = stage it: save the track (and add it to `set`) without loading a deck, so a whole set can be pre-rolled"
        ),
        "energy": prop("number", "How hard it hits, 0–1 (kept for set planning)"),
        "key": prop("string", "Its key, e.g. \"A minor\" (kept for set planning)"),
        "set": prop("string", "Add it to this set (created if new), in `slot` if given"),
        "slot": prop("number", "Plan slot index to fill in `set`"),

        "path": prop(
          "string", "Absolute path (or ~/…) to a .mid / .midi / .musicxml / .xml / .mxl file"),
        "from": prop("number", "First bar of the excerpt, 0-based (default 0)"),
        "bars": prop("number", "Bars to load, 1–64 (default 16)"),
        "tempo": prop("number", "BPM override, 40–300 (default: the file's first tempo)"),
        "name": prop("string", "Title (default: the file's title or name)"),
        "source": prop("string", "Origin and licence, e.g. \"Mutopia, J.S. Bach, public domain\""),
        "inspect": prop("boolean", "Only return the summary; load nothing"),
        "map": obj([
          ("type", .string("object")),
          (
            "description",
            .string(
              "Override roles: {\"<track>:<channel>\" or \"<channel>\": role}, role one of bass, "
                + "melody, harmony, arp, skip (drums are mapped by note)")
          ),
        ]),
      ],
      required: ["path"]),
    tool(
      "dj_compositions",
      """
      The tracks dj_compose, dj_inspired and dj_import have played, kept on disk for reference: \
      each is a JSON file in the compositions folder (reply `directory`; \
      ~/Library/Application Support/dj-vevr-se/compositions/) holding the request that made it \
      (the roll: parts, notes, tempo, brief; for an import its source and report) and the \
      raw-nets envelope. Those three tools save automatically and say where (`saved`). action \
      list (default) returns them newest first with id, name, kind compose|inspired|import, \
      deck, saved, cid, tempo, note and path (optional `query` filters ids, `limit` caps); load \
      {deck, id} puts one back on a deck (id may be any unique part: a title word or the cid \
      tail). Does not start playback. Never publishes.
      """,
      [
        "action": prop("string", "list (default) or load"),
        "deck": prop("string", "A or B (load)"),
        "id": prop("string", "The composition's id, or a unique part of it (load)"),
        "query": prop("string", "Filter the list by part of an id (list)"),
        "limit": prop("number", "Most rows to list (default 50)"),
      ]),
    tool(
      "dj_set",
      """
      Plan, pre-roll and play a whole set. A set is a named plan of slots on an energy curve \
      (label, energy 0–1, tempo, key) with a saved composition in each slot, kept in \
      ~/Library/Application Support/dj-vevr-se/sets/. Workflow: `plan` {set, count, shape arc|rise|\
      plateau, bpm [low, high]} (or explicit `slots` [{label, energy, bpm?, key?, bars?}]) → pre-roll \
      tracks with dj_compose / dj_inspired / dj_import using load false, set, slot, energy, key (they \
      are saved and filled into the plan; nothing is loaded) → `sequence` fills the plan from \
      everything saved by energy, tempo (matchable at 1×, ½×, 2×) and key distance on the circle of \
      fifths, and returns `gaps` (slots nothing fits: the brief to compose) and `tempoJumps` → \
      `start` {set, deck?, play?} loads track 1 → `mix` {set, fadeBars?, wait?} hands off to the next \
      track: loads it on the idle deck with its bass EQ down, starts it, tempo-matches and \
      bar-aligns it (the deck's sync), crossfades over fadeBars bars (default the set's, 8) with the \
      bass swapped at the midpoint, stops the old deck. It returns at once (hand-off runs in the \
      app; poll `status`: phase loading|fading|done, progress, warnings such as a tempo gap, bar, \
      barsInTrack); `wait` blocks until done. Other actions: list, show, add {set, id, slot?}, \
      remove {set, index|id}, abort. The app does not advance by itself yet: call `mix` when you \
      want the next track (every move is recorded like the performer's own).
      """,
      [
        "action": prop(
          "string",
          "list (default) | show | plan | add | remove | sequence | start | mix | status | abort"),
        "set": prop("string", "The set's name"),
        "slots": obj([
          ("type", .string("array")),
          ("description", .string("plan: [{label, energy 0-1, bpm?, key?, bars?}]")),
        ]),
        "count": prop("number", "plan: generate this many slots on a curve (1–32)"),
        "shape": prop("string", "plan with count: arc (default) | rise | plateau"),
        "bpm": obj([
          ("type", .string("array")),
          ("description", .string("plan with count: [low, high] tempo mapped onto the curve")),
        ]),
        "fadeBars": prop(
          "number",
          "Crossfade length in bars, 1–32 (plan: the set's default; mix: this hand-off; add: this track's)"
        ),
        "keepItems": prop("boolean", "plan: keep the tracks already in the set"),
        "from": prop(
          "string", "sequence: all (default, everything saved) | set (only tracks already in it)"),
        "id": prop("string", "add / remove: a composition id or any unique part of it"),
        "index": prop("number", "remove: track index"),
        "slot": prop("number", "add: plan slot to fill"),
        "mixOutBar": prop("number", "add: bar to start mixing out at (for the auto runner)"),
        "deck": prop("string", "start: A (default) or B"),
        "play": prop("boolean", "start: also start the deck"),
        "wait": prop("boolean", "mix: wait for the hand-off to finish"),
      ]),
    tool(
      "dj_favorites",
      """
      The starred tracks and samples (also the star by a deck's title and Load ▸ Favorites in \
      the app). action list (default) returns them, newest first, with title, cid, genre, seed \
      (nets) or kind sample + file, and tags; add {deck} stars what a deck plays: its net \
      (instrument changes included) or a sample loaded from a file (Apple Loop or audio file); \
      remove {cid | deck}; load {deck, cid} puts one on a deck (does not start playback); \
      tags {cid | deck, tags} replaces a favorite's tags. Crates (the Load panel's own lists; \
      a crate is a tag, so its loops stay starred): crates lists them (every reply carries \
      crates too); newCrate {crate} makes an empty one; addToCrate {crate, cid | path} puts a \
      favorite, or a stock loop by path (starred as a sample first), in it; removeFromCrate \
      {crate, cid} takes one out (it stays starred); deleteCrate {crate} drops the crate, not \
      its favorites. keepMove {deck, step} toggles the star on the track a move of the deck's \
      walk (dj_state wander.log) led to or played on: the reply's kept says which. A net's cid \
      is its share CID, a sample's "file:" + its path.
      """,
      [
        "action": prop(
          "string",
          "list | add | remove | load | tags | crates | newCrate | addToCrate | removeFromCrate | "
            + "deleteCrate | keepMove"),
        "tags": prop("array", "tags: the favorite's tags (they replace the old ones)"),
        "deck": prop("string", "A or B"),
        "cid": prop("string", "A favorite's cid, from list"),
        "crate": prop(
          "string", "A crate's name (newCrate, addToCrate, removeFromCrate, deleteCrate)"),
        "path": prop("string", "addToCrate: a stock loop's path, from dj_stock_loops"),
        "step": prop("number", "keepMove: the move's step, from dj_state wander.log"),
      ]),
    tool(
      "dj_stock_loops",
      """
      The Apple Loops installed on this Mac (~15k; the Load panel's stock loops). action list \
      (default) filters by `category` (Drums, Bass, Keyboards…; the reply lists them) and \
      `query` words, nearest in tempo to `near` BPM (or the other deck's when `deck` is given) \
      first, up to `limit` (20); load {deck, path} puts one on a deck as a sample with its own \
      tempo as the beat grid (does not start playback); addToRow {path} puts one on the loop \
      row as a clip (dj_state.loops.clips, provenance kind stock), looping under the mixer from \
      the next launch boundary in time with the decks; the same loop twice is one clip. A set \
      with a stock loop on the row is never published.
      """,
      [
        "action": prop("string", "list | load | addToRow"),
        "deck": prop("string", "A or B (load)"),
        "path": prop("string", "A loop's path, from list"),
        "category": prop("string", "e.g. Drums, Bass, Keyboards"),
        "query": prop("string", "Words to match in name, pack, genre, subcategory"),
        "near": prop("number", "Sort by closeness to this BPM"),
        "limit": prop("integer", "How many to return (default 20)"),
      ]),
    tool(
      "dj_copy_deck",
      "Load the net track on one deck onto the other, instrument changes included, from its "
        + "start (at the next bar if that deck is playing). Returns the target deck.",
      ["from": prop("string", "A or B"), "to": prop("string", "A or B")],
      required: ["from", "to"]),
    tool(
      "dj_set_instrument",
      """
      Change the beats instrument a role plays on a net deck (dj_state's `instruments`): it \
      picks the synth voice and, through its category, the sampled sound. Stored as the \
      share's `tracks` override, so it records, stars and shares. The track reloads from its \
      start (at the next bar if playing): use it on the deck that isn't live. Roles sharing a \
      channel (the drum kit) change together. A wrong instrument lists the choices.
      """,
      [
        "deck": prop("string", "A or B"),
        "role": prop("string", "e.g. bass, melody, kick"),
        "instrument": prop("string", "e.g. reese, supersaw (an error lists the choices)"),
      ],
      required: ["deck", "role", "instrument"]),
    tool(
      "dj_variations",
      """
      Saved variations: named ways to play an instrument (the sound panel's chips), kept across \
      launches by instrument name. action list (default) {instrument?}: each instrument's \
      variations (name, params — the voiceTweak values — and useSynth); save {deck, channel, \
      name}: keep what that net deck's channel sounds like now (its voiceTweak / voiceSynth; \
      the same name replaces it); apply {deck, channel, name, instrument?}: play one on the \
      channel, as voiceTweak / voiceSynth acts — an instrument other than the channel's \
      reloads the track with it first (as dj_set_instrument); rename {instrument | deck + \
      channel, name, to}; delete {instrument | deck + channel, name}. dj_state's voices show \
      each channel's instrument, `variation` (the one it matches) and `variations`. Errors \
      list the channels and variations there are.
      """,
      [
        "action": prop("string", "list | save | apply | rename | delete"),
        "deck": prop("string", "A or B (a net deck)"),
        "channel": prop("integer", "A channel from dj_state's voices"),
        "instrument": prop(
          "string",
          "list: only this one; apply: play it with this instrument (default: the "
            + "channel's); rename / delete: whose variation"),
        "name": prop("string", "The variation's name"),
        "to": prop("string", "rename: the new name"),
      ]),
    tool(
      "dj_minecraft_events",
      """
      Minecraft gameplay fires stingers. Pass what the minecraft server's mc_recent_events \
      returned (its array of {at, source, event, params}, oldest first) as `events`; each \
      event is mapped through voices/minecraft-events.json (log:death → stinger 0, log:advancement → 1, minecraft:notification/players/joined → 2) and played \
      on `deck` (default: the focus deck), recorded like a button. The app keeps a cursor, so \
      re-sending an overlapping window fires each event once; a deck takes at most one \
      stinger a bar (the rest are skipped, with the reason). prime: take the events without \
      playing them (start a polling loop without replaying the backlog). Stingers need a net \
      deck.
      """,
      [
        "events": prop("array", "mc_recent_events' events, oldest first"),
        "deck": prop("string", "A or B (default: the focus deck)"),
        "prime": prop("boolean", "Take the events without playing any"),
      ], required: ["events"]),
    tool(
      "dj_press_pad",
      "Press a pad on the APC mini grid (the real one, or the on-screen one, which this shows). "
        + "Recorded as MIDI, exactly like the hardware.",
      [
        "group": prop(
          "string",
          "pads (8×8 grid, 0-63) | track (0-7) | scene (0-7) | drumPads (0-15); dj_catalog lists what each is bound to"
        ),
        "index": prop("integer", "Pad index within the group"),
        "shift": prop(
          "boolean",
          "true to hold SHIFT around the press. SHIFT + pads is the loop page: loops 1-64 read like text, top-left (pad 56) = loop 1, top row 1-8, the next row down 9-16 (in/out on the downbeat)"
        ),
      ],
      required: ["group", "index"]),
    tool(
      "dj_audition",
      "Play one instrument on the Mac's output, outside the decks: a strummed chord and a few "
        + "notes, or the MIDI notes you give. Also saved as a WAV; returns its path, level and "
        + "which sound it uses (pluck, or the wavetable family it folds into).",
      [
        "instrument": prop("string", "An instrument name from dj_catalog, e.g. acoustic-guitar"),
        "notes": obj([
          ("type", .string("array")), ("items", obj([("type", .string("integer"))])),
          (
            "description",
            .string("Optional MIDI notes, played 0.3 s apart (e.g. [40, 45, 50, 55])")
          ),
        ]),
        "play": prop("boolean", "false to only render the WAV (default true)"),
      ],
      required: ["instrument"]),
    tool(
      "dj_screenshot",
      "Capture the live DJApp window (decks, net rings, timeline, pads) and return it as a PNG "
        + "image. Also saved to disk; the path is in the text part.",
      [
        "path": prop(
          "string", "Where to save the PNG (default: ~/Library/Application Support/DJApp/shots/)")
      ]),
    tool(
      "dj_view",
      "Show or hide the main window's panels: the Soundboard (every loop as a big pad), "
        + "Controllers, Map, Scopes, the on-screen APC pads and the Loops master FX strip; fold "
        + "each deck's sections open or shut; set what the scope panel shows; open, close or set "
        + "the Stage window. Leave anything out to keep it as it is; returns what shows now.",
      [
        "soundboard": prop("boolean", "The Soundboard: one pad per loop, scenes on top"),
        "controllers": prop("boolean", "Every controller drawn with its bindings"),
        "map": prop("boolean", "The device map"),
        "scopes": prop("boolean", "The scope panel"),
        "pads": prop("boolean", "The on-screen APC mini grid"),
        "loopMasterFx": prop("boolean", "The Loops row's master FX strip"),
        "sections": obj([
          ("type", .string("object")),
          (
            "description",
            .string(
              "Per deck, the sections to show open (the rest fold), e.g. {\"A\": [\"perform\", "
                + "\"masterfx\"]}: perform, wander, masterfx, reverb, track, favorites, "
                + "generate, load, notes, history")
          ),
          (
            "additionalProperties",
            obj([("type", .string("array")), ("items", obj([("type", .string("string"))]))])
          ),
        ]),
        "scope": obj([
          ("type", .string("object")),
          ("description", .string("The scope panel (dj_state.scope)")),
          (
            "properties",
            obj([
              ("open", prop("boolean", "Show the panel (as scopes)")),
              ("kind", prop("string", "live | spectro | bands | raster")),
              ("source", prop("string", "master, A or B")),
              ("measured", prop("boolean", "The measured half (spectro and bands)")),
            ])
          ),
        ]),
        "stage": obj([
          ("type", .string("object")),
          ("description", .string("The Stage window (dj_state.stage)")),
          (
            "properties",
            obj([
              ("open", prop("boolean", "Open (true) or close (false) the window")),
              ("source", prop("string", "master, A or B")),
              (
                "visualizer",
                prop("string", "mandala (constellation) | corona | sonar | petal | shuffle")
              ),
              (
                "overlays",
                obj([
                  ("type", .string("array")), ("items", obj([("type", .string("string"))])),
                  (
                    "description",
                    .string("The overlays on, replacing the set: flow, pulse, flame, tilt, bolts")
                  ),
                ])
              ),
              ("background", prop("string", "void | stars | aurora")),
            ])
          ),
        ]),
      ]),
    tool(
      "dj_settings",
      """
      The monitoring settings: pfl {A, B} (a deck's headphone cue), headphoneMix (0 cue only … \
      1 master only in the headphones), headphoneLevel (0…1), awake (keep the screen from \
      sleeping) and inpulseOutput (master → the Inpulse's outputs 1/2, cue → 3/4; restarts the \
      audio engine, an error when no Inpulse is connected). Only the keys given change (a bad \
      one changes nothing); returns headphones {mix, level, pfl}, awake and inpulseOutput as \
      they stand (dj_state shows the same). These are monitoring, not performance: they never \
      reach the master mix, so a recorded session does not record them.
      """,
      [
        "pfl": prop("object", "Deck name → cue on/off, e.g. {\"A\": true, \"B\": false}"),
        "headphoneMix": prop("number", "0 = cue only … 1 = master only"),
        "headphoneLevel": prop("number", "Headphone volume, 0…1"),
        "awake": prop("boolean", "Keep the display awake while the app is open"),
        "inpulseOutput": prop("boolean", "Route master and cue to the Inpulse's audio outputs"),
      ]),
    tool(
      "dj_record",
      "Start (on: true) or stop (on: false) recording a session. Stopping saves it locally and "
        + "returns its CID. Publishing stays a button in the app: it is public.",
      ["on": prop("boolean", "true to start, false to stop and save")],
      required: ["on"]),
    tool(
      "dj_notes",
      """
      Notes on tracks. A note is text on what a deck plays — a net track by its share CID (the \
      same genre, seed and settings is the same track, so its notes come back whenever it plays \
      again), a sample by its content id, a loop clip by id — at the bar it was on. action list \
      (default): every note, or {deck} the notes on what that deck plays now, or {target} those \
      on a target key ("track:<cid>", "sample:<id>", "clip:<id>"); add {deck, text}: a note at \
      the deck's current bar, or {clip, text} on a loop clip; edit {id, text}; delete {id}. \
      Notes are journal events (dj_journal), so the History panel and `djctl journal show` list \
      them.
      """,
      [
        "action": prop("string", "list | add | edit | delete"),
        "deck": prop("string", "A or B"),
        "clip": prop("string", "A loop clip's id (dj_state.loops.clips[].id)"),
        "target": prop("string", "A target key, e.g. track:z4EBG…"),
        "text": prop("string", "The note"),
        "id": prop("string", "A note's id, from list"),
      ]),
    tool(
      "dj_loops",
      """
      The Loops row's buttons that are not deck actions. action list (default) returns \
      dj_state.loops; undo puts back the loop last taken off the row (the row's Undo, for a few \
      seconds after dj_perform clipRemove; clipRestore {id} brings back any removed loop); \
      loadSource {id, deck} loads the track a clip was taken from onto deck A or B (a net \
      composed again, at the section it was in; a sample while its audio is in memory; does not \
      start playback); export {id, path} writes a clip's audio as a 32-bit float stereo WAV to \
      path (an absolute .wav path, or a folder: named after the clip) and returns its frames and \
      sampleRate; stopAll takes every looping clip out on the next launch boundary (a clipLoop \
      off each, recorded) and returns the ids stopped. Starting, stopping, gain, crop, mute, \
      solo and a clip's FX (clipFx) are dj_perform ops.
      """,
      [
        "action": prop("string", "list | undo | loadSource | export | stopAll"),
        "id": prop("string", "A clip's id (dj_state.loops.clips[].id)"),
        "deck": prop("string", "A or B (loadSource)"),
        "path": prop("string", "export: an absolute .wav path, or a folder"),
      ]),
    tool(
      "dj_journal",
      """
      The app's journal: the always-on log of every state change this run (deck actions, \
      controller MIDI, favorites, crates, variations, locks, notes), the record a run is \
      rebuilt from (`djctl journal replay`). action list (default): the file and its latest \
      entries (seq, time, engine frame, kind, a summary, and the event as JSON), newest last. \
      action rewind {seq}: put the app back where it stood at that seq — the journal is \
      replayed to it, the decks, loop row, mixer and stores reset to the result — and journal a \
      `rewind <seq>` mark and a checkpoint (nothing is deleted: the journal is append-only). \
      Returns the checkpoint written and any clips or samples whose audio was gone.
      """,
      [
        "action": prop("string", "list | rewind"),
        "seq": prop("integer", "rewind: the entry to go back to (its seq, from list)"),
        "limit": prop("integer", "How many entries (default 50, at most 400)"),
        "kind": prop(
          "string", "Only entries of this kind, e.g. act, midi, note.add (prefix: note.)"),
      ]),
  ]

  static func tool(
    _ name: String, _ description: String, _ props: [String: JSONValue],
    required: [String] = []
  ) -> JSONValue {
    var schema = JSONObject([("type", .string("object"))])
    schema["properties"] = .object(
      JSONObject(props.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return obj([
      ("name", .string(name)), ("description", .string(description)),
      ("inputSchema", .object(schema)),
    ])
  }

  static func prop(_ type: String, _ description: String) -> JSONValue {
    obj([("type", .string(type)), ("description", .string(description))])
  }
}

private func obj(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(pairs)) }
