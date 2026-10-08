import Foundation

/// What a decoded message did, for monitors, the UI and the coverage log.
public enum SurfaceOutcome: Equatable, Sendable {
  case bound(SurfaceProfile.Binding)
  /// Decoded, deliberately parked by the layout.
  case unbound(reason: String)
  /// Decoded, but the layout has no entry at all (a profile gap).
  case unmapped
  /// Bound, but held back by soft takeover: another control (or the UI)
  /// moved this parameter last, and this one has not reached its value yet.
  case pickup(SurfaceProfile.Binding)
}

/// Routes one surface's messages to the engine and computes its LED
/// feedback. Not thread-safe: use from the main actor.
public final class SurfaceController {
  public let profile: SurfaceProfile
  private let dj: DJEngine
  private var decoder: SurfaceDecoder
  private var exact: [String: [SurfaceProfile.Binding]] = [:]  // "group#index"
  private var groupWide: [String: [SurfaceProfile.Binding]] = [:]  // "group"
  private var ledCache: [UInt16: UInt16] = [:]  // channel<<8 | note → status<<8 | vel
  private var flashed: [String: TimeInterval] = [:]
  /// Last value each continuous control sent, for soft-takeover crossing.
  private var lastValue: [String: Double] = [:]
  /// Software shift (APC): true while a `shift` control is held.
  public private(set) var shiftHeld = false

  /// Palette indices (APC mini mk2 velocity → colour chart).
  enum Color {
    static let off: UInt8 = 0, red: UInt8 = 5, orange: UInt8 = 9, cyan: UInt8 = 37
  }
  static let flashSeconds = 0.18
  /// Centre detent for pitch faders: ±2 % of travel snaps to zero.
  static let pitchDeadZone = 0.02
  /// Soft takeover accepts a value this close to the parameter's.
  static let pickupWindow = 0.03

  public init(profile: SurfaceProfile, engine: DJEngine) {
    self.profile = profile
    dj = engine
    decoder = SurfaceDecoder(profile: profile)
    for b in profile.layout {
      if let i = b.index {
        exact[Self.key(b.group, i), default: []].append(b)
      } else {
        groupWide[b.group, default: []].append(b)
      }
    }
  }

  public func decode(_ bytes: [UInt8]) -> ControlEvent? { decoder.decode(bytes) }

  /// The binding for an event under the current shift state.
  public func binding(for e: ControlEvent) -> SurfaceProfile.Binding? {
    let candidates = exact[Self.key(e.group, e.index)] ?? groupWide[e.group] ?? []
    return candidates.first { $0.shift == nil || $0.shift == shiftHeld }
  }

  public func outcome(for e: ControlEvent) -> SurfaceOutcome {
    guard let b = binding(for: e) else { return .unmapped }
    if b.action == .unbound { return .unbound(reason: b.reason ?? "parked") }
    return .bound(b)
  }

  /// Decode and apply one raw message. Returns nil for messages the profile
  /// does not describe at all.
  @discardableResult
  public func handle(bytes: [UInt8], now: TimeInterval = ProcessInfo.processInfo.systemUptime)
    -> (ControlEvent, SurfaceOutcome)?
  {
    guard let e = decode(bytes) else { return nil }
    return (e, handle(e, now: now))
  }

