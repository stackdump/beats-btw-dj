import DJCore
import Foundation
import Observation

/// The Claude agent the app spawns and talks to: one long-lived `claude -p` process in stream-json
/// mode, primed as the DJ (`.claude/agents/dj.md`), that drives the app through the MCP like anyone
/// else. The console is its terminal (`agent start | say … | stop`); what it says and does is
/// printed there. The app can also wake it when something happens (a hand-off finished): off by
/// default, because every wake is a turn that costs money.
@MainActor @Observable
public final class AgentController {
  public enum State: String, Sendable { case stopped, starting, idle, working }

  public private(set) var state: State = .stopped
  public private(set) var session: String?
  /// The session's cost so far (USD) and its turns, from the agent's own result lines.
  public private(set) var cost = 0.0
  public private(set) var turns = 0
  public var wakeOnEvents: Bool { didSet { defaults.set(wakeOnEvents, forKey: Keys.wake) } }
  public var cwd: String { didSet { defaults.set(cwd, forKey: Keys.cwd) } }
  public var model: String? { didSet { defaults.set(model, forKey: Keys.model) } }
  public var budget: Double { didSet { defaults.set(budget, forKey: Keys.budget) } }
  /// Tests point this at a fake `claude`.
  var executableOverride: String?

  enum Keys {
    static let session = "agent.session"
    static let cwd = "agent.cwd"
    static let model = "agent.model"
    static let budget = "agent.budget"
    static let wake = "agent.wake"
  }

  weak var console: ConsoleModel?
  private let defaults: UserDefaults
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var errTail = ""
  private var pending: [String] = []
  private var pendingWake: String?
  private var lastWake = -TimeInterval.infinity
  /// Wakes no closer than this, so a run of quick events is one turn (the latest one wins).
  var minWakeInterval: TimeInterval = 15
  private var wakeTask: Task<Void, Never>?

  public init(console: ConsoleModel?, defaults: UserDefaults = .standard) {
    self.console = console
    self.defaults = defaults
    wakeOnEvents = defaults.bool(forKey: Keys.wake)
    cwd =
      defaults.string(forKey: Keys.cwd)
      ?? NSString(string: "~/Workspace/dj-vevr-se").expandingTildeInPath
    model = defaults.string(forKey: Keys.model)
    budget = defaults.object(forKey: Keys.budget) as? Double ?? 5
  }

  public var isRunning: Bool { state != .stopped }

  func say(_ kind: ConsoleModel.Kind, _ text: String) { console?.add(kind, text) }

  // MARK: process

