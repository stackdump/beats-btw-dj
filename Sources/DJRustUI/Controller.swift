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
    }
  }

  /// A profile's macro id as djrust's effect: by id, else by its label ("beat-repeat" → "Beat
  /// Repeat").
  private func controllerEffect(_ id: String) -> FxInfo? {
    if let f = fxCatalogue.first(where: { $0.id == id }) { return f }
    let want = id.replacingOccurrences(of: "-", with: " ").lowercased()
    return fxCatalogue.first { $0.label.lowercased() == want }
  }
}