  @discardableResult
  public func handle(_ e: ControlEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime)
    -> SurfaceOutcome
  {
    let result = outcome(for: e)
    guard case .bound(let b) = result else { return result }
    let deck = b.deck.flatMap { dj[$0] }
    let press = e.pressed && (!e.isCC || e.value > 0.5)
    if let param = Self.parameter(b),
      let me = b.index.map({ "\(profile.name)/\(Self.key(b.group, $0))" })
    {
      let v = e.value
      let previous = lastValue[me]
      lastValue[me] = v
      if let owner = dj.owners[param], owner != me, let cur = faderPosition(b) {
        let crossed = previous.map { ($0 - cur) * (v - cur) <= 0 } ?? false
        guard abs(v - cur) < Self.pickupWindow || crossed else { return .pickup(b) }
      }
      dj.owners[param] = me
    }
    switch b.action {
    case .volume: deck?.volume = e.value
    case .filter: deck?.filter = e.value
    case .gain: deck?.gain = e.value
    case .eqLow: deck?.eqLow = e.value
    case .eqMid: deck?.eqMid = e.value
    case .eqHigh: deck?.eqHigh = e.value
    case .pitch:
      let p = e.value * 2 - 1
      deck?.pitch = abs(p) < Self.pitchDeadZone ? 0 : p
    case .crossfader: dj.crossfader = e.value
    case .master: dj.master = e.value
    case .shift: shiftHeld = e.pressed
    case .unbound: break
    case .nudge:
      // centred control: 0.5 = no nudge, full travel = ± the tempo-fader range
      dj[dj.focus]?.nudge((e.value - 0.5) * 2 * Deck.pitchRange)
    case .section, .sectionPrev, .sectionNext, .roleMute, .macro, .panic, .stinger, .nextTrack,
      .keys, .sync, .quantize, .rewind:
      perform(b, deck: deck, event: e, press: press, now: now)
    case .play, .cue, .hotcue, .clearcue, .loopIn, .loopOut, .loopHalve, .loopDouble:
      guard press else { break }
      if let i = b.index { flashed[Self.key(b.group, i)] = now }
      switch b.action {
      case .play: deck.map { $0.setPlaying(!$0.playing) }
      case .cue: deck?.cue()
      case .hotcue: deck?.hotCue(b.slot ?? 0)
      case .clearcue: deck?.clearCue(b.slot ?? 0)
      case .loopIn: deck?.loopIn()
      case .loopOut: deck?.loopOut()
      case .loopHalve: deck?.loopHalve()
      case .loopDouble: deck?.loopDouble()
      default: break
      }
    }
    return result
  }

  /// Net-deck performance actions. They act on the binding's deck, or the focus deck for
  /// deck-less ones (keys).
  private func perform(
    _ b: SurfaceProfile.Binding, deck: Deck?, event e: ControlEvent, press: Bool, now: TimeInterval
  ) {
    if b.action == .keys {
      guard let d = dj[dj.focus] else { return }
      if e.pressed && e.value > 0 {
        d.keyDown(e.index, velocity: max(1, Int((e.value * 127).rounded())))
      } else {
        d.keyUp(e.index)
      }
      return
    }
    guard press, let deck else { return }
    dj.focus = deck.name
    if let i = b.index { flashed[Self.key(b.group, i)] = now }
    switch b.action {
    case .section: deck.launchSection(b.slot ?? 0)
    case .sectionPrev: deck.stepSection(-1)
    case .sectionNext: deck.stepSection(1)
    case .roleMute: if let r = b.role { deck.toggleRole(r) }
    case .macro: if let m = b.macro.flatMap(NetMacro.init(id:)) { deck.fire(m) }
    case .panic: deck.panic()
    case .stinger: deck.stinger(b.slot ?? 0)
    case .nextTrack: deck.skipToNextTrack()
    case .sync:
      if let other = dj.decks.values.sorted(by: { $0.name < $1.name }).first(where: { $0 !== deck })
      {
        deck.sync(to: other, align: b.slot == 1 ? .bar : .beat)
      }
    case .quantize:
      deck.quantize = deck.quantize == .off ? .beat : (deck.quantize == .beat ? .bar : .off)
    case .rewind: deck.rewind()
    default: break
    }
  }

