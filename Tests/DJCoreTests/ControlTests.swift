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
}
