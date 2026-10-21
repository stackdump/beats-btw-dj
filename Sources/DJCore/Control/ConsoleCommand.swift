import Foundation

// The debug console's command language (`DJViews/ConsoleView`): a CLI over the same tools the MCP
// exposes — one parser, built from `MCPBridge`'s own tool list, so a tool added to the MCP is in
// the console the same moment, with its help and completion. Pure: a line in, a command out.
//
//   state                                  a tool, by its short name (dj_ is optional)
//   set show first-night                   bare words fill the tool's usual first arguments
//   set action=plan set=fri count=6 shape=arc bpm=[124,150]    key=value, values read as JSON
//   perform op=crossfader value=0          dj_perform: key=value pairs are the action's fields
//   compose {"deck":"A","parts":{…}}        a JSON object is merged into the arguments
//   raw loadShare {"deck":"A","link":"…"}   a control-socket method, directly
//   help [tool] · tools [filter] · clear · history · expand · agent <start|stop|say …>

/// One MCP tool as the console sees it.
public struct MCPToolInfo: Equatable, Sendable {
  public struct Property: Equatable, Sendable {
    public var name: String
    public var type: String
    public var description: String
  }

  public var name: String  // dj_set
  public var method: String  // set (the control-socket method)
  public var description: String
  public var properties: [Property]
  public var required: [String]

  /// `set` for `dj_set`.
  public var shortName: String { name.hasPrefix("dj_") ? String(name.dropFirst(3)) : name }

  /// The first sentence, for the tool list.
  public var summary: String {
    let flat = description.replacingOccurrences(of: "\n", with: " ")
    if let dot = flat.range(of: ". ") ?? flat.range(of: ": ") {
      let s = String(flat[..<dot.lowerBound])
      if s.count >= 16 { return s.count > 110 ? String(s.prefix(107)) + "…" : s }
    }
    return flat.count > 110 ? String(flat.prefix(107)) + "…" : flat
  }
}

extension MCPBridge {
  /// Every tool the MCP lists, with its control method, in the MCP's order.
  public static var catalog: [MCPToolInfo] {
    tools.compactMap { t in
      guard let name = t["name"]?.string, let method = methods[name] else { return nil }
      let schema = t["inputSchema"]
      let props = (schema?["properties"]?.object?.entries ?? []).map { k, v in
        MCPToolInfo.Property(
          name: k, type: v["type"]?.string ?? "any", description: v["description"]?.string ?? "")
      }
      let required = (schema?["required"]?.array ?? []).compactMap(\.string)
      return MCPToolInfo(
        name: name, method: method, description: t["description"]?.string ?? "",
        properties: props, required: required)
    }
  }
}

/// A console message that is an error (a failed lookup, a bad argument).
public struct ConsoleMessage: Error, Equatable {
  public var text: String
  public init(_ t: String) { text = t }
}

public enum ConsoleCommand: Equatable {
  case blank
  case help(String?)
  case tools(String?)
  case clear
  case history
  case expand
  case tool(name: String, method: String, params: JSONValue)
  case raw(method: String, params: JSONValue)
  /// `agent <sub> [text]`: the Claude process (`AgentProcess`).
  case agent(String, String)
  case error(String)
}

public enum ConsoleParser {
  /// Bare words fill these arguments in order (`set show first-night`), for the tools whose
  /// first arguments are usually obvious. A word past the list is an error.
  static let positional: [String: [String]] = [
    "dj_set": ["action", "set"], "dj_compositions": ["action", "id"],
    "dj_favorites": ["action"], "dj_journal": ["action"], "dj_loops": ["action"],
    "dj_notes": ["action"], "dj_view": ["action"], "dj_settings": ["action"],
    "dj_variations": ["action"], "dj_record": ["on"], "dj_palettes": ["deck"],
    "dj_generate": ["deck", "genre", "seed"], "dj_load_share": ["deck", "link"],
    "dj_load_file": ["deck", "path"], "dj_import": ["path", "deck"],
    "dj_perform": ["op", "deck"], "dj_press_pad": ["group", "index"],
    "dj_copy_deck": ["from", "to"], "dj_audition": [],
  ]

  static let builtins = ["help", "tools", "clear", "history", "expand", "raw", "agent"]

