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
// docs/ANDROID-PORT.md "Engine changes wanted". LEDs are not driven yet.

@MainActor
public final class RustControllers {
  private let model: RustDJModel
  private var midi: MIDIIn?
  /// Per connected port: its profile's decoder.
  private var decoders: [String: SurfaceDecoder] = [:]
  /// A software SHIFT held (profiles whose shift is a binding, e.g. the APC mini).
  private var shiftHeld = false

  public init(model: RustDJModel) { self.model = model }

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
  }

  private func connect() {
    guard let midi else { return }
    let profiles = SurfaceProfile.all
    let ports = (try? midi.connect { p in profiles.contains { $0.matches(portName: p.name) } }) ?? []
    for p in ports where decoders[p.name] == nil {
      if let prof = profiles.first(where: { $0.matches(portName: p.name) }) {
        decoders[p.name] = SurfaceDecoder(profile: prof)
      }
    }
    let present = Set(MIDIPort.sources().map(\.name))
    decoders = decoders.filter { present.contains($0.key) }
    model.controllers = decoders.values.map(\.profile.name).sorted()
  }

  private func handle(_ m: MIDIMessage) {
    guard var dec = decoders[m.port], let e = dec.decode(m.bytes) else { return }
    decoders[m.port] = dec
    for b in Self.bindings(dec.profile, e, shift: shiftHeld) {
      if b.action == .shift {
        shiftHeld = e.pressed
      } else if let a = Self.action(b, e, lead: model.lead) {
        model.perform(a)
      }
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
    case .nextTrack: return press ? .next(deck: deck) : nil
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
