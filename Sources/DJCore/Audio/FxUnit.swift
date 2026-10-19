import Foundation

// The FX unit: hands-on, continuous control of a target's master chain (MasterFx/) and, on a net
// deck, of its room and echo sends (Space.swift, Echo.swift). A target is deck "A", deck "B" or
// the loop channel "L"; each has its own settings (`Deck.fxUnit`).
//
//   chain (every target)       filter (bipolar: left LP, right HP, centre off), HP, LP, phaser
//                              mix / depth / rate, crush, drive, pitch (semitones)
//   sends (net decks only)     room (the genre's room, `.space`), echo and feedback (the genre's
//                              echo, `.echo`; genres without one have none). Sample decks and the
//                              loops have no room or echo of their own here (their channel reverb
//                              is the Reverb section's `DeckReverb`).
//
// The poke is the value (`DeckAction.fx`): a setting is configuration, so a replay that sets the
// same values renders the same audio. The boundary is immediate: a move is smoothed on the audio
// thread over ~30 ms (one-pole per block, each block a linear / exponential ramp inside the chain),
// a deliberate exception to bar quantise for continuous controls. Reset and kill can wait for the
// next beat (`onBeat`); a knob moved while one waits makes it land at once.
//
// How it combines with the master macros (`FxAutomation`, beats' sliders): the macros keep running
// on their own sliders and the chain hears, per key, the more processed of the two — HP the higher
// cutoff, LP the lower, phaser mix / crush / drive the larger; pitch adds (±24); phaser depth and
// rate are the macro's while it moves them, else the unit's. So a macro rides on top of the unit's
// setting and releases back to it, and a unit at neutral leaves every macro exactly as it was.
//
// A neutral unit (every value at `neutral`, or killed) asks the chain for its resting values, so
// the chain goes back to bypass and is bit-transparent (MasterChain's rest rule); a unit never
// moved sends the chain nothing at all.
//
// Real-time: `FxUnitLayer` is allocated in its owner's init; `take` and `beginBlock` allocate,
// lock and free nothing (`FxUnitRealTimeTests`).

/// One control of the FX unit.
public enum FxParam: String, CaseIterable, Sendable {
  case filter
  case hp
  case lp
  case phaserMix = "phaser-mix"
  case phaserDepth = "phaser-depth"
  case phaserRate = "phaser-rate"
  case crush
  case drive
  case pitch
  case room
  case echo
  case feedback

  public var id: String { rawValue }
  public init?(id: String) { self.init(rawValue: id) }

  /// Its place in `FxUnitSettings.values` (and the audio thread's arrays).
  public var index: Int {
    switch self {
    case .filter: 0
    case .hp: 1
    case .lp: 2
    case .phaserMix: 3
    case .phaserDepth: 4
    case .phaserRate: 5
    case .crush: 6
    case .drive: 7
    case .pitch: 8
    case .room: 9
    case .echo: 10
    case .feedback: 11
    }
  }
  public static let count = 12

  /// Its travel: −1…1 for the bipolar filter, −12…12 semitones for pitch, else 0…1.
  public var range: ClosedRange<Double> {
    switch self {
    case .filter: -1...1
    case .pitch: -12...12
    default: 0...1
    }
  }

  /// Where it does nothing: LP open, the phaser's depth at beats' default (3 octaves), the rest 0.
  public var neutral: Double {
    switch self {
    case .lp: 1
    case .phaserDepth: 0.5
    default: 0
    }
  }

  public var label: String {
    switch self {
    case .filter: "Filter"
    case .hp: "HP"
    case .lp: "LP"
    case .phaserMix: "Phaser"
    case .phaserDepth: "Depth"
    case .phaserRate: "Rate"
    case .crush: "Crush"
    case .drive: "Drive"
    case .pitch: "Pitch"
    case .room: "Room"
    case .echo: "Echo"
    case .feedback: "Feedback"
    }
  }

  /// A send on a net deck's runner (its room and echo), not the master chain.
  public var isSend: Bool { self == .room || self == .echo || self == .feedback }

  /// The value, inside its travel (NaN: neutral).
  public func clamp(_ v: Double) -> Double {
    guard v.isFinite else { return neutral }
    return Swift.max(range.lowerBound, Swift.min(range.upperBound, v))
  }

