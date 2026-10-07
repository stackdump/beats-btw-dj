import AppKit
import DJCore
import SwiftUI

@main
struct DJApp: App {
  @State private var model = JogModel()

  init() {
    // Run unbundled (`swift run DJApp`) as a normal foreground app with a Dock icon.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
  }

  var body: some Scene {
    WindowGroup("dj-vevr-se") {
      ContentView(model: model)
        .frame(minWidth: 420, minHeight: 260)
        .task { model.start() }
    }
  }
}

/// Live jog state, updated from CoreMIDI and read by SwiftUI on the main actor.
@MainActor @Observable
final class JogModel {
  var ports: [String] = []
  var status = "starting…"
  var touched: [String: Bool] = [:]
  var platterSeconds: [String: Double] = [:]
  var lastEvent = ""

  private let profile = JogProfile.inpulse200MK3
  private var midi: MIDIIn?

  func start() {
    ports = MIDIPort.sources().map(\.name)
    do {
      let profile = self.profile
      let midi = try MIDIIn { [weak self] m in
        guard let event = profile.parse(m.bytes) else { return }
        Task { @MainActor in self?.apply(event) }
      }
      let connected = try midi.connect { profile.matches(portName: $0.name) }
      self.midi = midi
      status =
        connected.isEmpty
        ? "no \(profile.name) found — plug it in and relaunch"
        : "listening: \(connected.map(\.name).joined(separator: ", "))"
    } catch {
      status = "MIDI error: \(error)"
    }
  }

  private func apply(_ event: JogEvent) {
    lastEvent = "\(event)"
    switch event {
    case .touch(let deck, _, let down):
      touched[deck] = down
    case .scratch(let deck, _, let ticks), .bend(let deck, _, let ticks):
      platterSeconds[deck, default: 0] += Double(ticks) * profile.secondsPerTick
    }
  }
}

struct ContentView: View {
  let model: JogModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.status).font(.headline)
      HStack(spacing: 24) {
        ForEach(["A", "B"], id: \.self) { deck in
          VStack {
            Text("Deck \(deck)").font(.title3)
            Circle()
              .strokeBorder(
                model.touched[deck] == true ? Color.orange : Color.secondary, lineWidth: 4
              )
              .overlay(
                Rectangle().frame(width: 3, height: 40).offset(y: -20)
                  .rotationEffect(.degrees((model.platterSeconds[deck] ?? 0) / 1.8 * 360))
              )
              .frame(width: 110, height: 110)
            Text(String(format: "%+.3f s", model.platterSeconds[deck] ?? 0)).monospacedDigit()
          }
        }
      }
      Text(model.lastEvent).font(.caption.monospaced()).foregroundStyle(.secondary)
    }
    .padding()
  }
}
