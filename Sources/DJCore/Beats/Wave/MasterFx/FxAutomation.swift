import Foundation

// beats' macro animation for the master chain, ported as a state machine that runs on the deck's
// transport clock (lib/macros/effects.js `fxSweep`, `fxHold`, `runCompound`,
// `clearLocalMacroState`; lib/macros/runtime.js `executeMacro`, `feelSnap`, `feelSweep`,
// `feelGenreReset`, `restoreFeelState`, `cancelFeelAnim`; lib/feel/axes.js `applyFeelGrid`;
// lib/ui/controllers.js `applyFeel`, `setFxByKey`).
//
// Timing is the one beats uses when it renders offline (`sched.js audioAnimLoop` with an
// OfflineAudioContext): every animation dispatches its slider on a fixed audio-clock grid from
// the moment it was fired — 120 ms for the FX sweeps and holds, 200 ms for the feel sweeps and
// the reset — plus once at its end. Live, beats animates the sliders on requestAnimationFrame and
// throttles the dispatches to the same 120 ms, so the grid is the deterministic version of what
// the browser does. All of it is in transport seconds: it stops while the deck is paused, as
// Tone.Transport does. Events at the same time run in the order they were scheduled.
//
// A dispatch goes through the slider (`slider.value = Math.round(v)`, clamped to its range) and
// then to the engine. beats coalesces the engine calls (build.js: one flush 33 ms later, latest
// value per slider); here every dispatch of one instant is flushed together at that instant, in
// the order the sliders were first touched in it. Zero latency instead of up to 33 ms of wall time.
//
// Only the sliders that reach wave audio are kept (see MasterMacro.swift); beats' reverb / delay
// / master-volume sliders never feed back into these, so dropping them changes nothing here.
// Feel tempo writes go out as `.tempo` events (the owner applies them with `WaveRunner.setTempo`,
// as the tempo macros do).
//
// Real-time: everything is preallocated in `init`; `fire`, `setSlider`, `panic`, `advance` and
// the callbacks they make allocate nothing (`MasterChainRealTimeTests`). Checked against beats'
// real code event for event by `MasterFxParityTests` (macro-fx.json).

/// What the automation tells its owner.
enum FxAutomationEvent {
  /// `applyFx(key, value)` at transport time `time`.
  case fx(time: Double, key: MasterFxKey, value: Int)
  /// `setTempo(bpm)` (already clamped to 20...300) at transport time `time`.
  case tempo(time: Double, bpm: Double)
}

final class FxAutomation {
  /// audioAnimLoop's dispatch grids (ms).
  static let fxStepMs = 120.0
  static let feelStepMs = 200.0
  /// The Feel snapshot's FX sliders (runtime.js `FEEL_FX_KEYS`) that reach wave audio.
  static let feelKeys: [MasterFxKey] = [.distortion, .crushBits, .lpFreq]
  static let keyCount = MasterFxKey.allCases.count
  static let maxOps = 3
  static let compoundCapacity = 16

  // MARK: state that beats keeps on the element

  /// The sliders (`parseInt(slider.value)`).
  private(set) var sliders: [Int]
  /// `el._tempo`. The owner keeps it in step with the runner before each block.
  var tempo: Double
  /// The current genre's BPM (`el._genreData[genre].bpm`): Feel's tempo axis and Reset's target.
  var genreBpm: Double
  /// `el._feelState.puck`.
  private(set) var puckX = 0.5
  private(set) var puckY = 0.5
  /// Transport time of the instant being run (the time of the last `advance`).
  private(set) var now = 0.0
  /// `schedAudio` order: events at equal times run in this order.
  private var seq = 0

  // the pending flush (build.js `_fxPending`)
  private var pendingValue: [Int]
  private var pendingSet: [Bool]
  private var pendingOrder: [Int]
  private var pendingCount = 0

  // MARK: animations (one token per slider: `el._fxAnim[fxKey]`)