  /// Close enough to call it there (the audio thread snaps onto the target from this near).
  var epsilon: Double { (range.upperBound - range.lowerBound) * 1e-5 }

  /// What it does at `v`, for a label: "LP 1.2 kHz", "HP 310 Hz", "8 bit", "+3.0 st", "+6 dB".
  public func readout(_ v: Double) -> String {
    func hz(_ f: Double) -> String {
      f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }
    func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
    let v = clamp(v)
    switch self {
    case .filter:
      if v < 0 { return "LP " + hz(Swift.max(100, MasterParams.lpFreq(100 * (1 + v)))) }
      if v > 0 { return "HP " + hz(Swift.min(5000, MasterParams.hpFreq(100 * v))) }
      return "off"
    case .hp: return v == 0 ? "off" : hz(Swift.min(5000, MasterParams.hpFreq(100 * v)))
    case .lp: return v == 1 ? "off" : hz(Swift.max(100, MasterParams.lpFreq(100 * v)))
    case .phaserMix, .drive, .feedback: return v == 0 ? "off" : pct(v)
    case .phaserDepth: return String(format: "%.1f oct", Swift.max(0.5, v * 6))
    case .phaserRate: return String(format: "%.1f Hz", v == 0 ? 0.1 : 0.1 + v * 9.9)
    case .crush: return v == 0 ? "off" : String(format: "%.1f bit", Swift.max(1, 16 - v * 15))
    case .pitch: return v == 0 ? "0 st" : String(format: "%+.1f st", v)
    case .room, .echo: return v == 0 ? "off" : String(format: "+%.1f dB", 20 * log10(1 + 3 * v))
    }
  }

  /// The chain's controls, in panel order.
  public static let chain: [FxParam] = [
    .filter, .hp, .lp, .phaserMix, .phaserDepth, .phaserRate, .crush, .drive, .pitch,
  ]
  /// The net decks' sends.
  public static let sends: [FxParam] = [.room, .echo, .feedback]

  /// The most the echo's feedback goes to (feedback 1): repeats that ring for seconds.
  static let maxFeedback = 0.92
  /// Room / echo 1 sends 4× the genre's own (+12 dB).
  static let maxSendGain = 4.0
}

/// One target's FX unit: a value per control, and the kill (bypass the unit, keep the knobs).
public struct FxUnitSettings: Equatable, Sendable {
  public private(set) var values: [Double]
  /// The unit is bypassed (the chain hears its neutral), its values kept for when it is let go.
  public var killed = false

  public init() { values = FxParam.allCases.map(\.neutral) }

  public subscript(_ p: FxParam) -> Double {
    get { values[p.index] }
    set { values[p.index] = p.clamp(newValue) }
  }

  /// Every control at its neutral (killed or not).
  public var isNeutral: Bool { FxParam.allCases.allSatisfy { self[$0] == $0.neutral } }

  /// Is the unit changing the sound (not neutral, not killed)?
  public var isActive: Bool { !killed && !isNeutral }

  /// The controls away from neutral, in panel order.
  public var moved: [FxParam] { FxParam.allCases.filter { self[$0] != $0.neutral } }

  /// The controls that differ, and only them; `killed` only when on.
  public var json: JSONValue {
    var o = JSONObject()
    for p in moved { o[p.id] = .number(self[p]) }
    if killed { o["killed"] = .bool(true) }
    return .object(o)
  }

  public init(json v: JSONValue?) {
    self.init()
    for p in FxParam.allCases { if let x = v?[p.id]?.double { self[p] = x } }
    killed = v?["killed"]?.bool ?? false
  }

  /// The actions that set this from neutral (a recording that starts with it).
  public func actions(deck: String) -> [DeckAction] {
    moved.map { DeckAction.fx(deck: deck, param: $0.id, value: self[$0]) }
      + (killed ? [.fxKill(deck: deck, on: true, onBeat: false)] : [])
  }
}

