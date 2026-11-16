import DJCore
import DJRustUI
import Foundation

// The controllers' LEDs on the djrust decks: DJCore's `SurfaceController.ledFrame` / `lights`
// (which DJApp drives from its DJEngine) with the same profile data — which groups have LEDs,
// RGB or single, the status bytes, the APC palette — the same rules where djrust has the state,
// and the model's `ControllerLightState` in place of the engine:
//
// - play: dark with nothing loaded, lit while stopped, blinking while it plays (DJCore's);
// - sync: lit while the deck runs at the other deck's tempo (±0.05 BPM);
// - next / regenerate: lit with a track loaded, blinking while one is composed;
// - role pads: lit while the role plays, dim (RGB) or dark (single) while paused, dark when
//   locked out (DJCore lights an APC role pad dim always; here it shows the role);
// - effect pads: the APC's colour per macro group (DJCore's: red, yellow for the tempo ones,
//   magenta pitch, green feel, cyan the other master macros), full while on, blinking while
//   it waits for its bar, dim at rest, dark when djrust has no such effect;
// - aim (APC scene 4 / 5): lit for the deck the "*" pads act on;
// - anything djmobile has no call for (`RustControllers.action` nil: cue, hot cues, PFL, stems,
//   loops, clips, FX unit kill / reset, Wander…) is dark: a dark control does nothing.
// A press flashes an RGB pad full for 0.18 s, as DJCore's.

public struct RustLEDs {
  public let profile: SurfaceProfile
  private var cache: [UInt16: UInt16] = [:]  // channel<<8 | note → status<<8 | vel
  private var flashed: [String: TimeInterval] = [:]
  private var exact: [String: [SurfaceProfile.Binding]] = [:]

  /// APC mini mk2 palette indices (DJCore's `SurfaceController.Color`).
  enum Color {
    static let off: UInt8 = 0, red: UInt8 = 5, orange: UInt8 = 9, cyan: UInt8 = 37
    static let white: UInt8 = 3, yellow: UInt8 = 13, green: UInt8 = 21, magenta: UInt8 = 53
  }
  static let flashSeconds = 0.18

  public init(profile: SurfaceProfile) {
    self.profile = profile
    for b in profile.layout {
      if let i = b.index { exact[Self.key(b.group, i), default: []].append(b) }
    }
  }

  static func key(_ group: String, _ index: Int) -> String { "\(group)#\(index)" }

  /// The binding a control's LED shows: the layer its press reaches (DJCore's `lit`).
  func lit(_ group: String, _ index: Int, shift: Bool) -> SurfaceProfile.Binding? {
    let c = exact[Self.key(group, index)] ?? []
    return c.first { $0.shift == shift } ?? c.first { $0.shift == nil }
  }

  /// A press: its RGB pad shows full for a moment.
  public mutating func flash(group: String, index: Int, now: TimeInterval) {
    flashed[Self.key(group, index)] = now
  }

  /// What every LED shows now, by group (one entry per control), as DJCore's `lights`.
  /// `aim`: the deck "*" bindings act on.
  public func lights(_ s: ControllerLightState, aim: String, shift: Bool, now: TimeInterval) -> [String: [PadLight]] {
    guard let leds = profile.leds else { return [:] }
    var out: [String: [PadLight]] = [:]
    for g in profile.groups where leds.rgbGroups.contains(g.id) {
      out[g.id] = g.controlNumbers.indices.map { i in
        let (c, level) = rgb(lit(g.id, i, shift: shift), s, aim: aim)
        if now - (flashed[Self.key(g.id, i)] ?? -1) < Self.flashSeconds { return PadLight(colorIndex: c, level: .full) }
        return PadLight(colorIndex: c, level: level == .blink && leds.rgbBlinkStatus == nil ? .dim : level)
      }
    }
    for g in profile.groups where leds.singleGroups.contains(g.id) {
      out[g.id] = g.controlNumbers.indices.map { i in
        PadLight(colorIndex: 0, level: single(lit(g.id, i, shift: shift), s, aim: aim, shift: shift))
      }
    }
    return out
  }

  /// The LED messages whose state changed since the last frame (DJCore's `ledFrame`). Call
  /// ~20 times a second and send them to the controller's output of the same name.
  public mutating func frame(_ s: ControllerLightState, aim: String, shift: Bool, now: TimeInterval) -> [[UInt8]] {
    guard let leds = profile.leds else { return [] }
    let l = lights(s, aim: aim, shift: shift, now: now)
    var out: [[UInt8]] = []
    func emit(_ ch: UInt8, _ note: UInt8, _ statusBase: UInt8, _ vel: UInt8) {
      let status = statusBase | ch
      let k = UInt16(ch) << 8 | UInt16(note)
      let sig = UInt16(status) << 8 | UInt16(vel)
      if cache[k] == sig { return }
      cache[k] = sig
      out.append([status, note, vel])
    }
    for g in profile.groups where leds.rgbGroups.contains(g.id) {
      for (i, note) in g.controlNumbers.enumerated() {
        let p = l[g.id]![i]
        // APC: the status byte's low nibble is the brightness, so no channel here
        let status =
          switch p.level {
          case .full: leds.rgbFullStatus
          case .blink: leds.rgbBlinkStatus ?? leds.rgbDimStatus
          case .dim, .off: leds.rgbDimStatus
          }
        emit(0, note, status, p.colorIndex)
      }
    }
    for g in profile.groups where leds.singleGroups.contains(g.id) {
      for (i, note) in g.controlNumbers.enumerated() {
        let v: UInt8 =
          switch l[g.id]![i].level {
          case .full: leds.singleOn
          case .blink: leds.singleBlink
          case .dim, .off: leds.singleOff
          }
        emit(g.channel ?? 0, note, 0x90, v)
      }
    }
    return out
  }

