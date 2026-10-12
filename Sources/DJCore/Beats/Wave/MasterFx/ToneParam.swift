import Foundation

// Tone.js's automation timeline, ported for the master chain's parameters.
//
// What a beats setter does to a parameter (tone-engine.js `setLowpassFreq` & co.) is a Tone call:
// `frequency.cancelScheduledValues(now)`, `frequency.rampTo(f, 0.1)`, `wet.rampTo(w, 0.05)`,
// `bits.value = b`. Tone keeps its own copy of the AudioParam's event list (core/util/Timeline.js)
// and mirrors every call onto the native param, so the value the browser renders at time t is
// Tone's `getValueAtTime(t)`. This is a port of exactly that, from Tone 15.1.22
// (core/context/Param.js: `setValueAtTime`, `linearRampToValueAtTime`,
// `exponentialRampToValueAtTime`, `cancelScheduledValues`, `cancelAndHoldAtTime`,
// `setRampPoint`, `rampTo`, the `value` setter, `getValueAtTime`; Timeline.js: `add`, `get`,
// `getAfter`, `cancel`, `_search`), including its quirks — the ones that are audible here:
//   * `rampTo` starts from Tone's idea of the value *after* any cancel the caller made first. The
//     HP/LP setters cancel before ramping, so a ramp cut short by the next one (a panic 30 ms after
//     a dispatch) jumps back to where the cut ramp started, then ramps from there.
//   * a ramp point of exactly 0 becomes 1e-7 (`_minOutput`), linear ramps included.
//   * times within 1e-6 s are "equal" (core/util/Math.js `EQ`).
// `setTargetAtTime` is not ported (nothing in the master chain uses it).
//
// Checked against the real Tone code: `MasterFxParityTests` replays the call log of every case
// in macro-fx.json and compares the values Tone read back mid-run (scripts/beats-macro-fx.mjs).
//
// Real-time: fixed capacity, no allocation after `init`. Tone keeps 1000 events per param; this
// keeps `capacity`, and `prune(before:)` drops events no future query can reach (the queries only
// move forward in time), so the list stays short.

struct ToneParam {
  enum Kind: UInt8 {
    case set
    case linear
    case exponential
  }

  /// core/util/Math.js EPSILON.
  static let epsilon = 1e-6
  /// Param.js `_minOutput`.
  static let minOutput = 1e-7
  static let capacity = 16

  /// The value before any event (the native param's value when Tone built the node).
  let initialValue: Double
  /// `rampTo` is exponential for frequency units (Param.js `rampTo`), linear otherwise.
  let exponentialRamps: Bool
  /// The context's `sampleTime` (one `cancel` in `cancelAndHoldAtTime` uses it).
  let sampleTime: Double

  private(set) var count = 0
  private var times: [Double]
  private var kinds: [Kind]
  private var values: [Double]

  init(value: Double, exponentialRamps: Bool, sampleRate: Double) {
    initialValue = value
    self.exponentialRamps = exponentialRamps
    sampleTime = 1 / sampleRate
    times = [Double](repeating: 0, count: Self.capacity)
    kinds = [Kind](repeating: .set, count: Self.capacity)
    values = [Double](repeating: 0, count: Self.capacity)
  }

  // MARK: Timeline.js

  private static func eq(_ a: Double, _ b: Double) -> Bool { abs(a - b) < epsilon }
  private static func lt(_ a: Double, _ b: Double) -> Bool { a + epsilon < b }
  private static func gt(_ a: Double, _ b: Double) -> Bool { a > b + epsilon }

  /// `_search`: the index of the last event at or before `t` (equal within epsilon), or -1.
  private func search(_ t: Double) -> Int {
    if count == 0 { return -1 }
    var beginning = 0
    var end = count
    if times[count - 1] <= t { return count - 1 }
    while beginning < end {
      var mid = beginning + (end - beginning) / 2
      let at = times[mid]
      if Self.eq(at, t) {
        var i = mid
        while i < count, Self.eq(times[i], t) {
          mid = i
          i += 1
        }
        return mid
      }
      // JS reads `_timeline[mid + 1]` past the end as undefined (comparisons false).
      if Self.lt(at, t), mid + 1 < count, Self.gt(times[mid + 1], t) {
        return mid
      } else if Self.gt(at, t) {
        end = mid
      } else {
        beginning = mid + 1
      }
    }
    return -1
  }

