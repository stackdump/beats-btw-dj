import Testing

@testable import DJCore

struct AgentStreamTests {
  @Test func theInitLineIsTheAgentBeingReady() {
    let e = AgentStream.parse(
      line:
        #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-x","tools":[]}"#)
    #expect(e == [.ready(session: "abc-123", model: "claude-x")])
    #expect(AgentStream.parse(line: #"{"type":"system","subtype":"status"}"#).isEmpty)
  }

  @Test func assistantTextAndToolCallsBecomeConsoleEvents() {
    let line = """
      {"type":"assistant","message":{"content":[
        {"type":"text","text":"Checking the set."},
        {"type":"tool_use","name":"mcp__dj-vevr-se__dj_set","input":{"action":"show","set":"first-night","wander":true}},
        {"type":"text","text":"   "}]}}
      """.replacingOccurrences(of: "\n", with: "")
    #expect(
      AgentStream.parse(line: line) == [
        .text("Checking the set."),
        .toolUse(name: "dj_set", summary: "action=show set=first-night wander=true"),
      ])
    // other servers' tools keep their full name; long arguments are cut
    let long = String(repeating: "x", count: 300)
    let e = AgentStream.parse(
      line:
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"\#(long)"}}]}}"#
    )
    guard case .toolUse(let name, let summary)? = e.first else {
      Issue.record("no tool use")
      return
    }
    #expect(name == "Read" && summary.count <= 200 && summary.hasSuffix("…"))
  }

  @Test func toolResultsAreOneLineAndErrorsAreFlagged() {
    let a = AgentStream.parse(
      line:
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"line one\nline two"}]}}"#
    )
    #expect(a == [.toolResult(text: "line one line two", isError: false)])
    let b = AgentStream.parse(
      line:
        #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":[{"type":"text","text":"no set called x"}]}]}}"#
    )
    #expect(b == [.toolResult(text: "no set called x", isError: true)])
    #expect(AgentStream.parse(line: #"{"type":"user","message":{"content":"hello"}}"#).isEmpty)
  }

  @Test func aTurnEndsWithItsCostOrItsError() {
    #expect(
      AgentStream.parse(
        line:
          #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.452,"num_turns":2}"#
      )
        == [.turnDone(ok: true, cost: 0.452, turns: 2, message: nil)])
    #expect(
      AgentStream.parse(
        line:
          #"{"type":"result","subtype":"error_max_budget_usd","total_cost_usd":5.1,"num_turns":9}"#)
        == [.turnDone(ok: false, cost: 5.1, turns: 9, message: "error_max_budget_usd")])
    #expect(
      AgentStream.parse(line: "not json").isEmpty
        && AgentStream.parse(line: #"{"type":"rate_limit_event"}"#).isEmpty)
  }

  @Test func aMessageIsOneStreamJSONUserLine() throws {
    let line = AgentStream.userMessage("more energy, \"darker\"\nplease")
    #expect(!line.contains("\n"))
    let v = try JSONValue.parse(line)
    #expect(v["type"]?.string == "user" && v["message"]?["role"]?.string == "user")
    #expect(v["message"]?["content"]?.string == "more energy, \"darker\"\nplease")
  }

  @Test func theLaunchArgumentsPrimeTheDJAndLockItToTheApp() {
    var l = AgentStream.Launch()
    let base = AgentStream.arguments(l)
    #expect(
      Array(base.prefix(7)) == [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--agent",
      ])
    #expect(base.contains("dj") && base.contains("--permission-mode") && base.contains("dontAsk"))
    #expect(base.contains("--max-budget-usd") && base.contains("5") && !base.contains("--resume"))
    #expect(!base.contains("--strict-mcp-config") && !base.contains("--model"))
    l.mcpConfigPath = "/x/mcp.json"
    l.model = "opus"
    l.resume = "sess-1"
    l.budgetUSD = 2.5
    let a = AgentStream.arguments(l)
    #expect(
      a.contains("--strict-mcp-config") && a.contains("--mcp-config") && a.contains("/x/mcp.json"))
    #expect(
      a.contains("--model") && a.contains("opus") && a.contains("--resume") && a.contains("sess-1")
        && a.contains("2.5"))
    #expect(
      a.firstIndex(of: "--allowedTools").map { a[$0 + 1] } == "mcp__dj-vevr-se,Skill,Read,Glob,Grep"
    )
    l.budgetUSD = nil
    #expect(!AgentStream.arguments(l).contains("--max-budget-usd"))
  }

  @Test func theMCPConfigNamesOnlyTheAppsServer() throws {
    let v = try JSONValue.parse(AgentStream.mcpConfig(djctl: "/a b/djctl"))
    let servers = try #require(v["mcpServers"]?.object)
    #expect(servers.keys == ["dj-vevr-se"])
    #expect(servers["dj-vevr-se"]?["command"]?.string == "/a b/djctl")
    #expect(servers["dj-vevr-se"]?["args"] == .array([.string("mcp")]))
  }

  @Test func claudeAndDjctlAreFoundWhereTheyUsuallyAre() {
    let have: Set<String> = [
      "/opt/bin/claude", "/Users/m/.local/bin/claude", "/p/build/mcp/djctl", "/custom/djctl",
    ]
    let exists: (String) -> Bool = { have.contains($0) }
    #expect(
      AgentStream.findClaude(env: ["PATH": "/usr/bin:/opt/bin"], home: "/Users/m", exists: exists)
        == "/opt/bin/claude")
    #expect(
      AgentStream.findClaude(env: ["PATH": "/usr/bin"], home: "/Users/m", exists: exists)
        == "/Users/m/.local/bin/claude")
    #expect(
      AgentStream.findClaude(
        env: ["DJ_CLAUDE": "/opt/bin/claude", "PATH": ""], home: "/h", exists: exists)
        == "/opt/bin/claude")
    #expect(AgentStream.findClaude(env: [:], home: "/nowhere", exists: { _ in false }) == nil)
    #expect(AgentStream.findDjctl(env: [:], cwd: "/p", exists: exists) == "/p/build/mcp/djctl")
    #expect(
      AgentStream.findDjctl(env: ["DJ_DJCTL": "/custom/djctl"], cwd: "/q", exists: exists)
        == "/custom/djctl")
    #expect(AgentStream.findDjctl(env: [:], cwd: "/q", exists: exists) == nil)
  }
}
