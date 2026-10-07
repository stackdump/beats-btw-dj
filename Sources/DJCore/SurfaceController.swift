import Foundation

/// Routes one surface's control events to the engine and computes its LED
/// feedback. Not thread-safe: use from the main actor.
public final class SurfaceController {
  public let profile: SurfaceProfile
  private let dj: DJEngine
  private var bindings: [String: SurfaceProfile.Binding] = [:]
  private var ledCache: [UInt8: UInt16] = [:]
  private var flashed: [String: TimeInterval] = [:]

  /// Palette indices (APC mini mk2 velocity → colour chart).
  enum Color {
    static let off: UInt8 = 0, red: UInt8 = 5, orange: UInt8 = 9, cyan: UInt8 = 37
  }
  static let flashSeconds = 0.18
  /// Centre detent for pitch faders: ±2 % of travel snaps to zero.
  static let pitchDeadZone = 0.02

  public init(profile: SurfaceProfile, engine: DJEngine) {
    self.profile = profile
    dj = engine
    for b in profile.layout { bindings[Self.key(b.group, b.index)] = b }
  }

  public func binding(for e: ControlEvent) -> SurfaceProfile.Binding? {
    bindings[Self.key(e.group, e.index)]
  }

  public func handle(_ e: ControlEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard let b = binding(for: e) else { return }
    let deck = b.deck.flatMap { dj[$0] }
    switch b.action {
    case .volume: deck?.volume = e.value
    case .filter: deck?.filter = e.value
    case .pitch:
      let p = e.value * 2 - 1
      deck?.pitch = abs(p) < Self.pitchDeadZone ? 0 : p
    case .crossfader: dj.crossfader = e.value
    case .master: dj.master = e.value
    case .play, .hotcue, .clearcue:
      guard e.pressed, !e.isCC || e.value > 0.5 else { return }
      flashed[Self.key(e.group, e.index)] = now
      switch b.action {
      case .play: deck.map { $0.setPlaying(!$0.playing) }
      case .hotcue: deck?.hotCue(b.slot ?? 0)
      case .clearcue: deck?.clearCue(b.slot ?? 0)
      default: break
      }
    }
  }

  /// LED messages whose state changed since the last call (empty for surfaces
  /// without LEDs). Call ~20x/s and send the result to the surface's output.
  public func ledFrame(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [[UInt8]] {
    guard let leds = profile.leds else { return [] }
    var out: [[UInt8]] = []
    func emit(_ note: UInt8, _ status: UInt8, _ vel: UInt8) {
      let sig = UInt16(status) << 8 | UInt16(vel)
      if ledCache[note] == sig { return }
      ledCache[note] = sig
      out.append([status, note, vel])
    }
    for g in profile.groups where leds.rgbGroups.contains(g.id) {
      for i in 0..<Int(g.count) {
        let note = g.first + UInt8(i)
        let k = Self.key(g.id, i)
        let full = now - (flashed[k] ?? -1) < Self.flashSeconds
        let (color, lit) = rgbState(bindings[k])
        emit(note, full || lit ? leds.rgbFullStatus : leds.rgbDimStatus, color)
      }
    }
    for g in profile.groups where leds.singleGroups.contains(g.id) {
      for i in 0..<Int(g.count) {
        let b = bindings[Self.key(g.id, i)]
        var vel = b == nil ? leds.singleOff : leds.singleOn
        if let b, b.action == .play, let d = b.deck.flatMap({ dj[$0] }), d.playing {
          vel = leds.singleBlink
        }
        emit(g.first + UInt8(i), 0x90, vel)
      }
    }
    return out
  }

  /// Messages turning every LED off (on quit / disconnect).
  public func blackout() -> [[UInt8]] {
    guard let leds = profile.leds else { return [] }
    ledCache = [:]
    return profile.groups.filter {
      leds.rgbGroups.contains($0.id) || leds.singleGroups.contains($0.id)
    }
    .flatMap { g in (0..<g.count).map { [0x90, g.first + $0, 0] } }
  }

  /// (palette colour, solid-bright?) for a grid pad.
  private func rgbState(_ b: SurfaceProfile.Binding?) -> (UInt8, Bool) {
    guard let b, let d = b.deck.flatMap({ dj[$0] }) else { return (Color.off, false) }
    let deckColor = b.deck == "A" ? Color.orange : Color.cyan
    let isSet = d.hotCues[b.slot ?? 0] != nil
    switch b.action {
    case .hotcue: return (deckColor, isSet)
    case .clearcue: return (isSet ? Color.red : Color.off, false)
    default: return (deckColor, false)
    }
  }

  static func key(_ group: String, _ index: Int) -> String { "\(group)#\(index)" }
}
