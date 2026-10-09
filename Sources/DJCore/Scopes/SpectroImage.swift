// SpectroImage: the two images of the Spectro scope (SPEC modes 2 and 3), as numbers.
// scope.js `drawSpectro` at beats-bitwrap-io 095d030, the part that fills `ImageData`:
//
//   MODEL     66 columns (64 + 2 steps) x 28 rows, one column per song step starting at
//             `first = floor(stepOf(t0))`
//   MEASURED  160 columns (time slices of the window) x 28 rows
//
// Both are an image of LUT INDICES (0...255 into MAGMA) with row 0 on top: bin j (0 = lowest) is
// row 27 - j, so low frequencies are at the bottom. A pixel is
//
//     li = trunc((dB - floor) / 50 * 255)  clamped to 0...255,    floor = mx - 50
//
// where `mx` is the loudest dB among the cells that are going to be drawn (the model image: the
// valid columns of this very image; the measured one: the frames inside the window). Anything
// that is not a valid, finite cell is index 0 (MAGMA[0] = (0, 0, 4), near black), including the
// whole image when `mx` is not finite (nothing to show).
//
// Pure values: no SwiftUI, no feed. The view blits the bitmap NEAREST-neighbour stretched between
// the times of its first and last column (`SpectroScene` computes the rectangle).

import Foundation

/// A grid of MAGMA indices.
public struct SpectroBitmap: Equatable, Sendable {
  public var width: Int
  public var height: Int
  /// `width * height` indices, row 0 first (the highest-frequency row).
  public var levels: [UInt8]
  /// `mx`: the loudest dB the image was fitted to; `-infinity` when it had nothing (all black).
  public var peakDb: Double

  public init(width: Int, height: Int, levels: [UInt8], peakDb: Double) {
    self.width = width
    self.height = height
    self.levels = levels
    self.peakDb = peakDb
  }

  /// The index at column `x`, row `y` (row 0 = top).
  public func level(_ x: Int, _ y: Int) -> UInt8 { levels[y * width + x] }

  /// Opaque RGBA bytes through `lut` (MAGMA by default), 4 per pixel, row 0 first.
  public func rgba(lut: ScopeLUT = ScopeColors.magma) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: levels.count * 4)
    for (i, l) in levels.enumerated() {
      let k = Int(l) * 3
      out[i * 4] = lut.bytes[k]
      out[i * 4 + 1] = lut.bytes[k + 1]
      out[i * 4 + 2] = lut.bytes[k + 2]
    }
    return out
  }
}

/// What the model keeps of its spectrogram (`ModelEngine.specCol`, `specStep`, `specCur`): a ring
/// of `ModelGrid.specCap` columns of `ModelGrid.ns` floats, valid per slot by `step`.
public struct SpectroColumns: Sendable {
  /// `(step % specCap) * ns + j`, j = 0 the lowest bin: linear power.
  public var col: [Float]
  /// The step each slot holds (-1: none).
  public var step: [Int32]
  /// Steps below this are final.
  public var cur: Int

  public init(col: [Float], step: [Int32], cur: Int) {
    self.col = col
    self.step = step
    self.cur = cur
  }

  /// Nothing finalised.
  public static let empty = SpectroColumns(
    col: [Float](repeating: 0, count: ModelGrid.specCap * ModelGrid.ns),
    step: [Int32](repeating: -1, count: ModelGrid.specCap), cur: -1)

  /// scope.js: `st >= 0 && st < specCur && specStep[st % SPEC_CAP] === st`.
  public func isValid(step st: Int) -> Bool {
    st >= 0 && st < cur && Int(step[st % ModelGrid.specCap]) == st
  }
}

extension ModelEngine {
  /// The spectrogram ring as `SpectroImage` reads it (arrays are shared, not copied).
  public var spectroColumns: SpectroColumns {
    SpectroColumns(col: specCol, step: specStep, cur: specCur)
  }
}

public enum SpectroImage {
  /// `WINDOW_STEPS + 2`: the steps the model image spans, so that its ends can slide out of the
  /// window instead of popping.
  public static let modelColumns = ScopeTimeAxis.windowSteps + 2
  /// scope.js `COLS` of the measured block.
  public static let measuredColumns = 160
  /// `NS`.
  public static let rows = ModelGrid.ns
  /// The dynamic range: `floor = mx - 50` dB.
  public static let rangeDb = 50.0
  /// A measured frame counts for a slice if it is at most this old (seconds).
  public static let maxFrameAge = 0.25

  /// The LUT index of a cell: scope.js `Math.max(0, Math.min(255, li | 0))` for
  /// `li = (dB - floor) / 50 * 255`. The `| 0` truncates toward zero; NaN and ±infinity are 0
  /// (JS `ToInt32`). Values beyond 2^31 wrap in JS; here they clamp (a cell is at most a few
  /// hundred above the range).
  public static func level(db: Double, floor: Double) -> UInt8 {
    levelOf((db - floor) / rangeDb * 255)
  }

