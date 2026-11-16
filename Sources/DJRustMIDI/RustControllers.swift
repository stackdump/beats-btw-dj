import DJCore
import DJRustUI
import Foundation

// Hardware controllers on the Mac's djrust app (docs/ANDROID-PORT.md, milestone 8). djmobile is
// built without djhost's `midi`, so MIDI stays Swift, as in DJApp: DJCore's CoreMIDI input and
// its device profiles (`SurfaceProfile`, the same JSON DJApp plays) decode a control, and its
// binding becomes a `ControllerAction` on the model — the calls the pages make.
//
// What the profiles bind that djmobile's `Player` has no call for stays unbound here (EQ, gain,
// cue / hot cues, headphones, the jog wheels, stems, clips, loop record, Wander): the list is in
// docs/ANDROID-PORT.md "Engine changes wanted". The LEDs follow the model (RustLEDs.swift),
// sent ~20 times a second to the output port of the controller's name; those controls stay dark.

@MainActor
public final class RustControllers {
  private let model: RustDJModel
  private var midi: MIDIIn?
  /// Per connected port: its profile's decoder.
  private var decoders: [String: SurfaceDecoder] = [:]
  /// A software SHIFT held (profiles whose shift is a binding, e.g. the APC mini).
  private var shiftHeld = false
  /// The deck "*" bindings act on once an aim button picked one (the APC's scene 4 / 5, as
  /// DJApp's focus); nil: the lead deck.
  public private(set) var aimed: String?
  /// Per connected port: its LEDs.
  private var leds: [String: RustLEDs] = [:]
  private var out: MIDIOut?
  private var timer: Timer?

  public init(model: RustDJModel) { self.model = model }

  /// The deck "*" bindings act on now.
  public var aim: String { aimed ?? model.lead }

  /// Open CoreMIDI and connect every source a profile matches; again whenever devices change.
  public func start() {
    do {
      midi = try MIDIIn(
        name: "djrust",
        onSetupChange: { DispatchQueue.main.async { MainActor.assumeIsolated { self.connect() } } },
        // FIFO onto the main thread (never a Task: presses must land in order)
        handler: { m in DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(m) } } })
      connect()
    } catch {
      model.error = "MIDI could not start: \(error)"
    }
    out = try? MIDIOut(name: "djrust out")
    let t = Timer(timeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { self.sendLEDs() } }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  /// Every LED off (the app quitting); the timer stops.
  public func stop() {
    timer?.invalidate()
    for port in leds.keys { send(leds[port]!.blackout(), to: port) }
  }

  private func sendLEDs() {
    guard !leds.isEmpty else { return }
    let s = model.controllerLights
    let now = ProcessInfo.processInfo.systemUptime
    for port in Array(leds.keys) {
      send(leds[port]!.frame(s, aim: aim, shift: shiftHeld, now: now), to: port)
    }
  }

  private func send(_ messages: [[UInt8]], to port: String) {
    guard !messages.isEmpty, let out, let dest = MIDIPort.destinations().first(where: { $0.name == port }) else { return }
    out.send(messages, to: dest)
  }

  private func connect() {
    guard let midi else { return }
    let profiles = SurfaceProfile.all
    let ports = (try? midi.connect { p in profiles.contains { $0.matches(portName: p.name) } }) ?? []
    for p in ports where decoders[p.name] == nil {
      if let prof = profiles.first(where: { $0.matches(portName: p.name) }) {
        decoders[p.name] = SurfaceDecoder(profile: prof)
        // a fresh cache: the first frame lights every LED
        if prof.leds != nil { leds[p.name] = RustLEDs(profile: prof) }
      }
    }
    let present = Set(MIDIPort.sources().map(\.name))
    decoders = decoders.filter { present.contains($0.key) }
    leds = leds.filter { present.contains($0.key) }
    model.controllers = decoders.values.map(\.profile.name).sorted()
  }

  private func handle(_ m: MIDIMessage) {
    guard var dec = decoders[m.port], let e = dec.decode(m.bytes) else { return }
    decoders[m.port] = dec
    for b in Self.bindings(dec.profile, e, shift: shiftHeld) {
      let press = e.pressed && (!e.isCC || e.value > 0.5)
      if b.action == .shift {
        shiftHeld = e.pressed
      } else if b.action == .focusDeck {
        if press, let d = Self.aim(b.slot) { aimed = d }
      } else if let a = Self.action(b, e, lead: aim) {
        if press { leds[m.port]?.flash(group: e.group, index: e.index, now: ProcessInfo.processInfo.systemUptime) }
        model.perform(a)
      }
    }
  }

  /// What an aim button (`focusDeck`) aims at: slot 0 deck A, 1 deck B; nil for DJApp's loop
  /// channel (slot 2), which djrust has none of.
  public nonisolated static func aim(_ slot: Int?) -> String? {
    switch slot ?? 0 {
    case 0: "A"
    case 1: "B"
    default: nil
    }
  }

  /// The profile's bindings for a decoded control, on the layer SHIFT selects.
  public nonisolated static func bindings(_ p: SurfaceProfile, _ e: ControlEvent, shift: Bool) -> [SurfaceProfile.Binding] {
    p.layout.filter { $0.group == e.group && ($0.index == nil || $0.index == e.index) && ($0.shift == nil || $0.shift == shift) }
  }

  /// What a binding does with a control's event on the djrust decks; nil when djmobile has no
  /// call for it (or a button's release). Deck "*" and deck-less controls act on `lead`.
  public nonisolated static func action(_ b: SurfaceProfile.Binding, _ e: ControlEvent, lead: String) -> ControllerAction? {
    let press = e.pressed && (!e.isCC || e.value > 0.5)
    let deck = b.deck.flatMap { $0 == "*" ? nil : $0 } ?? lead
    switch b.action {
    case .play: return press ? .play(deck: deck) : nil
    case .sync: return press ? .sync(deck: deck) : nil
    // DJApp's regenerate is the next version of the song: what djrust's ⏭ does
    case .nextTrack, .regenerate: return press ? .next(deck: deck) : nil
    case .panic: return press ? .panic(deck: deck) : nil
    case .autoNext: return press ? .autoAdvanceToggle(deck: deck) : nil
    case .rewind: return press ? .previous(deck: deck) : nil
    case .roleMute: return press ? b.role.map { .roleToggle(deck: deck, role: $0) } : nil
    case .macro: return b.macro.map { .effect(deck: deck, id: $0, down: press) }
    case .volume: return .volume(deck: deck, position: e.value)
    case .pitch: return .pitch(deck: deck, position: e.value)
    case .filter: return .filter(deck: deck, position: e.value)
    case .crossfader: return .crossfader(position: e.value)
    case .seedStep: return e.delta != 0 ? .seedStep(delta: e.delta > 0 ? 1 : -1) : nil
    default: return nil  // no djmobile call for it yet
    }
  }
}
