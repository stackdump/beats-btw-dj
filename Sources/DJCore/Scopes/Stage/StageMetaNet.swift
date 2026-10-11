import Foundation

// The Stage as ONE Petri net (SPEC mode 8): N square transitions (each a live sub-ring panel)
// alternating with N small place circles on an inner ring, closed by 2N arcs
// `t_i -> p_i -> t_(i+1)`. stage.js `renderMetaNet` + `edge`, as numbers; the view just strokes
// them. Drawn for 2...16 panels (`StageRingLayout.showsMeta`).

/// A line with an arrowhead, in stage coordinates.
public struct StageEdge: Equatable, Sendable {
  public var x1: Double
  public var y1: Double
  public var x2: Double
  public var y2: Double
  /// The two barbs of the head, from `(x2, y2)` back to these points.
  public var hx1: Double
  public var hy1: Double
  public var hx2: Double
  public var hy2: Double
}

public enum StageMetaNet {
  public static let arcOpacity = 0.35
  /// Place circle stroke opacity: `arcOpacity + 0.1`.
  public static let placeStrokeOpacity = 0.45
  /// Place circle fill: rgba(74,144,217,0.06).
  public static let placeFillAlpha = 0.06
  public static let headLength = 12.0

  /// stage.js `edge(a, b, aInset, bInset)`: a line from `a` to `b` that starts `aInset` out from
  /// `a` and ends `bInset` short of `b` (so it meets each shape's outline, not its centre), with a
  /// head of `headLength` at +-30 degrees on the end.
  public static func edge(_ a: StagePoint, _ b: StagePoint, aInset: Double, bInset: Double)
    -> StageEdge
  {
    let dx = b.x - a.x
    let dy = b.y - a.y
    var len = hypot(dx, dy)
    if len == 0 { len = 1 }
    let ux = dx / len
    let uy = dy / len
    let x1 = a.x + ux * aInset
    let y1 = a.y + uy * aInset
    let x2 = b.x - ux * bInset
    let y2 = b.y - uy * bInset
    let ang = atan2(uy, ux)
    return StageEdge(
      x1: x1, y1: y1, x2: x2, y2: y2,
      hx1: x2 - headLength * cos(ang - Double.pi / 6),
      hy1: y2 - headLength * sin(ang - Double.pi / 6),
      hx2: x2 - headLength * cos(ang + Double.pi / 6),
      hy2: y2 - headLength * sin(ang + Double.pi / 6))
  }

  /// The 2N arcs, in stage.js order: for each place `i`, `t_i -> p_i` then `p_i -> t_(i+1)`.
  /// A transition is a square of `side`, a place a circle of `placeR`. Empty when the layout has
  /// no meta-net.
  public static func edges(layout: StageRingLayout) -> [StageEdge] {
    guard layout.showsMeta, let placeR = layout.placeR else { return [] }
    let transitions = layout.panelCenters
    let places = layout.placeCenters
    let half = layout.side / 2
    var out: [StageEdge] = []
    out.reserveCapacity(places.count * 2)
    for i in 0..<places.count {
      let a = transitions[i]
      let p = places[i]
      let b = transitions[(i + 1) % transitions.count]
      out.append(edge(a, p, aInset: half, bInset: placeR))
      out.append(edge(p, b, aInset: placeR, bInset: half))
    }
    return out
  }
}
