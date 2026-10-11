// Raster layout: the pure geometry of scope.js `drawRaster`, so the numbers can be tested
// without drawing. All sizes are in points (CSS pixels in the JS); y grows downward.
//
//   gut = 64 | pw = W - gut      lanes: lh = (H - top - axisH) / L   top = 14, axisH = 14
//   x(step) = gut + step / total * pw            total = max(1, steps)
//
// Operation order follows the JS expression by expression (`vel / 127 * lh * 0.8`,
// `0.76 * (note - lo) / span`), so the floating-point results are the same.

import Foundation

/// A rectangle in points.
public struct RasterRect: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
}

/// A line of text and where its top-left corner goes (the JS draws with `textBaseline = 'top'`).
public struct RasterLabel: Equatable, Sendable {
  public var text: String
  public var x: Double
  public var y: Double

  public init(text: String, x: Double, y: Double) {
    self.text = text
    self.x = x
    self.y = y
  }
}

public struct RasterLayout: Equatable, Sendable {
  /// Left gutter for the lane names.
  public static let gut = 64.0
  /// Space above the plot (section names, loop label).
  public static let top = 14.0
  /// Space under the plot (bar numbers).
  public static let axisH = 14.0
  /// Candidates for the bar-number step; 128 when none is wide enough.
  public static let labelSteps = [1, 2, 4, 8, 16, 32, 64]

  public let width: Double
  public let height: Double
  /// Number of lanes drawn.
  public let laneCount: Int
  /// `max(1, r.steps)`.
  public let total: Double

  public init(width: Double, height: Double, laneCount: Int, steps: Int) {
    self.width = width
    self.height = height
    self.laneCount = laneCount
    total = Double(max(1, steps))
  }

  public var gut: Double { Self.gut }
  public var top: Double { Self.top }
  public var axisH: Double { Self.axisH }
  /// Plot width.
  public var pw: Double { width - gut }
  /// Plot height: `H - top - axisH`.
  public var plotHeight: Double { height - top - axisH }
  /// Height of one lane (0 without lanes).
  public var lh: Double { laneCount > 0 ? plotHeight / Double(laneCount) : 0 }
  /// Bars in the raster (fractional if `steps` is not a multiple of 16).
  public var bars: Double { total / 16 }
  public var pxBar: Double { pw / max(1, bars) }

  /// A bar line every bar when a bar is at least 6 px wide, every 4 bars from 1.5 px, else every
  /// 16.
  public var lineEvery: Int { pxBar >= 6 ? 1 : pxBar >= 1.5 ? 4 : 16 }

  /// The first of 1, 2, 4 ... 64 bars that spans at least 26 px, else 128.
  public var labelEvery: Int { Self.labelSteps.first { Double($0) * pxBar >= 26 } ?? 128 }

  /// scope.js `xs`.
  public func x(step: Double) -> Double { gut + step / total * pw }

  // MARK: grid

  public struct BarLine: Equatable, Sendable {
    public var bar: Int
    /// A 1 px wide line at `Math.round(x)`, over the plot height.
    public var rect: RasterRect
    /// Every fourth bar (from 0): the bar-line colour; the others use the grid colour.
    public var major: Bool
  }

  /// Bar lines `b = 0, lineEvery, 2·lineEvery ... <= bars`.
  public func barLines() -> [BarLine] {
    var out: [BarLine] = []
    var b = 0
    while Double(b) <= bars {
      let x = jsRound(self.x(step: Double(b * 16)))
      out.append(
        BarLine(
          bar: b, rect: RasterRect(x: x, y: top, w: 1, h: plotHeight), major: b % 4 == 0))
      b += lineEvery
    }
    return out
  }

  /// Bar numbers (1-based) under the plot, every `labelEvery` bars from the first.
  public func axisLabels() -> [RasterLabel] {
    var out: [RasterLabel] = []
    var b = 0
    while Double(b) < bars {
      out.append(
        RasterLabel(
          text: String(b + 1), x: x(step: Double(b * 16)) + 2, y: height - axisH + 2))
      b += labelEvery
    }
    return out
  }

  /// The 1 px grid line above lane `l`: from the gutter to the right edge at `Math.round(y)`.
  public func laneSeparator(_ l: Int) -> RasterRect {
    RasterRect(x: gut, y: jsRound(top + Double(l) * lh), w: pw, h: 1)
  }

  /// The lane's name: its first 9 characters, at `(2, y + max(0, lh / 2 - 5))`.
  public func laneLabel(_ l: Int, key: String) -> RasterLabel {
    let y = top + Double(l) * lh
    return RasterLabel(
      text: String(decoding: Array(key.utf16.prefix(9)), as: UTF16.self), x: 2,
      y: y + max(0, lh / 2 - 5))
  }