/// Main → audio: what the FX unit's owner (a net deck's `WaveDeckSource`, a sample deck's or the
/// loops' `LoopMasterBus`) takes from its command ring.
public enum FxUnitCommand: BitwiseCopyable, Sendable {
  /// A control (`FxParam.index`) to `value`, smoothed; `snap`: at once (a restore, a mode switch).
  case set(param: UInt8, value: Double, snap: Bool)
  /// Every control back to neutral and the kill off, at the block holding owner frame `frame`
  /// (0, or a frame already past: the next block).
  case reset(frame: Int)
  /// The kill on or off, at the block holding `frame`.
  case kill(on: Bool, frame: Int)
}

/// The FX unit on the audio thread: the controls' targets, their smoothed values, and the chain
/// keys it has asked for. Its owner calls `take` for each command, `beginBlock` at the start of
/// every block (the unit's moves, at sample 0 of the block, as ramps over it), and `automated` for
/// every slider dispatch of the macros (the combined value, applied as the macro's own op).
final class FxUnitLayer {
  static let smoothSeconds = 0.03
  static let keyCount = MasterFxKey.allCases.count

  let sampleRate: Double
  private var target: [Double]
  private var current: [Double]
  private let neutral: [Double]
  private let epsilon: [Double]
  private var killed = false
  /// The macros' last slider value per key (`FxAutomation`'s, as dispatched).
  private var slider: [Double]
  /// What the chain was last asked for, per key.
  private var applied: [Double]
  private let restKey: [Double]
  // one quantised move waiting for its frame: 0 none, 1 reset, 2 kill on, 3 kill off
  private var pendingKind: UInt8 = 0
  private var pendingFrame = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    var n = [Double](repeating: 0, count: FxParam.count)
    var e = [Double](repeating: 0, count: FxParam.count)
    for p in FxParam.allCases {
      n[p.index] = p.neutral
      e[p.index] = p.epsilon
    }
    // every mutable array its own buffer: one sharing storage with another would copy on its
    // first write, on the audio thread (CoW)
    neutral = n
    epsilon = e
    target = n.map { $0 }
    current = n.map { $0 }
    let rest = MasterFxKey.allCases.map { Double($0.defaultValue) }
    restKey = rest
    slider = rest.map { $0 }
    applied = rest.map { $0 }
  }

  // MARK: commands

  func take(_ c: FxUnitCommand) {
    switch c {
    case .set(let i, let v, let snap):
      let k = Int(i)
      guard k < FxParam.count else { return }
      if pendingKind != 0 { landPending() }  // the hand wins: what waited lands now
      target[k] = v
      if snap { current[k] = killed ? neutral[k] : v }
    case .reset(let frame):
      if pendingKind != 0 { landPending() }
      if frame <= 0 {
        reset()
      } else {
        pendingKind = 1
        pendingFrame = frame
      }
    case .kill(let on, let frame):
      if pendingKind != 0 { landPending() }
      if frame <= 0 {
        killed = on
      } else {
        pendingKind = on ? 2 : 3
        pendingFrame = frame
      }
    }
  }

  private func reset() {
    for i in 0..<FxParam.count { target[i] = neutral[i] }
    killed = false
  }

  private func landPending() {
    switch pendingKind {
    case 1: reset()
    case 2: killed = true
    case 3: killed = false
    default: break
    }
    pendingKind = 0
  }

  // MARK: the block

  /// Is every control where it is going (no smoothing in flight)?
  private(set) var settled = true

  /// The block starting at owner frame `startFrame`: land a quantised move due in it, smooth the
  /// controls one step, and `emit` each chain key whose combined value moved (the owner applies it
  /// at the block's first sample as a ramp over the block).
  func beginBlock(
    frames: Int, startFrame: Int, automation: FxAutomation, _ emit: (MasterFxKey, Double) -> Void
  ) {
    if pendingKind != 0 && pendingFrame < startFrame + frames { landPending() }
    let a = 1 - exp(-Double(frames) / (Self.smoothSeconds * sampleRate))
    var still = true
    for i in 0..<FxParam.count {
      let t = killed ? neutral[i] : target[i]
      var c = current[i]
      guard c != t else { continue }
      c += (t - c) * a
      if abs(t - c) <= epsilon[i] { c = t } else { still = false }
      current[i] = c
    }
    settled = still
    for k in 0..<Self.keyCount {
      let key = MasterFxKey(rawValue: k)!
      let v = combined(key, automation.isAnimating(key))
      if v != applied[k] {
        applied[k] = v
        emit(key, v)
      }
    }
  }

  /// A macro's slider dispatch: what the chain should hear for it (the macro on the unit).
  func automated(_ key: MasterFxKey, _ value: Int, automation: FxAutomation) -> Double {
    let k = key.rawValue
    slider[k] = Double(value)
    let v = combined(key, automation.isAnimating(key))
    applied[k] = v
    return v
  }

  /// The unit's own position for a chain key, in the slider's units.
  private func unitValue(_ key: MasterFxKey) -> Double {
    let f = current[FxParam.filter.index]
    switch key {
    case .hpFreq: return 100 * max(current[FxParam.hp.index], max(0, f))
    case .lpFreq: return 100 * min(current[FxParam.lp.index], 1 + min(0, f))
    case .phaserWet: return 100 * current[FxParam.phaserMix.index]
    case .phaserDepth: return 100 * current[FxParam.phaserDepth.index]
    case .phaserFreq: return 100 * current[FxParam.phaserRate.index]
    case .crushBits: return 100 * current[FxParam.crush.index]
    case .distortion: return 100 * current[FxParam.drive.index]
    case .masterPitch: return current[FxParam.pitch.index]
    }
  }

  /// The combination rule (see the top of the file). With the unit at neutral it is the slider.
  private func combined(_ key: MasterFxKey, _ animating: Bool) -> Double {
    let u = unitValue(key)
    let s = slider[key.rawValue]
    switch key {
    case .hpFreq, .phaserWet, .crushBits, .distortion: return max(u, s)
    case .lpFreq: return min(u, s)
    case .masterPitch: return max(-24, min(24, u + s))
    case .phaserDepth, .phaserFreq:
      return animating || s != restKey[key.rawValue] ? s : u
    }
  }

  // MARK: sends (net decks)

  /// The room's send gain: 1 = the genre's own, up to `FxParam.maxSendGain`.
  var roomGain: Double { 1 + (FxParam.maxSendGain - 1) * current[FxParam.room.index] }
  var echoGain: Double { 1 + (FxParam.maxSendGain - 1) * current[FxParam.echo.index] }
  /// 0 = the genre's feedback, 1 = `FxParam.maxFeedback`.
  var feedbackBoost: Double { current[FxParam.feedback.index] }

  /// The smoothed value of a control (tests).
  func value(_ p: FxParam) -> Double { current[p.index] }
}

