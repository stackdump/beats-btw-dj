// A reversible net clock.
//
// beats' jog lab ran its Petri clock backwards by un-firing the transitions whose
// outputs held the token ("the marking after scrubbing out and back is the marking
// you left"). The same holds here, but for the whole executor: the log records what
// every recent tick fired and every state change it made (mutes, slot choices, macro
// timers, the beat-repeat counter), so `unadvance` can undo a tick exactly —
// including the control nets that drain tokens, which are not conservative.
//
// The log is fixed-size (512 ticks = 32 bars, fewer if the ticks are busy) and
// preallocated; nothing here allocates.

extension WaveGraph {
  // change record: 6 Int32 — [code, a, b, c, d, e]
  //   0  muted[a] was b
  //   1  mutedGroups[a] was b
  //   2  activeSlot[a] was b
  //   3  timer slot a was (kind b, net c, remaining d, arg e)
  //   4  repeater was (remaining a, elapsed b, step c, burst d)
  static let changeSize = 6

  func clearHistory() {
    hTicks = 0
    hFireCount = 0
    hChangeCount = 0
  }

  /// How many ticks `unadvance` can still undo.
  public var rewindableTicks: Int { hTicks }

  func logFire(_ net: Int, _ trans: Int) {
    guard recording, hFireCount + 2 <= hFires.count else { return }
    hFires[hFireCount] = Int32(net)
    hFires[hFireCount + 1] = Int32(trans)
    hFireCount += 2
  }

  func logChange(_ code: Int32, _ a: Int, _ b: Int, _ c: Int = 0, _ d: Int = 0, _ e: Int = 0) {
    guard recording, hChangeCount + Self.changeSize <= hChanges.count else { return }
    hChanges[hChangeCount] = code
    hChanges[hChangeCount + 1] = Int32(truncatingIfNeeded: a)
    hChanges[hChangeCount + 2] = Int32(truncatingIfNeeded: b)
    hChanges[hChangeCount + 3] = Int32(truncatingIfNeeded: c)
    hChanges[hChangeCount + 4] = Int32(truncatingIfNeeded: d)
    hChanges[hChangeCount + 5] = Int32(truncatingIfNeeded: e)
    hChangeCount += Self.changeSize
  }

  /// `muted[i] = v`, logged so a rewind restores the old value.
  func setMuted(_ i: Int, _ v: UInt8) {
    guard muted[i] != v else { return }
    logChange(0, i, Int(muted[i]))
    muted[i] = v
  }

  func setTimer(_ i: Int, kind: UInt8, net: Int32, remaining: Int32, arg: Int32) {
    logChange(3, i, Int(timerKind[i]), Int(timerNet[i]), Int(timerRemaining[i]), Int(timerArg[i]))
    timerKind[i] = kind
    timerNet[i] = net
    timerRemaining[i] = remaining
    timerArg[i] = arg
  }

  func logRepeat() { logChange(4, repeatRemaining, repeatElapsed, repeatStep, repeatBurst) }

  /// Make room for one more tick in the log, dropping the oldest ticks if it is full.
  func ensureHistoryRoom() {
    // a tick fires at most one transition per enabled transition: bound it by the net sizes
    if fireNeedCache < 0 {
      fireNeedCache = min(hFires.count / 4, nets.reduce(0) { $0 + $1.nTrans } * 2)
    }
    let fireNeed = fireNeedCache
    let changeNeed = min(hChanges.count / 4, 4096)
    while hTicks > 0
      && (hTicks >= Self.historyTicks || hFireCount + fireNeed > hFires.count
        || hChangeCount + changeNeed > hChanges.count)
    {
      dropOldestTick()
    }
  }

  private func dropOldestTick() {
    let fireCut = Int(hFireEnd[0])
    let changeCut = Int(hChangeEnd[0])
    hFires.withUnsafeMutableBufferPointer { p in
      for i in fireCut..<hFireCount { p[i - fireCut] = p[i] }
    }
    hChanges.withUnsafeMutableBufferPointer { p in
      for i in changeCut..<hChangeCount { p[i - changeCut] = p[i] }
    }
    for i in 1..<max(hTicks, 1) {
      hFireEnd[i - 1] = hFireEnd[i] - Int32(fireCut)
      hChangeEnd[i - 1] = hChangeEnd[i] - Int32(changeCut)
    }
    hFireCount -= fireCut
    hChangeCount -= changeCut
    hTicks -= 1
  }

  func endTickRecord() {
    guard recording else { return }
    hFireEnd[hTicks] = Int32(hFireCount)
    hChangeEnd[hTicks] = Int32(hChangeCount)
    hTicks += 1
  }

  /// Undo the last tick: un-fire what it fired (newest first), restore what it changed,
  /// and step the tick counter back. `onUndo(net, transition)` is called for each undone
  /// fire that was audible — the notes a scratch plays. False when there is nothing left
  /// to undo.
  @discardableResult
  public func unadvance(_ onUndo: (CompiledNet, Int) -> Void) -> Bool {
    guard hTicks > 0 else { return false }
    let last = hTicks - 1
    let fireStart = last == 0 ? 0 : Int(hFireEnd[last - 1])
    let changeStart = last == 0 ? 0 : Int(hChangeEnd[last - 1])
    let fireEnd = Int(hFireEnd[last])
    let changeEnd = Int(hChangeEnd[last])

    var i = fireEnd - 2
    while i >= fireStart {
      let ni = Int(hFires[i])
      let t = Int(hFires[i + 1])
      let n = nets[ni]
      if n.midi[t] && muted[ni] == 0 && mutedNotes[ni * 128 + (n.note[t] & 127)] == 0 {
        onUndo(n, t)
      }
      unfire(n, t)
      i -= 2
    }
    var c = changeEnd - Self.changeSize
    while c >= changeStart {
      let a = Int(hChanges[c + 1])
      let b = Int(hChanges[c + 2])
      switch hChanges[c] {
      case 0: muted[a] = UInt8(truncatingIfNeeded: b)
      case 1: mutedGroups[a] = UInt8(truncatingIfNeeded: b)
      case 2: activeSlot[a] = b
      case 3:
        timerKind[a] = UInt8(truncatingIfNeeded: b)
        timerNet[a] = hChanges[c + 3]
        timerRemaining[a] = hChanges[c + 4]
        timerArg[a] = hChanges[c + 5]
      case 4:
        repeatRemaining = a
        repeatElapsed = b
        repeatStep = Int(hChanges[c + 3])
        repeatBurst = Int(hChanges[c + 4])
      default: break
      }
      c -= Self.changeSize
    }
    hFireCount = fireStart
    hChangeCount = changeStart
    hTicks -= 1
    tick -= 1
    firedCount = 0
    controlCount = 0
    stopRequested = false
    return true
  }

  func unfire(_ n: CompiledNet, _ t: Int) {
    for a in n.outStart[t]..<n.outStart[t + 1] {
      let p = n.outPlace[a]
      if p >= 0 { n.state[p] -= n.outW[a] }
    }
    for a in n.inStart[t]..<n.inStart[t + 1] {
      let p = n.inPlace[a]
      if !n.inInhib[a] && p >= 0 { n.state[p] += n.inW[a] }
    }
  }
}