  private mutating func add(_ kind: Kind, _ value: Double, at t: Double) {
    // (Tone trims its oldest event after inserting; with pruning this list never fills up.)
    if count == Self.capacity { removeFirst(1) }
    let at = search(t) + 1
    var i = count
    while i > at {
      times[i] = times[i - 1]
      kinds[i] = kinds[i - 1]
      values[i] = values[i - 1]
      i -= 1
    }
    times[at] = t
    kinds[at] = kind
    values[at] = value
    count += 1
  }

  private mutating func removeFirst(_ n: Int) {
    guard n > 0 else { return }
    for i in n..<count {
      times[i - n] = times[i]
      kinds[i - n] = kinds[i]
      values[i - n] = values[i]
    }
    count -= n
  }

  /// Timeline `cancel(after)`: drop every event at or after `after`.
  private mutating func cancel(_ after: Double) {
    if count > 1 {
      var index = search(after)
      if index >= 0 {
        if Self.eq(times[index], after) {
          var i = index
          while i >= 0, Self.eq(times[i], after) {
            index = i
            i -= 1
          }
          count = index
        } else {
          count = index + 1
        }
      } else {
        count = 0
      }
    } else if count == 1 {
      if Self.gt(times[0], after) || Self.eq(times[0], after) { count = 0 }
    }
  }

  // MARK: Param.js

  /// `getValueAtTime`.
  func value(at time: Double) -> Double {
    let t = max(time, 0)
    let b = search(t)
    guard b >= 0 else { return initialValue }
    let a = b + 1 < count ? b + 1 : -1
    if a < 0 { return values[b] }
    switch kinds[a] {
    case .linear:
      return values[b] + (values[a] - values[b]) * ((t - times[b]) / (times[a] - times[b]))
    case .exponential:
      return values[b] * pow(values[a] / values[b], (t - times[b]) / (times[a] - times[b]))
    case .set:
      return values[b]
    }
  }

  /// `setValueAtTime`.
  mutating func setValue(_ v: Double, at t: Double) { add(.set, v, at: t) }

  /// `linearRampToValueAtTime`.
  mutating func linearRamp(to v: Double, endingAt t: Double) { add(.linear, v, at: t) }

  /// `exponentialRampToValueAtTime`.
  mutating func exponentialRamp(to v: Double, endingAt t: Double) {
    add(.exponential, Self.eq(v, 0) ? Self.minOutput : v, at: t)
  }

  /// `cancelScheduledValues`.
  mutating func cancelScheduledValues(_ t: Double) { cancel(t) }

  /// `cancelAndHoldAtTime`.
  mutating func cancelAndHold(_ t: Double) {
    let held = value(at: t)
    let b = search(t)
    let a = b + 1 < count ? b + 1 : -1
    if b >= 0, Self.eq(times[b], t) {
      if a >= 0 { cancel(times[a]) } else { cancel(t + sampleTime) }
    } else if a >= 0 {
      let afterTime = times[a]
      let afterKind = kinds[a]
      cancel(afterTime)
      switch afterKind {
      case .linear: linearRamp(to: held, endingAt: t)
      case .exponential: exponentialRamp(to: held, endingAt: t)
      case .set: break
      }
    }
    add(.set, held, at: t)
  }

  /// `setRampPoint`.
  mutating func setRampPoint(_ t: Double) {
    var current = value(at: t)
    cancelAndHold(t)
    if current == 0 { current = Self.minOutput }
    setValue(current, at: t)
  }

  /// `rampTo(value, rampTime)` called at `now` (no start time: Tone uses `now()`).
  mutating func rampTo(_ v: Double, duration: Double, at now: Double) {
    setRampPoint(now)
    if exponentialRamps {
      exponentialRamp(to: v, endingAt: now + duration)
    } else {
      linearRamp(to: v, endingAt: now + duration)
    }
  }

  /// The `value` setter at `now`: cancel, then set.
  mutating func setImmediate(_ v: Double, at now: Double) {
    cancelScheduledValues(now)
    setValue(v, at: now)
  }

  // MARK: rendering

  /// No event after `t`: the value stays what it is at `t` from here on.
  func isSettled(at t: Double) -> Bool {
    count == 0 || times[count - 1] <= t
  }

  /// Drop events that no query at `now` or later can reach: everything before the last event
  /// that is a millisecond or more in the past.
  mutating func prune(before now: Double) {
    var keep = -1
    for i in 0..<count where times[i] < now - 1e-3 { keep = i }
    if keep > 0 { removeFirst(keep) }
  }
}
