import Testing

@testable import DJCore

struct ControlSocketTests {
  func tempSocket() -> String { tempSocketPath() }

  @Test func aRequestRoundTripsThroughTheSocket() async throws {
    let path = tempSocket()
    let server = try ControlServer(path: path) { method, params in
      if method == "boom" { throw ControlError.remote("no deck C") }
      return .object(JSONObject([("method", .string(method)), ("echo", params)]))
    }
    defer { server.stop() }
    let r = try await Task.detached {
      let c = try ControlClient(path: path, timeout: 60)
      let first = try c.request("state", .object(JSONObject([("x", .int(1))])))
      let second = try c.request("catalog")  // same connection, next line
      return (first, second)
    }.value
    #expect(r.0["method"]?.string == "state")
    #expect(r.0["echo"]?["x"]?.int == 1)
    #expect(r.1["method"]?.string == "catalog")
    let err = await Task.detached { () -> ControlError? in
      do {
        _ = try ControlClient(path: path, timeout: 60).request("boom")
        return nil
      } catch { return error as? ControlError }
    }.value
    #expect(err == .remote("no deck C"))
  }

  @Test func theSocketIsUserOnlyAndGoesAwayOnStop() throws {
    let path = tempSocket()
    let server = try ControlServer(path: path) { _, _ in .null }
    #expect(posixMode(path) == 0o600)
    server.stop()
    #expect(!fileExists(path))
  }

  @Test func noAppMeansAClearError() {
    #expect(throws: ControlError.self) { try ControlClient(path: tempSocket(), timeout: 1) }
  }

  @Test func garbageGetsAnErrorLineNotADroppedConnection() async throws {
    let reply = await ControlServer.respond(to: "not json") { _, _ in .null }
    #expect(try JSONValue.parse(reply)["error"]?.string != nil)
  }
}

struct MCPBridgeTests {
  func bridge(_ seen: Box) -> MCPBridge {
    MCPBridge { method, params in
      seen.calls.append((method, params))
      if method == "perform" { throw ControlError.remote("no deck C") }
      return .object(JSONObject([("ok", .bool(true))]))
    }
  }
  final class Box: @unchecked Sendable { var calls: [(String, JSONValue)] = [] }

  func reply(_ b: MCPBridge, _ line: String) throws -> JSONValue {
    try JSONValue.parse(try #require(b.handle(line)))
  }

  @Test func initializeEchoesTheProtocolAndOffersTools() throws {
    let r = try reply(
      bridge(Box()),
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
    #expect(r["id"]?.int == 1)
    #expect(r["result"]?["protocolVersion"]?.string == "2025-03-26")
    #expect(r["result"]?["capabilities"]?["tools"] != nil)
    #expect(r["result"]?["serverInfo"]?["name"]?.string == "dj-vevr-se")
    #expect(r["result"]?["serverInfo"]?["version"]?.string == BuildInfo.current.id)
  }

  @Test func notificationsGetNoReply() {
    #expect(bridge(Box()).handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
  }

  @Test func everyToolHasASchemaAndAMethod() throws {
    let r = try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = try #require(r["result"]?["tools"]?.array)
    #expect(tools.count == MCPBridge.methods.count)
    for t in tools {
      let name = try #require(t["name"]?.string)
      #expect(MCPBridge.methods[name] != nil, "\(name) routes somewhere")
      #expect(t["inputSchema"]?["type"]?.string == "object")
      #expect((t["description"]?.string ?? "").isEmpty == false)
    }
  }

  @Test func aToolCallBecomesOneControlRequest() throws {
    let seen = Box()
    let r = try reply(
      bridge(seen),
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"dj_generate","arguments":{"deck":"A","genre":"techno","seed":7}}}"#
    )
    #expect(seen.calls.count == 1)
    #expect(seen.calls[0].0 == "generate")
    #expect(seen.calls[0].1["genre"]?.string == "techno")
    #expect(r["result"]?["isError"]?.bool == false)
    #expect(r["result"]?["content"]?[0]?["text"]?.string == #"{"ok":true}"#)
  }

  @Test func loadShareIsOneControlRequest() throws {
    let seen = Box()
    let link = "https://beats.bitwrap.io/?g=house&s=7"
    let r = try reply(
      bridge(seen),
      #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"dj_load_share","arguments":{"deck":"B","link":"\#(link)"}}}"#
    )
    #expect(seen.calls.count == 1 && seen.calls[0].0 == "loadShare")
    #expect(seen.calls[0].1["link"]?.string == link && seen.calls[0].1["deck"]?.string == "B")
    #expect(r["result"]?["isError"]?.bool == false)
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":8,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    let tool = try #require(tools.first { $0["name"]?.string == "dj_load_share" })
    #expect(tool["inputSchema"]?["required"] == .array([.string("deck"), .string("link")]))
    #expect(tool["description"]?.string?.contains("raw-nets") == true)
  }

  @Test func appErrorsAreToolErrorsNotProtocolErrors() throws {
    let r = try reply(
      bridge(Box()),
      #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"dj_perform","arguments":{}}}"#
    )
    #expect(r["error"] == nil)
    #expect(r["result"]?["isError"]?.bool == true)
    #expect(r["result"]?["content"]?[0]?["text"]?.string == "no deck C")
  }

