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
    func at(_ i: Int) -> CGPoint { RingGeometry.position(i, of: 4, size: 100) }
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

  /// A few-step ring (the hihat's) at its biggest: every step a full-velocity hit, the one at
  /// 12 o'clock just fired (flash + playhead + glow) and holding the token. Nothing it draws
  /// may reach the canvas edge — the Canvas clips there, which cut the dots flat (2026-10-13).
  @Test func theBiggestMarksStayInsideTheCell() throws {
    for (steps, side) in [(4, 62), (4, 100), (3, 62), (8, 62), (16, 62)] {
      let r = RingView(
        id: "hihat", role: "hihat", size: steps, hits: [Bool](repeating: true, count: steps),
        velocities: [Int](repeating: 127, count: steps), token: 0, lastFired: 0, phase: 0,
        muted: false)
      let px = try #require(
        renderPixels(
          RingNetView(ring: r, tint: Color(red: 1, green: 0.4, blue: 0)), width: side,
          height: side))
      func inked(_ xs: Range<Int>, _ ys: Range<Int>) -> Int {
        var n = 0
        for y in ys { for x in xs where px.color(x, y).a > 24 { n += 1 } }
        return n
      }
      let edge =
        inked(0..<side, 0..<1) + inked(0..<side, side - 1..<side) + inked(0..<1, 0..<side)
        + inked(side - 1..<side, 0..<side)
      #expect(edge == 0, "\(steps) steps in \(side) pt: \(edge) inked edge pixels")
      // and the ring still fills its cell (the dots are not shrunk to nothing)
      #expect(inked(0..<side, 0..<side / 5) > side, "\(steps) steps: the top step is drawn")
    }
    // The deck's grid at its real width (260 pt), every ring at its biggest, for a look:
    // DJ_SHOT_DIR=… make swift-test-filter FILTER=theBiggestMarksStayInsideTheCell
    let grid = [("kick", 4), ("snare", 4), ("hihat", 8), ("bass", 16), ("melody", 16)].map {
      RingView(
        id: $0.0, role: $0.0, size: $0.1, hits: [Bool](repeating: true, count: $0.1),
        velocities: [Int](repeating: 127, count: $0.1), token: 0, lastFired: 0, phase: 0,
        muted: false)
    }
    savePNG(
      NetRingsView(
        snapshot: NetSnapshot(tick: 0, rings: grid), tint: Color(red: 1, green: 0.4, blue: 0)),
      width: 260, height: 150, name: "ring-grid-biggest")
  }

  @Test func aMutedRingIsDimmer() throws {
    let tint = Color(red: 0, green: 1, blue: 0)
    let on = try #require(
      renderPixels(RingNetView(ring: ring(), tint: tint), width: 100, height: 100))
    let off = try #require(
      renderPixels(RingNetView(ring: ring(muted: true), tint: tint), width: 100, height: 100))
    let p = RingGeometry.position(2, of: 4, size: 100)
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

  /// Stingers don't take a part's place in the grid: they sit in a short row of small rings
  /// under it, and every part ring stays full size.
  @Test func stingersSitInASmallRowUnderTheParts() throws {
    let rings = ["kick", "bass", "hit1", "hit2", "hit3"].map {
      RingView(
        id: $0, role: $0, size: 16, hits: [Bool](repeating: true, count: 16),
        velocities: [Int](repeating: 100, count: 16), token: 0, lastFired: -1, phase: 0,
        muted: false)
    }
    let view = NetRingsView(snapshot: NetSnapshot(tick: 0, rings: rings), tint: .orange)
    savePNG(view, width: 320, height: 160, name: "rings-stingers")
    let px = try #require(renderPixels(view, width: 320, height: 160))
    // bands of rows that hold orange: the parts' row, then the stingers' much shorter one (the
    // labels between them are white, and clear of the rings since the rings are padded)
    let orange = { (r: Int, _: Int, b: Int) in r > 150 && b < 100 }
    var bands: [Range<Int>] = []
    for y in 0..<160 where px.count(inX: 0..<320, y: y..<(y + 1), where: orange) > 0 {
      if let last = bands.last, last.upperBound >= y - 2 {
        bands[bands.count - 1] = last.lowerBound..<(y + 1)
      } else {
        bands.append(y..<(y + 1))
      }
    }
    try #require(bands.count == 2, "\(bands)")
    #expect(bands[0].count > 60 && bands[1].count < 34, "\(bands)")
    // the parts' row holds kick and bass only (columns 3 and 4 empty)
    #expect(px.count(inX: 170..<320, y: bands[0], where: { r, _, _ in r > 150 }) == 0)
    #expect(NetRingsView.isStinger("hit12") && !NetRingsView.isStinger("hihat"))
  }

  /// A ring's flash reaches past its square (2.4 × base round a dot 6 pt in); the grid pads
  /// each ring by the most any ring can, so a loud bottom step never paints over the label
  /// under it.
  @Test func aFlashStaysInsideItsCell() throws {
    for n in [1, 4, 8, 16, 32, 64] {
      for size in stride(from: 20.0, through: 160, by: 10) {
        #expect(RingGeometry.overflow(steps: n, size: size) <= RingGeometry.maxOverflow)
      }
    }
    #expect(RingGeometry.overflow(steps: 8, size: 60) > 0, "it does overflow unpadded")
    // one column of four, (320 − 3 × 6) / 4 wide; the step at 3 o'clock fired, loud: its flash
    // and playhead (orange / gold on the light test background) stay left of the column's edge
    let cell = Int(((320.0 - 18) / 4).rounded(.down))
    let ring = RingView(
      id: "hihat", role: "", size: 8, hits: [Bool](repeating: true, count: 8),
      velocities: [Int](repeating: 127, count: 8), token: 0, lastFired: 2, phase: 0, muted: false)
    let view = NetRingsView(snapshot: NetSnapshot(tick: 0, rings: [ring]), tint: .orange)
    savePNG(view, width: 320, height: 120, name: "ring-flash-cell")
    let px = try #require(renderPixels(view, width: 320, height: 120))
    let coloured = { (r: Int, _: Int, b: Int) in r > 200 && b < 170 && r - b > 60 }
    #expect(px.count(inX: 0..<cell, y: 0..<120, where: coloured) > 100)
    let spill = px.count(inX: cell..<320, y: 0..<120, where: coloured)
    #expect(spill == 0, "\(spill) ring pixels past the ring's column")
  }
}
