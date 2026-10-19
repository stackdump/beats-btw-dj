import Synchronization

// The loops' master bus ("Loops master FX"): the net decks' master chain, on the loop channel.
//
// A net deck's `WaveDeckSource` ends in beats' master inserts (`MasterChain`) driven by the master
// macros (`FxAutomation`); the loop channel had only each clip's own after effects (`LoopFX`, per
// voice) and a safety limiter. This puts the same chain and automation on the loop channel as one
// insert, after the 16 voices are summed:
//
//   voices (turntable → LoopFX → level × fade) → Σ → [vinyl brake] → MasterChain → limiter
//
// The limiter stays last: distortion, crush and the pitch shifter can lift peaks, and the channel's
// promise (never past −0.5 dBFS) holds after the chain. It runs while this bus is engaged too.
//
// Clock: the bus's transport is the loop channel's own frame count (it never pauses: the loops
// play whenever they are in). Macros are timed in bars of the loops' tempo: the main thread sends
// each fire with the loop clock's BPM (`DJEngine.loopClock`, the bar grid loops launch on) and the
// deck frame it lands on (the next launch line, at most a bar away; a linked fire, at once). The
// duration is fixed at the fire from that tempo, as beats fixes a deck macro's. Feel macros drive
// the Feel puck as on a deck, but only its filter reaches the loops: their tempo axis is dropped
// (the loops follow the decks' tempo; a loop bus that set it would fight them).
//
// `vinyl-brake` is the net deck's turntable brake (`TurntableBrake`) with the bank as its source:
// every voice slows down together (varispeed on the summed voices, before the chain, which keeps
// real time like the mixer insert it is), then each voice that sounded through it skips on by the
// frames it fell behind (`Turntable.skip`) and the loops drop back in on the beat they would be on,
// over a 5 ms fade. Panic releases (5 ms), as on a deck.
//
// At rest the bus is bit-transparent (a neutral chain is bypassed, an idle brake renders straight
// through), so loops without master FX render the bank's old bytes.
//
// Sample decks A / B run one each too (`DeckRenderer.master`): the source is the turntable and the
// clip's FX, the clock the deck's frames rendered in sample mode, macros timed on the deck's bar
// grid at its tempo (`Deck.sampleMasterFire`). The brake slows the turntable (and the clip's FX,
// the record's own) and the release skips its playhead on by the frames it fell behind
// (`Turntable.catchUp`), so the sample lands on the deck's beat grid again. A hand on the
// platter or a transport stop cancels it where it is (`cancelBrake`): the jog wins.
//
// Threading: `render` is the audio thread's (from `LoopBank.render`, `DeckRenderer.renderBlock`). `fire`, `setSlider`, `panic`
// and the mirrors are the main thread's. Real-time: everything is allocated in `init`
// (`LoopMasterRealTimeTests`). Make it off the audio thread: `MasterChain` builds wavetables.

/// Main → audio messages for the loops' master bus.
enum LoopMasterCommand: BitwiseCopyable {
  /// A master macro (`MasterMacro.rawValue`) for `bars` bars (< 0: its default, 0: permanent) at
  /// the loops' tempo `bpm`, starting at loop-channel frame `frame` (a frame already past: at once).
  case macro(id: UInt8, bars: Int16, frame: Int, bpm: Double)
  /// A hand on a master FX slider (`MasterFxKey.rawValue`, the slider's own units).
  case slider(key: UInt8, value: Int16)
  /// Cancel and restore everything (pending fires too); a running brake releases.
  case panic
  /// The FX unit (FxUnit.swift): a control, a reset, the kill. (No sends: the bus has no room or
  /// echo of its own.)
  case fxUnit(FxUnitCommand)
}

public final class LoopMasterBus: @unchecked Sendable {
  let sampleRate: Double
  private let commands = SPSCRing<LoopMasterCommand>(capacity: 128)
  private let fx: FxAutomation
  private let chain: MasterChain
  /// The FX unit's hands on the chain (FxUnit.swift).
  private let unit: FxUnitLayer
  private let brake: TurntableBrake

