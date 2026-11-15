import Foundation

// The wheel's magnets between polls (djandroid MagnetTracker.kt), for a drawing that runs at the
// display's rate.
//
// Each poll is a `Sample`: the magnets' places and speeds on the voice's clock (frames rendered
// over the sample rate), stamped with the monotonic clock (`DispatchTime`, nanoseconds) when it
// was read. The tracker keeps a smoothed offset between the two clocks, so the drawing asks
// "where is it at this frame?" on the voice's clock and a poll's timing (late, early, two in one
// frame) doesn't jitter the motion. Between polls a magnet moves on at its speed; when a poll
// disagrees with that guess the difference is eased out over `easeS` instead of jumping.
//
// `extent` is a periodic path's length (positions wrap), 0 for an open one. The poll feeds it off
// the main thread and the drawing reads it on the main thread: every access holds its lock.

/// The monotonic clock the tracker and the drawing share.
func monoNs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }

final class MagnetTracker: @unchecked Sendable {
  struct Sample {
    var z: [Double]
    var v: [Double]
    var on: [Bool]
    var seg: [Int]
    /// The voice's clock at the poll (s).
    var voiceS: Double
    /// `monoNs()` just after the poll returned.
    var stampNs: Int64
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
  private let lock = NSLock()
  private var cur: Sample?
  /// voice clock − wall clock (s), smoothed; NaN before the first sample.
  private var offset = Double.nan
  private var corr: [Double] = []
  private var corrAtNs: Int64 = 0

  init(extent: Double) { self.extent = extent }

  var sample: Sample? { lock.withLock { cur } }

  func feed(_ s: Sample) {
    lock.withLock {
      let wall = Double(s.stampNs) / 1e9
      let o = s.voiceS - wall
      let prev = cur
      // where the drawing had each magnet at this instant, before taking the new sample
      let before = prev.map { p in (0..<p.z.count).map { at(p, $0, s.stampNs) } }
      offset = offset.isNaN || abs(o - offset) > Self.resetS ? o : offset + (o - offset) * Self.offsetGain
      cur = s
      var c = [Double](repeating: 0, count: s.z.count)
      if let prev, let before, prev.z.count == s.z.count {
        for k in c.indices {
          guard s.on[k], prev.on[k], prev.seg[k] == s.seg[k] else { continue }
          let d = wrap(before[k] - project(s, k, s.stampNs))
          // a real jump (a magnet dropped back in, a hand on the rail) is drawn as one
          if abs(d) < Self.snapM { c[k] = d }
        }
      }
      corr = c
      corrAtNs = s.stampNs
    }
  }

  /// Magnet k's place at frame time `ns` (`monoNs()` base).
  func z(_ k: Int, _ ns: Int64) -> Double {
    lock.withLock {
      guard let s = cur else { return 0 }
      return at(s, k, ns)
    }
  }

  /// Every magnet's sample and place at `ns`, under one lock (a frame's worth).
  func frame(_ ns: Int64) -> (Sample, [Double])? {
    lock.withLock {
      guard let s = cur else { return nil }
      return (s, (0..<s.z.count).map { at(s, $0, ns) })
    }
  }

  /// Nothing will move until the next poll: every magnet still and the last correction eased
  /// out. The drawing stops asking for frames then.
  func idle(_ ns: Int64) -> Bool {
    lock.withLock {
      guard let s = cur else { return true }
      for k in s.v.indices where s.on[k] && abs(s.v[k]) > Self.stillMps { return false }
      let left = exp(-Double(ns - corrAtNs) / 1e9 / Self.easeS)
      return corr.allSatisfy { abs($0) * left < 1e-5 }
    }
  }

  private func at(_ s: Sample, _ k: Int, _ ns: Int64) -> Double {
    let left = exp(-Double(max(0, ns - corrAtNs)) / 1e9 / Self.easeS)
    let c = k < corr.count ? corr[k] * left : 0
    return project(s, k, ns) + c
  }

  /// The sample's guess for magnet k at wall time `ns`: on at its speed, on the voice's clock.
  private func project(_ s: Sample, _ k: Int, _ ns: Int64) -> Double {
    let dt = min(max((Double(ns) / 1e9 + offset) - s.voiceS, -Self.maxBackS), Self.maxAheadS)
    return s.z[k] + s.v[k] * dt
  }

  private func wrap(_ d: Double) -> Double {
    guard extent > 0 else { return d }
    var x = d.truncatingRemainder(dividingBy: extent)
    if x > extent / 2 { x -= extent } else if x < -extent / 2 { x += extent }
    return x
  }
}