  /// Every LED off (quit, a port going away); the next frame sends everything again.
  public mutating func blackout() -> [[UInt8]] {
    guard let leds = profile.leds else { return [] }
    cache = [:]
    return profile.groups.flatMap { g -> [[UInt8]] in
      if leds.rgbGroups.contains(g.id) { return g.controlNumbers.map { [0x90, $0, 0] } }
      if leds.singleGroups.contains(g.id) { return g.controlNumbers.map { [0x90 | (g.channel ?? 0), $0, 0] } }
      return []
    }
  }

  // MARK: the rules

  private func deckName(_ b: SurfaceProfile.Binding, aim: String) -> String {
    b.deck.flatMap { $0 == "*" ? nil : $0 } ?? aim
  }

  /// The other deck's tempo matches this one's (both loaded).
  private func synced(_ name: String, _ s: ControllerLightState) -> Bool {
    guard let mine = s.decks[name]?.tempo,
      let other = s.decks.first(where: { $0.key != name })?.value.tempo
    else { return false }
    return abs(mine - other) < 0.05
  }

  /// A single LED (Inpulse buttons, APC track row and scene column).
  func single(_ b: SurfaceProfile.Binding?, _ s: ControllerLightState, aim: String, shift: Bool) -> PadLight.Level {
    guard let b else { return .off }
    let name = deckName(b, aim: aim)
    let d = s.decks[name]
    switch b.action {
    case .play:
      guard let d, d.loaded else { return .off }
      return d.playing ? .blink : .full
    case .sync: return synced(name, s) ? .full : .off
    case .nextTrack, .regenerate:
      guard let d else { return .off }
      return d.composing ? .blink : (d.loaded ? .full : .off)
    case .rewind, .panic: return d?.loaded == true ? .full : .off
    case .roleMute: return d?.roles[b.role ?? ""] == .on ? .full : .off
    case .autoNext: return d?.autoAdvance == true ? .full : .off
    case .focusDeck: return RustControllers.aim(b.slot) == aim ? .full : .off
    case .shift: return shift ? .full : .off
    case .macro:
      guard let id = b.macro, let fx = ControllerEffect.match(id, in: s.catalogue) else { return .off }
      return d?.effects[fx.id] == .waiting ? .blink : .full
    default: return .off  // no djmobile call for it: dark
    }
  }

  /// An RGB pad (the APC's grid): (palette colour, brightness). Never `.off`: a dark pad is a
  /// dim pad of colour 0, which is how the APC is told to go dark.
  func rgb(_ b: SurfaceProfile.Binding?, _ s: ControllerLightState, aim: String) -> (UInt8, PadLight.Level) {
    guard let b else { return (Color.off, .dim) }
    let name = deckName(b, aim: aim)
    let d = s.decks[name]
    let deckColor = name == "A" ? Color.orange : Color.cyan
    switch b.action {
    case .macro:
      guard let id = b.macro, let fx = ControllerEffect.match(id, in: s.catalogue) else { return (Color.off, .dim) }
      let level: PadLight.Level =
        switch d?.effects[fx.id] {
        case .on: .full
        case .waiting: .blink
        case nil: .dim
        }
      return (Self.color(macro: id), level)
    case .roleMute:
      switch d?.roles[b.role ?? ""] {
      case .on: return (deckColor, .full)
      case .paused: return (deckColor, .dim)
      case .out, nil: return (Color.off, .dim)
      }
    case .panic: return d?.loaded == true ? (Color.red, .dim) : (Color.off, .dim)
    default:
      // a button on the grid: its single-LED state in the deck's colour
      switch single(b, s, aim: aim, shift: false) {
      case .off: return (Color.off, .dim)
      case .full: return (deckColor, .full)
      case .blink: return (deckColor, .blink)
      case .dim: return (deckColor, .dim)
      }
    }
  }

  /// beats' APC colour per macro group (DJCore `SurfaceController.deckPadState` / `color`).
  static func color(macro id: String) -> UInt8 {
    if let m = NetMacro(id: id) {
      return [NetMacro.halfTime, .tapeStop, .tempoAnchor].contains(m) ? Color.yellow : Color.red
    }
    if let m = MasterMacro(id: id) {
      return m.group == "Pitch" ? Color.magenta : (m.group == "Feel" ? Color.green : Color.cyan)
    }
    return Color.white
  }
}
