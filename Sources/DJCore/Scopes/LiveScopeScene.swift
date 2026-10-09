// LiveScopeScene: every rect, line and label of one frame of the Scope / Live view, in the order
// scope.js `draw` -> `drawLive` paints them (the background is the host's):
//
//   grid lines + bar numbers + section markers     (`drawGrid`, labels on)
//   envelope: one rect per pixel column            rgba(74,144,217,0.6)
//   RMS: two polylines, -rms then +rms             #f5a623, 1.2 wide
//   corner label `x · ±peak`, empty-state label
//   lane separators                                 GRID
//   events, newest first                            lane colour
//   lane labels on dark plates                      (only when a lane is >= 8 high)
//
// Pure numbers: no SwiftUI. `LiveScopeScene.make` is a function of its arguments, so the geometry
// is pinned by unit tests without an engine. All coordinates are canvas points, y down.
//
// A stopped song. The JS stops its loop when the transport stops and holds the last picture; the
// engine here keeps running, "now" with it, and the waveform and the hits are measured against
// that time, so they go on scrolling (a tail, silence, or whatever else is on the master). The
// GRID is different: it is the song's, extrapolated from the newest anchor at `tickSec` a step,
// and a song that has stopped has no steps after its newest anchor. With `running == false` the
// grid, its bar numbers and the section markers end at that anchor's step instead of counting on.

import Foundation

public struct LiveScopeRect: Equatable, Sendable {
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

public struct LiveScopePoint: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// A piece of text; `x`, `y` are its top-left (`textBaseline = 'top'`).
public struct LiveScopeText: Equatable, Sendable {
  public var text: String
  public var x: Double
  public var y: Double

  public init(_ text: String, x: Double, y: Double) {
    self.text = text
    self.x = x
    self.y = y
  }
}

public struct LiveScopeScene: Sendable {
  /// scope.js `axisH`: the strip under the lanes that holds the bar numbers.
  public static let axisHeight = 12.0

  /// A beat line (every 4 steps): a 1 px wide rect, in BARLINE colour if it is a bar line.
  public struct GridLine: Equatable, Sendable {
    public var rect: LiveScopeRect
    public var bar: Bool
  }

  /// A section start: a 2 px SECTION-coloured rect and its name (drawn in the same colour).
  public struct SectionMark: Equatable, Sendable {
    public var rect: LiveScopeRect
    public var name: LiveScopeText
  }

  /// One hit: a rect in its lane's colour.
  public struct Event: Equatable, Sendable {
    public var lane: Int
    public var rect: LiveScopeRect
  }

  /// A lane's name. The plate is `rgba(5,10,20,0.7)`, from `plateX`, `y`, as wide as the text
  /// plus 4 (the view measures the text), `plateHeight` tall; the text sits at `textX`, `y`.
  public struct LaneLabel: Equatable, Sendable {
    public var text: String
    public var lane: Int
    public var color: ScopeColor
    public var plateX: Double
    public var textX: Double
    public var y: Double
    public var plateHeight: Double
  }

  public var width: Double
  public var height: Double
  /// Is there a usable time axis? When not, nothing but the background is drawn.
  public var ok = false
  /// Height of the waveform band: `round((H - 12) * 0.5)`; the lanes start 2 below it.
  public var hTop = 0.0
  /// Centre line of the waveform: `hTop / 2`.
  public var mid = 0.0
  /// Pixels per unit of signal, `(hTop / 2 - 3) / disp`.
  public var scale = 1.0

  public var gridLines: [GridLine] = []
  /// Bar numbers `st / 16 + 1`, drawn in TEXT colour 1 px under the grid.
  public var barLabels: [LiveScopeText] = []
  public var sections: [SectionMark] = []
  /// Per pixel column: x, top, 1 wide, `max(1, h)` tall. Filled `rgba(74,144,217,0.6)`.
  public var envelope: [LiveScopeRect] = []
  /// The lower RMS line (sign -1: `mid + rms * sc`), stroked first.
  public var rmsLower: [LiveScopePoint] = []
  /// The upper RMS line (sign +1: `mid - rms * sc`).
  public var rmsUpper: [LiveScopePoint] = []
  /// `x · ±0.xx` at `(W - 70, 2)`, TEXT colour. The number is the PEAK, not the displayed scale.
  public var corner: LiveScopeText?
  /// `waiting for audio…` / `press play` at `(6, mid - 5)` while no block exists.
  public var emptyMessage: LiveScopeText?

