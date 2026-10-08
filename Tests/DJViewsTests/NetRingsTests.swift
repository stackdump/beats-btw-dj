import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct NetRingsRenderTests {
  func ring(token: Int = 1, lastFired: Int = 0, phase: Double = 0, muted: Bool = false) -> RingView
  {
    RingView(
      id: "kick", role: "kick", size: 4, hits: [true, false, true, false],
      velocities: [100, 0, 127, 0], token: token, lastFired: lastFired, phase: phase, muted: muted)
  }

  func whiteNear(_ px: Pixels, _ p: CGPoint, radius: Int = 9) -> Int {
    let x = Int(p.x)
    let y = Int(p.y)
    return px.count(
      inX: max(0, x - radius)..<min(px.width, x + radius),
      y: max(0, y - radius)..<min(px.height, y + radius)
    ) {
      r, g, b in r > 200 && g > 200 && b > 200
    }
  }

  @Test func hitsTokenAndFlashAreWhereTheyShould() throws {
    let tint = Color(red: 1, green: 0.4, blue: 0)
    let px = try #require(
      renderPixels(RingNetView(ring: ring(), tint: tint), width: 100, height: 100))
    func at(_ i: Int) -> CGPoint { RingGeometry.position(i, of: 4, size: 100, inset: 6) }
    // hits (steps 0 and 2) are tinted discs; rests (1, 3) are small and grey
    #expect(px.color(Int(at(2).x), Int(at(2).y)).r > 180, "hit at step 2 takes the tint")
    let rest = px.color(Int(at(3).x), Int(at(3).y))
    #expect(abs(rest.r - rest.b) < 30, "a rest is grey: \(rest)")
    // the token (step 1) is circled in white; step 3 has none
    #expect(whiteNear(px, at(1)) > 8)
    #expect(whiteNear(px, at(3)) == 0)
    // step 0 just fired and the tick has barely started: a white flash over it
    #expect(whiteNear(px, at(0), radius: 6) > 10)
    // a late phase fades the flash
    let late = try #require(
      renderPixels(RingNetView(ring: ring(phase: 0.97), tint: tint), width: 100, height: 100))
    #expect(whiteNear(late, at(0), radius: 6) < whiteNear(px, at(0), radius: 6) / 2)
  }

  @Test func aMutedRingIsDimmer() throws {
    let tint = Color(red: 0, green: 1, blue: 0)
    let on = try #require(
      renderPixels(RingNetView(ring: ring(), tint: tint), width: 100, height: 100))
    let off = try #require(
      renderPixels(RingNetView(ring: ring(muted: true), tint: tint), width: 100, height: 100))
    let p = RingGeometry.position(2, of: 4, size: 100, inset: 6)
    #expect(on.color(Int(p.x), Int(p.y)).g > off.color(Int(p.x), Int(p.y)).g + 60)
  }

  @Test func theGridLaysOutOneRingPerRole() throws {
    let rings = ["kick", "snare", "hihat", "bass", "melody"].map {
      RingView(
        id: $0, role: $0, size: 16, hits: [Bool](repeating: true, count: 16),
        velocities: [Int](repeating: 100, count: 16), token: 0, lastFired: -1, phase: 0,
        muted: false)
    }
    let px = try #require(
      renderPixels(
        NetRingsView(snapshot: NetSnapshot(tick: 0, rings: rings), tint: .orange), width: 320,
        height: 160))
    // 4 columns: two rows for five rings; the second row has a single ring on the left
    let row2Left = px.count(inX: 0..<80, y: 80..<160) { r, _, _ in r > 150 }
    let row2Right = px.count(inX: 160..<320, y: 80..<160) { r, _, _ in r > 150 }
    #expect(row2Left > 20 && row2Right == 0, "left \(row2Left) right \(row2Right)")
  }
}