  /// Resolve `word` to a tool: its full name, its short name, or an unambiguous prefix (3+ letters).
  public static func resolve(_ word: String) -> Result<MCPToolInfo, ConsoleMessage> {
    let all = MCPBridge.catalog
    let w = word.lowercased()
    if let t = all.first(where: { $0.name == w || $0.shortName == w }) { return .success(t) }
    let near = all.filter { $0.shortName.hasPrefix(w) || $0.name.hasPrefix(w) }
    if near.count == 1, w.count >= 3 { return .success(near[0]) }
    if near.count > 1 {
      return .failure(
        ConsoleMessage(
          "`\(word)` is ambiguous: \(near.map(\.shortName).sorted().joined(separator: ", "))"))
    }
    let guess = all.map(\.shortName).filter { $0.contains(w) }
    return .failure(
      ConsoleMessage(
        "unknown command `\(word)`"
          + (guess.isEmpty
            ? " (help lists the tools)"
            : ": did you mean \(guess.sorted().joined(separator: ", "))?")))
  }

  // MARK: tokens

  /// Split a line into words: quotes group (and drop their quotes), a `{…}` / `[…]` JSON value is one
  /// word (balanced, quotes inside respected), also after `key=`.
  static func tokens(_ line: String) throws -> [String] {
    var out: [String] = []
    var cur = ""
    var started = false
    var i = line.startIndex
    func flush() {
      if started { out.append(cur) }
      cur = ""
      started = false
    }
    while i < line.endIndex {
      let c = line[i]
      if c == " " || c == "\t" {
        flush()
        i = line.index(after: i)
      } else if c == "\"" || c == "'" {
        let q = c
        started = true
        i = line.index(after: i)
        while i < line.endIndex, line[i] != q {
          if line[i] == "\\", line.index(after: i) < line.endIndex {
            i = line.index(after: i)
          }
          cur.append(line[i])
          i = line.index(after: i)
        }
        guard i < line.endIndex else { throw ConsoleParseError("unterminated quote") }
        i = line.index(after: i)
      } else if c == "{" || c == "[" {
        started = true
        var depth = 0
        var inString = false
        var esc = false
        while i < line.endIndex {
          let d = line[i]
          cur.append(d)
          if inString {
            if esc {
              esc = false
            } else if d == "\\" {
              esc = true
            } else if d == "\"" {
              inString = false
            }
          } else if d == "\"" {
            inString = true
          } else if d == "{" || d == "[" {
            depth += 1
          } else if d == "}" || d == "]" {
            depth -= 1
          }
          i = line.index(after: i)
          if depth == 0 { break }
        }
        guard depth == 0 else { throw ConsoleParseError("unbalanced \(c) in JSON") }
      } else {
        started = true
        cur.append(c)
        i = line.index(after: i)
      }
    }
    flush()
    return out
  }

  struct ConsoleParseError: Error {
    var message: String
    init(_ m: String) { message = m }
  }

  /// A value as JSON when it reads as JSON (numbers, true / false / null, arrays, objects), else text.
  static func value(_ s: String) -> JSONValue {
    if s == "true" { return .bool(true) }
    if s == "false" { return .bool(false) }
    if s == "null" { return .null }
    if let first = s.first, "{[-0123456789".contains(first), let v = try? JSONValue.parse(s) {
      return v
    }
    return .string(s)
  }

  // MARK: parse

  public static func parse(_ line: String) -> ConsoleCommand {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return .blank }
    let words: [String]
    do { words = try tokens(trimmed) } catch let e as ConsoleParseError {
      return .error(e.message)
    } catch {
      return .error("\(error)")
    }
    guard let head = words.first?.lowercased() else { return .blank }
    let rest = Array(words.dropFirst())
    switch head {
    case "help", "?": return .help(rest.first)
    case "tools", "ls": return .tools(rest.first)
    case "clear", "cls": return .clear
    case "history": return .history
    case "expand": return .expand
    case "agent":
      let sub = rest.first?.lowercased() ?? "status"
      // the text after the subcommand, as typed
      let text: String = {
        guard let r = trimmed.range(of: rest.first ?? "\u{0}") else { return "" }
        return String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
      }()
      return .agent(sub, text)
    case "raw":
      guard let method = rest.first else {
        return .error("raw <method> [json]: a control-socket method")
      }
      var params = JSONObject()
      for w in rest.dropFirst() {
        if w.hasPrefix("{") {
          guard let v = try? JSONValue.parse(w), let o = v.object else {
            return .error("not a JSON object: \(w)")
          }
          for (k, x) in o.entries { params[k] = x }
        } else if let eq = w.firstIndex(of: "=") {
          params[String(w[..<eq])] = value(String(w[w.index(after: eq)...]))
        } else {
          return .error("raw takes key=value or a JSON object, not `\(w)`")
        }
      }
      return .raw(method: method, params: .object(params))
    default: break
    }