  private var animActive: [Bool]
  private var animHold: [Bool]
  private var animMacro: [UInt8]
  private var animStart: [Double]
  private var animTo: [Double]
  private var animT0: [Double]
  private var animDur: [Double]
  private var animRampDown: [Double]
  private var animSustain: [Double]
  private var animTail: [Double]
  private var animGrid: [Int]  // dispatches before the final one
  private var animNext: [Int]  // index of the next event (animGrid = the final one)
  private var animSeq: [Int]  // seq of event 0

  // MARK: the Feel animation (`el._feelAnim`): one at a time

  private enum FeelKind { case none, snap, sweep, reset }
  private var feelKind = FeelKind.none
  private var feelMacro: UInt8 = 0
  private var feelT0 = 0.0
  private var feelDur = 0.0
  private var feelGrid = 0
  private var feelNext = 0
  private var feelSeq = 0
  /// The pending restore (snap: at the end; sweep: 60 ms after it), or none.
  private var feelRestoreAt = Double.infinity
  private var feelRestoreSeq = 0
  // sweep
  private var feelFromX = 0.0
  private var feelFromY = 0.0
  private var feelToX = 0.0
  private var feelToY = 0.0
  // snapshot (snap / sweep): `snapshotFeelState`
  private var snapPuckX = 0.5
  private var snapPuckY = 0.5
  private var snapTempo = 120.0
  private var snapFx: [Int]
  // reset: `startFx`, `startBpm`, `targetBpm`
  private var resetFx: [Int]
  private var resetStartBpm = 120.0
  private var resetTargetBpm = 120.0
  private var resetBpmChanges = false

  // MARK: compound sub-fires (`el._compoundTimers`)

  private var compoundAt: [Double]
  private var compoundSeq: [Int]
  private var compoundSubMs: [Double]
  private var compoundMacro: [UInt8]
  private var compoundCount = 0

  // MARK: the catalog, flattened (no array is built on the audio thread)

  private var opCount: [Int]
  private var opKey: [Int]
  private var opTo: [Double]
  private var holdTail: [Double]
  private var kindCode: [UInt8]  // 0 sweep, 1 hold, 2 compound, 3 snap, 4 feel sweep, 5 reset
  private var targetX: [Double]
  private var targetY: [Double]
  private var defaultBars: [Int]

  init(tempo: Double = 120, genreBpm: Double = 120) {
    self.tempo = tempo
    self.genreBpm = genreBpm
    let n = Self.keyCount
    sliders = MasterFxKey.allCases.map(\.defaultValue)
    pendingValue = [Int](repeating: 0, count: n)
    pendingSet = [Bool](repeating: false, count: n)
    pendingOrder = [Int](repeating: 0, count: n)
    animActive = [Bool](repeating: false, count: n)
    animHold = [Bool](repeating: false, count: n)
    animMacro = [UInt8](repeating: 0, count: n)
    animStart = [Double](repeating: 0, count: n)
    animTo = [Double](repeating: 0, count: n)
    animT0 = [Double](repeating: 0, count: n)
    animDur = [Double](repeating: 0, count: n)
    animRampDown = [Double](repeating: 0, count: n)
    animSustain = [Double](repeating: 0, count: n)
    animTail = [Double](repeating: 0, count: n)
    animGrid = [Int](repeating: 0, count: n)
    animNext = [Int](repeating: 0, count: n)
    animSeq = [Int](repeating: 0, count: n)
    snapFx = [Int](repeating: 0, count: n)
    resetFx = [Int](repeating: 0, count: n)
    let c = Self.compoundCapacity
    compoundAt = [Double](repeating: 0, count: c)
    compoundSeq = [Int](repeating: 0, count: c)
    compoundSubMs = [Double](repeating: 0, count: c)
    compoundMacro = [UInt8](repeating: 0, count: c)
    let m = MasterMacro.allCases.count
    opCount = [Int](repeating: 0, count: m)
    opKey = [Int](repeating: 0, count: m * Self.maxOps)
    opTo = [Double](repeating: 0, count: m * Self.maxOps)
    holdTail = [Double](repeating: 0.6, count: m)
    kindCode = [UInt8](repeating: 0, count: m)
    targetX = [Double](repeating: 0, count: m)
    targetY = [Double](repeating: 0, count: m)
    defaultBars = [Int](repeating: 1, count: m)
    for macro in MasterMacro.allCases {
      let i = Int(macro.rawValue)
      defaultBars[i] = macro.defaultDuration
      func put(_ ops: [MasterMacro.Op]) {
        precondition(ops.count <= Self.maxOps)
        opCount[i] = ops.count
        for (j, op) in ops.enumerated() {
          opKey[i * Self.maxOps + j] = op.key.rawValue
          opTo[i * Self.maxOps + j] = op.to
        }
      }
      switch macro.kind {
      case .sweep(let ops):
        kindCode[i] = 0
        put(ops)
      case .hold(let ops, let tail):
        kindCode[i] = 1
        put(ops)
        holdTail[i] = tail
      case .compound: kindCode[i] = 2
      case .feelSnap(let x, let y):
        kindCode[i] = 3
        targetX[i] = x
        targetY[i] = y
      case .feelSweep(let x, let y):
        kindCode[i] = 4
        targetX[i] = x
        targetY[i] = y
      case .genreReset: kindCode[i] = 5
      }
    }
  }

