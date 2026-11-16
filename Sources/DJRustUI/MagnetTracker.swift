import Foundation

// The wheel's magnets between polls, for a drawing that runs at the display's rate (djandroid
// MagnetTracker.kt).
//
// Each poll is a `Sample`: the magnets' places and speeds on the voice's clock (frames rendered
// over the sample rate), stamped with the wall clock when it was read. The tracker keeps a
// smoothed offset between the two clocks, so the drawing asks "where is it at this frame?" on the
// voice's clock and a poll's timing (late, early, two in one frame) doesn't jitter the motion.
// Between polls a magnet moves on at its speed; when a poll disagrees with that guess the
// difference is eased out over `easeS` instead of jumping.
//
// `extent` is a periodic path's length (positions wrap), 0 for an open one.

final class MagnetTracker {
  struct Sample {
    var z: [Double]
    var v: [Double]
    var on: [Bool]
    var seg: [Int]
    /// The voice's clock at the poll (s).
    var voiceS: Double
    /// The wall clock just after the poll returned (s, `Date.timeIntervalSinceReferenceDate`).
    var stamp: Double
    /// Which poll it is: a new one is fed once.
    var seq: Int
  }

  static let offsetGain = 0.05
  /// An offset this far off is a new clock (the voice stalled or restarted): take it.
  static let resetS = 0.08
  static let easeS = 0.06
  static let snapM = 0.1
  static let stillMps = 1e-4
  /// How far a sample is moved on at most (a stalled poll doesn't fling the magnets).
  static let maxAheadS = 0.1
  static let maxBackS = 0.05

  private let extent: Double
  private(set) var sample: Sample?
  /// voice clock − wall clock (s), smoothed; nil before the first sample.
  private var offset: Double?
  private var corr: [Double] = []
  private var corrAt = 0.0

  init(extent: Double) { self.extent = extent }

  func feed(_ s: Sample) {
    let o = s.voiceS - s.stamp
    let prev = sample
    // where the drawing had each magnet at this instant, before taking the new sample
    let before = prev.map { p in (0..<p.z.count).map { at(p, $0, s.stamp) } }
    if let off = offset, abs(o - off) <= Self.resetS { offset = off + (o - off) * Self.offsetGain } else { offset = o }
    sample = s
    var c = [Double](repeating: 0, count: s.z.count)
    if let p = prev, let before, p.z.count == s.z.count {
      for k in c.indices where s.on[k] && p.on[k] && p.seg[k] == s.seg[k] {
        let d = wrap(before[k] - project(s, k, s.stamp))
        // a real jump (a magnet dropped back in, a hand on the rail) is drawn as one
        if abs(d) < Self.snapM { c[k] = d }
      }
    }
    corr = c
    corrAt = s.stamp
  }

  /// Magnet k's place at wall time `t`.
  func z(_ k: Int, _ t: Double) -> Double {
    guard let s = sample else { return 0 }
    return at(s, k, t)
  }

  /// Nothing will move until the next poll: every magnet still and the last correction eased out.
  func idle(_ t: Double) -> Bool {
    guard let s = sample else { return true }
    for k in s.v.indices where s.on[k] && abs(s.v[k]) > Self.stillMps { return false }
    let left = exp(-(t - corrAt) / Self.easeS)
    return corr.allSatisfy { abs($0) * left < 1e-5 }
  }

  private func at(_ s: Sample, _ k: Int, _ t: Double) -> Double {
    let left = exp(-max(0, t - corrAt) / Self.easeS)
    let c = (s.seq == sample?.seq && k < corr.count) ? corr[k] * left : 0
    return project(s, k, t) + c
  }

  /// The sample's guess for magnet k at wall time `t`: on at its speed, on the voice's clock.
  private func project(_ s: Sample, _ k: Int, _ t: Double) -> Double {
    let dt = min(max(t + (offset ?? 0) - s.voiceS, -Self.maxBackS), Self.maxAheadS)
    return s.z[k] + s.v[k] * dt
  }

  private func wrap(_ d: Double) -> Double {
    guard extent > 0 else { return d }
    var x = d.truncatingRemainder(dividingBy: extent)
    if x > extent / 2 { x -= extent } else if x < -extent / 2 { x += extent }
    return x
  }
}

/// The motion poll's hand-over to the drawing: the latest sample (not observed, so a moving
/// wheel redraws only its magnet layer) and whether a drawing is on screen to want them.
final class WheelFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var _sample: MagnetTracker.Sample?
  private var _watchers = 0
  var sample: MagnetTracker.Sample? { lock.withLock { _sample } }
  var watching: Bool { lock.withLock { _watchers > 0 } }
  func publish(_ s: MagnetTracker.Sample) { lock.withLock { _sample = s } }
  func watch(_ on: Bool) { lock.withLock { _watchers += on ? 1 : -1 } }
}

/// The newest value of a control a drag sends dozens of times: one engine call on its way at a
/// time, and it takes the latest value when it gets there (djandroid's `*Pending` atomics).
final class Latest<T: Equatable>: @unchecked Sendable {
  private let lock = NSLock()
  private var v: T?
  /// Keep `x` as the latest; true when nothing was pending (the caller starts the apply).
  func put(_ x: T) -> Bool {
    lock.withLock {
      let idle = v == nil
      v = x
      return idle
    }
  }
  var value: T? { lock.withLock { v } }
  /// Done applying `x`: true when it is still the latest (the pending slot is cleared).
  func done(_ x: T) -> Bool {
    lock.withLock {
      guard v == x else { return false }
      v = nil
      return true
    }
  }
}