  /// Frames the bus has run (the loop channel's own clock).
  private var transportFrames: Int64 = 0
  private var blockTransport = 0.0
  private var blockFrames = 0

  // Fires waiting for their frame (audio thread), in arrival order.
  static let pendingCapacity = 16
  private var pendingID: [UInt8]
  private var pendingBars: [Int16]
  private var pendingFrame: [Int]
  private var pendingBPM: [Double]
  private var pendingCount = 0

  // This block's slider dispatches, in time order (as `WaveDeckSource`).
  private static let opCapacity = 256
  private let opIndex: UnsafeMutablePointer<Int>
  private let opTime: UnsafeMutablePointer<Double>
  private let opKey: UnsafeMutablePointer<UInt8>
  private let opValue: UnsafeMutablePointer<Double>
  private let opLive: UnsafeMutablePointer<Bool>
  private var opCount = 0

  // Audio → main.
  private let maskAtomic = Atomic<UInt32>(0)
  private let hpCornerBits = Atomic<UInt64>(20.0.bitPattern)
  private let lpCornerBits = Atomic<UInt64>(20000.0.bitPattern)
  private let idleAtomic = Atomic<Bool>(true)

  /// Macro commands taken from the ring (audio thread; published as `seenAtomic`).
  private var seen = 0

  /// Did the last block change the audio (the chain was not at rest, or the brake ran)? Audio
  /// thread: the bank runs its limiter while it is.
  private(set) var engaged = false

