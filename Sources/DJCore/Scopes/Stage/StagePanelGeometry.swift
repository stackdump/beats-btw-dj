import Foundation

// Panel drawing numbers shared by the constellation (SPEC mode 7): the arrowhead of an arc and the
// scale pulse of a node that just fired. Pure, so each constant is pinned by a test.

/// The arrowhead of a panel arc (canvas.js `drawArrowhead`, used by stage.js `drawPanel`): the
/// tip sits `offset` back from the target's centre along the arc, the barbs are `headLength`
/// long at +-30 degrees.
public enum StageArcArrow {
  public static let headLength = 12.0
  /// Reaches the edge of the target node (a place is 50 wide).
  public static let offset = 25.0

  public struct Head: Equatable, Sendable {
    public var tipX: Double
    public var tipY: Double
    public var leftX: Double
    public var leftY: Double
    public var rightX: Double
    public var rightY: Double
  }

  public static func head(x1: Double, y1: Double, x2: Double, y2: Double) -> Head {
    let angle = atan2(y2 - y1, x2 - x1)
    let tx = x2 - cos(angle) * offset
    let ty = y2 - sin(angle) * offset
    return Head(
      tipX: tx, tipY: ty,
      leftX: tx - headLength * cos(angle - Double.pi / 6),
      leftY: ty - headLength * sin(angle - Double.pi / 6),
      rightX: tx - headLength * cos(angle + Double.pi / 6),
      rightY: ty - headLength * sin(angle + Double.pi / 6))
  }
}

extension StagePanel {
  /// `.pn-transition.firing { animation: pulse 0.1s ease-out }` with
  /// `@keyframes pulse { 0% scale(1); 50% scale(1.1); 100% scale(1) }`: the scale of a lit node,
  /// `1` when it is not lit. `ease-out` is applied between keyframes.
  public func pulseScale(transition i: Int, now: Double) -> Double {
    let flash = flash(transition: i, now: now)
    if flash <= 0 { return 1 }
    let p = 1 - flash  // 0 at the fire, 1 when the 100 ms are over
    if p < 0.5 { return 1 + 0.1 * StageFade.easeOut(p / 0.5) }
    return 1.1 - 0.1 * StageFade.easeOut((p - 0.5) / 0.5)
  }
}
