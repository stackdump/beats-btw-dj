// The step <-> audio-time anchors of a scope feed: scope.js `pushAnchor` / `anchorAt` and the
// time-axis maps built on them, fed by the engine's exact tick anchors instead of by fires.
//
// One anchor says "step S began at audio time T". `step` is the song step, `tick - 1` as in
// scope.js `scopeOnFire`. Time is audio seconds in the engine's frame base (frame / sampleRate).

/// One (audio time, step) pair.
public struct ScopeAnchor: Equatable, Sendable {
  /// Audio seconds: `frame / sampleRate`.
  public var time: Double
  /// Engine frame at which the step begins.
  public var frame: Int
  /// Song step (`tick - 1`; the first step of a song is 0).
  public var step: Int
  /// The net clock's BPM during the step.
  public var tempo: Double
  /// The engine generation (project) the tick belongs to.
  public var generation: Int32
  /// This anchor does not continue the one before it (play, stop, align, scratch ...): steps and
  /// spacing do not follow on, so nothing is interpolated across it.
  public var discontinuity: Bool
  /// A queued project took over here; the step counter restarted or jumped.
  public var swap: Bool

  public init(
    time: Double, frame: Int, step: Int, tempo: Double, generation: Int32,
    discontinuity: Bool = false, swap: Bool = false
  ) {
    self.time = time
    self.frame = frame
    self.step = step
    self.tempo = tempo
    self.generation = generation
    self.discontinuity = discontinuity
    self.swap = swap
  }

  /// Does a new run of consecutive steps start here?
  public var startsRun: Bool { discontinuity || swap }
}

/// A ring of the most recent anchors, oldest first when read by index.
///
/// scope.js keeps 64 (`AN_CAP`) because its anchors come from fires. Here the engine publishes
/// one per tick, so the default is 128: two 64-step windows, enough for a time axis to look up
/// the step at the left edge of its window as well as at "now".
public struct ScopeAnchorRing: Sendable {
  public static let defaultCapacity = 128

  public let capacity: Int
  private var storage: [ScopeAnchor] = []
  private var head = 0  // index of the oldest when full

  public init(capacity: Int = ScopeAnchorRing.defaultCapacity) {
    self.capacity = max(2, capacity)
    storage.reserveCapacity(self.capacity)
  }

  public var count: Int { storage.count }
  public var isEmpty: Bool { storage.isEmpty }

  /// The anchor `i` places after the oldest (0 = oldest, `count - 1` = newest).
  public subscript(i: Int) -> ScopeAnchor {
    storage[(head + i) % storage.count]
  }

  /// Does any stored anchor satisfy the predicate?
  public func contains(where p: (ScopeAnchor) -> Bool) -> Bool {
    for i in 0..<count where p(self[i]) { return true }
    return false
  }

  public var newest: ScopeAnchor? { storage.isEmpty ? nil : self[storage.count - 1] }
  public var oldest: ScopeAnchor? { storage.isEmpty ? nil : self[0] }

  public mutating func removeAll() {
    storage.removeAll(keepingCapacity: true)
    head = 0
  }

  /// scope.js `pushAnchor`: ignored when the newest anchor has the same step, except that an
  /// anchor that starts a run (discontinuity or swap) is always kept: a pause and resume on one
  /// step is a new fact about time. Returns whether it was stored.
  @discardableResult
  public mutating func push(_ a: ScopeAnchor) -> Bool {
    if let n = newest, n.step == a.step, !a.startsRun { return false }
    if storage.count < capacity {
      storage.append(a)
    } else {
      storage[head] = a
      head = (head + 1) % capacity
    }
    return true
  }

  /// Index (0 = oldest) of the run a position belongs to: the first anchor of the newest run.
  public var newestRunStart: Int {
    var i = storage.count - 1
    while i > 0 {
      if self[i].startsRun { return i }
      i -= 1
    }
    return 0
  }