  /// LED messages whose state changed since the last call (empty for surfaces
  /// without LEDs). Call ~20x/s and send the result to the surface's output.
  public func ledFrame(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [[UInt8]] {
    guard let leds = profile.leds else { return [] }
    var out: [[UInt8]] = []
    func emit(_ ch: UInt8, _ note: UInt8, _ statusBase: UInt8, _ vel: UInt8) {
      let status = statusBase | ch
      let k = UInt16(ch) << 8 | UInt16(note)
      let sig = UInt16(status) << 8 | UInt16(vel)
      if ledCache[k] == sig { return }
      ledCache[k] = sig
      out.append([status, note, vel])
    }
    for g in profile.groups where leds.rgbGroups.contains(g.id) {
      for (i, note) in g.controlNumbers.enumerated() {
        let k = Self.key(g.id, i)
        let full = now - (flashed[k] ?? -1) < Self.flashSeconds
        let (color, lit) = rgbState(exact[k]?.first)
        // APC: the status byte's low nibble is the brightness, so no channel here.
        emit(0, note, full || lit ? leds.rgbFullStatus : leds.rgbDimStatus, color)
      }
    }
    for g in profile.groups where leds.singleGroups.contains(g.id) {
      for (i, note) in g.controlNumbers.enumerated() {
        let b = exact[Self.key(g.id, i)]?.first
        emit(g.channel ?? 0, note, 0x90, singleState(b, leds))
      }
    }
    return out
  }

  /// Messages turning every LED off (on quit / disconnect).
  public func blackout() -> [[UInt8]] {
    guard let leds = profile.leds else { return [] }
    ledCache = [:]
    return profile.groups.flatMap { g -> [[UInt8]] in
      if leds.rgbGroups.contains(g.id) { return g.controlNumbers.map { [0x90, $0, 0] } }
      if leds.singleGroups.contains(g.id) {
        return g.controlNumbers.map { [0x90 | (g.channel ?? 0), $0, 0] }
      }
      return []
    }
  }

  private func singleState(_ b: SurfaceProfile.Binding?, _ leds: SurfaceProfile.LEDs) -> UInt8 {
    guard let b, b.action != .unbound else { return leds.singleOff }
    let d = b.deck.flatMap { dj[$0] }
    switch b.action {
    case .roleMute: return d?.isRoleOn(b.role ?? "") == true ? leds.singleOn : leds.singleOff
    case .sectionPrev, .sectionNext:
      guard let d, d.mode == .net, !d.sections.isEmpty else { return leds.singleOff }
      return leds.singleOn
    case .nextTrack: return d?.nextReady != nil ? leds.singleBlink : leds.singleOff
    case .quantize: return d?.quantize == .off ? leds.singleOff : leds.singleOn
    case .sync:
      // lit while this deck runs at the other deck's tempo
      guard let d, let mine = d.effectiveBPM,
        let other = dj.decks.values.first(where: { $0 !== d })?.effectiveBPM
      else { return leds.singleOff }
      return abs(mine - other) < 0.05 ? leds.singleOn : leds.singleOff
    case .play: return d?.playing == true ? leds.singleBlink : leds.singleOn
    case .hotcue: return d?.hotCues[b.slot ?? 0] != nil ? leds.singleOn : leds.singleOff
    case .loopOut: return d?.looping == true ? leds.singleOn : leds.singleOff
    case .loopIn: return d?.loopStart != nil ? leds.singleOn : leds.singleOff
    case .shift: return shiftHeld ? leds.singleOn : leds.singleOff
    default: return leds.singleOn
    }
  }

  /// (palette colour, solid-bright?) for a grid pad.
  private func rgbState(_ b: SurfaceProfile.Binding?) -> (UInt8, Bool) {
    guard let b, b.action != .unbound, let d = b.deck.flatMap({ dj[$0] }) else {
      return (Color.off, false)
    }
    let deckColor = b.deck == "A" ? Color.orange : Color.cyan
    let isSet = d.hotCues[b.slot ?? 0] != nil
    switch b.action {
    case .section:
      let secs = d.sections
      guard secs.indices.contains(b.slot ?? 0) else { return (Color.off, false) }
      return (deckColor, d.currentSectionIndex == b.slot)
    case .macro, .panic, .stinger:
      guard d.mode == .net else { return (Color.off, false) }
      return (b.action == .panic ? Color.red : deckColor, false)
    case .hotcue: return (deckColor, isSet)
    case .clearcue: return (isSet ? Color.red : Color.off, false)
    default: return (deckColor, false)
    }
  }

  static func key(_ group: String, _ index: Int) -> String { "\(group)#\(index)" }

  /// Engine parameter a continuous binding writes, for ownership.
  public static func parameter(_ b: SurfaceProfile.Binding) -> String? {
    switch b.action {
    case .crossfader: "crossfader"
    case .master: "master"
    case .volume, .filter, .gain, .eqLow, .eqMid, .eqHigh, .pitch:
      "\(b.deck ?? "?").\(b.action.rawValue)"
    default: nil
    }
  }

  /// The parameter's current value in the control's 0...1 travel.
  private func faderPosition(_ b: SurfaceProfile.Binding) -> Double? {
    let d = b.deck.flatMap { dj[$0] }
    switch b.action {
    case .crossfader: return dj.crossfader
    case .master: return dj.master
    case .volume: return d?.volume
    case .filter: return d?.filter
    case .gain: return d?.gain
    case .eqLow: return d?.eqLow
    case .eqMid: return d?.eqMid
    case .eqHigh: return d?.eqHigh
    case .pitch: return d.map { ($0.pitch + 1) / 2 }
    default: return nil
    }
  }
}
