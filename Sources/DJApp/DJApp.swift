import AppKit
import DJCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct DJApp: App {
  @State private var model = AppModel()

  init() {
    // Run unbundled (`swift run DJApp`) as a normal foreground app with a Dock icon.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
  }

  var body: some Scene {
    WindowGroup("dj-vevr-se") {
      ContentView(model: model)
        .frame(minWidth: 720, minHeight: 460)
        .task { model.start() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
          model.stop()
        }
    }
  }
}

/// Snapshot of one deck for SwiftUI (Deck itself is not observable).
struct DeckState: Equatable {
  var title = "—"
  var playing = false
  var platterSeconds = 0.0
  var positionSeconds = 0.0
  var duration = 0.0
  var rate = 0.0
  var volume = 0.8
  var filter = 0.5
  var pitch = 0.0
  var nudge = 0.0
  var touching = false
  var cues: Set<Int> = []
}

@MainActor @Observable
final class AppModel {
  var status = "starting…"
  var devices: [ControllerHub.Device] = []
  var lastMessage = ""
  var decks: [String: DeckState] = ["A": .init(), "B": .init()]
  var crossfader = 0.5
  var master = 0.8

  private var dj: DJEngine?
  private var hub: ControllerHub?
  private var refresh: Timer?

  func start() {
    guard dj == nil else { return }
    do {
      let dj = try DJEngine()
      for d in dj.decks.values { d.loadDemo() }
      dj.master = master
      try dj.start()
      let hub = ControllerHub(engine: dj)
      hub.onMessage = { [weak self] m, d in
        self?.lastMessage = "\(m.port): " + (d.isEmpty ? "(unbound)" : d)
      }
      try hub.start()
      self.dj = dj
      self.hub = hub
      status = "\(Int(dj.sampleRate)) Hz"
      let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
        MainActor.assumeIsolated { [weak self] in self?.poll() }
      }
      RunLoop.main.add(t, forMode: .common)
      refresh = t
    } catch {
      status = "audio/MIDI error: \(error)"
    }
  }

  func stop() {
    hub?.stop()
    dj?.stop()
  }

  private func poll() {
    guard let dj, let hub else { return }
    devices = hub.devices
    crossfader = dj.crossfader
    master = dj.master
    for (name, d) in dj.decks {
      let adapter = hub.jogAdapters.first { $0.deck == name }
      decks[name] = DeckState(
        title: d.title, playing: d.playing, platterSeconds: d.platterSeconds,
        positionSeconds: d.positionSeconds,
        duration: d.loaded?.duration ?? 0, rate: d.turntable.currentRate, volume: d.volume,
        filter: d.filter,
        pitch: d.pitch, nudge: adapter?.nudge ?? 0, touching: adapter?.touching ?? false,
        cues: Set(d.hotCues.keys))
    }
  }

  // Actions from the UI. Hardware goes through the hub; both end up on Deck.
  func togglePlay(_ deck: String) { dj?[deck].map { $0.setPlaying(!$0.playing) } }
  func hotCue(_ deck: String, _ slot: Int) { dj?[deck]?.hotCue(slot) }
  func clearCue(_ deck: String, _ slot: Int) { dj?[deck]?.clearCue(slot) }
  func setVolume(_ deck: String, _ v: Double) {
    dj?.owners["\(deck).volume"] = "ui"
    dj?[deck]?.volume = v
  }
  func setFilter(_ deck: String, _ v: Double) {
    dj?.owners["\(deck).filter"] = "ui"
    dj?[deck]?.filter = v
  }
  func setPitch(_ deck: String, _ v: Double) {
    dj?.owners["\(deck).pitch"] = "ui"
    dj?[deck]?.pitch = v
  }
  func setCrossfader(_ v: Double) {
    dj?.owners["crossfader"] = "ui"
    dj?.crossfader = v
  }
  func setMaster(_ v: Double) {
    dj?.owners["master"] = "ui"
    dj?.master = v
  }
  func loadDemo(_ deck: String) { dj?[deck]?.loadDemo() }

  func load(_ deck: String, url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do { try dj?[deck]?.load(contentsOf: url) } catch { status = "\(error)" }
  }
}

