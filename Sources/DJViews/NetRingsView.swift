import DJCore
import SwiftUI

/// Where step `i` of an `n`-step ring sits: 12 o'clock first, clockwise.
public enum RingGeometry {
  public static func position(_ i: Int, of n: Int, size: CGFloat, inset: CGFloat) -> CGPoint {
    let a = Double(i) / Double(max(n, 1)) * 2 * .pi
    let r = size / 2 - inset
    return CGPoint(x: size / 2 + CGFloat(sin(a)) * r, y: size / 2 - CGFloat(cos(a)) * r)
  }
}

/// One ring net: a dot per place (bigger and brighter where a note is bound), the token
/// as a bright disc, and the step that just fired flashing as the tick elapses.
public struct RingNetView: View {
  public var ring: RingView
  public var tint: Color

  public init(ring: RingView, tint: Color) {
    self.ring = ring
    self.tint = tint
  }

  public var body: some View {
    Canvas { ctx, size in
      let s = min(size.width, size.height)
      let n = ring.size
      let dim = ring.muted ? 0.35 : 1.0
      let base = max(1.5, min(5, s / CGFloat(n) * 0.9))
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
      }
      let t = RingGeometry.position(ring.token, of: n, size: s, inset: 6)
      let tr = base * 1.6
      ctx.stroke(
        Path(ellipseIn: CGRect(x: t.x - tr, y: t.y - tr, width: 2 * tr, height: 2 * tr)),
        with: .color(.white.opacity(dim)), lineWidth: 2)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

/// Every audible ring of a net deck, labelled by role.
public struct NetRingsView: View {
  public var snapshot: NetSnapshot?
  public var tint: Color

  public init(snapshot: NetSnapshot?, tint: Color) {
    self.snapshot = snapshot
    self.tint = tint
  }

  public var body: some View {
    let rings = snapshot?.rings ?? []
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
      ForEach(rings, id: \.role) { r in
        VStack(spacing: 1) {
          RingNetView(ring: r, tint: tint)
          Text(r.role).font(.system(size: 9)).foregroundStyle(r.muted ? .secondary : .primary)
        }
      }
    }
  }
}
