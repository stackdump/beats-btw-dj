import DJCore
import SwiftUI

/// Where step `i` of an `n`-step ring sits: 12 o'clock first, clockwise.
public enum RingGeometry {
  public static func position(_ i: Int, of n: Int, size: CGFloat, inset: CGFloat) -> CGPoint {
    let a = Double(i) / Double(max(n, 1)) * 2 * .pi
    let r = size / 2 - inset
    return CGPoint(x: size / 2 + CGFloat(sin(a)) * r, y: size / 2 - CGFloat(cos(a)) * r)
  }

  /// Radius of the dot of a step that rests / fires: the ring's `base` is
  /// `max(1.5, min(5, size / n * 0.9))`.
  public static func baseRadius(steps n: Int, size: CGFloat) -> CGFloat {
    max(1.5, min(5, size / CGFloat(max(n, 1)) * 0.9))
  }
}

extension Color {
  /// `#rrggbb` as an sRGB colour (the ring's chrome colours are beats' CSS values).
  fileprivate init(rgb8 c: (r: Int, g: Int, b: Int), opacity: Double = 1) {
    self.init(
      .sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255,
      opacity: opacity)
  }
}

/// One ring net: a dot per place (bigger and brighter where a note is bound), the token
/// as a bright disc, and the step that just fired flashing as the tick elapses.
///
/// Beyond the dots (SPEC mode 22, canvas.js `drawRing`, petri-note.css `.playhead`):
///  * the step that fired last keeps a `#ffd36a` ring with a soft glow until the next one
///    fires, drawn over the flash;
///  * with `arcs`, the net's arcs are drawn under the dots (`#4a90d9`), dimmed while the deck
///    plays and turned by the Auto-DJ swing. Without them the ring is dots only. The Swift
///    ring has no arc layer of its own: the arcs are the chords from each step to the next,
///    which is what a ring net's arcs project to.
public struct RingNetView: View {
  public var ring: RingView
  public var tint: Color
  public var arcs: RingArcs?
  /// The app's hub, for the perf monitor (SPEC mode 27): the draw is timed as the `ring` path.
  @Environment(\.scopeHub) private var hub

  public init(ring: RingView, tint: Color, arcs: RingArcs? = nil) {
    self.ring = ring
    self.tint = tint
    self.arcs = arcs
  }

  public var body: some View {
    let hub = hub
    Canvas { ctx, size in
      let span = VizSpan(hub, .ring)
      defer { span.end() }
      let s = min(size.width, size.height)
      let n = ring.size
      let dim = ring.muted ? 0.35 : 1.0
      let base = RingGeometry.baseRadius(steps: n, size: s)
      if let arcs { drawArcs(&ctx, arcs, n: n, size: s, base: base, dim: dim) }
      for i in 0..<n {
        let p = RingGeometry.position(i, of: n, size: s, inset: 6)
        let hit = ring.hits[i]
        let r = hit ? base * (1.2 + CGFloat(ring.velocities[i]) / 127 * 0.8) : base * 0.55
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.fill(
          Path(ellipseIn: rect), with: .color(hit ? tint.opacity(dim) : .gray.opacity(0.4 * dim)))
      }
      if ring.lastFired >= 0 {
        let p = RingGeometry.position(ring.lastFired, of: n, size: s, inset: 6)
        let flash = (1 - ring.phase) * dim
        let r = base * 2.4
        ctx.fill(
          Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
          with: .color(.white.opacity(flash * (ring.hits[ring.lastFired] ? 0.9 : 0.25))))
        drawPlayhead(&ctx, at: p, base: base, dim: dim)
      }
      let t = RingGeometry.position(ring.token, of: n, size: s, inset: 6)
      let tr = base * 1.6
      ctx.stroke(
        Path(ellipseIn: CGRect(x: t.x - tr, y: t.y - tr, width: 2 * tr, height: 2 * tr)),
        with: .color(.white.opacity(dim)), lineWidth: 2)
    }
    .aspectRatio(1, contentMode: .fit)
  }