    let tool: MCPToolInfo
    switch resolve(head) {
    case .success(let t): tool = t
    case .failure(let m): return .error(m.text)
    }
    var params = JSONObject()
    var extras = JSONObject()  // dj_perform: loose key=value pairs are the action's fields
    var order = positional[tool.name] ?? []
    for w in rest {
      if w.hasPrefix("{") {
        guard let v = try? JSONValue.parse(w), let o = v.object else {
          return .error("not a JSON object: \(w)")
        }
        for (k, x) in o.entries { params[k] = x }
      } else if let eq = w.firstIndex(of: "="), eq != w.startIndex,
        w[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
      {
        let key = String(w[..<eq])
        let val = value(String(w[w.index(after: eq)...]))
        if tool.name == "dj_perform", key != "action" {
          extras[key] = val
        } else {
          params[key] = val
          order.removeAll { $0 == key }
        }
      } else {
        guard !order.isEmpty else {
          return .error(
            "`\(w)`: no argument to put it in. Use key=value (\(tool.properties.prefix(6).map(\.name).joined(separator: ", ")))"
          )
        }
        let key = order.removeFirst()
        if tool.name == "dj_perform" { extras[key] = value(w) } else { params[key] = value(w) }
      }
    }
    if tool.name == "dj_perform", !extras.entries.isEmpty {
      var action = params["action"]?.object ?? JSONObject()
      for (k, x) in extras.entries { action[k] = x }
      params["action"] = .object(action)
    }
    return .tool(name: tool.name, method: tool.method, params: .object(params))
  }

  // MARK: completion

  /// Candidates for the word being typed at the end of `line` (a trailing space starts a new word).
  public static func complete(_ line: String) -> [String] {
    let endsWithSpace = line.last == " "
    let words = (try? tokens(line)) ?? line.split(separator: " ").map(String.init)
    let catalog = MCPBridge.catalog
    if words.isEmpty || (words.count == 1 && !endsWithSpace) {
      let prefix = (words.first ?? "").lowercased()
      let all = builtins + catalog.map(\.shortName)
      return Array(Set(all.filter { $0.hasPrefix(prefix) })).sorted()
    }
    guard case .success(let tool) = resolve(words[0]) else { return [] }
    let current = endsWithSpace ? "" : words.last!
    guard !current.contains("=") else { return [] }
    let used = Set(
      words.dropFirst().compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
    )
    return tool.properties.map(\.name).filter { $0.hasPrefix(current) && !used.contains($0) }
      .sorted().map { $0 + "=" }
  }
}

// MARK: - help

public enum ConsoleHelp {
  public static let usage = """
    A CLI over the same tools the MCP exposes (every `dj_*` tool; the dj_ is optional).

      <tool> [word …] [key=value …] [{json}]     e.g.  state · set show first-night · perform play A on=true
      raw <method> [key=value …] [{json}]        a control-socket method directly
      tools [filter]    list the tools        help <tool>    one tool's arguments
      history           your commands         clear · expand (the last long output in full)
      agent <start|stop|restart|status|say <text>|wake on|off|cwd <dir>|model <m>|budget <usd>>
                        the Claude agent: start it, talk to it, see what it does

    Bare words fill a tool's usual first arguments (set show NAME → action=show set=NAME).
    Values read as JSON (6, true, [124,150]) else text. `perform` takes its fields loose:
    perform op=crossfader value=0. ↑/↓ history · ⇥ complete · ⌘K clear.
    """

  public static func overview(filter: String? = nil) -> String {
    let all = MCPBridge.catalog.filter {
      filter == nil || $0.name.contains(filter!.lowercased())
        || $0.description.lowercased().contains(filter!.lowercased())
    }
    let width = (all.map { $0.shortName.count }.max() ?? 8) + 2
    return all.map {
      $0.shortName.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary
    }
    .joined(separator: "\n")
  }

  public static func detail(_ word: String) -> String {
    switch ConsoleParser.resolve(word) {
    case .failure(let m): return m.text
    case .success(let t):
      var s = "\(t.name)  (control method `\(t.method)`)\n\n\(t.description)\n"
      if !t.properties.isEmpty {
        s += "\narguments:\n"
        let w = (t.properties.map { $0.name.count }.max() ?? 4) + 1
        for p in t.properties {
          let req = t.required.contains(p.name) ? " (required)" : ""
          s +=
            "  " + p.name.padding(toLength: w, withPad: " ", startingAt: 0)
            + "\(p.type)\(req)  \(p.description)\n"
        }
      }
      if let pos = ConsoleParser.positional[t.name], !pos.isEmpty {
        s += "\nbare words fill: \(pos.joined(separator: ", "))"
      }
      return s
    }
  }
}