  // MARK: queries

  /// Bits (`MasterMacro.bit`) of the macros with an animation, a restore or a sub-fire pending.
  var activeMask: UInt32 {
    var m: UInt32 = 0
    for k in 0..<Self.keyCount where animActive[k] { m |= 1 << UInt32(animMacro[k]) }
    if feelKind != .none { m |= 1 << UInt32(feelMacro) }
    for i in 0..<compoundCount { m |= 1 << UInt32(compoundMacro[i]) }
    return m
  }

  /// Anything scheduled (an animation, a feel restore, a sub-fire)?
  var isBusy: Bool { activeMask != 0 }

  func slider(_ k: MasterFxKey) -> Int { sliders[k.rawValue] }

  /// Is slider `k` (`MasterFxKey.rawValue`) under a sweep or hold right now?
  func animatingKey(_ k: Int) -> Bool { animActive[k] }

  // MARK: the user's steps (at `now`; flushed by the next `advance`)

  /// Move the clock to `t` without running anything (the start of a block). Events before `t`
  /// must have been run by an `advance` already.
  func setNow(_ t: Double) { now = Swift.max(now, t) }

  /// Where the Feel puck is (beats keeps it in localStorage; it starts at the centre).
  func setPuck(_ x: Double, _ y: Double) {
    puckX = x
    puckY = y
  }

  /// A hand on a slider (`setFxByKey`).
  func setSlider(_ key: MasterFxKey, _ value: Double) { setFx(key.rawValue, value) }