  /// The persistent playhead: a `#ffd36a` ring round the last-fired step with an outer glow
  /// and a faint glow inside.
  private func drawPlayhead(_ ctx: inout GraphicsContext, at p: CGPoint, base: CGFloat, dim: Double)
  {
    let b = Double(base)
    let r = CGFloat(RingPlayhead.radius(base: b))
    let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    let inner = CGFloat(RingPlayhead.innerGlowRadius(base: b))
    ctx.fill(
      circle,
      with: .radialGradient(
        Gradient(stops: [
          .init(color: Color(rgb8: RingPlayhead.rgb8, opacity: 0), location: max(0, 1 - inner / r)),
          .init(
            color: Color(rgb8: RingPlayhead.rgb8, opacity: RingPlayhead.innerGlowAlpha * dim),
            location: 1),
        ]), center: p, startRadius: 0, endRadius: r))
    ctx.drawLayer { layer in
      layer.addFilter(
        .shadow(
          color: Color(rgb8: RingPlayhead.rgb8, opacity: RingPlayhead.outerGlowAlpha * dim),
          radius: CGFloat(RingPlayhead.outerGlowRadius(base: b)), x: 0, y: 0))
      layer.stroke(
        circle, with: .color(Color(rgb8: RingPlayhead.rgb8, opacity: dim)),
        lineWidth: CGFloat(RingPlayhead.lineWidth(base: b)))
    }
  }

  /// The arc layer: a chord from each step to the next, `#4a90d9`, an arrowhead on those long
  /// enough to carry one, all turned about the ring's centre by `arcs.angleDegrees`. A muted
  /// ring's arcs are as faint as its dots (`dim`).
  private func drawArcs(
    _ ctx: inout GraphicsContext, _ arcs: RingArcs, n: Int, size s: CGFloat, base: CGFloat,
    dim: Double
  ) {
    guard n > 1 else { return }
    var layer = ctx
    layer.opacity = arcs.alpha * dim
    layer.translateBy(x: s / 2, y: s / 2)
    layer.rotate(by: .degrees(arcs.angleDegrees))
    layer.translateBy(x: -s / 2, y: -s / 2)
    let color = Color(.sRGB, red: 74 / 255, green: 144 / 255, blue: 217 / 255, opacity: 1)
    let width = CGFloat(arcs.lineWidth())
    var lines = Path()
    var heads = Path()
    let chord = 2 * (s / 2 - 6) * sin(.pi / CGFloat(n))
    // drawArrowhead: wings at +-30 degrees from a tip set back from the target dot
    let headLen = RingArcs.headLength(chord: Double(chord), base: Double(base)).map { CGFloat($0) }
    let setBack = CGFloat(RingArcs.tipSetBack(base: Double(base)))
    let wing = CGFloat(RingArcs.wingAngle)
    for i in 0..<n {
      var a = RingGeometry.position(i, of: n, size: s, inset: 6)
      var b = RingGeometry.position((i + 1) % n, of: n, size: s, inset: 6)
      lines.move(to: a)
      lines.addLine(to: b)
      guard let headLen else { continue }
      if arcs.reverseArrows { swap(&a, &b) }
      let angle = atan2(b.y - a.y, b.x - a.x)
      let tip = CGPoint(x: b.x - cos(angle) * setBack, y: b.y - sin(angle) * setBack)
      for side in [-wing, wing] {
        heads.move(to: tip)
        heads.addLine(
          to: CGPoint(
            x: tip.x - headLen * cos(angle + side), y: tip.y - headLen * sin(angle + side)))
      }
    }
    layer.stroke(lines, with: .color(color), lineWidth: width)
    layer.stroke(heads, with: .color(color), lineWidth: width)
  }
}

/// Every audible ring of a net deck, labelled by role.
public struct NetRingsView: View {
  public var snapshot: NetSnapshot?
  public var tint: Color
  public var arcs: RingArcs?

  public init(snapshot: NetSnapshot?, tint: Color, arcs: RingArcs? = nil) {
    self.snapshot = snapshot
    self.tint = tint
    self.arcs = arcs
  }

  public var body: some View {
    let rings = snapshot?.rings ?? []
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
      ForEach(rings, id: \.role) { r in
        VStack(spacing: 1) {
          RingNetView(ring: r, tint: tint, arcs: arcs)
          Text(r.role).font(.system(size: 9)).foregroundStyle(r.muted ? .secondary : .primary)
        }
      }
    }
  }
}
