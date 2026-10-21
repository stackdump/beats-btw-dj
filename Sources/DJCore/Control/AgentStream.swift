import Foundation

// The Claude agent the app spawns (`DJViews/AgentController`): how to start `claude`, how to read
// its stream-json output, how to send it a message. Pure, so the whole protocol is tested against
// recorded lines and a fake `claude` without spending a cent.
//
//   claude -p --input-format stream-json --output-format stream-json --verbose --agent dj
//          --permission-mode dontAsk --strict-mcp-config --mcp-config <only dj-vevr-se>
//          --allowedTools mcp__dj-vevr-se,Skill,Read,Glob,Grep --max-budget-usd N [--model M]
//          [--resume <session>]
//
// One long-lived process: each user line is a turn; the agent (`.claude/agents/dj.md`) drives the
// app through the same MCP tools anyone else does, so everything it does is recorded.

public enum AgentEvent: Equatable, Sendable {
  case ready(session: String, model: String?)
  case text(String)
  case toolUse(name: String, summary: String)
  case toolResult(text: String, isError: Bool)
  /// A turn ended: `ok` false for errors (budget, max turns); cost is the session's so far.
  case turnDone(ok: Bool, cost: Double?, turns: Int?, message: String?)
}

public enum AgentStream {
  public static let mcpServerName = "dj-vevr-se"
  static let toolPrefix = "mcp__dj-vevr-se__"

  // MARK: reading

  /// The events one output line carries (none for lines the console doesn't show).
  public static func parse(line: String) -> [AgentEvent] {
    guard let v = try? JSONValue.parse(line), let type = v["type"]?.string else { return [] }
    switch type {
    case "system":
      guard v["subtype"]?.string == "init", let sid = v["session_id"]?.string else { return [] }
      return [.ready(session: sid, model: v["model"]?.string)]
    case "assistant":
      var out: [AgentEvent] = []
      for b in v["message"]?["content"]?.array ?? [] {
        switch b["type"]?.string {
        case "text":
          if let t = b["text"]?.string, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.text(t))
          }
        case "tool_use":
          let name = b["name"]?.string ?? "?"
          out.append(.toolUse(name: shortTool(name), summary: summarize(b["input"])))
        default: break
        }
      }
      return out
    case "user":
      guard let content = v["message"]?["content"]?.array else { return [] }
      return content.compactMap { b in
        guard b["type"]?.string == "tool_result" else { return nil }
        return .toolResult(
          text: oneLine(resultText(b["content"])), isError: b["is_error"]?.bool ?? false)
      }
    case "result":
      let ok = v["subtype"]?.string == "success" && v["is_error"]?.bool != true
      return [
        .turnDone(
          ok: ok, cost: v["total_cost_usd"]?.double, turns: v["num_turns"]?.int,
          message: ok ? nil : (v["result"]?.string ?? v["subtype"]?.string))
      ]
    default: return []
    }
  }

  static func shortTool(_ name: String) -> String {
    name.hasPrefix(toolPrefix) ? String(name.dropFirst(toolPrefix.count)) : name
  }

  /// `{"action":"show","set":"x"}` as `action=show set=x`: compact, for a console line.
  static func summarize(_ input: JSONValue?) -> String {
    guard let o = input?.object, !o.entries.isEmpty else { return "" }
    let parts = o.entries.map { k, v -> String in
      switch v {
      case .string(let s): return "\(k)=\(s.count > 40 ? String(s.prefix(37)) + "…" : s)"
      case .object, .array:
        let t = v.jsStringified
        return "\(k)=\(t.count > 48 ? String(t.prefix(45)) + "…" : t)"
      default: return "\(k)=\(v.jsStringified)"
      }
    }
    let s = parts.joined(separator: " ")
    return s.count > 200 ? String(s.prefix(197)) + "…" : s
  }

  static func resultText(_ c: JSONValue?) -> String {
    if let s = c?.string { return s }
    return (c?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: " ")
  }

  static func oneLine(_ s: String) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count > 220 ? String(flat.prefix(217)) + "…" : flat
  }

  // MARK: writing

  /// One user turn, as a stream-json input line (no trailing newline).
  public static func userMessage(_ text: String) -> String {
    JSONValue.object(
      JSONObject([
        ("type", .string("user")),
        ("message", .object(JSONObject([("role", .string("user")), ("content", .string(text))]))),
      ])
    ).jsStringified
  }

  // MARK: launching

  public struct Launch: Equatable, Sendable {
    public var agent = "dj"
    public var model: String?
    public var budgetUSD: Double? = 5
    /// Resume this session (the conversation continues), else a fresh one.
    public var resume: String?
    /// A JSON file naming only the dj-vevr-se MCP server; nil = whatever the user's config has.
    public var mcpConfigPath: String?
    public var allowedTools = "mcp__dj-vevr-se,Skill,Read,Glob,Grep"
    public init() {}
  }

  public static func arguments(_ l: Launch) -> [String] {
    var a = [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--agent", l.agent, "--permission-mode", "dontAsk", "--allowedTools", l.allowedTools,
    ]
    if let p = l.mcpConfigPath { a += ["--strict-mcp-config", "--mcp-config", p] }
    if let m = l.model, !m.isEmpty { a += ["--model", m] }
    if let b = l.budgetUSD, b > 0 { a += ["--max-budget-usd", String(format: "%g", b)] }
    if let r = l.resume, !r.isEmpty { a += ["--resume", r] }
    return a
  }

  /// The MCP config naming only the app's own server (`djctl mcp` over the control socket).
  public static func mcpConfig(djctl: String) -> String {
    JSONValue.object(
      JSONObject([
        (
          "mcpServers",
          .object(
            JSONObject([
              (
                mcpServerName,
                .object(
                  JSONObject([
                    ("command", .string(djctl)), ("args", .array([.string("mcp")])),
                  ]))
              )
            ]))
        )
      ])
    ).jsStringified
  }

  /// Where `claude` is: `$DJ_CLAUDE`, then PATH, then the usual install places.
  public static func findClaude(
    env: [String: String], home: String,
    exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> String? {
    if let p = env["DJ_CLAUDE"], exists(p) { return p }
    var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs += [
      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local",
      "\(home)/.npm-global/bin",
    ]
    for d in dirs where exists("\(d)/claude") { return "\(d)/claude" }
    return nil
  }

  /// `djctl` for the MCP config: `$DJ_DJCTL`, the project's `build/mcp/djctl` (`make mcp-install`).
  public static func findDjctl(
    env: [String: String], cwd: String,
    exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> String? {
    if let p = env["DJ_DJCTL"], exists(p) { return p }
    let p = "\(cwd)/build/mcp/djctl"
    return exists(p) ? p : nil
  }
}