  @Test func unknownThingsAreProtocolErrors() throws {
    let b = bridge(Box())
    #expect(
      try reply(b, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)["error"]?["code"]?.int
        == -32601)
    #expect(
      try reply(b, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"dj_nope"}}"#)[
        "error"]?["code"]?.int == -32602)
  }

  /// Every op the session decoder takes (but load, which dj_perform refuses) decodes from a
  /// minimal object and is named in dj_perform's description as `op {` or `op/`.
  @Test func everyPerformOpIsDocumented() throws {
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    let text = try #require(
      tools.first { $0["name"]?.string == "dj_perform" }?["description"]?.string)
    // the fields an op cannot decode without
    let needs: [String: String] = [
      "queueNext": #""share":{"genre":"techno","seed":1}"#,
      "voiceTweak": #""channel":0"#, "voiceSynth": #""channel":0"#,
      "clipMove": #""id":"x""#, "clipFx": #""id":"x""#, "lock": #""key":"A.play""#,
      "wanderPace": #""bars":8"#, "wanderLock": #""dimension":"tempo""#,
      "setRoleVoice": #""role":"bass""#, "clipImport": #""id":"x""#,
      "masterFx": #""key":"lp-freq""#,
    ]
    #expect(Set(DeckAction.jsonOps).count == DeckAction.jsonOps.count)
    for op in DeckAction.jsonOps where op != "load" {
      let extra = needs[op].map { "," + $0 } ?? ""
      let v = try JSONValue.parse(#"{"op":"\#(op)","deck":"A"\#(extra)}"#)
      let a = DeckAction(json: v)
      #expect(a != nil, "\(op) decodes")
      #expect(a?.json["op"]?.string == op, "\(op) encodes back as itself")
      #expect(
        text.contains("\(op) {") || text.contains("\(op)/") || text.contains("/\(op) {"),
        "dj_perform's description documents \(op)")
    }
    let dims = WanderLock.dimensions.joined(separator: "|")
    #expect(text.contains("dimension: \(dims)|keep:<role>"), "wanderLock's dimensions are listed")
  }

  /// clipRetune takes its instruments by MIDI channel (`{"3": "saw"}`), and dj_perform says so.
  @Test func clipRetuneTakesVoicesByChannel() throws {
    let v = try JSONValue.parse(
      #"{"op":"clipRetune","id":"x","voices":{"3":"saw","bass":"piano","1":"organ"}}"#)
    #expect(DeckAction(json: v) == .clipRetune(id: "x", voices: [3: "saw", 1: "organ"]))
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    let text = try #require(
      tools.first { $0["name"]?.string == "dj_perform" }?["description"]?.string)
    #expect(text.contains(#"clipRetune {id, voices: {"<MIDI channel>": instrument}}"#))
  }

  /// The mix-out / mix-in ops say their bars and defaults, and that they need a net deck.
  @Test func mixOutAndMixInAreDocumented() throws {
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    let text = try #require(
      tools.first { $0["name"]?.string == "dj_perform" }?["description"]?.string)
    #expect(text.contains("mixOut {deck, bars? 1-64, default \(MixOutTail.defaultBars)}"))
    #expect(text.contains("mixIn {deck, bars? 1-64, default \(DeckAction.defaultMixInBars)}"))
    // Master FX run on sample decks too (the user's call), so panic left the net-only list.
    #expect(text.contains("stinger, mixOut, mixIn) need a deck in net mode"))
    #expect(text.contains("master-chain macros and panic also work on a sample deck"))
    let mix = try #require(DeckAction.jsonOps.firstIndex(of: "mixOut"))
    #expect(DeckAction.jsonOps[mix + 1] == "mixIn")
  }

  /// The controller-only ops say what they take: the focus targets, the STEMS groups, and every
  /// master FX slider key with the 0…1 travel.
  @Test func theControllerOnlyOpsAreDocumented() throws {
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":12,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    let text = try #require(
      tools.first { $0["name"]?.string == "dj_perform" }?["description"]?.string)
    #expect(text.contains("rewind {deck}"))
    #expect(text.contains("focus {deck: A|B|L}"))
    #expect(
      text.contains(
        "stemMute {deck, stem: \(Deck.stemNames.reversed().joined(separator: "|")), on}"))
    let keys = MasterFxKey.allCases.map(\.id).joined(separator: "|")
    #expect(text.contains("masterFx {deck, key: \(keys), value 0…1}"))
  }

  @Test func importingAStockLoopOntoTheRowIsDocumented() throws {
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    func text(_ name: String) -> String {
      tools.first { $0["name"]?.string == name }?["description"]?.string ?? ""
    }
    #expect(text("dj_perform").contains("clipImport {id, title, bpm, beats, provenance?}"))
    #expect(text("dj_stock_loops").contains("addToRow {path}"))
    #expect(text("dj_stock_loops").contains("never published"))
    let stock = tools.first { $0["name"]?.string == "dj_stock_loops" }
    #expect(
      stock?["inputSchema"]?["properties"]?["action"]?["description"]?.string
        == "list | load | addToRow")
  }

  @Test func dJPerformDocumentsAClipsOwnFollow() throws {
    let tools = try #require(
      try reply(bridge(Box()), #"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#)["result"]?[
        "tools"]?.array)
    let text = try #require(
      tools.first { $0["name"]?.string == "dj_perform" }?["description"]?.string)
    #expect(text.contains("clipFollow {id, mode: louder|source or null}"))
    #expect(DeckAction.jsonOps.contains("clipFollow"))
  }
}
