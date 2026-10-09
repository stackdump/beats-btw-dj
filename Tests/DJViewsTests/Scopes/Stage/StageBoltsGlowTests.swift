import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// The glow of the bolts and the seeds (SPEC mode 17) against Chrome's canvas shadows
// (`ChromeGlow`, StageChromeGlowReference.swift), at a display scale of 1 and of 2, and the
// halo's place in the paint order.
//
// A canvas `shadowBlur` is a Gaussian of half its value in DEVICE pixels, so on a 2x display the
// glow is the same number of device pixels but half as wide in points. SwiftUI's own `.shadow`
// filter is a Gaussian only for big shapes: for a 2.2 point line, and a 3 point disc, it is a
// few times too strong (a 1.5 point disc at radius 5 peaks at 43/255 where the Gaussian gives
// 11/255), which is why the painter blurs the shape itself (`StageBoltsPainter.glow`).

@MainActor
struct StageBoltsGlowTests {
  private let background = Color(red: 10.0 / 255, green: 10.0 / 255, blue: 26.0 / 255)

  /// A 100 x 100 point canvas over the stage background, painted by `paint`, at `scale`.
  private func canvas(
    scale: Int, paint: @escaping (inout GraphicsContext) -> Void
  ) throws -> Pixels {
    let view = Canvas { gc, _ in paint(&gc) }.background(background)
    return try #require(renderPixelsAt(scale: CGFloat(scale), view, width: 100, height: 100))
  }

