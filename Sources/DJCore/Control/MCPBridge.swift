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
    "dj_press_pad": "pad",
    "dj_record": "record", "dj_screenshot": "screenshot",
    "dj_audition": "audition", "dj_favorites": "favorites", "dj_copy_deck": "copyDeck",
    "dj_set_instrument": "setInstrument", "dj_stock_loops": "stockLoops",
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
    """

  static let tools: [JSONValue] = [
    tool(
      "dj_state",
      "Snapshot of the app: per deck (title, mode sample|net, playing, bpm, position, sections "
        + "and the current one, roles and which are on, volume/filter/pitch, quantize, next "
        + "track), crossfader, master, the LOOP-record clips and the loop channel (loops), "
        + "connected controllers, recording, status line, and the "
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
      reverbTone, value} (0…1, 0.5 = centre for filter/gain/eq; pitch is -1…1 = ±8%, 0 = none; \
      reverb: wet 0 = off, size 0…1 = 0.25…8 s decay, tone 0 dark … 1 bright) · crossfader {value 0…1, \
      0 = A} · master {value} · nextTrack {deck} · autoAdvance {deck, on} · \
      section {deck, index} · role {deck, role, on} · macro {deck, macro: id from \
      dj_catalog, a net macro or a master-chain FX / pitch / feel one} · panic {deck} · \
      stinger {deck, n 0-3} · sync {deck, align: beat|bar|tempo} \
      · quantize {deck, mode: off|beat|bar} · follow {deck, leader: deck or null} · \
      queueNext {deck, share: {genre, seed, structure?}} · \
      loopRecord {deck, on}: LOOP record, held (on true) then let go (on false): the deck's \
      bars from the downbeat before the press to the one after the release become a clip, \
      looping under the mixer (dj_state.loops) · clipLoop {id, on}: a clip in or out under the \
      mixer on the next downbeat (several loop at once) · clipGain {id, value 0…1} · \
      clipCrop {id, from, to}: keep its beats from..<to · clipSequence {steps: [{clip, repeats}], \
      replacing?}: join clips into a sequence (or rewrite one) · clip {deck: L|A|B, id}: move a \
      clip onto a deck (L = under the mixer). Deck "L" also takes param volume / mute (1 = muted).
      Net-only ops (section, role, macro, stinger, panic) need a deck in net mode. Use \
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
      structure). Takes a few seconds; returns the deck when loaded, with `share` = {kind \
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
      "dj_favorites",
      """
      The starred tracks (also the star by a deck's title and Load ▸ Favorites in the app). \
      action list (default) returns them, newest first, with title, cid, genre, seed; add \
      {deck} stars the net on a deck (instrument changes included); remove {cid | deck}; \
      load {deck, cid} puts one on a deck (does not start playback).
      """,
      [
        "action": prop("string", "list | add | remove | load"),
        "deck": prop("string", "A or B"),
        "cid": prop("string", "A favorite's cid, from list"),
      ]),
    tool(
      "dj_stock_loops",
      """
      The Apple Loops installed on this Mac (~15k; the Load panel's stock loops). action list \
      (default) filters by `category` (Drums, Bass, Keyboards…; the reply lists them) and \
      `query` words, nearest in tempo to `near` BPM (or the other deck's when `deck` is given) \
      first, up to `limit` (20); load {deck, path} puts one on a deck as a sample with its own \
      tempo as the beat grid (does not start playback).
      """,
      [
        "action": prop("string", "list | load"),
        "deck": prop("string", "A or B"),
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
      "dj_record",
      "Start (on: true) or stop (on: false) recording a session. Stopping saves it locally and "
        + "returns its CID. Publishing stays a button in the app: it is public.",
      ["on": prop("boolean", "true to start, false to stop and save")],
      required: ["on"]),
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