  /// `executeMacro(el, id, { duration })` at `now`; `duration` in bars, 0 = permanent, nil = the
  /// macro's default. Returns the macro's run time in ticks (`markMacroRunning`).
  @discardableResult
  func fire(
    _ macro: MasterMacro, duration: Int?, _ emit: (FxAutomationEvent) -> Void
  ) -> Int {
    let i = Int(macro.rawValue)
    let d = duration ?? defaultBars[i]
    let permanent = d == 0
    let effective = permanent ? defaultBars[i] : d
    let durationTicks = effective * 16
    let msPerTick = msPerBar() / 16
    let durationMs = Double(durationTicks) * msPerTick
    switch kindCode[i] {
    case 0, 1:
      for j in 0..<opCount[i] {
        let k = opKey[i * Self.maxOps + j]
        let to = opTo[i * Self.maxOps + j]
        if permanent {
          setFx(k, to)
        } else if kindCode[i] == 0 {
          fxSweep(k, to, durationMs, macro: macro.rawValue)
        } else {
          fxHold(k, to, durationMs, tailFrac: holdTail[i], macro: macro.rawValue)
        }
      }
    case 2:
      // vinyl-brake: steps [{tape-stop, 0 ms}, {octave-down, 60 ms}]. runCompound fires only
      // `mute` and `fx-sweep` / `fx-hold` sub-macros: the tape-stop step (a tempo-sweep) does
      // nothing in beats, so here neither. Octave-down runs for ITS default duration (1 bar, as
      // `step.durationTicks || sub.defaultDuration * 16`) and with fxHold's default tail (0.6:
      // runCompound passes no tailFrac). The parity path only: on a project prepared with
      // `WaveOptions.turntableBrake` (the app) the deck brakes instead (TurntableBrake.swift).
      seq += 1  // the tape-stop step's timer
      addCompound(at: now + 60.0 / 1000, subMs: Double(1 * 16) * msPerTick, macro: macro.rawValue)
    case 3:
      if permanent {
        cancelFeelAnim(emit)
        applyFeel(clamp01(targetX[i]), clamp01(targetY[i]), emit)
      } else {
        feelSnap(i, durationMs, emit)
      }
    case 4: feelSweep(i, durationMs, emit)
    default: feelGenreReset(macro.rawValue, durationMs, emit)
    }
    // runtime.js: permanent macros budget the pulse (`min(3 bars, 4 s)`), others the duration.
    if permanent {
      let pulseMs = Swift.min(3 * msPerBar(), 4000)
      return Swift.max(1, Int((pulseMs / msPerTick).rounded(.up)))
    }
    return durationTicks
  }

  /// `clearLocalMacroState` (panic, transport stop): drop the sub-fires, cancel the Feel
  /// animation and run its restore, cancel every slider animation and put its slider back where
  /// it started. (The tempo macros' restore is the runner's.)
  func panic(_ emit: (FxAutomationEvent) -> Void) {
    compoundCount = 0
    cancelFeelAnim(emit)
    for k in 0..<Self.keyCount where animActive[k] {
      animActive[k] = false
      setFx(k, animStart[k])
    }
  }

  // MARK: the clock

  /// Run every event before `end` (transport seconds), one instant at a time: the events of an
  /// instant in schedule order, then the flush. Whatever the steps since the last call
  /// dispatched is flushed first, at `now`, with the events due at `now`.
  func advance(until end: Double, _ emit: (FxAutomationEvent) -> Void) {
    if pendingCount > 0 {
      runInstant(now, emit)
    }
    while true {
      let t = nextTime()
      guard t < end else { break }
      now = t
      runInstant(t, emit)
    }
  }

  /// Flush the steps' dispatches at `now` without running any event (a paused transport).
  func flush(_ emit: (FxAutomationEvent) -> Void) {
    flushPending(emit)
  }

  private func runInstant(_ t: Double, _ emit: (FxAutomationEvent) -> Void) {
    while true {
      // the earliest (time, seq) that is due at exactly t
      var best = -1
      var bestSeq = Int.max
      var source = 0  // 1 anim, 2 feel grid, 3 feel restore, 4 compound
      for k in 0..<Self.keyCount where animActive[k] {
        if animTime(k) == t, animSeq[k] + animNext[k] < bestSeq {
          bestSeq = animSeq[k] + animNext[k]
          best = k
          source = 1
        }
      }
      if feelKind == .sweep || feelKind == .reset, feelNext <= feelGrid, feelTime() == t,
        feelSeq + feelNext < bestSeq
      {
        bestSeq = feelSeq + feelNext
        source = 2
      }
      if feelRestoreAt == t, feelRestoreSeq < bestSeq {
        bestSeq = feelRestoreSeq
        source = 3
      }
      for i in 0..<compoundCount where compoundAt[i] == t && compoundSeq[i] < bestSeq {
        bestSeq = compoundSeq[i]
        best = i
        source = 4
      }
      switch source {
      case 1: runAnim(best)
      case 2: runFeelStep(emit)
      case 3: runFeelRestore(emit)
      case 4: runCompound(best)
      default:
        flushPending(emit)
        return
      }
    }
  }

