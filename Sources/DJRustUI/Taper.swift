import Foundation

// A slider's taper (djandroid ui/Taper.kt): how a thumb position (0 … 1) maps to the value it
// sets, and back. Linear is the default; the others give the values that matter more travel.

protocol Taper {
  func toPos(_ v: Double) -> Double
  func fromPos(_ p: Double) -> Double
}

/// The edge a taper's "off" stop takes: a short stretch at one end that sets `LogTaper.off`.
private let stop = 0.04

/// Log: `lo` … `hi` with equal travel per doubling (times, heights, speeds, ratios). `offAt`: a
/// short stop at the start (-1) or the end (+1) that sets `off` (0: "off", "sustained").
struct LogTaper: Taper {
  let lo: Double, hi: Double
  var offAt = 0
  var off = 0.0
  private var a: Double { offAt < 0 ? stop : 0 }
  private var b: Double { offAt > 0 ? 1 - stop : 1 }

  func toPos(_ v: Double) -> Double {
    if offAt != 0 && v == off { return offAt < 0 ? 0 : 1 }
    return a + (b - a) * (log(min(max(v, lo), hi) / lo) / log(hi / lo))
  }

  func fromPos(_ p: Double) -> Double {
    if offAt < 0 && p < a { return off }
    if offAt > 0 && p > b { return off }
    return lo * exp((min(max(p, a), b) - a) / (b - a) * log(hi / lo))
  }
}

/// A power curve over 0 … `max`: `k` > 1 gives the small values more travel (a mild 1.5).
struct PowTaper: Taper {
  let max: Double, k: Double
  func toPos(_ v: Double) -> Double { pow(Swift.min(Swift.max(v, 0), max) / max, 1 / k) }
  func fromPos(_ p: Double) -> Double { max * pow(Swift.min(Swift.max(p, 0), 1), k) }
}

/// Linear over `lo` … `hi`.
struct LinearTaper: Taper {
  let lo: Double, hi: Double
  func toPos(_ v: Double) -> Double { hi > lo ? (v - lo) / (hi - lo) : 0 }
  func fromPos(_ p: Double) -> Double { lo + p * (hi - lo) }
}

/// The square-law volume fader (`Fader`) as a taper.
struct FaderTaper: Taper {
  func toPos(_ v: Double) -> Double { Fader.toPos(v) }
  func fromPos(_ p: Double) -> Double { Fader.fromPos(p) }
}