extension FxAutomation {
  /// Is a macro animating this slider now (a sweep or hold running on it)?
  func isAnimating(_ key: MasterFxKey) -> Bool { animatingKey(key.rawValue) }
}

/// A dragged knob, recorded at a bounded rate: the first move goes at once, then at most one every
/// `interval` per key, the latest value winning; whatever waits goes out when its time comes
/// (`due`, from a poll) or when the drag ends (`finish`), so the last value is always the one that
/// lands. Sessions stay small (a 2 s drag is ≤ 60 actions, not one per mouse event). Main thread.
public struct FxUnitCoalescer {
  /// ≤ 30 Hz.
  public static let interval = 1.0 / 30
  public let interval: Double
  private var sent: [String: Double] = [:]
  private var waiting: [String: Double] = [:]

  public init(interval: Double = FxUnitCoalescer.interval) { self.interval = interval }

  /// A move of `key` to `value` at time `now` (seconds): true to send it now, false if it waits.
  public mutating func offer(_ key: String, _ value: Double, now: Double) -> Bool {
    if let last = sent[key], now - last < interval {
      waiting[key] = value
      return false
    }
    sent[key] = now
    waiting[key] = nil
    return true
  }

  /// The waiting moves whose time has come, to send now (sorted by key).
  public mutating func due(now: Double) -> [(key: String, value: Double)] {
    var out: [(String, Double)] = []
    for (k, v) in waiting.sorted(by: { $0.key < $1.key }) where now - (sent[k] ?? -1e9) >= interval {
      out.append((k, v))
      sent[k] = now
      waiting[k] = nil
    }
    return out
  }

  /// The drag on `key` ended: its waiting value, if any, to send now.
  public mutating func finish(_ key: String) -> Double? {
    sent[key] = nil
    return waiting.removeValue(forKey: key)
  }

  public var hasWaiting: Bool { !waiting.isEmpty }
}
