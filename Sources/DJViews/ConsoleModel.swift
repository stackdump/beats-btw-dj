import DJCore
import Foundation
import Observation

/// The debug console's state: a scrollback of lines and a command history. Commands run through the
/// same `AppModel.control` the control socket and the MCP use, so everything the MCP can do is here,
/// recorded the same way. The parsing is `ConsoleParser` (DJCore); the Claude agent is `agent …`.
@MainActor @Observable
public final class ConsoleModel {
  public enum Kind: Sendable { case input, output, error, info, agent, agentTool, event }

  public struct Line: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: Kind
    public var text: String
  }

  public private(set) var lines: [Line] = []
  public var input = ""
  public private(set) var history: [String] = []
  /// A command is running (a compose or a load takes a moment).
  public private(set) var busy = false
  /// Longer outputs are shortened: `expand` prints the last one in full.
  public static let maxOutputLines = 80

  private var nextID = 0
  private var cursor: Int?  // position in `history` while browsing with ↑/↓
  private var stash = ""  // what was typed before browsing
  private var lastFull: String?
  private let defaults: UserDefaults
  /// The defaults the history is kept in (tests build a second console on the same ones).
  var testDefaults: UserDefaults { defaults }
  // strong: the app owns its one console for the life of the process
  var app: AppModel?
  /// `agent …` (set by `AgentController`): (subcommand, text).
  var agentHandler: ((String, String) async -> Void)?

  static let historyKey = "console.history"
  static let historyLimit = 300

  public init(app: AppModel?, defaults: UserDefaults = .standard) {
    self.app = app
    self.defaults = defaults
    history = defaults.stringArray(forKey: Self.historyKey) ?? []
    add(
      .info,
      "dj-vevr-se debug console. `help` for the commands, `tools` for every tool; ⇥ completes.")
  }

  // MARK: lines

  public func add(_ kind: Kind, _ text: String) {
    for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
      lines.append(Line(id: nextID, kind: kind, text: String(part)))
      nextID += 1
    }
    if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
  }

  public func clear() { lines = [] }

  // MARK: input

  /// Run what is typed.
  public func submit() async {
    let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
    input = ""
    cursor = nil
    guard !line.isEmpty else { return }
    if history.last != line { history.append(line) }
    if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    defaults.set(history, forKey: Self.historyKey)
    await run(line)
  }

  /// ↑: an older command (the line being typed is kept for ↓ to come back to).
  public func historyBack() {
    guard !history.isEmpty else { return }
    if cursor == nil {
      stash = input
      cursor = history.count - 1
    } else if let c = cursor, c > 0 {
      cursor = c - 1
    }
    if let c = cursor { input = history[c] }
  }

  public func historyForward() {
    guard let c = cursor else { return }
    if c + 1 < history.count {
      cursor = c + 1
      input = history[c + 1]
    } else {
      cursor = nil
      input = stash
    }
  }

  /// ⇥: complete the word being typed (the common prefix of the candidates; the candidates listed
  /// when there are several).
  public func complete() {
    let c = ConsoleParser.complete(input)
    guard !c.isEmpty else { return }
    let current = input.last == " " ? "" : String(input.split(separator: " ").last ?? "")
    if c.count == 1 {
      input = String(input.dropLast(current.count)) + c[0] + (c[0].hasSuffix("=") ? "" : " ")
      return
    }
    var prefix = c[0]
    for x in c.dropFirst() { while !x.hasPrefix(prefix) { prefix.removeLast() } }
    if prefix.count > current.count { input = String(input.dropLast(current.count)) + prefix }
    add(.info, c.joined(separator: "  "))
  }

  // MARK: running

  public func run(_ line: String) async {
    add(.input, "› " + line)
    switch ConsoleParser.parse(line) {
    case .blank: break
    case .error(let m): add(.error, m)
    case .help(let word):
      add(.info, word.map(ConsoleHelp.detail) ?? ConsoleHelp.usage)
    case .tools(let filter): add(.info, ConsoleHelp.overview(filter: filter))
    case .clear: clear()
    case .history:
      add(
        .info,
        history.enumerated().map { "\($0.offset + 1)  \($0.element)" }.suffix(40).joined(
          separator: "\n"))
    case .expand:
      if let full = lastFull { add(.output, full) } else { add(.info, "nothing to expand") }
    case .tool(_, let method, let params): await call(method, params)
    case .raw(let method, let params): await call(method, params)
    case .agent(let sub, let text):
      if let agentHandler {
        await agentHandler(sub, text)
      } else {
        add(.error, "the agent is not available here")
      }
    }
  }

  private func call(_ method: String, _ params: JSONValue) async {
    guard let app else { return add(.error, "no app") }
    busy = true
    defer { busy = false }
    let started = Date()
    do {
      let result = try await app.control(method, params)
      output(ConsoleFormat.pretty(result))
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      if ms >= 250 { add(.info, "(\(ms) ms)") }
    } catch {
      add(.error, "error: \(error)")
    }
  }

  private func output(_ text: String) {
    let all = text.split(separator: "\n", omittingEmptySubsequences: false)
    lastFull = text
    if all.count <= Self.maxOutputLines { return add(.output, text) }
    add(.output, all.prefix(Self.maxOutputLines).joined(separator: "\n"))
    add(.info, "… \(all.count - Self.maxOutputLines) more lines (`expand` prints it all)")
  }
}

/// JSON for reading: two-space indentation, short scalar arrays on one line, strings as text.
public enum ConsoleFormat {
  public static func pretty(_ v: JSONValue, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number, .string: return v.jsStringified
    case .array(let a):
      if a.isEmpty { return "[]" }
      let scalars = a.allSatisfy {
        if case .array = $0 { false } else if case .object = $0 { false } else { true }
      }
      if scalars {
        let inline = "[" + a.map { $0.jsStringified }.joined(separator: ", ") + "]"
        if inline.count <= 100 { return inline }
      }
      return "[\n" + a.map { pad + "  " + pretty($0, indent: indent + 1) }.joined(separator: ",\n")
        + "\n" + pad + "]"
    case .object(let o):
      if o.entries.isEmpty { return "{}" }
      return "{\n"
        + o.entries.map {
          pad + "  " + JSONValue.string($0.key).jsStringified + ": "
            + pretty($0.value, indent: indent + 1)
        }
        .joined(separator: ",\n") + "\n" + pad + "}"
    }
  }
}
