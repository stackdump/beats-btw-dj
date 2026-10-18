// The FX unit on a deck (FxUnit.swift): where its settings go, which controls a deck has, and where
// a quantised reset or kill lands. The pokes are `DeckAction.fx` / `.fxReset` / `.fxKill`
// (`DJEngine.applyAction`); the deck keeps the settings (`Deck.fxUnit`, in `DeckParams`, so sessions
// and journal checkpoints start from them) and sends each change to the chain it plays through now:
// a net's `WaveDeckSource`, a sample deck's bus (`DeckRenderer.master`) or, on "L", the loops'
// bus. A mode switch hands the whole setting to the other chain (`syncFxUnit`).

extension Deck {
  /// The controls this deck's chain has right now: every chain control on any target; the room on
  /// a net deck whose song has one (`.space`), echo and feedback on one whose genre has an echo.
  public var fxUnitControls: Set<FxParam> {
    var s = Set(FxParam.chain)
    if bank == nil && mode == .net {
      if wave.hasRoom { s.insert(.room) }
      if wave.hasEcho {
        s.insert(.echo)
        s.insert(.feedback)
      }
    }
    return s
  }

  /// Why a control is greyed out here, or nil when the deck has it.
  public func fxUnitMissing(_ p: FxParam) -> String? {
    guard !fxUnitControls.contains(p) else { return nil }
    if bank != nil { return "the loops have no room or echo send (their reverb is Reverb)" }
    if mode != .net { return "a sample deck has no room or echo send (its reverb is Reverb)" }
    return p == .room ? "this song has no room" : "this genre has no echo"
  }

  /// Set one control (smoothed on the audio thread).
  public func setFx(_ p: FxParam, _ value: Double) {
    fxUnit[p] = value
    sendFxUnit(.set(param: UInt8(p.index), value: fxUnit[p], snap: false))
  }

  /// Every control back to neutral and the kill off; `frame` (deck frames, 0 = now): the block
  /// holding it (`DJEngine.fxBeatFrame`, the next beat).
  public func resetFx(atFrame frame: Int = 0) {
    fxUnit = FxUnitSettings()
    sendFxUnit(.reset(frame: frame))
  }

  /// The kill: the unit bypassed (its knobs kept) or back.
  public func killFx(_ on: Bool, atFrame frame: Int = 0) {
    fxUnit.killed = on
    sendFxUnit(.kill(on: on, frame: frame))
  }

  /// A whole setting at once, at once (a session's or a checkpoint's starting state).
  func applyFxUnit(_ s: FxUnitSettings) {
    fxUnit = s
    syncFxUnit()
  }

  /// Hand the whole setting to the chain the deck plays through now, without smoothing (a mode
  /// switch: the other chain kept whatever it last had).
  func syncFxUnit() {
    for p in FxParam.allCases {
      sendFxUnit(.set(param: UInt8(p.index), value: fxUnit[p], snap: true))
    }
    sendFxUnit(.kill(on: fxUnit.killed, frame: 0))
  }

  private func sendFxUnit(_ c: FxUnitCommand) {
    if let bank {
      bank.master.sendFxUnit(c)
    } else if mode == .net {
      wave.sendFxUnit(c)
    } else {
      renderer.master?.sendFxUnit(c)
    }
  }
}

extension DJEngine {
  /// Where a quantised FX unit move (`onBeat`) on `deck` lands: the next beat of its own grid at
  /// least `loopLead` frames ahead (the loops: their clock's), in that deck's frames. 0 (at once)
  /// on a stopped deck or one with no grid.
  func fxBeatFrame(_ deck: Deck) -> Int {
    if deck.bank != nil {
      let clock = loopClock(for: nil)
      guard clock.framesPerBeat > 0 else { return 0 }
      return clock.nextBoundary(after: loopChannel.renderedFrames + Self.loopLead, every: 1)
    }
    guard deck.playing, let s = deck.beatState, s.bpm > 0 else { return 0 }
    let now = deck.renderedFrames
    let clock = LoopClock(
      ref: deck, origin: (now, s.beat), framesPerBeat: 60 / s.bpm * deck.turntable.sampleRate,
      bpm: s.bpm)
    return clock.nextBoundary(after: now + Self.loopLead, every: 1)
  }
}