  /// Top of the first lane, `hTop + 2`, and a lane's height `(H - 12 - top) / L`; 0 without lanes.
  public var laneTop = 0.0
  public var laneHeight = 0.0
  /// GRID-coloured separators, full width, 1 px tall: `round(laneTop + l * laneHeight)`.
  public var laneLines: [LiveScopeRect] = []
  /// The colour of each lane (index = `Event.lane`), as the lanes of the feed have them.
  public var laneColors: [ScopeColor] = []
  /// Newest first, the order the JS paints them.
  public var events: [Event] = []
  public var laneLabels: [LaneLabel] = []

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }

  /// Build the frame. `axis` is `feed.timeAxis(x0: 0, w: width)`, `columns` the reduction of the
  /// block ring over it, `gain` the auto-gain state this frame draws with. `running` is the
  /// transport (`feed.clock.playing`, scope.js `s.running`): it picks the empty-state message and
  /// ends the grid at the newest anchor while the song is not running (see the header).
  public static func make(
    width: Double, height: Double, axis ax: ScopeTimeAxis, columns: LiveScopeColumns,
    gain: LiveScopeGain, lanes: [ScopeLane], fires: ScopeFireLog, sections: [ScopeSection],
    hasBlocks: Bool, running: Bool
  ) -> LiveScopeScene {
    var s = LiveScopeScene(width: width, height: height)
    let axisH = axisHeight
    s.hTop = jsRound((height - axisH) * 0.5)
    guard ax.ok else { return s }
    s.ok = true
    s.mid = s.hTop / 2
    s.scale = gain.scale(hTop: s.hTop)
    s.addGrid(axis: ax, y0: 0, y1: height - axisH, sections: sections, running: running)
    s.addWaveform(columns: columns)
    s.corner = LiveScopeText("x · ±" + toFixed2(gain.peak), x: width - 70, y: 2)
    if !hasBlocks {
      s.emptyMessage = LiveScopeText(
        running ? "waiting for audio…" : "press play", x: 6, y: s.mid - 5)
    }
    s.addLanes(axis: ax, lanes: lanes, fires: fires)
    return s
  }

  /// JS `x.toFixed(2)` for a finite `x >= 0`. Both work from the exact value of the double; they
  /// differ only on an exact tie (an odd multiple of 1/8), which `toFixed` sends to the larger
  /// neighbour, `(0.125).toFixed(2) == "0.13"`, and printf to the even one, "0.12".
  static func toFixed2(_ x: Double) -> String {
    let scaled = x * 100  // exact for a tie: x is j/8, so x * 100 is j * 12.5
    if x.isFinite, x * 8 == (x * 8).rounded(), scaled != scaled.rounded() {
      return String(format: "%.2f", (scaled.rounded(.down) + 1) / 100)
    }
    return String(format: "%.2f", x)
  }

  // drawGrid(s, ctx, ax, 0, height - axisH, true)
  private mutating func addGrid(
    axis ax: ScopeTimeAxis, y0: Double, y1: Double, sections secs: [ScopeSection], running: Bool
  ) {
    guard ax.hasAnchor else { return }
    let sA = (ax.stepOf(ax.t0) / 4).rounded(.up) * 4
    // a song that is not running has no step after its newest anchor (`aS`, the anchor at or
    // before "now", is that anchor once the song has stopped); the JS never drew such a frame
    let sB = running ? ax.stepOf(ax.tNow) : Swift.min(ax.stepOf(ax.tNow), ax.aS)
    guard sA.isFinite, sB.isFinite, sB - sA <= 4096 else { return }
    var st = sA
    while st <= sB {
      defer { st += 4 }
      let x = ax.xOf(ax.timeOf(st))
      guard x.isFinite else { continue }
      let bar = st.truncatingRemainder(dividingBy: 16) == 0
      gridLines.append(
        GridLine(rect: LiveScopeRect(x: jsRound(x), y: y0, w: 1, h: y1 - y0), bar: bar))
      if bar && st >= 0 {
        let n = st / 16 + 1
        barLabels.append(
          LiveScopeText(abs(n) < 1e15 ? String(Int(n)) : String(n), x: x + 3, y: y1 + 1))
      }
    }
    let left = ax.stepOf(ax.t0)
    for sec in secs {
      let step = Double(sec.step)
      if step < left || step > sB { continue }
      let x = ax.xOf(ax.timeOf(step))
      guard x.isFinite else { continue }
      sections.append(
        SectionMark(
          rect: LiveScopeRect(x: jsRound(x) - 1, y: y0, w: 2, h: y1 - y0),
          name: LiveScopeText(sec.name, x: x + 4, y: y0 + 2)))
    }
  }

