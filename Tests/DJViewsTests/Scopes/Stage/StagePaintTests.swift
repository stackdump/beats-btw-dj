import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Pixel-exact checks of the constellation's paint, on a hand-made net (`SyntheticStage`): every
// colour is the CSS blend computed here (not read off the render), every position a coordinate
// derived from the net and the panel's 1 point border. Where these pin a number, a 10% change of
// the number fails a test.
//
// The synthetic stage: one 408-point panel centred in 600 x 600, the net at scale 1, so a net
// point (x, y) is at stage (301 + x, 301 + y). P0 (0, -80), P1 (0, 80); T0 (-80, 0) with a note,
// T1 (80, 0) without; one arc P0 -> P1.

@MainActor
struct StagePaintTests {
  // MARK: the panel's border inset

  @Test func theNetSitsOneBorderInsideThePanelsCorner() throws {
    let s = try SyntheticStage()
    let px = try s.pixels()
    savePNG(s.scene, width: 600, height: 600, name: "stage-paint-plain")
    // T1 is centred on (381, 301): its 40-point square (outer edge, 3 point red border) runs
    // x 361...401, y 281...321. One point to the left would put the first red pixel at 360.
    let red = Sw.red
    #expect(px.near(361, 301, red, tol: 4) && px.near(363, 301, red, tol: 4), "left edge")
    #expect(px.near(360, 301, Sw.background, tol: 3), "just outside: \(px.color(360, 301))")
    #expect(px.near(399, 301, red, tol: 4) && px.near(400, 301, red, tol: 4), "right edge")
    #expect(px.near(401, 301, Sw.background, tol: 3), "just outside: \(px.color(401, 301))")
    #expect(px.near(381, 281, red, tol: 4) && px.near(381, 283, red, tol: 4), "top edge")
    #expect(px.near(381, 280, Sw.background, tol: 3), "just outside: \(px.color(381, 280))")
    // and the model's own coordinate is the JS formula's: one point up and left of the drawn node
    let at = try #require(s.panel.nodeCenterInStage(transition: 1))
    #expect(Sw.near(at, 380, 300, 1e-9))
  }

  // MARK: sizes and colours of the nodes

  @Test func aPlaceIsFiftyAcrossWithAThreePointBlueBorder() throws {
    let s = try SyntheticStage()
    let px = try s.pixels()
    // P0 is centred on (301, 221): the border covers radius 22...25, the fill radius < 22
    let (cx, cy) = SyntheticStage.at(0, -80)
    #expect(px.near(cx + 23, cy, Sw.arcBlue, tol: 4), "border: \(px.color(cx + 23, cy))")
    #expect(px.near(cx - 24, cy, Sw.arcBlue, tol: 4) && px.near(cx, cy - 23, Sw.arcBlue, tol: 4))
    #expect(px.near(cx + 15, cy, Sw.fill, tol: 3), "fill: \(px.color(cx + 15, cy))")
    #expect(px.near(cx, cy, Sw.fill, tol: 3), "an empty place: \(px.color(cx, cy))")
    #expect(px.near(cx + 27, cy, Sw.background, tol: 3), "outside: \(px.color(cx + 27, cy))")
  }