  /// Start `claude` primed as the DJ. `fresh`: a new conversation instead of resuming the last.
  public func start(fresh: Bool = false) {
    guard state == .stopped else { return say(.info, "the agent is already \(state.rawValue)") }
    let env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    guard
      let exe = executableOverride
        ?? AgentStream.findClaude(env: env, home: home)
    else {
      return say(.error, "can't find `claude` (set DJ_CLAUDE, or put it on PATH / ~/.local/bin)")
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
      return say(.error, "the agent's directory doesn't exist: \(cwd) (agent cwd <dir>)")
    }
    var launch = AgentStream.Launch()
    launch.model = model
    launch.budgetUSD = budget
    if !fresh { launch.resume = defaults.string(forKey: Keys.session) }
    if let djctl = AgentStream.findDjctl(env: env, cwd: cwd) {
      launch.mcpConfigPath = writeMCPConfig(djctl: djctl)
    } else {
      say(.info, "no build/mcp/djctl in \(cwd): using your own MCP config (make mcp-install)")
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = AgentStream.arguments(launch)
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    var penv = env
    penv["PATH"] = ((env["PATH"] ?? "") + ":\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin")
    p.environment = penv
    let out = Pipe()
    let err = Pipe()
    let inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = inp
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty {
        h.readabilityHandler = nil
        return
      }
      Task { @MainActor in self?.consume(d) }
    }
    err.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty {
        h.readabilityHandler = nil
        return
      }
      let s = String(decoding: d, as: UTF8.self)
      Task { @MainActor in
        guard let self else { return }
        self.errTail = String((self.errTail + s).suffix(1500))
      }
    }
    p.terminationHandler = { [weak self] proc in
      let status = proc.terminationStatus
      Task { @MainActor in self?.exited(status: status) }
    }
    do {
      try p.run()
    } catch {
      return say(.error, "couldn't start the agent: \(error)")
    }
    process = p
    input = inp.fileHandleForWriting
    buffer = Data()
    errTail = ""
    state = .starting
    say(
      .info,
      "starting the DJ agent (\(fresh || launch.resume == nil ? "new conversation" : "resuming") · budget $\(String(format: "%g", budget)))…"
    )
  }

  private func writeMCPConfig(djctl: String) -> String? {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/agent", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("mcp.json")
    do {
      try AgentStream.mcpConfig(djctl: djctl).write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch { return nil }
  }

  public func stop() {
    guard let p = process else { return }
    p.terminate()
    pending = []
    pendingWake = nil
    wakeTask?.cancel()
    wakeTask = nil
  }

  private func exited(status: Int32) {
    let wasRunning = state != .stopped
    process = nil
    input = nil
    state = .stopped
    pending = []
    pendingWake = nil
    guard wasRunning else { return }
    say(.info, "the agent exited (status \(status))")
    if status != 0 && status != 15, !errTail.isEmpty {
      say(.error, errTail.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  // MARK: talking

  /// Send the agent a message (queued while it starts or is mid-turn).
  public func send(_ text: String) {
    switch state {
    case .stopped: say(.error, "the agent isn't running: `agent start`")
    case .starting, .working: pending.append(text)
    case .idle: write(text)
    }
  }

  private func write(_ text: String) {
    guard let input else { return }
    do {
      try input.write(contentsOf: Data((AgentStream.userMessage(text) + "\n").utf8))
      state = .working
    } catch {
      say(.error, "couldn't write to the agent: \(error)")
    }
  }

  /// Something happened that the agent might act on (a hand-off finished). A no-op unless wakes are
  /// on. One turn at a time and at most one wake per `minWakeInterval`: while it is busy or the
  /// interval hasn't passed the latest wake waits (an earlier one is dropped).
  public func wake(_ text: String) {
    guard wakeOnEvents, state != .stopped else { return }
    pendingWake = text
    flush()
  }

  private var nowSeconds: TimeInterval { Date().timeIntervalSinceReferenceDate }

  // MARK: output

  private func consume(_ data: Data) {
    buffer.append(data)
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
      buffer.removeSubrange(buffer.startIndex...nl)
      for e in AgentStream.parse(line: line) { handle(e) }
    }
  }

  func handle(_ e: AgentEvent) {
    switch e {
    case .ready(let sid, let model):
      session = sid
      defaults.set(sid, forKey: Keys.session)
      if state == .starting { state = .idle }
      say(.info, "agent ready · \(model ?? "default model") · session \(sid.prefix(8))")
      flush()
    case .text(let t): say(.agent, t)
    case .toolUse(let name, let summary):
      say(.agentTool, "⚙ \(name)\(summary.isEmpty ? "" : " " + summary)")
    case .toolResult(let text, let isError): say(isError ? .error : .agentTool, "  ↳ \(text)")
    case .turnDone(let ok, let c, let t, let message):
      if let c { cost = c }
      if let t { turns += t }
      state = .idle
      say(
        ok ? .info : .error,
        "— turn done · $\(String(format: "%.2f", cost)) so far" + (message.map { " · \($0)" } ?? "")
      )
      flush()
    }
  }

  /// The next queued message (then the waiting wake, once its interval has passed), now that the
  /// agent is idle.
  private func flush() {
    guard state == .idle else { return }
    if !pending.isEmpty { return write(pending.removeFirst()) }
    guard let w = pendingWake else { return }
    let wait = lastWake + minWakeInterval - nowSeconds
    if wait > 0 {
      if wakeTask == nil {
        wakeTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(wait))
          guard !Task.isCancelled else { return }
          self?.wakeTask = nil
          self?.flush()
        }
      }
      return
    }
    pendingWake = nil
    lastWake = nowSeconds
    say(.event, "⏰ waking the agent: \(w)")
    write(w)
  }

  // MARK: console

  /// `agent <sub> [text]`.
  public func command(_ sub: String, _ text: String) async {
    switch sub {
    case "start": start(fresh: text == "new")
    case "stop":
      if isRunning { stop() } else { say(.info, "the agent isn't running") }
    case "restart":
      stop()
      for _ in 0..<40 where state != .stopped { try? await Task.sleep(for: .milliseconds(50)) }
      start(fresh: text == "new")
    case "say", "tell", "ask":
      guard !text.isEmpty else { return say(.error, "agent say <message>") }
      send(text)
    case "status": say(.info, statusText())
    case "wake":
      switch text {
      case "on": wakeOnEvents = true
      case "off": wakeOnEvents = false
      default: break
      }
      say(
        .info,
        "wakes are \(wakeOnEvents ? "on: the agent is woken when a hand-off finishes" : "off (agent wake on|off)")"
      )
    case "cwd":
      guard !text.isEmpty else { return say(.info, "the agent runs in \(cwd)") }
      let p = NSString(string: text).expandingTildeInPath
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
        return say(.error, "no such directory: \(p)")
      }
      cwd = p
      say(.info, "the agent will run in \(p) (a restart picks it up)")
    case "model":
      model = text.isEmpty ? nil : text
      say(.info, "model: \(model ?? "the default") (a restart picks it up)")
    case "budget":
      guard let b = Double(text), b > 0 else {
        return say(
          .info, "budget: $\(String(format: "%g", budget)) per process (agent budget <usd>)")
      }
      budget = b
      say(.info, "budget: $\(String(format: "%g", b)) per process (a restart picks it up)")
    case "session":
      if text == "clear" {
        defaults.removeObject(forKey: Keys.session)
        session = nil
        say(.info, "the next start is a new conversation")
      } else {
        say(.info, "session \(session ?? defaults.string(forKey: Keys.session) ?? "none")")
      }
    default:
      // `agent more energy` — anything else is a message to it
      send(([sub] + (text.isEmpty ? [] : [text])).joined(separator: " "))
    }
  }

  func statusText() -> String {
    """
    agent: \(state.rawValue) · session \(session ?? defaults.string(forKey: Keys.session) ?? "none") · \
    $\(String(format: "%.2f", cost)) so far over \(turns) turns
    dir: \(cwd) · model: \(model ?? "default") · budget: $\(String(format: "%g", budget)) · wakes: \(wakeOnEvents ? "on" : "off")
    """
  }
}
