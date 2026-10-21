import DJCore
import SwiftUI

/// The debug console's id and title (`Window(ConsoleWindow.title, id: ConsoleWindow.id)`).
public enum ConsoleWindow {
  public static let id = "console"
  public static let title = "Debug Console"
}

/// A scrollback and a command line: the CLI over every MCP tool (`ConsoleModel`).
public struct ConsoleView: View {
  @Bindable var model: ConsoleModel
  @FocusState private var focused: Bool

  public init(model: ConsoleModel) { self.model = model }

  static func color(_ k: ConsoleModel.Kind) -> Color {
    switch k {
    case .input: Color(red: 0.55, green: 0.85, blue: 1.0)
    case .output: Color(white: 0.88)
    case .error: Color(red: 1.0, green: 0.45, blue: 0.45)
    case .info: Color(white: 0.55)
    case .agent: Color(red: 0.75, green: 1.0, blue: 0.6)
    case .agentTool: Color(red: 0.95, green: 0.8, blue: 0.4)
    case .event: Color(red: 0.8, green: 0.65, blue: 1.0)
    }
  }

  public var body: some View {
    VStack(spacing: 0) {
      AgentBar(agent: model.app?.agent, run: { line in Task { await model.run(line) } })
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.lines) { line in
              Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Self.color(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .id(line.id)
            }
          }
          .padding(10)
        }
        .onChange(of: model.lines.last?.id) { _, id in
          if let id { proxy.scrollTo(id, anchor: .bottom) }
        }
      }
      Divider()
      HStack(spacing: 8) {
        Text(model.busy ? "…" : "›")
          .font(.system(size: 13, weight: .bold, design: .monospaced))
          .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
        TextField("", text: $model.input)
          .textFieldStyle(.plain)
          .font(.system(size: 13, design: .monospaced))
          .focused($focused)
          .onSubmit { Task { await model.submit() } }
          .onKeyPress(.upArrow) {
            model.historyBack()
            return .handled
          }
          .onKeyPress(.downArrow) {
            model.historyForward()
            return .handled
          }
          .onKeyPress(.tab) {
            model.complete()
            return .handled
          }
        Button("Clear") { model.clear() }
          .keyboardShortcut("k", modifiers: .command)
          .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(Color.black.opacity(0.35))
    }
    .background(Color(white: 0.08))
    .onAppear { focused = true }
  }
}

/// The window's content: the app's one console, so closing and reopening keeps the scrollback.
public struct ConsoleWindowView: View {
  let app: AppModel
  public init(app: AppModel) { self.app = app }
  public var body: some View { ConsoleView(model: app.console) }
}

/// The agent's controls, above the scrollback: its state, start / stop, and wakes.
struct AgentBar: View {
  let agent: AgentController?
  let run: (String) -> Void

  var body: some View {
    if let agent {
      HStack(spacing: 10) {
        Circle().fill(color(agent.state)).frame(width: 8, height: 8)
        Text("DJ agent: \(agent.state.rawValue)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
        if agent.isRunning || agent.cost > 0 {
          Text("$\(String(format: "%.2f", agent.cost))")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        Spacer()
        Toggle(
          "Wake on hand-off",
          isOn: Binding(
            get: { agent.wakeOnEvents }, set: { run("agent wake \($0 ? "on" : "off")") })
        )
        .toggleStyle(.checkbox).font(.caption)
        .help("Wake the agent when a set hand-off finishes (each wake is a billed turn)")
        if agent.isRunning {
          Button("Stop") { run("agent stop") }
        } else {
          Button("Start agent") { run("agent start") }
          Button("New conversation") { run("agent start new") }
        }
      }
      .controlSize(.small)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.black.opacity(0.25))
    }
  }

  func color(_ s: AgentController.State) -> Color {
    switch s {
    case .stopped: .gray
    case .starting: .yellow
    case .idle: .green
    case .working: .orange
    }
  }
}