  /// The first frame of the last block the bus changed (`engaged`; `frames` when it didn't): a
  /// fire landing mid-block leaves the frames before it as they were, so a sample deck's limiter
  /// starts there, not at the block's start. Audio thread.
  private(set) var engagedFrom = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    fx = FxAutomation()
    chain = MasterChain(sampleRate: sampleRate)
    unit = FxUnitLayer(sampleRate: sampleRate)
    brake = TurntableBrake(sampleRate: sampleRate)
    let p = Self.pendingCapacity
    pendingID = [UInt8](repeating: 0, count: p)
    pendingBars = [Int16](repeating: 0, count: p)
    pendingFrame = [Int](repeating: 0, count: p)
    pendingBPM = [Double](repeating: 120, count: p)
    opIndex = .allocate(capacity: Self.opCapacity)
    opTime = .allocate(capacity: Self.opCapacity)
    opKey = .allocate(capacity: Self.opCapacity)
    opValue = .allocate(capacity: Self.opCapacity)
    opLive = .allocate(capacity: Self.opCapacity)
  }

  deinit {
    opIndex.deallocate()
    opTime.deallocate()
    opKey.deallocate()
    opValue.deallocate()
    opLive.deallocate()
  }

  // MARK: main thread

  /// Fire `macro` for `bars` bars (nil: its default; 0: permanent) at the loops' tempo `bpm`,
  /// landing at loop-channel frame `frame` (0 or a frame already rendered: the next block).
  public func fire(_ macro: MasterMacro, bars: Int? = nil, frame: Int = 0, bpm: Double) {
    commands.push(
      .macro(
        id: macro.rawValue, bars: Int16(clamping: bars ?? -1), frame: frame,
        bpm: bpm.isFinite && bpm > 0 ? bpm : 120))
    sent += 1
    queuedMask |= macro.bit
    queuedAt = sent
  }

  /// The last value each master FX slider was set to by hand (`setSlider`).
  public private(set) var sliderSet: [MasterFxKey: Int] = [:]

  /// A hand on a master FX slider (a fader aimed at the loops).
  public func setSlider(_ key: MasterFxKey, _ value: Int) {
    sliderSet[key] = value
    commands.push(.slider(key: UInt8(key.rawValue), value: Int16(clamping: value)))
  }

  /// The FX unit (FxUnit.swift; the deck sends it, `Deck.setFx`).
  func sendFxUnit(_ c: FxUnitCommand) { commands.push(.fxUnit(c)) }

  /// Release everything: animations cancelled and restored, waiting fires dropped, a brake out.
  public func panic() {
    commands.push(.panic)
    queuedMask = 0
  }

  // Fires sent but maybe not yet seen by the audio thread (they count as running for the UI
  // until it has applied the last of them).
  private var queuedMask: UInt32 = 0
  private var sent = 0
  private var queuedAt = 0
  private let seenAtomic = Atomic<Int>(0)

  /// The master macros running (or waiting for their bar) as of the last block. Main thread.
  public var activeMasterMacros: [MasterMacro] {
    let m = runningMask
    return MasterMacro.allCases.filter { m & $0.bit != 0 }
  }

  public func isActive(_ macro: MasterMacro) -> Bool { runningMask & macro.bit != 0 }

  private var runningMask: UInt32 {
    // once the audio thread has taken the fires (pending or running), its mask speaks for them
    if queuedMask != 0, seenAtomic.load(ordering: .acquiring) >= queuedAt { queuedMask = 0 }
    return maskAtomic.load(ordering: .relaxed) | queuedMask
  }

  /// The chain's HP and LP corners (Hz) at the last block, and whether it was at rest.
  public var filterCorners: (hp: Double, lp: Double, bypassed: Bool) {
    (
      Double(bitPattern: hpCornerBits.load(ordering: .relaxed)),
      Double(bitPattern: lpCornerBits.load(ordering: .relaxed)),
      idleAtomic.load(ordering: .relaxed)
    )
  }

  // MARK: audio thread

  /// Render `frames` of `source` (the bank's summed voices) through the brake and the chain into
  /// `left` (`right`), the block starting at loop-channel frame `s`. Real-time safe.
  func render<S: BrakeSource>(
    _ source: S, frames n: Int, left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>?, startFrame s: Int
  ) {
    blockTransport = Double(transportFrames) / sampleRate
    blockFrames = n
    opCount = 0
    fx.setNow(blockTransport)
    let braking = brake.isOn
    let idleBefore = chain.isIdle()
    while let c = commands.pop() { apply(c) }
    unit.beginBlock(frames: n, startFrame: s, automation: fx) { key, value in
      queue(key, value, at: 0, live: true)
    }
    // the fires due in this block, in frame order; the source rendered up to each brake
    var done = 0
    var firstChange = n
    while let i = nextDue(before: s + n) {
      let k = min(n, max(0, pendingFrame[i] - s))
      let t = blockTransport + Double(k) / sampleRate
      fx.advance(until: t) { handle($0) }
      fx.setNow(t)
      let id = pendingID[i]
      let bars = Int(pendingBars[i])
      let bpm = pendingBPM[i]
      removePending(i)
      guard let m = MasterMacro(rawValue: id) else { continue }
      if m == .vinylBrake {
        if k > done {
          brake.render(
            source, left + done, right.map { $0 + done }, frames: k - done,
            startFrame: s + done)
          done = k
        }
        let b = bars <= 0 ? MasterMacro.vinylBrake.defaultDuration : bars
        firstChange = min(firstChange, k)
        brake.start(durationFrames: Int((Double(b * 4) * 60 / bpm * sampleRate).rounded()))
      } else {
        fx.tempo = bpm
        fx.genreBpm = bpm
        fx.fire(m, duration: bars < 0 ? nil : bars) { handle($0) }
      }
    }
    fx.advance(until: blockTransport + Double(n) / sampleRate) { handle($0) }
    transportFrames += Int64(n)
    if n > done {
      brake.render(
        source, left + done, right.map { $0 + done }, frames: n - done,
        startFrame: s + done)
    }
    var from = 0
    for i in 0..<opCount {
      let k = opIndex[i]
      if k > from {
        chain.process(left, right, from: from, to: k)
        from = k
      }
      chain.apply(
        MasterFxKey(rawValue: Int(opKey[i]))!, opValue[i], at: opTime[i],
        live: opLive[i] ? Double(n) / sampleRate : nil)
    }
    chain.process(left, right, from: from, to: n)
    chain.finish(frames: n)
    let idle = chain.isIdle()
    engaged = braking || brake.isOn || !idleBefore || !idle || opCount > 0
    for i in 0..<opCount { firstChange = min(firstChange, opIndex[i]) }
    engagedFrom = !engaged ? n : (braking || !idleBefore || firstChange >= n ? 0 : firstChange)
    var mask = fx.activeMask | (brake.isOn ? MasterMacro.vinylBrake.bit : 0)
    for i in 0..<pendingCount { mask |= 1 << UInt32(pendingID[i]) }
    maskAtomic.store(mask, ordering: .relaxed)
    seenAtomic.store(seen, ordering: .releasing)
    let corners = chain.filterCorners()
    hpCornerBits.store(corners.hp.bitPattern, ordering: .relaxed)
    lpCornerBits.store(corners.lp.bitPattern, ordering: .relaxed)
    idleAtomic.store(idle && !brake.isOn, ordering: .relaxed)
  }

  /// Audio thread, before `render`: drop a running brake where it is, without the catch-up (a
  /// sample deck's jog or transport stop). Waiting brake fires stay waiting.
  func cancelBrake() { brake.cancel() }

  /// Audio thread: is the brake running (spinning down or stopped, not yet released)?
  var braking: Bool { brake.isOn }

  private func apply(_ c: LoopMasterCommand) {
    switch c {
    case .macro(let id, let bars, let frame, let bpm):
      seen += 1
      guard pendingCount < Self.pendingCapacity else { return }
      pendingID[pendingCount] = id
      pendingBars[pendingCount] = bars
      pendingFrame[pendingCount] = frame
      pendingBPM[pendingCount] = bpm
      pendingCount += 1
    case .slider(let key, let value):
      if let k = MasterFxKey(rawValue: Int(key)) { fx.setSlider(k, Double(value)) }
    case .panic:
      pendingCount = 0
      brake.panic()
      fx.panic { handle($0) }
    case .fxUnit(let u): unit.take(u)
    }
  }

  /// The earliest pending fire due before deck frame `end` (ties: the first sent).
  private func nextDue(before end: Int) -> Int? {
    var best: Int?
    for i in 0..<pendingCount where pendingFrame[i] < end {
      if best == nil || pendingFrame[i] < pendingFrame[best!] { best = i }
    }
    return best
  }

  private func removePending(_ i: Int) {
    pendingCount -= 1
    for j in i..<pendingCount {
      pendingID[j] = pendingID[j + 1]
      pendingBars[j] = pendingBars[j + 1]
      pendingFrame[j] = pendingFrame[j + 1]
      pendingBPM[j] = pendingBPM[j + 1]
    }
  }

  /// The automation's events during a block: slider dispatches queued for the chain at their
  /// sample; tempo writes (the Feel puck's tempo axis) dropped — the loops keep the decks' tempo.
  private func handle(_ e: FxAutomationEvent) {
    guard case .fx(let t, let key, let value) = e else { return }
    // the macro's slider, on the FX unit's setting (FxUnit.swift: at neutral, the slider)
    queue(key, unit.automated(key, value, automation: fx), at: t - blockTransport, live: false)
  }

  /// A chain op for this block, `offset` seconds into it.
  private func queue(_ key: MasterFxKey, _ value: Double, at offset: Double, live: Bool) {
    guard opCount < Self.opCapacity else { return }
    let offset = max(0, offset)
    opIndex[opCount] = min(blockFrames, max(0, Int((offset * sampleRate).rounded(.up))))
    opTime[opCount] = chain.time(at: 0) + offset
    opKey[opCount] = UInt8(key.rawValue)
    opValue[opCount] = value
    opLive[opCount] = live
    opCount += 1
  }
}
