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

/// One LED as a display shows it.
public struct PadLight: Equatable, Sendable {
  public enum Level: Sendable { case off, dim, full, blink }
  /// APC palette index (RGB pads); 0 for single-colour LEDs.
  public var colorIndex: UInt8
  public var level: Level
  public init(colorIndex: UInt8, level: Level) {
    self.colorIndex = colorIndex
    self.level = level
  }
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
    /// beats' APC macro-group colours (lib/backend/apc-mini-mk2.js `GROUP_COLOR`)
    static let white: UInt8 = 3, yellow: UInt8 = 13, green: UInt8 = 21, magenta: UInt8 = 53
    /// The SHIFT loop page: Akai's chart index 48 (#B98CFF).
    static let violet: UInt8 = 48
  }
  static let flashSeconds = 0.18
  /// Centre detent for pitch faders: ±2 % of travel snaps to zero.
  static let pitchDeadZone = 0.02
  /// Centre detent for a bipolar FX unit fader (filter, pitch): ±3 % of travel is neutral
  /// (a 7-bit fader's 62…65), the rest spread over the whole range so the ends still reach it.
  static let fxDeadZone = 0.03
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
    layer(exact[Self.key(e.group, e.index)] ?? groupWide[e.group] ?? [])
  }

  /// The binding a control answers to under the current shift state (or `shift`, when given):
  /// one made for this layer (`shift` equal to `shiftHeld`) wins over one for either layer
  /// (`shift` nil), so a `"shift": true` entry beside a plain one is that control's SHIFT layer
  /// (the APC's loop page over its grid).
  private func layer(_ candidates: [SurfaceProfile.Binding], shift: Bool? = nil)
    -> SurfaceProfile.Binding?
  {
    let held = shift ?? shiftHeld
    return candidates.first { $0.shift == held } ?? candidates.first { $0.shift == nil }
  }

  /// The binding a control's LED shows: the same layer its press would reach.
  private func lit(_ group: String, _ index: Int, shift: Bool? = nil) -> SurfaceProfile.Binding? {
    layer(exact[Self.key(group, index)] ?? [], shift: shift)
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
    // locked by the user (right-click ▸ Disable on its button): the press does nothing
    if dj.lockedActions.contains(b.lockKey) { return result }
    let deck = target(b)
    let press = e.pressed && (!e.isCC || e.value > 0.5)
    noteAutoMixTouch(b, deck: deck, event: e, press: press)
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
    case .masterFx:
      // a slider position on its own range, as beats' FX panel sends it
      if let d = deck, let k = b.macro.flatMap(MasterFxKey.init(id:)) {
        d.setMasterFx(k, k.sliderValue(e.value))  // the net's chain, a sample deck's bus, or the loops'
      }
    case .reverbWet: deck?.reverb.wet = e.value
    case .reverbSize: deck?.reverb.size = e.value
    case .fxUnit:
      // the value is the poke (a setting, immediate and smoothed on the audio thread); applied
      // unrecorded, as the MIDI that moved it is what the session and the journal keep
      if let d = deck, let p = b.param.flatMap(FxParam.init(id:)) {
        dj.applyAction(.fx(deck: d.name, param: p.id, value: Self.fxValue(p, e.value)))
      }
    case .fxKill, .fxReset:
      guard press, let d = deck else { break }
      if let i = b.index { flashed[Self.key(b.group, i)] = now }
      dj.applyAction(
        b.action == .fxKill
          ? .fxKill(deck: d.name, on: !d.fxUnit.killed, onBeat: true)
          : .fxReset(deck: d.name, onBeat: true))
    case .focusDeck:
      if press { dj.focus = Self.aim(b.slot) }
    case .regenerate:
      if press, let d = deck, let spec = d.currentSpec {
        if let i = b.index { flashed[Self.key(b.group, i)] = now }
        Task { @MainActor in await d.generate(spec.nextVersion) }
      }
    case .autoNext:
      if press { deck?.autoAdvance.toggle() }
    case .crossfader: dj.crossfader = e.value
    case .master: dj.master = e.value
    case .headphoneMix: dj.headphoneMix = e.value
    case .headphoneLevel: dj.headphoneLevel = e.value
    case .shift: shiftHeld = e.pressed
    case .clipToggle:
      guard press, let slot = b.slot, dj.clips.indices.contains(slot) else { break }
      let id = dj.clips[slot].id
      let state = dj.loopState(id)
      dj.setLooping(id, state == .off || state == .stopping)
    case .loopRecord:
      if let deck {
        if press { dj.focus = deck.name }
        dj.loopRecord(deck.name, on: press, bars: dj.tapTakeBars)
      }
    case .unbound: break
    case .nudge:
      // centred control: 0.5 = no nudge, full travel = ± the tempo-fader range
      dj[dj.focus]?.nudge((e.value - 0.5) * 2 * Deck.pitchRange)
    case .seedStep:
      // deck-less: the focus deck if it is playing a composed net (loop or song), else the one
      // that is; turning it on a wandering deck grabs the walk (it waits for a quiet phrase)
      let nets = dj.decks.values.filter { $0.playing && $0.mode == .net && $0.currentSpec != nil }
        .sorted { $0.name < $1.name }
      guard e.delta != 0,
        let d = nets.first(where: { $0.name == dj.focus }) ?? (nets.count == 1 ? nets[0] : nil)
      else { break }
      dj.focus = d.name
      d.stepSeed(e.delta)
      d.grabWander()
    case .wander:
      // deck-less: the focus deck's walk on or off (locked with its on-screen button too)
      guard press, let d = dj[dj.focus], d.mode == .net,
        !dj.lockedActions.contains(DJActionKind.lockKey(deck: d.name, .wander))
      else { break }
      if let i = b.index { flashed[Self.key(b.group, i)] = now }
      d.setWander(!d.wander.on)
    case .wanderPace:
      guard e.delta != 0, let d = dj[dj.focus], d.mode == .net else { break }
      d.stepWanderPace(e.delta)
    case .autoMix:
      // recorded as the MIDI that pressed it, replayed through the router (as .wander is)
      guard press else { break }
      if let i = b.index { flashed[Self.key(b.group, i)] = now }
      let s = dj.autoMix.settings
      dj.setAutoMix(on: !s.on, bars: s.bars, every: s.every)
    case .autoMixNow:
      guard press else { break }
      if let i = b.index { flashed[Self.key(b.group, i)] = now }
      dj.autoMixNow()
    case .section, .sectionPrev, .sectionNext, .roleMute, .stemMute, .macro, .panic, .stinger,
      .nextTrack,
      .keys, .sync, .quantize, .rewind, .pfl:
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

  /// Tell auto-mix what a control did (`DJEngine.noteAutoMixTouch`): the steering ones pause
  /// it; knobs, mutes, macros and FX don't. The crossfader is not a touch: auto-mix sees a
  /// moved fader itself.
  private func noteAutoMixTouch(
    _ b: SurfaceProfile.Binding, deck: Deck?, event e: ControlEvent, press: Bool
  ) {
    let kind: AutoMixTouch
    switch b.action {
    case .play: kind = .transport
    case .nextTrack, .regenerate: kind = .load
    case .cue, .hotcue, .loopIn, .loopOut, .loopHalve, .loopDouble, .sync, .section,
      .sectionPrev, .sectionNext, .rewind:
      kind = .steer
    case .seedStep:
      guard e.delta != 0 else { return }
      let nets = dj.decks.values.filter { $0.playing && $0.mode == .net && $0.currentSpec != nil }
      let d = nets.first(where: { $0.name == dj.focus }) ?? (nets.count == 1 ? nets.first : nil)
      if let d { dj.noteAutoMixTouch(d.name, .steer) }
      return
    case .nudge:
      guard abs(e.value - 0.5) > 0.02 else { return }
      dj.noteAutoMixTouch(dj.focus, .steer)
      return
    default: return
    }
    guard press, let deck else { return }
    dj.noteAutoMixTouch(deck.name, kind)
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
    case .stemMute: if let r = b.role { deck.toggleStem(r) }
    case .macro: if let id = b.macro { deck.fireMacro(id: id) }
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
    case .pfl: deck.pfl.toggle()
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
        let (color, level) = rgbState(lit(g.id, i))
        // APC: the status byte's low nibble is the brightness, so no channel here.
        let status =
          switch full ? PadLight.Level.full : level {
          case .full: leds.rgbFullStatus
          case .blink: leds.rgbBlinkStatus ?? leds.rgbDimStatus
          case .dim, .off: leds.rgbDimStatus
          }
        emit(0, note, status, color)
      }
    }
    for g in profile.groups where leds.singleGroups.contains(g.id) {
      for (i, note) in g.controlNumbers.enumerated() {
        emit(g.channel ?? 0, note, 0x90, singleState(lit(g.id, i), leds))
      }
    }
    return out
  }

  /// What each LED of the surface is showing right now — the same state `ledFrame` sends,
  /// as data, for a mirror on screen. Keyed by group id, one entry per control. `shift`: the
  /// layer to show instead of the one `shiftHeld` picks (an on-screen mirror with the Shift key
  /// down shows the SHIFT layer, which a shift-click reaches, though SHIFT is held only for the
  /// click itself).
  public func lights(
    now: TimeInterval = ProcessInfo.processInfo.systemUptime, shift: Bool? = nil
  ) -> [String: [PadLight]] {
    guard let leds = profile.leds else { return [:] }
    var out: [String: [PadLight]] = [:]
    for g in profile.groups where leds.rgbGroups.contains(g.id) {
      out[g.id] = g.controlNumbers.indices.map { i in
        let k = Self.key(g.id, i)
        let full = now - (flashed[k] ?? -1) < Self.flashSeconds
        let (color, level) = rgbState(lit(g.id, i, shift: shift))
        if full { return PadLight(colorIndex: color, level: .full) }
        // a surface that cannot blink a pad shows it dim, and so does its mirror
        let shown: PadLight.Level = level == .blink && leds.rgbBlinkStatus == nil ? .dim : level
        return PadLight(colorIndex: color, level: shown)
      }
    }
    for g in profile.groups where leds.singleGroups.contains(g.id) {
      out[g.id] = g.controlNumbers.indices.map { i in
        let v = singleState(lit(g.id, i, shift: shift), leds, shift: shift)
        let level: PadLight.Level =
          v == leds.singleBlink ? .blink : (v == leds.singleOn ? .full : .off)
        return PadLight(colorIndex: 0, level: level)
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

  private func singleState(
    _ b: SurfaceProfile.Binding?, _ leds: SurfaceProfile.LEDs, shift: Bool? = nil
  ) -> UInt8 {
    guard let b, b.action != .unbound else { return leds.singleOff }
    let d = target(b)
    switch b.action {
    case .roleMute: return d?.isRoleOn(b.role ?? "") == true ? leds.singleOn : leds.singleOff
    case .stemMute: return d?.isStemMuted(b.role ?? "") == true ? leds.singleOn : leds.singleOff
    case .sectionPrev, .sectionNext:
      guard let d, d.mode == .net, !d.sections.isEmpty else { return leds.singleOff }
      return leds.singleOn
    case .nextTrack: return d?.nextReady != nil ? leds.singleBlink : leds.singleOff
    case .quantize: return d?.quantize == .off ? leds.singleOff : leds.singleOn
    case .pfl: return d?.pfl == true ? leds.singleOn : leds.singleOff
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
    case .focusDeck:
      let aim = Self.aim(b.slot)
      if dj.focus == aim { return leds.singleOn }
      // aimed at the loops: the deck aim buttons blink (SHIFT shows the loops' own, lit)
      return dj.focus == "L" && aim != "L" ? leds.singleBlink : leds.singleOff
    case .autoNext: return target(b)?.autoAdvance == true ? leds.singleOn : leds.singleOff
    case .clipToggle:
      // lit while its loop plays, blinking on its way in or out (dark: no loop in that slot)
      guard let slot = b.slot, dj.clips.indices.contains(slot) else { return leds.singleOff }
      switch dj.loopState(dj.clips[slot].id) {
      case .on: return leds.singleOn
      case .starting, .stopping: return leds.singleBlink
      case .off: return leds.singleOff
      }
    case .loopRecord:
      // lit while held, blinking while the last bar finishes
      guard let d, let t = dj.loopTakeProgress(d.name) else { return leds.singleOff }
      return t.released ? leds.singleBlink : leds.singleOn
    case .shift: return (shift ?? shiftHeld) ? leds.singleOn : leds.singleOff
    case .autoMix:
      // lit while on, blinking while a hand-off runs
      let a = dj.autoMix
      guard a.settings.on else { return leds.singleOff }
      return a.run != nil ? leds.singleBlink : leds.singleOn
    case .wander:
      // lit while the focus deck wanders, blinking while the wheel holds it
      guard let w = dj[dj.focus]?.wander, w.on else { return leds.singleOff }
      return w.paused ? leds.singleBlink : leds.singleOn
    default: return leds.singleOn
    }
  }

  /// (palette colour, brightness) for a grid pad. Never `.off`: an unlit pad is a dim pad of
  /// colour 0, which is how the APC is told to go dark.
  private func rgbState(_ b: SurfaceProfile.Binding?) -> (UInt8, PadLight.Level) {
    if let b, b.action == .clipToggle { return clipState(b.slot) }
    let (color, bright) = deckPadState(b)
    return (color, bright ? .full : .dim)
  }

  /// The loop page: violet full while the slot's loop plays, blinking on its way in or out,
  /// dark for a slot with no loop.
  private func clipState(_ slot: Int?) -> (UInt8, PadLight.Level) {
    guard let slot, dj.clips.indices.contains(slot) else { return (Color.off, .dim) }
    switch dj.loopState(dj.clips[slot].id) {
    case .on: return (Color.violet, .full)
    case .starting, .stopping: return (Color.violet, .blink)
    case .off: return (Color.off, .dim)
    }
  }

  /// (palette colour, solid-bright?) for a pad bound to a deck.
  private func deckPadState(_ b: SurfaceProfile.Binding?) -> (UInt8, Bool) {
    guard let b, b.action != .unbound, let d = target(b) else {
      return (Color.off, false)
    }
    // the FX unit's kill (red, bright while killed) and reset (white, bright while it has
    // something to reset), on whichever target is aimed (A, B or the loops)
    if b.action == .fxKill { return (Color.red, d.fxUnit.killed) }
    if b.action == .fxReset { return (Color.white, !d.fxUnit.isNeutral) }
    // the FX surface (aimed at a deck): beats' colour per macro group, lit while it runs
    if b.deck == "*", b.action == .macro || b.action == .stinger {
      if let bus = d.bank?.master {
        // aimed at the loops: only the master macros play there
        guard let m = MasterMacro.allCases.first(where: { $0.id == b.macro }) else {
          return (Color.off, false)
        }
        return (Self.color(m), bus.isActive(m))
      }
      let id = b.macro ?? ""
      if d.mode == .net, let m = NetMacro.allCases.first(where: { $0.id == id }) {
        let tempo = [NetMacro.halfTime, .tapeStop, .tempoAnchor].contains(m)
        return (tempo ? Color.yellow : Color.red, d.wave.activeMacros.contains(m))
      }
      // the master macros, in either mode: a sample deck plays them on its own bus
      if let m = Self.playableMaster(id, d) { return (Self.color(m), d.isMasterActive(m)) }
      return (d.mode == .net ? Color.white : Color.off, false)  // a hit (stinger); dark on a sample
    }
    let deckColor = b.deck == "A" ? Color.orange : Color.cyan
    let isSet = d.hotCues[b.slot ?? 0] != nil
    switch b.action {
    case .section:
      let secs = d.sections
      guard secs.indices.contains(b.slot ?? 0) else { return (Color.off, false) }
      return (deckColor, d.currentSectionIndex == b.slot)
    case .macro, .panic, .stinger:
      if d.mode == .sample, d.bank == nil {
        // a sample deck's bus: panic and the master macros work there, the rest are dark
        if b.action == .panic { return (Color.red, false) }
        if b.action == .macro, let m = Self.playableMaster(b.macro ?? "", d) {
          return (Self.color(m), d.isMasterActive(m))
        }
        return (Color.off, false)
      }
      guard d.mode == .net || (d.bank != nil && b.action == .panic) else {
        return (Color.off, false)
      }
      return (b.action == .panic ? Color.red : deckColor, false)
    case .hotcue: return (deckColor, isSet)
    case .clearcue: return (isSet ? Color.red : Color.off, false)
    default: return (deckColor, false)
    }
  }

  static func key(_ group: String, _ index: Int) -> String { "\(group)#\(index)" }

  /// A fader position (0…1) on an FX unit control's travel. Unipolar controls are linear
  /// (0 → the bottom of the range, 1 → the top; the LP's top is open). Bipolar ones (the filter,
  /// pitch) have a centre detent that lands exactly on neutral, so a fader parked in the middle
  /// leaves the chain bit-transparent; pitch steps in whole semitones.
  static func fxValue(_ p: FxParam, _ position: Double) -> Double {
    let x = position.isFinite ? Swift.max(0, Swift.min(1, position)) : 0.5
    let r = p.range
    guard r.lowerBound < 0 else { return r.lowerBound + x * (r.upperBound - r.lowerBound) }
    let c = x * 2 - 1
    guard abs(c) > fxDeadZone else { return p.neutral }
    let u = (abs(c) - fxDeadZone) / (1 - fxDeadZone) * (c < 0 ? -1 : 1)
    let v = u * r.upperBound
    return p == .pitch ? v.rounded() : v
  }

  /// The master macro `id` names, if `d` can play it: every one, in either mode (a sample deck
  /// runs the chain and the vinyl brake on its own bus).
  static func playableMaster(_ id: String, _ d: Deck) -> MasterMacro? { MasterMacro(id: id) }

  /// beats' APC colour for a master macro's group.
  static func color(_ m: MasterMacro) -> UInt8 {
    m.group == "Pitch" ? Color.magenta : (m.group == "Feel" ? Color.green : Color.cyan)
  }

  /// What a `focusDeck` binding aims at: slot 0 deck A, 1 deck B, 2 the loop channel.
  static func aim(_ slot: Int?) -> String {
    switch slot {
    case 1: "B"
    case 2: "L"
    default: "A"
    }
  }

  /// The deck a binding acts on: its own, or for "*" the aimed one (`DJEngine.focus`).
  func target(_ b: SurfaceProfile.Binding) -> Deck? {
    b.deck == "*" ? dj[dj.focus] : b.deck.flatMap { dj[$0] }
  }

  /// Engine parameter a continuous binding writes, for ownership.
  public static func parameter(_ b: SurfaceProfile.Binding) -> String? {
    switch b.action {
    case .crossfader: "crossfader"
    case .master: "master"
    case .headphoneMix: "headphoneMix"
    case .headphoneLevel: "headphoneLevel"
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
    case .headphoneMix: return dj.headphoneMix
    case .headphoneLevel: return dj.headphoneLevel
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

extension MasterFxKey {
  /// A slider position, 0…1 of its travel, in the slider's own units (its range, rounded): what a
  /// controller's master FX fader and `DeckAction.masterFx` both set.
  public func sliderValue(_ position: Double) -> Int {
    let p = position.isFinite ? Swift.max(0, Swift.min(1, position)) : 0
    return Int((Double(min) + p * Double(max - min)).rounded())
  }
}
