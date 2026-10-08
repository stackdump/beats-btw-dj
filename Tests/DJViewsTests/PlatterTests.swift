import SwiftUI
import Testing

@testable import DJViews

struct PlatterGeometryTests {
  @Test func oneRevolutionIsOnePointEightSeconds() {
    #expect(PlatterGeometry.angle(platterSeconds: 0) == 0)
    #expect(abs(PlatterGeometry.angle(platterSeconds: 0.45) - 90) < 1e-9)
    #expect(abs(PlatterGeometry.angle(platterSeconds: 1.8)) < 1e-9)
    #expect(abs(PlatterGeometry.angle(platterSeconds: 2.25) - 90) < 1e-9)
    #expect(abs(PlatterGeometry.angle(platterSeconds: -0.45) + 90) < 1e-9, "reverse turns it back")
  }

  @Test func rimDotsGoClockwiseFromTwelve() {
    let top = PlatterGeometry.rimDot(0, of: 4, size: 100, inset: 10)
    let right = PlatterGeometry.rimDot(1, of: 4, size: 100, inset: 10)
    let bottom = PlatterGeometry.rimDot(2, of: 4, size: 100, inset: 10)
    #expect(abs(top.x - 50) < 1e-9 && abs(top.y - 10) < 1e-9)
    #expect(abs(right.x - 90) < 1e-9 && abs(right.y - 50) < 1e-9)
    #expect(abs(bottom.x - 50) < 1e-9 && abs(bottom.y - 90) < 1e-9)
  }
}

@MainActor
struct PlatterRenderTests {
  @Test func theMarkerFollowsThePlatterAndTheRingLightsOnTouch() throws {
    let tint = Color(red: 0, green: 0.8, blue: 1)  // ~0,204,255
    let size = 160
    // marker is a 3 px white bar from the centre outwards; at 0° it points up
    let up = try #require(
      renderPixels(PlatterView(seconds: 0, touching: false, tint: tint), width: size, height: size))
    let quarter = try #require(
      renderPixels(
        PlatterView(seconds: 0.45, touching: false, tint: tint), width: size, height: size))
    func whiteCount(_ p: Pixels, _ xs: Range<Int>, _ ys: Range<Int>) -> Int {
      p.count(inX: xs, y: ys) { r, g, b in r > 200 && g > 200 && b > 200 }
    }
    // up: white above the centre, none to the right
    #expect(whiteCount(up, 76..<84, 20..<60) > 40)
    #expect(whiteCount(up, 100..<140, 76..<84) == 0)
    // a quarter turn (0.45 s): the marker points right
    #expect(whiteCount(quarter, 100..<140, 76..<84) > 40)
    #expect(whiteCount(quarter, 76..<84, 20..<60) == 0)
    // touch lights the rim in the tint colour
    let touched = try #require(
      renderPixels(PlatterView(seconds: 0, touching: true, tint: tint), width: size, height: size))
    let rim = touched.count(inX: 0..<size, y: 2..<6) { r, g, b in b > 200 && r < 80 && g > 120 }
    let idleRim = up.count(inX: 0..<size, y: 2..<6) { r, g, b in b > 200 && r < 80 && g > 120 }
    #expect(rim > 10 && idleRim == 0, "touched \(rim) idle \(idleRim)")
  }

  @Test func beatDotsLightTheCurrentBeat() throws {
    let tint = Color(red: 1, green: 0, blue: 0)
    let size = 160
    func lit(_ beat: Int) throws -> [Bool] {
      let px = try #require(
        renderPixels(
          PlatterView(seconds: 0, touching: false, tint: tint, beatInBar: beat), width: size,
          height: size))
      return (0..<4).map { i in
        let p = PlatterGeometry.rimDot(i, of: 4, size: CGFloat(size), inset: 12)
        return px.near(Int(p.x), Int(p.y), (255, 0, 0), tol: 60)
      }
    }
    #expect(try lit(0) == [true, false, false, false])
    #expect(try lit(2) == [false, false, true, false])
  }

  @Test func beatStripRenders() throws {
    let px = try #require(
      renderPixels(
        BeatStripView(bpm: 126.5, beatInBar: 1, scrubbing: true, tint: .orange), width: 260,
        height: 20))
    #expect(
      px.count(inX: 0..<260, y: 0..<20) { r, g, b in r > 30 || g > 30 || b > 30 } > 100,
      "text and dots drew")
  }
}