  private func nextTime() -> Double {
    var t = Double.infinity
    for k in 0..<Self.keyCount where animActive[k] { t = Swift.min(t, animTime(k)) }
    if feelKind == .sweep || feelKind == .reset, feelNext <= feelGrid {
      t = Swift.min(t, feelTime())
    }
    t = Swift.min(t, feelRestoreAt)
    for i in 0..<compoundCount { t = Swift.min(t, compoundAt[i]) }
    return t
  }

  private func flushPending(_ emit: (FxAutomationEvent) -> Void) {
    for j in 0..<pendingCount {
      let k = pendingOrder[j]
      pendingSet[k] = false
      emit(.fx(time: now, key: MasterFxKey(rawValue: k)!, value: pendingValue[k]))
    }
    pendingCount = 0
  }

  // MARK: sliders

  /// `setFxValue(slider, v)`: the slider takes `Math.round(v)` (clamped), and its `input` event
  /// queues the slider's value for the flush.
  private func setFx(_ k: Int, _ v: Double) {
    let key = MasterFxKey(rawValue: k)!
    let s = key.sanitize(v)
    sliders[k] = s
    if !pendingSet[k] {
      pendingSet[k] = true
      pendingOrder[pendingCount] = k
      pendingCount += 1
    }
    pendingValue[k] = s
  }

  /// `setTempo`: `el._tempo = clamp(20, 300, bpm)` and tell the engine.
  private func setTempo(_ bpm: Double, _ emit: (FxAutomationEvent) -> Void) {
    guard bpm.isFinite else { return }
    tempo = Swift.max(20, Swift.min(300, bpm))
    emit(.tempo(time: now, bpm: tempo))
  }

  /// petri-note.js `_msPerBar`.
  private func msPerBar() -> Double {
    (60000 / ((tempo != 0 ? tempo : 120) * 4)) * 16
  }

  // MARK: fxSweep / fxHold (effects.js)

  /// Grid points `0, 120, ...` below `durationMs` (audioAnimLoop's loop).
  private static func gridCount(_ durationMs: Double, _ step: Double) -> Int {
    var n = 0
    var e = 0.0
    while e < durationMs {
      n += 1
      e += step
    }
    return n
  }

  private func startAnim(_ k: Int, hold: Bool, to: Double, durationMs: Double, macro: UInt8) {
    // a re-fire keeps the first fire's start, so a stacked macro never strands its slider
    let start = animActive[k] ? animStart[k] : Double(sliders[k])
    animActive[k] = true
    animHold[k] = hold
    animMacro[k] = macro
    animStart[k] = start
    animTo[k] = to
    animT0[k] = now
    animDur[k] = durationMs
    animNext[k] = 0
    animGrid[k] = Self.gridCount(durationMs, Self.fxStepMs)
    animSeq[k] = seq
    seq += animGrid[k] + 1
  }

  private func fxSweep(_ k: Int, _ to: Double, _ durationMs: Double, macro: UInt8) {
    startAnim(k, hold: false, to: to, durationMs: durationMs, macro: macro)
    animRampDown[k] = durationMs * 0.8
  }

  private func fxHold(
    _ k: Int, _ to: Double, _ durationMs: Double, tailFrac: Double, macro: UInt8
  ) {
    startAnim(k, hold: true, to: to, durationMs: durationMs, macro: macro)
    let tail = Swift.max(50, durationMs * tailFrac)
    animTail[k] = tail
    animSustain[k] = Swift.max(0, durationMs - tail)
    setFx(k, to)
  }

  /// Time of slider `k`'s next dispatch: `now + elapsed / 1000` from its fire.
  private func animTime(_ k: Int) -> Double {
    let i = animNext[k]
    let elapsed = i < animGrid[k] ? Double(i) * Self.fxStepMs : animDur[k]
    return animT0[k] + elapsed / 1000
  }