  // MARK: events

  /// The mark of one event on lane `lane`, or nil when it has no finite position.
  ///
  /// A drum is a 1 px spike, `vel / 127 · 0.8` of the lane high, standing on the lane's floor; a
  /// pitched note is a 2 px bar at its place in the lane's note range (`0.12 + 0.76·frac` of the
  /// lane up), as long as the note, at least 1 px.
  public func eventRect(
    step: Int, lane: Int, note: Int, vel: Int, dur: Double, drum: Bool, lo: Int, hi: Int
  ) -> RasterRect? {
    let x = self.x(step: Double(step))
    let yb = top + Double(lane + 1) * lh
    if drum {
      let h = Double(vel) / 127 * lh * 0.8
      return RasterRect(x: x, y: yb - h - 1, w: 1, h: h)
    }
    let span = Double(max(1, hi - lo))
    let y = yb - lh * (0.12 + 0.76 * Double(note - lo) / span)
    let w = max(1, dur / total * pw)
    guard y.isFinite else { return nil }
    return RasterRect(x: x, y: y - 1, w: w, h: 2)
  }

  // MARK: markers

  /// Loop projects: the marker at the left edge of the plot (drawn in the section colour).
  public func loopMarker() -> RasterRect {
    RasterRect(x: gut - 1, y: top - 2, w: 2, h: plotHeight + 2)
  }

  /// `loop · N bar cycle` / `loop · no repeat in N bars` at `(gut + 3, 1)`.
  public func loopLabel(cycle: Int) -> RasterLabel {
    let n = Self.numberText(bars)
    return RasterLabel(
      text: cycle > 0 ? "loop · \(n) bar cycle" : "loop · no repeat in \(n) bars", x: gut + 3,
      y: 1)
  }

  /// A section start inside the raster: a 2 px marker at `Math.round(x) - 1` and its name.
  public struct SectionMark: Equatable, Sendable {
    public var rect: RasterRect
    public var label: RasterLabel
  }

  /// Sections that start before the end of the raster.
  public func sectionMarks(_ sections: [ScopeSection]) -> [SectionMark] {
    var out: [SectionMark] = []
    for sec in sections where Double(sec.step) < total {
      let x = self.x(step: Double(sec.step))
      out.append(
        SectionMark(
          rect: RasterRect(x: jsRound(x) - 1, y: top - 2, w: 2, h: plotHeight + 2),
          label: RasterLabel(text: sec.name, x: x + 3, y: 1)))
    }
    return out
  }

  /// `no music parts` / `raster unavailable`, shown inside the plot.
  public func emptyLabel(failed: Bool) -> RasterLabel {
    RasterLabel(
      text: failed ? "raster unavailable" : "no music parts", x: gut + 6, y: top + 4)
  }

  // MARK: playhead

  /// The playhead: a 1 px column over the plot (white, 80 % opaque). `tick` and `phase` are the
  /// engine's published tick counter and the fraction of the current tick elapsed. While the
  /// transport plays the head is `tick + phase` (the JS: `_tick + min(6, elapsed / tickMs)`),
  /// stopped it rests at `tick`; with the transport stopped at tick 0 there is none.
  public func playheadRect(tick: Int, phase: Double, playing: Bool) -> RasterRect? {
    guard playing || tick > 0 else { return nil }
    var est = Double(tick)
    if playing { est += min(6, max(0, phase.isFinite ? phase : 0)) }
    let x = gut + est.truncatingRemainder(dividingBy: total) / total * pw
    guard x.isFinite else { return nil }
    return RasterRect(x: x, y: top, w: 1, h: plotHeight)
  }

  // MARK: text

  /// A number as JS prints it: no decimals for a whole number (`12`, not `12.0`).
  public static func numberText(_ d: Double) -> String {
    if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
    return String(d)
  }

  /// The status line (scope.js `updateStatus`), for a finished raster.
  public static func statusText(_ r: RasterResult) -> String {
    if r.failed { return "raster unavailable\(r.error.isEmpty ? "" : " — " + r.error)" }
    var text = "raster · "
    if r.loop { text += r.cycle > 0 ? "loop cycle · " : "loop (no repeat) · " }
    text += "\(r.count) events · \(numberText(Double(r.steps) / 16)) bars · \(r.ms) ms"
    if r.dropped > 0 { text += " · \(r.dropped) dropped" }
    return text
  }
}
