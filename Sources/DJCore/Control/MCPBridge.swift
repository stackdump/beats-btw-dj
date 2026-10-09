import Foundation

/// The MCP face of the control socket: stdio JSON-RPC in (`djctl mcp`), one control request
/// out per tool call. It knows the tool list and how to phrase errors; the app decides what
/// each request does. Kept free of I/O so it can be tested line by line.
public struct MCPBridge {
  public typealias Call = (_ method: String, _ params: JSONValue) throws -> JSONValue
  public let call: Call
  public var version: String

  public init(version: String = "0.1.0", call: @escaping Call) {
    self.call = call
    self.version = version
  }

  /// Tool name → control method.
  static let methods: [String: String] = [
    "dj_state": "state", "dj_perform": "perform", "dj_generate": "generate",
    "dj_catalog": "catalog", "dj_load_file": "loadFile", "dj_press_pad": "pad",
    "dj_record": "record", "dj_screenshot": "screenshot",
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
        + "track), crossfader, master, connected controllers, recording, status line.",
      [:]),
    tool(
      "dj_perform",
      """
      Apply one deck action, as a button or fader in the app would. `action` is an object \
      with `op` plus fields:
      play {deck, on} · cue {deck} · hotCue/clearCue {deck, slot 0-7} · \
      loop {deck, loop: in|out|halve|double} · \
      param {deck, name: volume|filter|gain|eqLow|eqMid|eqHigh|pitch, value} (0…1, 0.5 = \
      centre for filter/gain/eq; pitch is -1…1 = ±8%, 0 = none) · crossfader {value 0…1, \
      0 = A} · master {value} · nextTrack {deck} · autoAdvance {deck, on} · \
      section {deck, index} · role {deck, role, on} · macro {deck, macro: id from \
      dj_catalog} · panic {deck} · stinger {deck, n 0-3} · sync {deck, align: beat|bar|tempo} \
      · quantize {deck, mode: off|beat|bar} · follow {deck, leader: deck or null} · \
      queueNext {deck, share: {genre, seed, structure?}}.
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
      "dj_press_pad",
      "Press a pad on the APC mini grid (the real one, or the on-screen one, which this shows). "
        + "Recorded as MIDI, exactly like the hardware.",
      [
        "group": prop(
          "string",
          "pads (8×8 grid, 0-63) | track (0-7) | scene (0-7) | drumPads (0-15); dj_catalog lists what each is bound to"
        ),
        "index": prop("integer", "Pad index within the group"),
      ],
      required: ["group", "index"]),
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
