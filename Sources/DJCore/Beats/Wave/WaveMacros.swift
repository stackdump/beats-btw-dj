// Live-performance controls on the net executor: role mutes, slot launches, macros,
// stingers, fast-forward. These are the Swift side of what beats' worker does for
// `mute-group`, `fire-macro` and friends (sequencer-worker.js, lib/macros/*), done the
// same way — a mute now, its restore N ticks later, locked to the net clock — but as
// fixed-capacity timers on the audio thread instead of injected chain nets, so nothing
// here allocates.

/// Which music nets a mute macro hits (`MACRO_TARGETS` in macros/catalog.js).
public enum MacroTargets: UInt8, Sendable {
  case nonDrums = 0
  case drumsOnly = 1
  case everything = 2
  /// Everything but the kick: beat repeat keeps a pulse under the stutter.
  case nonKick = 3
}

/// The net-native macros of `lib/macros/catalog.js` (mute, beat-repeat, compound and tempo
/// kinds). The catalog's FX, pan, shape, pitch and feel macros drive Tone master-chain
/// sliders; the wave engine has no master chain yet, so they are not ported.
public enum NetMacro: UInt8, CaseIterable, Sendable {
  case drop, breakdown, soloDrums, cut, doubleDrop, beatRepeat, halfTime, tapeStop, tempoAnchor

  public enum Unit: Sendable { case bar, tick }

  public var id: String {
    switch self {
    case .drop: "drop"
    case .breakdown: "breakdown"
    case .soloDrums: "solo-drums"
    case .cut: "cut"
    case .doubleDrop: "double-drop"
    case .beatRepeat: "beat-repeat"
    case .halfTime: "half-time"
    case .tapeStop: "tape-stop"
    case .tempoAnchor: "tempo-anchor"
    }
  }

  public var label: String {
    switch self {
    case .drop: "Drop"
    case .breakdown: "Breakdown"
    case .soloDrums: "Solo Drums"
    case .cut: "Cut"
    case .doubleDrop: "Double Drop"
    case .beatRepeat: "Beat Repeat"
    case .halfTime: "Half Time"
    case .tapeStop: "Tape Stop"
    case .tempoAnchor: "Anchor"
    }
  }

  public var defaultDuration: Int {
    switch self {
    case .drop, .doubleDrop, .beatRepeat, .tapeStop: 1
    default: 2
    }
  }

  public var unit: Unit { self == .cut ? .tick : .bar }

  /// Ticks for a duration in this macro's own unit (a bar is 16 ticks).
  public func ticks(_ duration: Int? = nil) -> Int {
    let d = duration ?? defaultDuration
    return unit == .bar ? d * 16 : d
  }

  public init?(id: String) {
    guard let m = Self.allCases.first(where: { $0.id == id }) else { return nil }
    self = m
  }
}

extension WaveGraph {
  /// A mute macro that starts `delay` ticks from now. `macro` is the `NetMacro.tag` it belongs
  /// to (0: none): the delayed mutes carry it, so the display knows whose they are. The timer's
  /// `arg` holds the mute length in its low 16 bits and the tag above them.
  func scheduleMute(_ which: MacroTargets, after delay: Int, ticks: Int, macro: UInt8 = 0) {
    for i in 0..<Self.timerCapacity where timerKind[i] == 0 {
      setTimer(
        i, kind: 3, net: Int32(which.rawValue), remaining: Int32(max(1, delay)),
        arg: Int32(min(max(ticks, 0), 0xFFFF)) | Int32(macro) << 16)
      return
    }
    timerOverflow += 1
  }

  // MARK: roles and slots

  /// Mute or unmute a role by `strHash(role)`: a riff group (all its slot nets) or a
  /// plain net. Unmuting a group brings back the slot it last activated.
  public func setRoleMuted(hash: Int32, _ muted: Bool) {
    guard let t = roleTargets[hash] else { return }
    if t >= 0 {
      setGroupMuted(t, muted)
    } else {
      self.muted[-t - 2] = muted ? 1 : 0
    }
  }