  @Test func aTransitionWithANoteHasATwoToneBody() throws {
    let s = try SyntheticStage()
    let px = try s.pixels()
    // T0 (221, 301) has a note: linear-gradient(135deg, #1a1a2e 50%, #2d1f3d 50%), the half below
    // the anti-diagonal is #2d1f3d. T1 (381, 301) has none: all #1a1a2e.
    let (t0x, t0y) = SyntheticStage.at(-80, 0)
    let (t1x, t1y) = SyntheticStage.at(80, 0)
    #expect(px.near(t0x - 10, t0y - 10, Sw.fill, tol: 2), "T0 upper left")
    #expect(px.near(t0x + 10, t0y + 10, Sw.midiFill, tol: 2), "T0 lower right")
    #expect(
      px.near(t0x + 12, t0y + 6, Sw.midiFill, tol: 2) && px.near(t0x - 6, t0y - 12, Sw.fill, tol: 2)
    )
    #expect(px.near(t1x - 10, t1y - 10, Sw.fill, tol: 2), "T1 upper left")
    #expect(px.near(t1x + 10, t1y + 10, Sw.fill, tol: 2), "T1 lower right (no note)")
  }

  // MARK: arcs

  @Test func arcsAreTwoPointsWideAtAlphaPointSix() throws {
    let s = try SyntheticStage()
    let px = try s.pixels()
    // the vertical arc P0 -> P1 is the line x = 301 (net x = 0), 2 points wide: columns 300, 301
    let want = Sw.blend(Sw.arcBlue, 0.6, over: Sw.background)
    #expect(want == (48, 90, 141))
    #expect(
      px.near(300, 301, want, tol: 3) && px.near(301, 301, want, tol: 3), "\(px.color(301, 301))")
    #expect(px.near(299, 301, Sw.background, tol: 3) && px.near(302, 301, Sw.background, tol: 3))
  }

  @Test func anArcHasItsArrowheadJustShortOfTheTarget() throws {
    let s = try SyntheticStage()
    let px = try s.pixels()
    // the head is 25 back from P1 (301, 381): tip (301, 356); barbs 12 long at +-30 degrees of
    // the direction of the arc (down), ending at (295.0, 345.6) and (307.0, 345.6). Three quarters
    // of the way down each barb is at (296.5, 347.2) and (305.5, 347.2).
    let head = StageArcArrow.head(x1: 0, y1: -80, x2: 0, y2: 80)
    #expect(Sw.near(head.tipX, 0) && Sw.near(head.tipY, 55))
    let want = Sw.blend(Sw.arcBlue, 0.6, over: Sw.background)
    for (bx, by) in [(head.leftX, head.leftY), (head.rightX, head.rightY)] {
      let x = Int((301 + head.tipX * 0.25 + bx * 0.75).rounded(.down))
      let y = Int((301 + head.tipY * 0.25 + by * 0.75).rounded(.down))
      #expect(Sw.anyNear(px, x, y, r: 1, want, tol: 8), "barb near (\(x), \(y)): \(px.color(x, y))")
    }
    // and nowhere else beside the line at that height but the two barbs: mid-way between them
    // and the line is background
    #expect(px.near(298, 347, Sw.background, tol: 3) || px.near(299, 347, Sw.background, tol: 3))
  }

  // MARK: live tokens

  @Test func aTokenIsATenPointDiscAndSeveralMakeAFifteenPointOne() throws {
    let one = try SyntheticStage(tokens: [1, 0])
    let many = try SyntheticStage(tokens: [3, 0])
    let a = try one.pixels()
    let b = try many.pixels()
    let (cx, cy) = SyntheticStage.at(0, -80)
    func blue(_ px: Pixels) -> Int {
      px.count(inX: (cx - 18)..<(cx + 18), y: (cy - 18)..<(cy + 18)) { r, g, bl in
        abs(r - 74) <= 14 && abs(g - 144) <= 14 && abs(bl - 217) <= 14
      }
    }
    // areas: pi 10^2 = 314 and pi 15^2 = 707 (less the digit "3" drawn on it in the fill colour)
    #expect(blue(a) > 290 && blue(a) < 340, "one token: \(blue(a)) blue pixels")
    #expect(blue(b) > 600 && blue(b) < 720, "three tokens: \(blue(b)) blue pixels")
    // the single token's centre is the place's blue; an empty place stays the fill
    #expect(a.near(cx, cy, Sw.arcBlue, tol: 3))
    let (ex, ey) = SyntheticStage.at(0, 80)
    #expect(a.near(ex, ey, Sw.fill, tol: 3), "P1 holds nothing")
  }

  // MARK: fire flash

  @Test func theFireGlowIsTheCSSBlur() throws {
    // T0 (note) and T1 (none) both fired this very instant (age 0: scale 1, flash 1)
    let s = try SyntheticStage(firedAt: [10, 10], audioNow: 10)
    let px = try s.pixels()
    savePNG(s.scene, width: 600, height: 600, name: "stage-paint-lit")
    // T0's left edge is at x = 201. `box-shadow: 0 0 8px` is a Gaussian of sigma 4 (blur 8 / 2):
    // the glow's alpha at distance d outside a straight edge is erfc(d / (4 sqrt 2)) / 2: 0.45 at
    // half a point, 0.13 at 4.5, 0.017 at 8.5. Over the background (10, 10, 26) the red channel
    // is 10 + alpha * 223.
    func glowRed(_ x: Int) -> Int { px.color(x, 301).r }
    #expect(abs(glowRed(200) - 110) <= 14, "d 0.5: \(glowRed(200))")
    #expect(abs(glowRed(196) - 39) <= 8, "d 4.5: \(glowRed(196))")
    #expect(glowRed(192) <= 18, "d 8.5: \(glowRed(192))")
    #expect(glowRed(188) <= 11, "d 12.5: \(glowRed(188))")
    // a node with a note keeps its two-tone body while it fires; the border is red as always
    let (t0x, t0y) = SyntheticStage.at(-80, 0)
    #expect(px.near(t0x - 10, t0y - 10, Sw.fill, tol: 2), "body, upper left")
    #expect(px.near(t0x + 10, t0y + 10, Sw.midiFill, tol: 2), "body, lower right")
    #expect(px.near(t0x - 19, t0y, Sw.red, tol: 4), "border")
    // one without a note would be filled red (`.firing`; nothing without a note ever fires)
    let (t1x, t1y) = SyntheticStage.at(80, 0)
    #expect(px.near(t1x, t1y, Sw.red, tol: 4) && px.near(t1x - 10, t1y - 10, Sw.red, tol: 4))
  }

  @Test func theFireGlowShrinksWithThePanelLikeTheCSS() throws {
    // a 120-point panel fits the net at scale 0.5: the node is 20 across and the CSS blur, which
    // is in the node's own units, is half as wide: sigma 2
    let s = try SyntheticStage(firedAt: [10, 10], audioNow: 10, scaleSide: 120)
    #expect(Sw.near(s.panel.view!.scale, 0.5, 1e-9))
    let px = try s.pixels()
    let c = try #require(s.panel.nodeCenterInStage(transition: 0))
    let (cx, cy) = (Int(c.x.rounded()) + 1, Int(c.y.rounded()) + 1)
    // T0's left edge is at cx - 10; distance d outside it: the alpha is erfc(d / (2 sqrt 2)) / 2,
    // 0.40 at half a point, 0.03 at 3.5, and nothing past 6
    #expect(abs(px.color(cx - 11, cy).r - 100) <= 14, "d 0.5: \(px.color(cx - 11, cy))")
    #expect(px.color(cx - 14, cy).r <= 26, "d 3.5: \(px.color(cx - 14, cy))")
    #expect(px.color(cx - 17, cy).r <= 11, "d 6.5: \(px.color(cx - 17, cy))")
  }

  @Test func theFireScalePulseGrowsTheNodeByTenPercentAtItsPeak() throws {
    // 50 ms after the fire the keyframe is at its middle: scale 1.1, so T0's 40-point square is
    // 44 across and its left edge moves out from x = 201 to 199
    let peak = try SyntheticStage(firedAt: [9.95, 9.95], audioNow: 10)
    let rest = try SyntheticStage(firedAt: [10, 10], audioNow: 10)
    let p = try peak.pixels()
    let r = try rest.pixels()
    #expect(p.near(199, 301, Sw.red, tol: 6) && p.near(200, 301, Sw.red, tol: 6), "peak")
    #expect(r.color(200, 301).r < 140 && r.color(199, 301).r < 140, "at the fire: glow, not red")
    #expect(r.near(201, 301, Sw.red, tol: 6))
    // and the other edge: 243 at the peak (221 + 22), against 241 at rest
    #expect(p.near(242, 301, Sw.red, tol: 6), "peak right edge")
    #expect(r.color(242, 301).r < 140, "at rest the right edge is still at 241")
  }

  // MARK: panel backs and labels

  @Test func aPanelBackIsARadialGradientWithAOnePointBorder() throws {
    let s = try SyntheticStage(showBacks: true)
    let px = try s.pixels()
    savePNG(s.scene, width: 600, height: 600, name: "stage-paint-backs")
    // the centre of the 408 point box (300, 300) is the gradient's inner colour #131a33; the
    // box's own corner region (rounded, radius 10) is nearly the outer #070712
    #expect(px.near(299, 300, (19, 26, 51), tol: 3), "centre: \(px.color(299, 300))")
    // the box spans 96...504: a point 3 inside its top-left corner is dark, 3 outside is the stage
    #expect(px.near(104, 104, (7, 7, 18), tol: 6), "corner region: \(px.color(104, 104))")
    #expect(px.near(90, 90, Sw.background, tol: 2) && px.near(96, 300, (20, 36, 62), tol: 14))
    // the border is rgba(74,144,217,0.18) over the gradient: one point wide
    let edge = px.color(96, 300)
    let inner = px.color(98, 300)
    #expect(edge.b > inner.b + 15 && edge.g > inner.g + 15, "border \(edge) over \(inner)")
    // a rounded corner: the very corner pixel is outside the 10 point radius, so the stage
    #expect(px.near(97, 97, Sw.background, tol: 6), "corner: \(px.color(97, 97))")
  }

  @Test func aLabelIsEightAndTenInsideTheBorder() throws {
    let s = try SyntheticStage(showLabels: true)
    let px = try s.pixels()
    savePNG(s.scene, width: 600, height: 600, name: "stage-paint-label")
    // the panel's corner is (96, 96); its border box 1 point, then the label at (10, 8): the text
    // box starts at (107, 105). 11 point uppercase "NET", rgba(255,255,255,0.55).
    var minX = Int.max
    var minY = Int.max
    var maxY = 0
    var ink = 0
    for y in 96..<140 {
      for x in 96..<200 where px.color(x, y).r > 60 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        ink += 1
      }
    }
    #expect(ink > 40, "the label is drawn (\(ink) pixels)")
    #expect(minX >= 107 && minX <= 109, "text starts at x 107 (+ the glyph's bearing): \(minX)")
    #expect(minY >= 105 && minY <= 109, "text starts at y 105 (+ the ascent gap): \(minY)")
    #expect(maxY - minY <= 10, "11 point capitals are about 8 tall: \(minY)...\(maxY)")
    // light, not full white: 0.55 over the (hidden-backs) stage
    let top = (96..<200).flatMap { x in (96..<140).map { px.color(x, $0).r } }.max() ?? 0
    #expect(top >= 130 && top <= 160, "55% white over the background peaks at ~145: \(top)")
  }

  // MARK: the empty state

  @Test func theEmptyMessageStaysUprightWhileTheDiagramTurns() throws {
    let flat = try SyntheticStage(metaRotation: 0, panels: false, hasNet: false)
    let turned = try SyntheticStage(metaRotation: 90, panels: false, hasNet: false)
    let a = try flat.pixels()
    let b = try turned.pixels()
    savePNG(turned.scene, width: 600, height: 600, name: "stage-paint-empty-turned")
    func box(_ px: Pixels) -> (w: Int, h: Int, ink: Int) {
      var x0 = Int.max
      var x1 = 0
      var y0 = Int.max
      var y1 = 0
      var ink = 0
      for y in 60..<600 {
        for x in 0..<600 where px.color(x, y).r > 40 {
          x0 = min(x0, x)
          x1 = max(x1, x)
          y0 = min(y0, y)
          y1 = max(y1, y)
          ink += 1
        }
      }
      return ink == 0 ? (0, 0, 0) : (x1 - x0 + 1, y1 - y0 + 1, ink)
    }
    let fb = box(a)
    #expect(fb.ink > 100 && fb.w > 4 * fb.h, "a line of text, wider than tall: \(fb)")
    #expect(
      sameSamples(a.rgba, b.rgba) == .identical, "turning the diagram does not turn the message")
  }
}