  /// One `applyAt(elapsed)` of slider `k`'s animation.
  private func runAnim(_ k: Int) {
    let i = animNext[k]
    let elapsed = i < animGrid[k] ? Double(i) * Self.fxStepMs : animDur[k]
    animNext[k] = i + 1
    let start = animStart[k]
    let to = animTo[k]
    let dur = animDur[k]
    if animHold[k] {
      if elapsed < animSustain[k] {
        if i >= animGrid[k] { animActive[k] = false }
        return
      }
      if elapsed >= dur {
        setFx(k, start)
        animActive[k] = false
        return
      }
      let t = (elapsed - animSustain[k]) / animTail[k]
      setFx(k, to + (start - to) * t)
    } else {
      let done = elapsed >= dur
      let rampDown = animRampDown[k]
      let v: Double
      if elapsed < rampDown {
        v = start + (to - start) * (elapsed / rampDown)
      } else if elapsed < dur {
        v = to + (start - to) * ((elapsed - rampDown) / (dur - rampDown))
      } else {
        v = start
      }
      setFx(k, v)
      if done { animActive[k] = false }
    }
    if i >= animGrid[k] { animActive[k] = false }
  }

  // MARK: compound (vinyl-brake)

  private func addCompound(at t: Double, subMs: Double, macro: UInt8) {
    let s = seq
    seq += 1
    guard compoundCount < Self.compoundCapacity else { return }
    compoundAt[compoundCount] = t
    compoundSeq[compoundCount] = s
    compoundSubMs[compoundCount] = subMs
    compoundMacro[compoundCount] = macro
    compoundCount += 1
  }

  private func runCompound(_ i: Int) {
    let subMs = compoundSubMs[i]
    let macro = compoundMacro[i]
    compoundCount -= 1
    for j in i..<compoundCount {
      compoundAt[j] = compoundAt[j + 1]
      compoundSeq[j] = compoundSeq[j + 1]
      compoundSubMs[j] = compoundSubMs[j + 1]
      compoundMacro[j] = compoundMacro[j + 1]
    }
    fxHold(MasterFxKey.masterPitch.rawValue, -12, subMs, tailFrac: 0.6, macro: macro)
  }

  // MARK: Feel (runtime.js, feel/axes.js)

  private func clamp01(_ v: Double) -> Double { Swift.max(0, Swift.min(1, v)) }

  /// `applyFeel(el, puck)` → `applyFeelGrid`: tempo = round(genre BPM × the blended multiplier)
  /// clamped to 40...300; LP slider = round(the blended LP).
  private func applyFeel(_ x0: Double, _ y0: Double, _ emit: (FxAutomationEvent) -> Void) {
    let x = Swift.max(0, Swift.min(1, x0.isFinite ? x0 : 0.5))
    let y = Swift.max(0, Swift.min(1, y0.isFinite ? y0 : 0.5))
    puckX = x
    puckY = y
    let w0 = (1 - x) * (1 - y)
    let w1 = x * (1 - y)
    let w2 = (1 - x) * y
    let w3 = x * y
    let bpmMult = 0.6 * w0 + 0.6 * w1 + 1.4 * w2 + 1.4 * w3
    let lp = 50 * w0 + 100 * w1 + 50 * w2 + 100 * w3
    let base = genreBpm != 0 ? genreBpm : (tempo != 0 ? tempo : 120)
    let bpm = jsRound(base * bpmMult)
    setTempo(Swift.max(40, Swift.min(300, bpm)), emit)
    setFx(MasterFxKey.lpFreq.rawValue, jsRound(lp))
  }

  private func snapshot() {
    snapPuckX = puckX
    snapPuckY = puckY
    snapTempo = tempo != 0 ? tempo : 120
    for k in Self.feelKeys { snapFx[k.rawValue] = sliders[k.rawValue] }
  }

  /// `restoreFeelState` (its reverb flush is dropped: no reverb here).
  private func restoreSnapshot(_ emit: (FxAutomationEvent) -> Void) {
    applyFeel(snapPuckX, snapPuckY, emit)
    setTempo(snapTempo, emit)
    for k in Self.feelKeys { setFx(k.rawValue, Double(snapFx[k.rawValue])) }
  }