  func setGroupMuted(_ gi: Int, _ muted: Bool) {
    if muted {
      mutedGroups[gi] = 1
      for i in groupNets[gi] { self.muted[i] = 1 }
    } else {
      mutedGroups[gi] = 0
      let pick = activeSlot[gi] >= 0 ? activeSlot[gi] : (groupNets[gi].first ?? -1)
      if pick >= 0 {
        for i in groupNets[gi] where i != pick { self.muted[i] = 1 }
        self.muted[pick] = 0
      }
    }
  }

  /// Whether a role currently makes sound (any slot unmuted / the net unmuted).
  public func isRoleAudible(hash: Int32) -> Bool {
    guard let t = roleTargets[hash] else { return false }
    if t >= 0 { return groupNets[t].contains { muted[$0] == 0 } }
    return muted[-t - 2] == 0
  }

  /// `activate-slot` aimed at a net by `strHash(netId)` (e.g. "bass-2").
  public func activateSlot(hash: Int32) {
    guard let tgt = byHash[hash] else { return }
    let gi = nets[tgt].groupIdx
    guard gi >= 0 else { return }
    for o in nets where o.groupIdx == gi && o.index != tgt { muted[o.index] = 1 }
    if mutedGroups[gi] == 0 { muted[tgt] = 0 }
    activeSlot[gi] = tgt
  }

  // MARK: macros

  /// `arg` of a kind-1 (unmute) timer is the `NetMacro.tag` of the macro that muted the net
  /// (0 when no macro did).
  private func addTimer(kind: UInt8, net: Int, ticks: Int, arg: Int32 = 0) {
    for i in 0..<Self.timerCapacity where timerKind[i] == 0 {
      setTimer(i, kind: kind, net: Int32(net), remaining: Int32(max(1, ticks)), arg: arg)
      return
    }
    timerOverflow += 1
  }

  /// Does a macro selector pick net `i`? (Control nets never.) The one rule `fireMute` mutes
  /// by, and the display asks to know which roles a running macro touches.
  func selects(_ which: MacroTargets, net i: Int) -> Bool {
    if isControlNet[i] { return false }
    switch which {
    case .nonDrums: return !isDrumNet[i]
    case .drumsOnly: return isDrumNet[i]
    case .everything: return true
    case .nonKick: return !isKickNet[i]
    }
  }

  /// Mute every audible net the selector picks and unmute it again after `ticks` ticks.
  /// Skips nets already muted, so the restore never undoes a mute someone meant.
  /// Returns how many nets it muted.
  ///
  /// `macro` is the `NetMacro.tag` of the macro firing (0: none; the tag rides on the restore
  /// timers so the display can tell which macro is holding which net).
  @discardableResult
  public func fireMute(_ which: MacroTargets, ticks: Int, macro: UInt8 = 0) -> Int {
    var n = 0
    for i in 0..<nets.count {
      if muted[i] != 0 || !selects(which, net: i) { continue }
      setMuted(i, 1)
      addTimer(kind: 1, net: i, ticks: ticks, arg: Int32(macro))
      n += 1
    }
    return n
  }

  /// Beat repeat: a mute burst of `burst` ticks every `step` ticks for `ticks` ticks.
  public func fireBeatRepeat(ticks: Int, step: Int = 2, burst: Int = 1) {
    logRepeat()
    repeatStep = max(1, step)
    repeatBurst = max(1, burst)
    repeatElapsed = 0
    repeatRemaining = max(1, ticks)
    fireMute(.nonKick, ticks: repeatBurst, macro: NetMacro.beatRepeat.tag)
    repeatElapsed = 1
    repeatRemaining -= 1
  }

  /// Unmute a stinger net (`hit1`…) for `ticks` ticks, then mute it again.
  public func fireStinger(hash: Int32, ticks: Int) {
    guard let i = byHash[hash] else { return }
    setMuted(i, 0)
    // Replace any pending restore for this net so a re-fire extends rather than stacks.
    for k in 0..<Self.timerCapacity where timerKind[k] == 2 && Int(timerNet[k]) == i {
      setTimer(k, kind: 0, net: 0, remaining: 0, arg: 0)
    }
    addTimer(kind: 2, net: i, ticks: ticks)
  }

