import DJCore
import SwiftUI
import Testing

@testable import DJViews

struct PadGridGeometryTests {
  @Test func clicksMapBackToControls() {
    let g = PadGridGeometry(size: CGSize(width: 450, height: 450))  // cell = 50
    #expect(g.cell == 50)
    // pad 0 is bottom-left, pad 7 bottom-right, pad 56 top-left
    func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    #expect(g.padRect(0) == CGRect(x: 0, y: 350, width: 50, height: 50))
    #expect(g.padRect(7).origin == CGPoint(x: 350, y: 350))
    #expect(g.padRect(56).origin == CGPoint(x: 0, y: 0))
    for i in [0, 7, 9, 31, 56, 63] {
      let c = g.control(at: centre(g.padRect(i)))
      #expect(c?.group == "pads" && c?.index == i)
    }
    for i in 0..<8 {
      #expect(g.control(at: centre(g.trackRect(i)))?.group == "track")
      #expect(g.control(at: centre(g.trackRect(i)))?.index == i)
      #expect(g.control(at: centre(g.sceneRect(i)))?.group == "scene")
      #expect(g.control(at: centre(g.sceneRect(i)))?.index == i)
    }
    #expect(g.sceneRect(0).origin.y == 0, "scene 0 is at the top")
    #expect(g.control(at: CGPoint(x: 440, y: 440)) == nil, "the corner is empty")
  }

  @Test func theGridStaysSquare() {
    let g = PadGridGeometry(size: CGSize(width: 900, height: 450))
    #expect(g.cell == 50)
  }
}

@MainActor
struct PadGridRenderTests {
  @Test func padsShowTheirPaletteColourAndBrightness() throws {
    var pads = [PadLight](repeating: PadLight(colorIndex: 0, level: .dim), count: 64)
    pads[0] = PadLight(colorIndex: 9, level: .full)  // orange, bright (bottom-left)
    pads[1] = PadLight(colorIndex: 9, level: .dim)  // orange, dim
    pads[63] = PadLight(colorIndex: 37, level: .full)  // cyan (top-right)
    pads[8] = PadLight(colorIndex: 5, level: .full)  // red (second row, left)
    let tracks = (0..<8).map { PadLight(colorIndex: 0, level: $0 == 2 ? .full : .off) }
    let scenes = (0..<8).map { PadLight(colorIndex: 0, level: $0 == 5 ? .blink : .off) }
    let size = 360
    let px = try #require(
      renderPixels(
        PadGridView(pads: pads, tracks: tracks, scenes: scenes), width: size, height: size))
    let g = PadGridGeometry(size: CGSize(width: size, height: size))
    func c(_ r: CGRect) -> (r: Int, g: Int, b: Int, a: Int) { px.color(Int(r.midX), Int(r.midY)) }
    let orange = c(g.padRect(0))
    #expect(orange.r > 220 && orange.g > 100 && orange.g < 170 && orange.b < 60, "\(orange)")
    let dim = c(g.padRect(1))
    #expect(dim.r > 40 && dim.r < 110 && dim.r < orange.r / 2, "dim \(dim)")
    let cyan = c(g.padRect(63))
    #expect(cyan.b > 200 && cyan.r < 60, "\(cyan)")
    #expect(c(g.padRect(8)).r > 220 && c(g.padRect(8)).g < 60)
    let dark = c(g.padRect(20))
    #expect(dark.r < 80 && dark.g < 80 && dark.b < 80)
    // single LEDs: track 2 red, scene 5 green, others dim grey
    let t2 = c(g.trackRect(2))
    #expect(t2.r > 200 && t2.g < 80, "\(t2)")
    #expect(c(g.trackRect(3)).r < 90)
    let s5 = c(g.sceneRect(5))
    #expect(s5.g > 120 && s5.r < 80, "\(s5)")
  }
}