  /// The truncate-and-clamp half of `level`, for an `li` computed elsewhere.
  public static func levelOf(_ li: Double) -> UInt8 {
    guard li.isFinite else { return 0 }
    if li >= 255 { return 255 }
    if li <= 0 { return 0 }
    return UInt8(li)  // truncates toward zero, as `| 0`
  }

  // MARK: model

  /// The model image for the window whose first column is song step `first`. Column `c` shows
  /// step `first + c` if it is valid (`SpectroColumns.isValid`).
  public static func model(first: Int, columns c: SpectroColumns) -> SpectroBitmap {
    let cols = modelColumns
    let ns = rows
    let cap = ModelGrid.specCap
    var mx = -Double.infinity
    for col in 0..<cols {
      let st = first + col
      guard c.isValid(step: st) else { continue }
      let o = (st % cap) * ns
      for j in 0..<ns {
        let v = c.col[o + j]
        if v > 0 {
          let db = 10 * log10(Double(v))
          if db > mx { mx = db }
        }
      }
    }
    let floor = mx - rangeDb
    var levels = [UInt8](repeating: 0, count: cols * ns)
    if mx.isFinite {
      for col in 0..<cols {
        let st = first + col
        guard c.isValid(step: st) else { continue }
        let o = (st % cap) * ns
        for j in 0..<ns {
          let v = c.col[o + j]
          levels[(ns - 1 - j) * cols + col] =
            v > 0 ? level(db: 10 * log10(Double(v)), floor: floor) : 0
        }
      }
    }
    return SpectroBitmap(width: cols, height: ns, levels: levels, peakDb: mx)
  }

  // MARK: measured

  /// Which frame supplies slice `slice` of the measured block, and whether it may be shown:
  /// walk the ring oldest -> newest alongside the slices to the newest frame at or before the
  /// slice's time `tc = t0 + (slice + 1) * win / 160`; it counts only if it is no later than
  /// `tc` and no older than `tc - 0.25 s`. `k` is the frame's place counted from the newest
  /// (1 = newest), nil when the ring is empty or the frame does not qualify.
  public static func measuredFrame(
    forSlice slice: Int, t0: Double, win: Double, in ring: MeasuredFrameRing
  )
    -> Int?
  {
    var walk = FrameWalk(ring: ring)
    return walk.frame(forSlice: slice, t0: t0, win: win)
  }

  /// The ring walk of `drawSpectro`: `k` only ever moves toward the newest.
  private struct FrameWalk {
    let ring: MeasuredFrameRing
    var k: Int

    init(ring: MeasuredFrameRing) {
      self.ring = ring
      k = ring.count
    }

    /// Slices must be asked in increasing order.
    mutating func frame(forSlice c: Int, t0: Double, win: Double) -> Int? {
      guard ring.count > 0 else { return nil }
      let tc = t0 + Double(c + 1) * win / Double(SpectroImage.measuredColumns)
      while k > 1 {
        if ring.time(newest: k - 1) <= tc { k -= 1 } else { break }
      }
      let t = ring.time(newest: k)
      return t <= tc && t >= tc - SpectroImage.maxFrameAge ? k : nil
    }
  }

  /// The measured image for the window `t0 ..< t0 + win` (seconds): 160 slices, each from the
  /// newest frame at or before its time (see `measuredFrame`). `mx` is the loudest cell among
  /// the frames inside the window (time >= t0), which is not the same set as the frames that
  /// supply slices: a slice may show a frame older than `t0` brighter than `mx`, and clamps.
  public static func measured(frames ring: MeasuredFrameRing, t0: Double, win: Double)
    -> SpectroBitmap
  {
    let cols = measuredColumns
    let ns = rows
    var mx = -Double.infinity
    var k = 1
    while k <= ring.count {
      if ring.time(newest: k) < t0 { break }
      for j in 0..<ns {
        let v = Double(ring.value(newest: k, row: j))
        if v > mx { mx = v }
      }
      k += 1
    }
    let floor = mx - rangeDb
    var levels = [UInt8](repeating: 0, count: cols * ns)
    if mx.isFinite {
      var walk = FrameWalk(ring: ring)
      for c in 0..<cols {
        guard let k = walk.frame(forSlice: c, t0: t0, win: win) else { continue }
        for j in 0..<ns {
          levels[(ns - 1 - j) * cols + c] = level(
            db: Double(ring.value(newest: k, row: j)), floor: floor)
        }
      }
    }
    return SpectroBitmap(width: cols, height: ns, levels: levels, peakDb: mx)
  }
}