  /// scope.js `anchorAt(t)`: index of the latest anchor at or before audio time `t`, else the
  /// oldest (0). Nil when there are no anchors. Binary search: anchors are in time order.
  public func indexAt(time t: Double) -> Int? {
    guard !storage.isEmpty else { return nil }
    var lo = 0
    var hi = storage.count - 1
    if self[0].time > t { return 0 }
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if self[mid].time <= t { lo = mid } else { hi = mid - 1 }
    }
    return lo
  }

  public func anchor(at t: Double) -> ScopeAnchor? { indexAt(time: t).map { self[$0] } }

  /// The song step at audio time `t` (fractional), or nil without anchors.
  ///
  /// Inside the table the step is interpolated between the two anchors around `t` when they are
  /// consecutive steps of one run (the next anchor starts no run); that is exact through tempo
  /// changes. After the newest anchor, or when the next one starts a new run, it extrapolates
  /// from the anchor at `tickSec` per step: scope.js `stepOf`. Before the oldest anchor it
  /// extrapolates backwards the same way.
  public func step(at t: Double, tickSec: Double) -> Double? {
    guard let i = indexAt(time: t) else { return nil }
    let a = self[i]
    if i + 1 < count {
      let b = self[i + 1]
      if !b.startsRun, b.step == a.step + 1, b.time > a.time, t >= a.time, t <= b.time {
        return Double(a.step) + (t - a.time) / (b.time - a.time)
      }
    }
    return Double(a.step) + (t - a.time) / tickSec
  }

  /// The audio time at which (fractional) song step `s` begins, in the newest run of anchors
  /// (steps from before a discontinuity are not in this run). Interpolated between consecutive
  /// anchors, extrapolated at `tickSec` per step beyond either end: scope.js `timeOf`.
  public func time(ofStep s: Double, tickSec: Double) -> Double? {
    guard !storage.isEmpty else { return nil }
    let start = newestRunStart
    let first = self[start]
    if s <= Double(first.step) { return first.time + (s - Double(first.step)) * tickSec }
    // latest anchor of the run whose step is <= floor(s)
    let whole = s.rounded(.down)
    var k = count - 1
    while k > start, Double(self[k].step) > whole { k -= 1 }
    let a = self[k]
    if k + 1 < count {
      let b = self[k + 1]
      if b.step == a.step + 1, b.time > a.time, s <= Double(b.step) {
        return a.time + (s - Double(a.step)) * (b.time - a.time)
      }
    }
    return a.time + (s - Double(a.step)) * tickSec
  }
}

/// The drawing axis of the live views: scope.js `timeAxis`, `xOf`, `stepOf`, `timeOf`. The right
/// edge is "now", the window is `windowSteps` steps wide. Steps map to time through the one
/// anchor at or before "now" and a constant `tickSec`, exactly as the JS draws them; for an exact
/// lookup through tempo changes use `ScopeFeed.step(at:)` / `time(ofStep:)`.
public struct ScopeTimeAxis: Equatable, Sendable {
  /// 4 bars.
  public static let windowSteps = 64

  public var tickSec: Double
  /// Window length in seconds: `windowSteps * tickSec`.
  public var win: Double
  public var tNow: Double
  /// Left edge in audio seconds.
  public var t0: Double
  /// Pixel range of the window.
  public var x0: Double
  public var w: Double
  /// Is there a usable window at all (finite, positive `win`, finite `tNow`)?
  public var ok: Bool
  /// The anchor at or before "now": audio time and step (NaN without one).
  public var aT: Double
  public var aS: Double

  public init(
    tickSec: Double, tNow: Double, anchor: ScopeAnchor?, x0: Double, w: Double,
    windowSteps: Int = ScopeTimeAxis.windowSteps
  ) {
    self.tickSec = tickSec
    win = Double(windowSteps) * tickSec
    self.tNow = tNow
    t0 = tNow - win
    self.x0 = x0
    self.w = w
    ok = win.isFinite && win > 0 && tNow.isFinite
    aT = anchor?.time ?? .nan
    aS = anchor.map { Double($0.step) } ?? .nan
  }

  /// Does the axis know where steps are (an anchor exists)?
  public var hasAnchor: Bool { aT.isFinite }

  /// Pixel x of audio time `t`.
  public func xOf(_ t: Double) -> Double { x0 + (t - t0) / win * w }
  /// Song step at audio time `t`.
  public func stepOf(_ t: Double) -> Double { aS + (t - aT) / tickSec }
  /// Audio time at song step `st`.
  public func timeOf(_ st: Double) -> Double { aT + (st - aS) * tickSec }
}