  /// `cancelFeelAnim`: stop the running Feel animation and land on what it would have landed on.
  private func cancelFeelAnim(_ emit: (FxAutomationEvent) -> Void) {
    let kind = feelKind
    guard kind != .none else { return }
    feelKind = .none
    feelRestoreAt = .infinity
    if kind == .reset { finishReset(emit) } else { restoreSnapshot(emit) }
  }

  private func feelSnap(_ i: Int, _ durationMs: Double, _ emit: (FxAutomationEvent) -> Void) {
    cancelFeelAnim(emit)
    snapshot()
    feelKind = .snap
    feelMacro = UInt8(i)
    applyFeel(clamp01(targetX[i]), clamp01(targetY[i]), emit)
    feelRestoreAt = now + durationMs / 1000
    feelRestoreSeq = seq
    seq += 1
  }

  private func feelSweep(_ i: Int, _ durationMs: Double, _ emit: (FxAutomationEvent) -> Void) {
    cancelFeelAnim(emit)
    snapshot()
    feelFromX = snapPuckX
    feelFromY = snapPuckY
    feelToX = clamp01(targetX[i])
    feelToY = clamp01(targetY[i])
    feelKind = .sweep
    feelMacro = UInt8(i)
    startFeelGrid(durationMs)
  }

  private func startFeelGrid(_ durationMs: Double) {
    feelT0 = now
    feelDur = durationMs
    feelNext = 0
    feelGrid = Self.gridCount(durationMs, Self.feelStepMs)
    feelSeq = seq
    seq += feelGrid + 1
  }

  private func feelTime() -> Double {
    let elapsed = feelNext < feelGrid ? Double(feelNext) * Self.feelStepMs : feelDur
    return feelT0 + elapsed / 1000
  }

  private func runFeelStep(_ emit: (FxAutomationEvent) -> Void) {
    let i = feelNext
    let elapsed = i < feelGrid ? Double(i) * Self.feelStepMs : feelDur
    feelNext = i + 1
    let t = elapsed / feelDur
    if feelKind == .sweep {
      if t >= 1 {
        applyFeel(feelToX, feelToY, emit)
        feelRestoreAt = now + 60.0 / 1000
        feelRestoreSeq = seq
        seq += 1
        return
      }
      let e = 0.5 - 0.5 * cos(t * Double.pi)
      applyFeel(feelFromX + (feelToX - feelFromX) * e, feelFromY + (feelToY - feelFromY) * e, emit)
    } else {
      if t >= 1 {
        feelKind = .none
        finishReset(emit)
        return
      }
      let e = sin(t * Double.pi / 2)
      lerpReset(e)
      if resetBpmChanges {
        setTempo(jsRound(resetStartBpm + (resetTargetBpm - resetStartBpm) * e), emit)
      }
    }
  }

  private func runFeelRestore(_ emit: (FxAutomationEvent) -> Void) {
    feelRestoreAt = .infinity
    feelKind = .none
    restoreSnapshot(emit)
  }

  private func lerpReset(_ e: Double) {
    for key in MasterFxKey.allCases {
      let k = key.rawValue
      let start = resetFx[k]
      let def = key.defaultValue
      if start == def { continue }
      setFx(k, jsRound(Double(start) + Double(def - start) * e))
    }
  }

  private func finishReset(_ emit: (FxAutomationEvent) -> Void) {
    lerpReset(1)
    if resetBpmChanges { setTempo(jsRound(resetTargetBpm), emit) }
  }

  private func feelGenreReset(
    _ macro: UInt8, _ durationMs: Double, _ emit: (FxAutomationEvent) -> Void
  ) {
    cancelFeelAnim(emit)
    for k in 0..<Self.keyCount { resetFx[k] = sliders[k] }
    resetStartBpm = tempo != 0 ? tempo : 120
    resetTargetBpm = genreBpm != 0 ? genreBpm : 120
    resetBpmChanges = abs(resetStartBpm - resetTargetBpm) > 1
    feelKind = .reset
    feelMacro = macro
    startFeelGrid(durationMs)
  }
}
