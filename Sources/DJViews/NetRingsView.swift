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

  /// How far the step centres sit from the canvas edge: the largest mark drawn on a step has
  /// to fit, or the Canvas clips it (the old fixed 6 pt cut a few-step ring's dots flat). The
  /// biggest are the playhead (its radius, half its stroke and two sigma of its glow) and the
  /// flash (`base * 2.4`); a full-velocity hit is `base * 2`, the token `base * 1.6` + 1.
  public static func inset(base: CGFloat) -> CGFloat {
    let b = Double(base)
    let playhead =
      RingPlayhead.radius(base: b) + RingPlayhead.lineWidth(base: b) / 2 + 2
      * RingPlayhead.outerGlowRadius(base: b)
    return (max(CGFloat(playhead), base * 2.4, base * 1.6 + 1)).rounded(.up) + 1
  }

  /// The share of the gap between neighbouring step centres a full-velocity hit (2 x base
  /// radius, so 4 x base across) may fill: the rest is clear space between the dots.
  public static let dotFill: CGFloat = 0.8

  /// The smallest `base` a small ring (under `smallRing` pt: the 30 pt stingers) is fitted
  /// down to, below `baseRadius`'s 1.5 pt floor, so its hits stay apart too. Rings in the parts
  /// grid keep the 1.5 pt floor: smaller dots there would make room for arc heads on dense
  /// rings, which are kept off them.
  public static let minFittedBase: CGFloat = 0.75
  public static let smallRing: CGFloat = 48

  /// The `base` a ring is drawn with: `baseRadius`, shrunk where full-velocity hits on
  /// neighbouring steps would touch (few steps in a small cell, e.g. an 8-step hihat in the
  /// deck's 62 pt grid, or any stinger ring). The inset shrinks with the base, which widens the
  /// gap again, so the fit is repeated until it settles (a few passes); it never grows past
  /// `baseRadius`, and every pass's base fits the gap its own inset leaves.
  public static func fittedBase(steps n: Int, size: CGFloat) -> CGFloat {
    let base = baseRadius(steps: n, size: size)
    guard n > 1 else { return base }
    func fit(_ b: CGFloat) -> CGFloat {
      let r = max(0, size / 2 - inset(base: b))
      let gap = 2 * r * CGFloat(sin(Double.pi / Double(n)))
      return min(base, gap * dotFill / 4)
    }
    var b = base
    for _ in 0..<6 {
      let next = fit(b)
      if abs(next - b) < 0.01 { break }
      b = next
    }
    // settle on a base that fits the gap its own inset leaves (the last pass may overshoot)
    let floor = size < smallRing ? minFittedBase : 1.5
    while b > floor && fit(b) < b - 0.001 { b -= 0.05 }
    return max(floor, b)
  }

  /// Step `i` placed with the inset its ring's marks need.
  public static func position(_ i: Int, of n: Int, size: CGFloat) -> CGPoint {
    position(i, of: n, size: size, inset: inset(base: fittedBase(steps: n, size: size)))
  }

  /// How far a ring drawn with `inset` reaches past its square: the fired step's flash
  /// (2.4 × base, the largest thing it draws) round a dot `inset` in from the edge.
  public static func overflow(steps n: Int, size: CGFloat, inset: CGFloat = 6) -> CGFloat {
    max(0, baseRadius(steps: n, size: size) * 2.4 - inset)
  }

  /// The most any ring overflows (base is at most 5 pt): what a layout leaves round one so its
  /// flash never lands on a label or the next ring.
  public static let maxOverflow: CGFloat = 5 * 2.4 - 6
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
      let base = RingGeometry.fittedBase(steps: n, size: s)
      let inset = RingGeometry.inset(base: base)
      if let arcs { drawArcs(&ctx, arcs, n: n, size: s, base: base, dim: dim) }
      for i in 0..<n {
        let p = RingGeometry.position(i, of: n, size: s, inset: inset)
        let hit = ring.hits[i]
        let r = hit ? base * (1.2 + CGFloat(ring.velocities[i]) / 127 * 0.8) : base * 0.55
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.fill(
          Path(ellipseIn: rect), with: .color(hit ? tint.opacity(dim) : .gray.opacity(0.4 * dim)))
      }
      if ring.lastFired >= 0 {
        let p = RingGeometry.position(ring.lastFired, of: n, size: s, inset: inset)
        let flash = (1 - ring.phase) * dim
        let r = base * 2.4
        ctx.fill(
          Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
          with: .color(.white.opacity(flash * (ring.hits[ring.lastFired] ? 0.9 : 0.25))))
        drawPlayhead(&ctx, at: p, base: base, dim: dim)
      }
      let t = RingGeometry.position(ring.token, of: n, size: s, inset: inset)
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
    let inset = RingGeometry.inset(base: base)
    var layer = ctx
    layer.opacity = arcs.alpha * dim
    layer.translateBy(x: s / 2, y: s / 2)
    layer.rotate(by: .degrees(arcs.angleDegrees))
    layer.translateBy(x: -s / 2, y: -s / 2)
    let color = Color(.sRGB, red: 74 / 255, green: 144 / 255, blue: 217 / 255, opacity: 1)
    let width = CGFloat(arcs.lineWidth())
    var lines = Path()
    var heads = Path()
    let chord = 2 * (s / 2 - inset) * sin(.pi / CGFloat(n))
    // drawArrowhead: wings at +-30 degrees from a tip set back from the target dot
    let headLen = RingArcs.headLength(chord: Double(chord), base: Double(base)).map { CGFloat($0) }
    let setBack = CGFloat(RingArcs.tipSetBack(base: Double(base)))
    let wing = CGFloat(RingArcs.wingAngle)
    for i in 0..<n {
      var a = RingGeometry.position(i, of: n, size: s, inset: inset)
      var b = RingGeometry.position((i + 1) % n, of: n, size: s, inset: inset)
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

/// Every audible ring of a net deck, labelled by role: the parts in a grid of four, the
/// stingers (`hit1`…, one-shots fired by hand) after them in a smaller, quieter row, so the
/// parts that play read first.
public struct NetRingsView: View {
  public var snapshot: NetSnapshot?
  public var tint: Color
  public var arcs: RingArcs?

  public init(snapshot: NetSnapshot?, tint: Color, arcs: RingArcs? = nil) {
    self.snapshot = snapshot
    self.tint = tint
    self.arcs = arcs
  }

  /// `hit1`, `hit2`…: beats' stinger nets.
  static func isStinger(_ role: String) -> Bool {
    role.hasPrefix("hit") && role.count > 3 && role.dropFirst(3).allSatisfy(\.isNumber)
  }

  public var body: some View {
    let rings = snapshot?.rings ?? []
    let parts = rings.filter { !Self.isStinger($0.role) }
    let stingers = rings.filter { Self.isStinger($0.role) }
    VStack(spacing: DJStyle.s) {
      // Four columns at the deck's 260 pt floor, more as it widens (each ring between 56 and
      // 120 pt), so a wide deck gets a shorter grid instead of four ever-larger rings.
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 120), spacing: 6)], spacing: 6) {
        ForEach(parts, id: \.role) { r in
          VStack(spacing: 1) {
            // no padding: the ring insets its own marks (`RingGeometry.inset`), so a loud hit's
            // flash already stays inside its square, off the label and the rings beside it
            RingNetView(ring: r, tint: tint, arcs: arcs)
            Text(r.role).font(.system(size: 11, weight: r.muted ? .regular : .medium))
              .lineLimit(1)
              .foregroundStyle(r.muted ? .secondary : .primary)
          }
        }
      }
      if !stingers.isEmpty {
        HStack(spacing: 6) {
          Text("STINGERS").font(.system(size: 8, weight: .semibold)).tracking(1)
            .foregroundStyle(.tertiary).fixedSize()
          ForEach(stingers, id: \.role) { r in
            RingNetView(ring: r, tint: tint, arcs: arcs).frame(width: 30, height: 30)
              .opacity(0.8)
              .help(r.role)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }
}