struct ContentView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .top, spacing: 24) {
        DeckView(name: "A", model: model, tint: .orange)
        MixerView(model: model)
        DeckView(name: "B", model: model, tint: .cyan)
      }
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Controllers").font(.caption.bold())
          if model.devices.isEmpty {
            Text("none — plug in an Inpulse 200 MK3, APC mini mk2 or MPK Mini").font(.caption)
          }
          ForEach(model.devices, id: \.port) { d in
            Text("● \(d.profile)").font(.caption).foregroundStyle(.green)
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(model.status).font(.caption)
          Text(model.lastMessage).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(
            1)
        }
      }
    }
    .padding()
  }
}

struct DeckView: View {
  let name: String
  let model: AppModel
  let tint: Color
  @State private var importing = false

  var state: DeckState { model.decks[name] ?? .init() }

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Text("Deck \(name)").font(.title3.bold())
        Spacer()
        Menu("Load") {
          Button("Audio file…") { importing = true }
          Button("Demo loop") { model.loadDemo(name) }
        }
        .fixedSize()
      }
      Text(state.title).font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      Platter(seconds: state.platterSeconds, touching: state.touching, tint: tint)
        .frame(width: 150, height: 150)
      Text(
        String(
          format: "%@ / %@  ·  %.3f×", clock(state.positionSeconds), clock(state.duration),
          state.rate)
      )
      .font(.caption.monospacedDigit())
      HStack {
        Button(state.playing ? "Pause" : "Play") { model.togglePlay(name) }
          .keyboardShortcut(name == "A" ? "a" : "b", modifiers: [])
        ForEach(0..<4, id: \.self) { slot in
          Button("\(slot + 1)") { model.hotCue(name, slot) }
            .tint(state.cues.contains(slot) ? tint : nil)
            .buttonStyle(.borderedProminent)
            .contextMenu { Button("Clear cue \(slot + 1)") { model.clearCue(name, slot) } }
            .help(
              state.cues.contains(slot)
                ? "Jump to cue (right-click to clear)" : "Set cue at playhead")
        }
      }
      LabeledSlider(
        label: "Vol", value: Binding(get: { state.volume }, set: { model.setVolume(name, $0) }),
        range: 0...1)
      LabeledSlider(
        label: "Filter", value: Binding(get: { state.filter }, set: { model.setFilter(name, $0) }),
        range: 0...1)
      LabeledSlider(
        label: String(format: "Pitch %+.1f%%", state.pitch * Deck.pitchRange * 100),
        value: Binding(get: { state.pitch }, set: { model.setPitch(name, $0) }), range: -1...1)
      if state.nudge != 0 {
        Text(String(format: "nudge %+.1f%%", state.nudge * 100)).font(.caption).foregroundStyle(
          tint)
      }
    }
    .frame(width: 260)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
      if case .success(let url) = result { model.load(name, url: url) }
    }
  }

  func clock(_ s: Double) -> String {
    String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
  }
}

struct MixerView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 14) {
      Text("Mixer").font(.title3.bold())
      LabeledSlider(
        label: "Master", value: Binding(get: { model.master }, set: { model.setMaster($0) }),
        range: 0...1)
      Spacer().frame(height: 120)
      VStack(spacing: 2) {
        Slider(
          value: Binding(get: { model.crossfader }, set: { model.setCrossfader($0) }), in: 0...1)
        HStack {
          Text("A")
          Spacer()
          Text("crossfader").foregroundStyle(.secondary)
          Spacer()
          Text("B")
        }
        .font(.caption)
      }
    }
    .frame(width: 160)
  }
}

struct LabeledSlider: View {
  let label: String
  let value: Binding<Double>
  let range: ClosedRange<Double>

  var body: some View {
    HStack {
      Text(label).font(.caption).frame(width: 84, alignment: .leading)
      Slider(value: value, in: range)
    }
  }
}

/// One revolution = 1.8 s of audio (33⅓ rpm).
struct Platter: View {
  let seconds: Double
  let touching: Bool
  let tint: Color

  var body: some View {
    ZStack {
      Circle().fill(.black.opacity(0.85))
      Circle().strokeBorder(touching ? tint : .gray.opacity(0.5), lineWidth: touching ? 5 : 2)
      Circle().fill(tint.opacity(0.8)).frame(width: 36, height: 36)
      Rectangle().fill(.white).frame(width: 3, height: 60).offset(y: -38)
        .rotationEffect(.degrees(seconds / 1.8 * 360))
    }
  }
}