  // the envelope and RMS part of drawLive
  private mutating func addWaveform(columns c: LiveScopeColumns) {
    let sc = scale
    for x in 0..<c.count where c.blocks[x] > 0 {
      let top = mid - Double(c.hi[x]) * sc
      let h = (Double(c.hi[x]) - Double(c.lo[x])) * sc
      if top.isFinite && h.isFinite {
        envelope.append(LiveScopeRect(x: Double(x), y: top, w: 1, h: Swift.max(1, h)))
      }
    }
    for sign in [-1.0, 1.0] {
      var pts: [LiveScopePoint] = []
      for x in 0..<c.count where c.blocks[x] > 0 {
        let y = mid - sign * (Double(c.sq[x]) / Double(c.blocks[x])).squareRoot() * sc
        if y.isFinite { pts.append(LiveScopePoint(x: Double(x), y: y)) }
      }
      if sign < 0 { rmsLower = pts } else { rmsUpper = pts }
    }
  }

  // the lanes part of drawLive
  private mutating func addLanes(axis ax: ScopeTimeAxis, lanes: [ScopeLane], fires: ScopeFireLog) {
    let laneCount = lanes.count
    guard laneCount > 0 else { return }
    let ly0 = hTop + 2
    let lh = (height - Self.axisHeight - ly0) / Double(laneCount)
    laneTop = ly0
    laneHeight = lh
    laneColors = lanes.map(\.color)
    for l in 0...laneCount {
      laneLines.append(LiveScopeRect(x: 0, y: jsRound(ly0 + Double(l) * lh), w: width, h: 1))
    }
    fires.forEachNewestFirst { f in
      let t = f.time
      if t < ax.t0 - 4 { return false }
      if t > ax.tNow { return true }
      guard lanes.indices.contains(f.lane) else { return true }
      let lane = lanes[f.lane]
      let x = ax.xOf(t)
      let yb = ly0 + Double(f.lane + 1) * lh
      if lane.drum {
        let h = Double(f.velocity) / 127 * lh * 0.85
        if x.isFinite && x >= 0 {
          events.append(Event(lane: f.lane, rect: LiveScopeRect(x: x, y: yb - h, w: 1.5, h: h)))
        }
      } else {
        let span = Swift.max(1, Double(lane.hi - lane.lo))
        let y = yb - lh * (0.1 + 0.8 * Double(f.note - lane.lo) / span)
        var w = f.durSec / ax.win * width
        let xs = Swift.max(0, x)
        w = Swift.min(w - (xs - x), ax.w - xs)
        if y.isFinite && w.isFinite && w > 0 {
          events.append(
            Event(
              lane: f.lane, rect: LiveScopeRect(x: xs, y: y - 1, w: Swift.max(1.5, w - 1), h: 2)))
        }
      }
      return true
    }
    if lh >= 8 {
      // on the master the lanes of both decks are in one list, usually the same parts twice: say
      // which deck a lane is (the JS has one deck)
      let deckNamed = Set(lanes.map(\.deck)).count > 1
      for (l, lane) in lanes.enumerated() {
        laneLabels.append(
          LaneLabel(
            text: deckNamed ? "\(lane.deck)·\(lane.key)" : lane.key, lane: l, color: lane.color,
            plateX: 2, textX: 4,
            y: ly0 + Double(l) * lh + 1, plateHeight: Swift.min(11, lh - 1)))
      }
    }
  }
}