  /// Run all pending restores now and stop the repeater (the panic button).
  public func cancelMacros() {
    for i in 0..<Self.timerCapacity where timerKind[i] != 0 {
      if timerKind[i] != 3 { setMuted(Int(timerNet[i]), timerKind[i] == 1 ? 0 : 1) }
      setTimer(i, kind: 0, net: 0, remaining: 0, arg: 0)
    }
    logRepeat()
    repeatRemaining = 0
  }

  /// Drop all macro state without restoring anything (reset / fast-forward).
  func clearMacros() {
    for i in 0..<Self.timerCapacity { timerKind[i] = 0 }
    repeatRemaining = 0
  }

  /// Is any macro in effect: a pending restore or a running beat repeat? Allocation-free.
  var hasActiveMacros: Bool {
    if repeatRemaining > 0 { return true }
    for i in 0..<Self.timerCapacity where timerKind[i] != 0 { return true }
    return false
  }

  /// Which macros are in effect, and which nets each is holding muted, for the display:
  /// bit `k` of `mask` is `NetMacro(rawValue: k)`; nets below 256 whose pending restore a macro
  /// owns (a mute timer carrying its tag) are in that macro's part of `held`. A beat repeat
  /// counts while it runs,
  /// even between its bursts. Tempo macros live on the runner (`WaveRunner.macroSnapshot`).
  /// Allocation-free: this runs on the audio thread once per render block.
  func macroSnapshot() -> MacroSnapshot {
    var s = MacroSnapshot()
    if repeatRemaining > 0 { s.mask |= NetMacro.beatRepeat.bit }
    for i in 0..<Self.timerCapacity where timerKind[i] != 0 {
      let tag: Int32
      switch timerKind[i] {
      case 1: tag = timerArg[i]
      case 3: tag = timerArg[i] >> 16
      default: tag = 0
      }
      guard tag > 0, tag <= 32 else { continue }
      s.mask |= 1 << UInt32(tag - 1)
      if timerKind[i] == 1 { s.hold(net: Int(timerNet[i]), slot: Int(tag - 1)) }
    }
    return s
  }

  /// Number of pending tick-locked restores (UI / tests).
  public var pendingMacroTimers: Int { timerKind.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } }

  /// Called at the end of every tick, after all nets (a macro's restore net sits last in
  /// the project, so its last transition fires on the Nth tick after injection).
  func serviceMacros() {
    for i in 0..<Self.timerCapacity where timerKind[i] != 0 {
      let remaining = timerRemaining[i] - 1
      if remaining <= 0 {
        let kind = timerKind[i]
        let net = timerNet[i]
        let arg = timerArg[i]
        setTimer(i, kind: 0, net: 0, remaining: 0, arg: 0)
        if kind == 3 {
          fireMute(
            MacroTargets(rawValue: UInt8(net)) ?? .nonDrums, ticks: Int(arg & 0xFFFF),
            macro: UInt8(truncatingIfNeeded: arg >> 16))
        } else {
          setMuted(Int(net), kind == 1 ? 0 : 1)
        }
      } else {
        setTimer(i, kind: timerKind[i], net: timerNet[i], remaining: remaining, arg: timerArg[i])
      }
    }
    if repeatRemaining > 0 {
      logRepeat()
      if repeatElapsed % repeatStep == 0 {
        fireMute(.nonKick, ticks: repeatBurst, macro: NetMacro.beatRepeat.tag)
      }
      repeatElapsed += 1
      repeatRemaining -= 1
    }
  }

  // MARK: seeking

  /// Rebuild the marking at `tick` by replaying from the start without sound (what the
  /// sequencer worker's `fastForwardTo` does). Not for the audio thread: it is O(tick).
  public func fastForward(to target: Int) {
    reset()
    recording = false
    var n = 0
    while n < target && !stopRequested {
      advance { _, _ in }
      n += 1
    }
    stopRequested = false
    recording = true
    clearHistory()
  }
}