  /// The red channel to the right of a seed of age `t` (fraction of its life) at (50, 50).
  private func seedRow(age t: Double, scale: Int, count: Int) throws -> (row: [Int], radius: Double)
  {
    let live = try #require(
      StageBolts.dot(
        of: StageSeed(x: 50, y: 50, ux: 0, uy: 1, bornMs: 0), planetR: 56.8,
        nowMs: t * StageBolts.seedLifeMs))
    // (the drift moves it along the inward direction; park it back on (50, 50))
    let dot = StageSeedDot(x: 50, y: 50, radius: live.radius, alpha: live.alpha)
    let px = try canvas(scale: scale) {
      StageBoltsPainter.drawSeed($0, dot, displayScale: Double(scale))
    }
    return ((0..<count).map { px.color(50 * scale + $0, 50 * scale).r }, live.radius)
  }

  /// The blue channel below a straight bolt (10, 50) -> (90, 50) of alpha `alpha`.
  private func boltColumn(alpha: Double, scale: Int, count: Int) throws -> [Int] {
    let stroke = StageBoltStroke(
      points: [StagePoint(x: 10, y: 50), StagePoint(x: 90, y: 50)], alpha: alpha)
    let px = try canvas(scale: scale) {
      StageBoltsPainter.drawBolt($0, stroke, displayScale: Double(scale))
    }
    return (0..<count).map { px.color(50 * scale, 50 * scale + $0).b }
  }

  private func expectClose(
    _ got: [Int], _ want: [Int], from: Int, tolerance: Int, _ what: String
  ) {
    #expect(got.count >= want.count, "\(what): a short row")
    for k in from..<min(got.count, want.count) {
      #expect(
        abs(got[k] - want[k]) <= tolerance,
        "\(what), \(k) device pixels out: \(got[k]) against Chrome's \(want[k])")
    }
  }

  @Test func theSeedsGlowIsChromesCanvasShadowOnAOneXAndATwoXDisplay() throws {
    let cases: [(age: Double, key: String, scale: Int)] = [
      (0, "0@1", 1), (0.436, "0.436@1", 1), (0, "0@2", 2), (0.436, "0.436@2", 2),
    ]
    for c in cases {
      let want = try #require(ChromeGlow.seedRed[c.key])
      let (row, radius) = try seedRow(age: c.age, scale: c.scale, count: want.count)
      // the disc itself and its anti-aliased edge differ by the rasteriser: compare the glow
      let edge = Int((radius * Double(c.scale)).rounded(.up)) + 1
      expectClose(row, want, from: edge, tolerance: 3, "seed \(c.key)")
      // the disc is there: bright warm white inside it
      #expect(row[0] > 120 && want[0] > 120)
    }
  }

  @Test func theSeedReallyGlows() throws {
    // At birth the Gaussian lifts the background by 23 levels 3 points out (Chrome: 33 against
    // 10): a seed with no glow, or one a fraction as strong, is nowhere near.
    let (row, _) = try seedRow(age: 0, scale: 1, count: 12)
    #expect(row[3] >= 28 && row[4] >= 25, "glow at 3 and 4 points: \(row)")
    #expect(row[8] > row[11] && row[11] >= 10, "and it fades with distance: \(row)")
  }

  @Test func theBoltsGlowIsChromesCanvasShadowOnAOneXAndATwoXDisplay() throws {
    let cases: [(alpha: Double, key: String, scale: Int)] = [
      (1, "1.0@1", 1), (0.5, "0.5@1", 1), (1, "1.0@2", 2), (0.5, "0.5@2", 2),
    ]
    for c in cases {
      let want = try #require(ChromeGlow.boltBlue[c.key])
      let col = try boltColumn(alpha: c.alpha, scale: c.scale, count: want.count)
      // (the line is 2.2 points wide: its half, and the edge pixel, are the rasteriser's)
      let edge = Int((1.1 * Double(c.scale)).rounded(.up)) + 1
      expectClose(col, want, from: edge, tolerance: 4, "bolt \(c.key)")
      #expect(abs(col[0] - want[0]) <= 6, "the white-hot core on the line: \(col[0]) vs \(want[0])")
    }
  }

  // MARK: the layer

  @Test func theLayerHandsTheDisplayScaleToThePainter() throws {
    var s = try OverlayStage(
      overlays: [.flame, .bolts], now: 5,
      models: StageLayerModels(bolts: StageBoltsModel(random: { 0.123456 })))
    s.step(dt: 0, fires: [s.fire(origin: StagePoint(x: 500, y: 144), macro: true)])
    s.step(dt: 0, overlays: [.bolts])
    let model = s.layers.bolts
    let context = s.context
    let strokes = model.strokes(in: context)
    let seeds = model.seedDots(in: context)
    let halo = model.halo(in: context)
    #expect(strokes.count == 1 && seeds.count == 1 && halo != nil)
    func render<V: View>(_ view: V) throws -> Pixels {
      try #require(renderPixelsAt(scale: 2, view.background(Color.black), width: 1000, height: 800))
    }
    func painted(displayScale: Double) -> some View {
      Canvas { gc, _ in
        StageBoltsPainter.draw(
          &gc, strokes: strokes, seeds: seeds, halo: halo, displayScale: displayScale)
      }
    }
    // rendered at 2x the layer sees `\.displayScale` = 2 and is the painter told 2, not 1
    let layer = try render(StageBoltsLayer(context: context, model: model))
    let two = try render(painted(displayScale: 2))
    let one = try render(painted(displayScale: 1))
    let xs = 880..<1120
    let ys = 280..<820
    // (the rasteriser is not bit-for-bit repeatable: a few edge pixels differ by 1 to 3 levels)
    let sameAsTwo = OverlaySwatch.changed(layer, two, tol: 3, in: xs, ys)
    #expect(sameAsTwo.isEmpty, "the layer paints as displayScale 2 (\(sameAsTwo.count) differ)")
    let sameAsOne = OverlaySwatch.changed(layer, one, tol: 6, in: xs, ys)
    #expect(sameAsOne.count > 300, "and not as 1 (\(sameAsOne.count) differ)")
  }

  // MARK: the halo is the last thing painted

  @Test func theHaloIsPaintedOverTheSeedsAndTheBolts() throws {
    // stage.js: the bolts, then `renderSeeds`, then the halo's two washes. A spark near the
    // planet's middle is under the halo: seed, then halo over it. (Painted the other way round,
    // a 16 level difference in red.)
    let seed = StageSeedDot(x: 60, y: 50, radius: 2.7, alpha: 1)
    let halo = StageHalo(glow: 1, centre: StagePoint(x: 50, y: 50), planetRadius: 40)
    let bare = try canvas(scale: 1) {
      StageBoltsPainter.draw(&$0, strokes: [], seeds: [seed], halo: nil)
    }
    let both = try canvas(scale: 1) {
      StageBoltsPainter.draw(&$0, strokes: [], seeds: [seed], halo: halo)
    }
    // the pixel in the middle of the spark, 10.5 from the halo's centre: the inner wash there
    let under = bare.color(60, 50)
    #expect(under.r > 200, "the spark itself: \(under)")
    let wash = StageCanvasGradient.color(
      at: hypot(10.5, 0.5) / 40, stops: StageBolts.haloInnerStops(glow: 1))
    let want = OverlaySwatch.over(
      (Int((wash.r * 255).rounded()), Int((wash.g * 255).rounded()), Int((wash.b * 255).rounded())),
      wash.a, (under.r, under.g, under.b))
    #expect(both.near(60, 50, want, tol: 3), "\(both.color(60, 50)) against \(want)")
    // a pixel away from every glow is the same with and without the halo's reach (outside 1.25 R)
    #expect(bare.near(99, 99, Sw.background, tol: 1) && both.near(99, 99, Sw.background, tol: 1))
  }
}
