import DJRust
import Foundation

// What a hardware controller can do on the djrust decks: the Mac's MIDI layer (DJRustMIDI, over
// DJCore's CoreMIDI input and device profiles) turns a profile's bindings into these, and they
// call the same model methods the pages do. Kept here, free of DJCore, so the iPad app (which has
// no MIDI layer yet) builds without it.

public enum ControllerAction: Sendable, Equatable {
  /// Buttons: act on the press.
  case play(deck: String)
  case sync(deck: String)
  case next(deck: String)
  case previous(deck: String)
  /// A role pad: the role paused or let play again, toggled on each press (as the desktop's).
  case roleToggle(deck: String, role: String)
  /// An effect pad (a macro id, matched to djrust's catalogue by id or label), down or up.
  case effect(deck: String, id: String, down: Bool)
  /// Faders and knobs: a position 0…1 as the hardware sends it.
  case volume(deck: String, position: Double)
  case pitch(deck: String, position: Double)
  case filter(deck: String, position: Double)
  case crossfader(position: Double)
  /// The browser encoder: steps the lead deck's seed (±1 a detent).
  case seedStep(delta: Int)
  /// PANIC: every macro, trick and latch on the deck ended at once.
  case panic(deck: String)
  /// "At the end: the next seed" toggled (DJApp's autoNext binding).
  case autoAdvanceToggle(deck: String)
}

// MARK: what the controllers' LEDs show

/// A role as its pad's LED shows it: playing, paused (a tap), locked out (a long press).
public enum RoleLight: Sendable, Equatable { case on, paused, out }

/// An effect on a deck as its pad shows it: running, or waiting for its bar.
public enum EffectLight: Sendable, Equatable { case on, waiting }

/// One deck as the controllers' LEDs see it (DJRustMIDI's `RustLEDs` turns it into LED bytes).
public struct ControllerDeckLights: Sendable, Equatable {
  public var loaded = false
  public var playing = false
  /// A track is being composed (the next one, or the first).
  public var composing = false
  /// The deck's BPM now; nil when nothing is loaded.
  public var tempo: Double?
  public var autoAdvance = false
  public var roles: [String: RoleLight] = [:]
  /// djrust effect id → its state, for the effects on or waiting.
  public var effects: [String: EffectLight] = [:]

  public init(
    loaded: Bool = false, playing: Bool = false, composing: Bool = false, tempo: Double? = nil,
    autoAdvance: Bool = false, roles: [String: RoleLight] = [:], effects: [String: EffectLight] = [:]
  ) {
    self.loaded = loaded
    self.playing = playing
    self.composing = composing
    self.tempo = tempo
    self.autoAdvance = autoAdvance
    self.roles = roles
    self.effects = effects
  }
}

/// Everything the controllers' LEDs show, read from the model once per LED frame.
public struct ControllerLightState: Sendable, Equatable {
  public var decks: [String: ControllerDeckLights]
  /// djrust's effects (id, label): what a profile's macro id can be matched to.
  public var catalogue: [ControllerEffect]

  public init(decks: [String: ControllerDeckLights], catalogue: [ControllerEffect]) {
    self.decks = decks
    self.catalogue = catalogue
  }
}

public struct ControllerEffect: Sendable, Equatable {
  public var id: String
  public var label: String
  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }

  /// A profile's macro id as djrust's effect: by id, else by its label ("beat-repeat" → "Beat
  /// Repeat"). nil: djrust has no such effect (its pad does nothing, and stays dark).
  public static func match(_ id: String, in catalogue: [ControllerEffect]) -> ControllerEffect? {
    if let f = catalogue.first(where: { $0.id == id }) { return f }
    let want = id.replacingOccurrences(of: "-", with: " ").lowercased()
    return catalogue.first { $0.label.lowercased() == want }
  }
}

extension RustDJModel {
  /// The pitch fader's dead zone round its centre (DJApp's SurfaceController.pitchDeadZone).
  static let pitchDeadZone = 0.02
  /// The filter knob's: a knob at rest reads exactly open.
  static let filterDeadZone = 0.03

  /// The deck the crossfader favours: what a deck-less control acts on.
  public var lead: String { leadDeck(mix?.crossfader) }

  public func perform(_ a: ControllerAction) {
    switch a {
    case .play(let d): togglePlay(d)
    case .sync(let d): sync(d)
    case .next(let d): next(d)
    case .previous(let d): previous(d)
    case .roleToggle(let d, let role):
      guard let r = decks[d]?.deck?.roles.first(where: { $0.name == role }), !r.disabled else { return }
      setRole(d, role, !r.audible)
    case .effect(let d, let id, let down):
      guard let fx = controllerEffect(id) else { return }
      let transition = fxCategories.first { $0.id == fx.category }?.transition == true
      if transition {
        if down { engage(d, fx.id, .momentary) } else { fxRelease(d, fx.id) }
      } else if down {
        // a press toggles it, as a tap on its pad: on for a bar, or let go if it's on
        if fxActive[d]?.contains(where: { $0.id == fx.id }) == true { fxUnlatch(d, fx.id) } else { engage(d, fx.id, .bars(bars: 1)) }
      }
    case .volume(let d, let p): setVolume(d, Fader.fromPos(p))
    case .pitch(let d, let p):
      let v = p * 2 - 1
      setPitch(d, abs(v) < Self.pitchDeadZone ? 0 : v)
    case .filter(let d, let p): trickKnob(d, abs(p - 0.5) < Self.filterDeadZone ? 0.5 : p)
    case .crossfader(let p): setCrossfader(p)
    case .seedStep(let delta):
      // the lead deck's song, the seed moved by the detents (composed, then swapped in)
      let d = leadDeck(mix?.crossfader)
      guard delta != 0, let s = decks[d]?.deck, let genre = s.genre, let seed = s.seed else { return }
      let next = max(1, seed + Int64(delta))
      editDraft(d) {
        $0.genre = genre
        $0.seed = next
        if let st = s.structure { $0.structure = st }
      }
      act { _ = try $0.compose(deck: d, genre: genre, seed: next, structure: s.structure) }
    case .panic(let d): fxPanic(d)
    case .autoAdvanceToggle(let d): setAutoAdvance(d, !(decks[d]?.autoAdvance ?? true))
    }
  }

  /// What the controllers' LEDs show now.
  public var controllerLights: ControllerLightState {
    var out: [String: ControllerDeckLights] = [:]
    for (name, ui) in decks {
      let s = ui.deck
      var roles: [String: RoleLight] = [:]
      for r in s?.roles ?? [] { roles[r.name] = r.disabled ? .out : (r.audible ? .on : .paused) }
      var fx: [String: EffectLight] = [:]
      for a in fxActive[name] ?? [] { fx[a.id] = a.pending ? .waiting : .on }
      out[name] = ControllerDeckLights(
        loaded: s?.loaded == true, playing: s?.playing == true, composing: s?.composing == true,
        tempo: s?.loaded == true ? s?.tempo : nil, autoAdvance: ui.autoAdvance, roles: roles, effects: fx)
    }
    return ControllerLightState(
      decks: out, catalogue: fxCatalogue.map { ControllerEffect(id: $0.id, label: $0.label) })
  }

  /// A profile's macro id as djrust's effect (`ControllerEffect.match`).
  private func controllerEffect(_ id: String) -> FxInfo? {
    let c = fxCatalogue.map { ControllerEffect(id: $0.id, label: $0.label) }
    guard let m = ControllerEffect.match(id, in: c) else { return nil }
    return fxCatalogue.first { $0.id == m.id }
  }
}
