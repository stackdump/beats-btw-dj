import DJCore
import Darwin
import SwiftUI
import Testing

@testable import DJViews

private let bg = (5, 10, 20)  // #050a14
private let grid = (26, 42, 58)  // #1a2a3a
private let barLine = (47, 74, 106)  // #2f4a6a
private let sectionRed = (233, 69, 96)  // #e94560
private let textGrey = (136, 153, 170)  // #8899aa
private let magma0 = (0, 0, 4)  // MAGMA[0]

/// A scene painted on the scope background and nothing else.
private struct SceneOnly: View {
  let scene: SpectroScene
  var body: some View {
    Canvas { ctx, size in
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)), with: .color(ScopeColors.background.color))
      SpectroPainter.paint(scene, in: &ctx)
    }
  }
}

/// Hand-made window, as in SpectroSceneTests: 800 x 330, tickSec 0.125, "now" at 10 s, step 32 at
/// 8 s, so the plot (x 30 ... 800) shows steps -16 ... 48 and a step is 12.03 px wide.
private let handAxis = ScopeTimeAxis(
  tickSec: 0.125, tNow: 10,
  anchor: ScopeAnchor(time: 8, frame: 0, step: 32, tempo: 120, generation: 1), x0: 30, w: 770)

/// Steps 0 ... 39 are final and carry a ramp: bin j at -2j dB (j < 25), the rest silent.
private func handColumns() -> SpectroColumns {
  var c = SpectroColumns.empty
  for st in 0..<40 {
    c.step[st] = Int32(st)
    for j in 0..<25 { c.col[st * 28 + j] = Float(pow(10, -Double(2 * j) / 10)) }
  }
  c.cur = 40
  return c
}

/// Frames every 1/30 s over the 8 s window: row j at -10 - 2j dB, 20 dB down for the 5 frames in
/// 30 that are "between kicks", so the picture has stripes in time.
private func handFrames() -> MeasuredFrameRing {
  var r = MeasuredFrameRing()
  for i in 0..<300 {
    let t = 2 + Double(i) / 30 + 0.001
    let quiet: Float = i % 30 < 5 ? -20 : 0
    r.push(time: t, values: (0..<28).map { -10 - 2 * Float($0) + quiet })
  }
  return r
}

private func handScene(
  measured: Bool = false, sections: [ScopeSection] = [], hasNet: Bool = true,
  hasTables: Bool = true, fx: String? = "pre-fader tap"
) -> SpectroScene {
  SpectroScene.make(
    width: 800, height: 330,
    input: SpectroScene.Input(
      axis: handAxis, sections: sections, hasNet: hasNet, hasTables: hasTables,
      columns: handColumns(), measured: measured ? handFrames() : nil, fxLabel: fx))
}

/// The pixel at the centre of cell (c, y) of a block's image.
private func cellPixel(_ block: SpectroScene.Block, _ c: Int, _ y: Int) -> (x: Int, y: Int) {
  let r = block.imageRect!
  let bm = block.bitmap!
  let x = r.x + (Double(c) + 0.5) * r.w / Double(bm.width)
  let yy = r.y + (Double(y) + 0.5) * r.h / Double(bm.height)
  return (Int(x.rounded(.down)), Int(yy.rounded(.down)))
}

private func magma(_ level: UInt8) -> (Int, Int, Int) {
  let c = ScopeColors.magma.rgb(at: Int(level))
  return (Int(c.r), Int(c.g), Int(c.b))
}

private func lit(_ px: Pixels, _ x: Range<Int>, _ y: Range<Int>, _ c: (Int, Int, Int), tol: Int)
  -> Int
{
  px.count(inX: x, y: y) { r, g, b in
    abs(r - c.0) <= tol && abs(g - c.1) <= tol && abs(b - c.2) <= tol
  }
}

@MainActor
struct ScopeSpectroViewTests {
  // MARK: the painter, on hand-made scenes

  @Test func theModelImageIsPaintedCellForCellInMagmaColours() throws {
    let scene = handScene()
    let view = SceneOnly(scene: scene)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-model-hand")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    let m = try #require(scene.model)
    let img = try #require(m.bitmap)
    // every column of steps 0 ... 39 is column c = step + 16; check a spread of cells in several
    // columns at the rows of bins 0 (bottom), 3, 7, 12, 17, 22 and an empty one (bin 26)
    var checked = 0
    for step in [1, 6, 11, 17, 25, 33, 38] where step % 4 != 0 {
      for bin in [0, 3, 7, 12, 17, 22, 26] {
        let c = step + 16
        let y = 27 - bin
        let (x, yy) = cellPixel(m, c, y)
        let want = magma(img.level(c, y))
        #expect(
          px.near(x, yy, want, tol: 4),
          "step \(step) bin \(bin) at (\(x), \(yy)): \(px.color(x, yy)) vs \(want) (level \(img.level(c, y)))"
        )
        checked += 1
      }
    }
    #expect(checked == 49)
    // the ramp: the loudest cell is the brightest colour and the tops are not: bin 0 is level
    // 255, the pale yellow at the end of MAGMA
    let (x0, y0) = cellPixel(m, 17, 27)
    #expect(px.near(x0, y0, (252, 253, 191), tol: 4), "bin 0: \(px.color(x0, y0))")
    let (x2, y2) = cellPixel(m, 17, 27 - 22)
    #expect(!px.near(x2, y2, (252, 253, 191), tol: 60), "bin 22 is much quieter")
  }

  @Test func theImageIsNearestNeighbourNotSmoothed() throws {
    let scene = handScene()
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 330))
    let m = try #require(scene.model)
    let img = try #require(m.bitmap)
    // bins 0 and 3 are 255 and 224: with smoothing the pixels between two cell centres, in a
    // column, would run through the colours in between. Walk down one column of step 17 (c = 33)
    // from the centre of bin 3's cell to the centre of bin 0's: only these two colours (and the
    // two of the cells between) may be seen.
    let c = 17 + 16
    let x = cellPixel(m, c, 27).x
    var seen = Set<[Int]>()
    for y in 0..<318 {
      let p = px.color(x, y)
      if y >= cellPixel(m, c, 24).y && y <= cellPixel(m, c, 27).y {
        seen.insert([p.r / 8, p.g / 8, p.b / 8])
      }
    }
    // 4 cells (bins 3, 2, 1, 0) => at most ~4 colours, plus a few anti-aliased/grid pixels
    #expect(seen.count <= 8, "colours in the column: \(seen.count)")
    #expect(img.level(c, 27) == 255)
  }

  @Test func theImageIsClippedToThePlotAndTheGutterHoldsTheLabels() throws {
    let scene = handScene()
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 330))
    // columns of steps -16 ... -1 (x 30 ... 222) are not final: MAGMA black, not the background
    #expect(
      px.near(100, 100, magma0, tol: 2), "an empty column inside the plot: \(px.color(100, 100))")
    // the gutter is the plain background (the image would reach into it, it starts at x 30 here)
    #expect(px.near(10, 100, bg, tol: 2) && px.near(25, 200, bg, tol: 2))
    #expect(px.near(35, 100, magma0, tol: 2))
    // and the bar strip under the block is background too
    #expect(px.near(400, 324, bg, tol: 2) || px.near(401, 330 - 3, bg, tol: 2))
    // labels: "50" at y 287, "200" 217, "1k" 135, "4k" 65, "12k" 10 (x 2), grey text pixels
    for (name, y) in [("50", 287), ("200", 217), ("1k", 135), ("4k", 65), ("12k", 10)] {
      let n = lit(px, 1..<29, y..<(y + 11), textGrey, tol: 50)
      #expect(n > 5, "label \(name) at y \(y): \(n) text pixels")
    }
    // there is none between them
    #expect(lit(px, 1..<29, 160..<200, textGrey, tol: 50) == 0)
  }

  @Test func aFirstColumnThatStartsLeftOfThePlotIsClippedAtTheGutter() throws {
    // half a step on (10.0625 s): the image starts 6 px left of the plot (x 23.98), the way it
    // does at almost every moment of a live window. The gutter is background all the same.
    let ax = ScopeTimeAxis(
      tickSec: 0.125, tNow: 10.0625,
      anchor: ScopeAnchor(time: 8, frame: 0, step: 32, tempo: 120, generation: 1), x0: 30, w: 770)
    let scene = SpectroScene.make(
      width: 800, height: 330, input: SpectroScene.Input(axis: ax, columns: handColumns()))
    let image = try #require(scene.model?.imageRect)
    #expect(image.x < 29 && image.x > 23, "the image reaches into the gutter: \(image.x)")
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 330))
    // y 100 is between the 4k and 1k labels
    for x in [0, 8, 24, 26, 29] {
      #expect(px.near(x, 100, bg, tol: 2), "x \(x): \(px.color(x, 100))")
    }
    // and the plot starts at 30 with the first (empty) column
    for x in [30, 31, 35] {
      #expect(px.near(x, 100, magma0, tol: 2), "x \(x): \(px.color(x, 100))")
    }
  }

  @Test func theFxPointLineIsReadableOverTheWarmestCells() throws {
    // every step final and at full scale: pale yellow everywhere, as under a loud passage
    var loud = SpectroColumns.empty
    for st in 0..<80 {
      loud.step[st] = Int32(st)
      for j in 0..<28 { loud.col[st * 28 + j] = 1 }
    }
    loud.cur = 80
    let scene = SpectroScene.make(
      width: 800, height: 330,
      input: SpectroScene.Input(
        axis: handAxis, columns: loud, fxLabel: "pre-fader tap"))
    let view = SceneOnly(scene: scene)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-note-plate")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    let m = try #require(scene.model)
    let plate = try #require(m.notePlate)
    // away from grid lines: the yellow outside the plate, the dimmed one inside it
    let gridXs = Set(m.grid.lines.map { Int($0.rect.x) })
    let free = (680...760).first { x in
      (x - 1...x + 1).allSatisfy { !gridXs.contains($0) } && Double(x) < plate.x - 2
    }
    let outside = try #require(free)
    #expect(px.near(outside, 20, (252, 253, 191), tol: 3), "\(px.color(outside, 20))")
    // the background at 60% over (252, 253, 191): 0.4 * 252 + 0.6 * 5 = 104, 107, 88
    // (the first row of the plate, above the glyphs, right of the 'model' title)
    let inside = (735...Int(plate.x + plate.w - 1)).first { x in
      (x - 1...x + 1).allSatisfy { !gridXs.contains($0) }
    }
    let ix = try #require(inside)
    #expect(px.near(ix, 13, (104, 107, 88), tol: 6), "plate at \(ix): \(px.color(ix, 13))")
    // the text is on top of it
    #expect(lit(px, 688..<770, 14..<26, textGrey, tol: 50) > 15, "pre-fader tap")
  }

  @Test func theGridIsDrawnOverTheImageAndTheBarNumbersUnderIt() throws {
    let scene = handScene(sections: [ScopeSection(step: 24, name: "chorus")])
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 330))
    // bar line at step 16 (x 415) over the image (steps 0 ... 39 are final), beat line at step 20
    // (30 + 36 * 12.03 = 463.1 -> 463)
    #expect(px.near(415, 100, barLine, tol: 2), "bar line \(px.color(415, 100))")
    #expect(px.near(463, 100, grid, tol: 2), "beat line \(px.color(463, 100))")
    // the section marker: 2 px at 510 ... 511
    #expect(px.near(510, 100, sectionRed, tol: 6) && px.near(511, 100, sectionRed, tol: 6))
    // bar numbers in the strip under the block: "2" right of the bar line at 415, y 319
    #expect(lit(px, 417..<428, 319..<330, textGrey, tol: 50) > 3, "bar number 2")
    #expect(lit(px, 515..<560, 2..<14, sectionRed, tol: 50) > 10, "section name")
  }

  @Test func theTitleSaysModelWithItsFxPointBelowItAndWarmingUpUntilKernelsAreIn() throws {
    let on = try #require(renderPixels(SceneOnly(scene: handScene()), width: 800, height: 330))
    // "model" at (690, 2): 5 chars; the fx point at (690, 14)
    #expect(lit(on, 688..<725, 2..<14, textGrey, tol: 50) > 8, "model")
    #expect(lit(on, 688..<770, 14..<26, textGrey, tol: 50) > 15, "pre-fader tap")
    let warm = try #require(
      renderPixels(SceneOnly(scene: handScene(hasTables: false)), width: 800, height: 330))
    // "model (warming up)" is 18 characters: it reaches x ~790
    #expect(lit(warm, 760..<800, 2..<14, textGrey, tol: 50) > 5, "(warming up)")
    #expect(lit(on, 760..<800, 2..<14, textGrey, tol: 50) < 3)
  }

  @Test func theMeasuredBlockIsOnlyThereWhenAskedFor() throws {
    let off = try #require(renderPixels(SceneOnly(scene: handScene()), width: 800, height: 330))
    let on = try #require(
      renderPixels(SceneOnly(scene: handScene(measured: true)), width: 800, height: 330))
    let view = SceneOnly(scene: handScene(measured: true))
    savePNG(view, width: 800, height: 330, name: "scope-spectro-measured-hand")
    // the gap between the blocks (y 156 ... 161) is background; with measured off it is image
    #expect(on.near(400, 158, bg, tol: 2), "gap \(on.color(400, 158))")
    #expect(!off.near(400, 158, bg, tol: 2))
    // "measured" at (690, 164) only when on
    #expect(lit(on, 688..<750, 164..<176, textGrey, tol: 50) > 15, "measured title")
    #expect(lit(off, 688..<750, 164..<176, textGrey, tol: 50) < 3)
    // the labels repeat for the second block: 12k at y0 + 164.1 ... (162 + 2)
    #expect(lit(on, 1..<29, 164..<176, textGrey, tol: 50) > 5)
    // bar numbers only once, under the last block: none in the strip under the model block
    #expect(lit(on, 417..<428, 157..<162, textGrey, tol: 50) == 0, "no bar number between")
    #expect(lit(on, 417..<428, 319..<330, textGrey, tol: 50) > 3, "under the measured block")
  }

  @Test func theMeasuredImageIsPaintedSliceForSliceInMagmaColours() throws {
    let scene = handScene(measured: true)
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 330))
    let x = try #require(scene.measured)
    let img = try #require(x.bitmap)
    #expect(img.width == 160 && img.peakDb == -10)
    var lit = 0
    for slice in [3, 20, 47, 80, 101, 130, 158] {
      for bin in [0, 5, 14, 20, 25] {
        let y = 27 - bin
        let (cx, cy) = cellPixel(x, slice, y)
        let level = img.level(slice, y)
        // skip cells next to a grid line (a slice is 4.8 px wide, a grid line 1 px)
        let want = magma(level)
        let ok =
          px.near(cx, cy, want, tol: 4) || px.near(cx, cy, grid, tol: 2)
          || px.near(cx, cy, barLine, tol: 2)
        #expect(ok, "slice \(slice) bin \(bin) at (\(cx), \(cy)): \(px.color(cx, cy)) vs \(want)")
        if level > 0 { lit += 1 }
      }
    }
    #expect(lit > 20, "the picture really has colour in it: \(lit)")
    // louder frames (the first 25 of every 30) are brighter than the quiet ones: stripes
    let loud = magma(img.level(7, 27))
    let quiet = magma(img.level(0, 27))
    #expect(loud != quiet || img.level(7, 27) == img.level(0, 27))
  }

  @Test func aSourceWithNoNetShowsItsMessageAndStillTheMeasuredBlock() throws {
    let scene = SpectroScene.make(
      width: 800, height: 330,
      input: SpectroScene.Input(
        axis: ScopeTimeAxis(tickSec: 0.125, tNow: 10, anchor: nil, x0: 30, w: 770),
        hasNet: false, hasTables: false, measured: handFrames(), noNetText: "needs a net deck"))
    let view = SceneOnly(scene: scene)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-no-net")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    // the message at (38, 8)
    #expect(lit(px, 36..<140, 6..<20, textGrey, tol: 50) > 20, "needs a net deck")
    // the model block is empty (no black image: the background shows), the measured one is drawn
    #expect(px.near(400, 80, bg, tol: 2), "no model image \(px.color(400, 80))")
    let x = try #require(scene.measured)
    let (cx, cy) = cellPixel(x, 158, 27 - 5)
    #expect(px.near(cx, cy, magma(x.bitmap!.level(158, 22)), tol: 4))
    // and no grid without steps
    #expect(lit(px, 30..<800, 100..<110, grid, tol: 2) == 0)
  }

  @Test func withoutAUsableAxisOnlyTheBackgroundIsPainted() throws {
    let scene = SpectroScene.make(
      width: 800, height: 330,
      input: SpectroScene.Input(
        axis: ScopeTimeAxis(tickSec: 0.125, tNow: .nan, anchor: nil, x0: 30, w: 770)))
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 330))
    let off = px.count(inX: 0..<800, y: 0..<330) { r, g, b in
      abs(r - 5) > 2 || abs(g - 10) > 2 || abs(b - 20) > 2
    }
    #expect(off == 0)
  }
}

// MARK: - the view over a real offline engine

/// Kernels are rendered once for the whole file (a debug-build render of a song takes a second or
/// two) and shared by the tests' controllers.
@MainActor private let sharedKernels = ModelKernelCache()

@MainActor
struct ScopeSpectroEngineViewTests {
  /// A controller that has watched `seconds` of the rig, updated every 0.1 s as a 10 Hz UI would
  /// (so the measured frames are never more than a quarter second apart).
  private func settled(
    _ rig: ScopeViewRig, source: ScopeSource, measured: Bool, seconds: Double = 7
  ) throws -> (feed: ScopeFeed, controller: SpectroController) {
    let feed = rig.hub.feed(source)
    feed.acquire()
    let controller = SpectroController(cache: sharedKernels, readers: MeasuredReaderStore())
    try rig.run(seconds: 0.5)  // the feed learns the lanes
    controller.update(feed: feed, engine: rig.dj, measured: measured)
    controller.model?.waitForKernels()
    for _ in 0..<Int((seconds * 10).rounded()) {
      try rig.run(seconds: 0.1)
      controller.update(feed: feed, engine: rig.dj, measured: measured)
    }
    return (feed, controller)
  }

  /// Check cells of `block`'s image: where the level is at least `minLevel`, the pixel at the
  /// cell's centre is that MAGMA colour (cells under a grid line or a label are left out).
  private func checkCells(
    _ px: Pixels, _ block: SpectroScene.Block, minLevel: UInt8, want: Int = 10
  ) -> Int {
    guard let img = block.bitmap, let r = block.imageRect else { return 0 }
    let gridXs = Set(block.grid.lines.map { Int($0.rect.x) })
    var ok = 0
    var tried = 0
    for c in stride(from: 3, to: img.width, by: 7) {
      for y in 0..<img.height where img.level(c, y) >= minLevel {
        let (x, yy) = cellPixel(block, c, y)
        if gridXs.contains(x) || gridXs.contains(x - 1) || gridXs.contains(x + 1) { continue }
        if Double(x) < r.x || x >= 800 { continue }
        // titles and labels sit in the top right and the gutter: not cell colours, and the
        // plate behind the fx point dims what is under it
        if y < 4 && x > 680 { continue }
        if let p = block.notePlate, Double(x) >= p.x, Double(x) <= p.x + p.w, Double(yy) >= p.y,
          Double(yy) <= p.y + p.h
        {
          continue
        }
        tried += 1
        if px.near(x, yy, magma(img.level(c, y)), tol: 6) { ok += 1 }
      }
    }
    #expect(tried >= want, "cells to check: \(tried)")
    #expect(ok == tried, "\(tried - ok) of \(tried) cells are not their MAGMA colour")
    return ok
  }

  @Test func aNetDeckShowsTheModelSpectrogramInMagma() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("A"), measured: false)
    let line = ScopeStatusLine()
    let view = ScopeSpectroView(feed: feed, measured: false, hub: rig.hub, controller: controller)
      .environment(\.scopeStatusLine, line)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-engine-deck")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    let scene = controller.scene(feed: feed, width: 800, height: 330, measured: false)
    let m = try #require(scene.model)
    #expect(m.bitmap?.levels.filter { $0 > 200 }.count ?? 0 > 40, "the picture has loud cells")
    _ = checkCells(px, m, minLevel: 100)
    // the loudest of them are warm colours (MAGMA orange / yellow at 200+), as pixels
    let warm = px.count(inX: 30..<800, y: 0..<318) { r, g, b in r > 200 && g > 90 && b < 160 }
    #expect(warm > 2000, "warm pixels: \(warm)")
    // labels in the gutter, the title and the fx point
    #expect(lit(px, 1..<29, 280..<300, textGrey, tol: 60) > 5, "50 label")
    #expect(lit(px, 688..<725, 2..<14, textGrey, tol: 60) > 8, "model")
    #expect(lit(px, 688..<770, 14..<26, textGrey, tol: 60) > 15, "pre-fader tap")
    // and the panel header's line is the kernel status with the same fx point
    let text = try #require(line.text)
    #expect(text.hasPrefix("model · ") && text.hasSuffix(" · pre-fader tap"), "\(text)")
    // bar numbers in the strip under the block
    #expect(lit(px, 30..<800, 319..<330, textGrey, tol: 60) > 6, "bar numbers")
  }

  @Test func theMasterShowsItToo() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .master, measured: false, seconds: 5)
    let view = ScopeSpectroView(feed: feed, measured: false, hub: rig.hub, controller: controller)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-engine-master")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    let m = try #require(
      controller.scene(feed: feed, width: 800, height: 330, measured: false).model)
    _ = checkCells(px, m, minLevel: 100)
    #expect(lit(px, 688..<770, 14..<26, textGrey, tol: 60) > 10, "master")
    #expect(m.note?.text == "master")
  }

  @Test func measuredAddsTheAnalyserBlockBelowWithTheSameAxes() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("A"), measured: true)
    let view = ScopeSpectroView(feed: feed, measured: true, hub: rig.hub, controller: controller)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-engine-measured")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    let scene = controller.scene(feed: feed, width: 800, height: 330, measured: true)
    let model = try #require(scene.model)
    let measured = try #require(scene.measured)
    #expect(model.height == 156 && measured.y0 == 162)
    _ = checkCells(px, model, minLevel: 100)
    _ = checkCells(px, measured, minLevel: 100)
    // the gap between the blocks is background, the second block's title and bar numbers are there
    #expect(px.near(400, 158, bg, tol: 2))
    #expect(lit(px, 688..<750, 164..<176, textGrey, tol: 60) > 15, "measured")
    #expect(
      lit(px, 30..<800, 319..<330, textGrey, tol: 60) > 6, "bar numbers under the second block")
    // both halves have their loud cells in the low half of the plot (kick and bass)
    func loudRows(_ b: SpectroScene.Block) -> Double {
      let img = b.bitmap!
      var sum = 0.0
      var n = 0.0
      for y in 0..<28 {
        for x in 0..<img.width where img.level(x, y) >= 230 {
          sum += Double(y)
          n += 1
        }
      }
      return n > 0 ? sum / n : -1
    }
    #expect(
      loudRows(model) > 16 && loudRows(measured) > 16, "\(loudRows(model)) \(loudRows(measured))")
  }

  @Test func aSampleDeckSaysItNeedsANetDeckAndStillMeasures() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("B"), measured: true, seconds: 3)
    let line = ScopeStatusLine()
    let view = ScopeSpectroView(feed: feed, measured: true, hub: rig.hub, controller: controller)
      .environment(\.scopeStatusLine, line)
    savePNG(view, width: 800, height: 330, name: "scope-spectro-engine-sample")
    let px = try #require(renderPixels(view, width: 800, height: 330))
    #expect(lit(px, 36..<140, 6..<20, textGrey, tol: 60) > 20, "needs a net deck")
    #expect(px.near(400, 80, bg, tol: 2), "no model image")
    let scene = controller.scene(feed: feed, width: 800, height: 330, measured: true)
    _ = checkCells(px, try #require(scene.measured), minLevel: 80, want: 5)
    #expect(line.text == "needs a net deck")
  }

  @Test func theHostShowsTheRealSpectroNotThePlaceholder() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 0.5)
    // a Spectro opened on a playing deck makes the model and starts the kernels; here the shared
    // cache is the app's
    let model = ModelEngine.start(for: feed, engine: rig.dj)
    model.waitForKernels()
    try rig.run(seconds: 7)  // the hub keeps the model consuming
    var titles: [Bool: Int] = [:]
    for measured in [false, true] {
      let panel = VStack(spacing: 0) {
        ScopePanelView(
          hub: rig.hub, kind: .constant(.spectro), source: .constant(.deck("A")),
          measured: .constant(measured), windowHeight: 800)
        Spacer(minLength: 0)
      }
      savePNG(
        panel, width: 900, height: 700,
        name: "scope-spectro-host-\(measured ? "measured" : "model")")
      let px = try #require(renderPixels(panel, width: 900, height: 700))
      let warm = px.count(inX: 0..<900, y: 20..<700) { r, g, b in r > 200 && g > 90 && b < 160 }
      #expect(warm > 2000, "magma pixels in the body (measured \(measured)): \(warm)")
      // text in the title column: 'model' and the fx point, and 'measured' only when it is on
      titles[measured] = lit(px, 790..<860, 20..<700, textGrey, tol: 40)
    }
    let off = try #require(titles[false])
    let on = try #require(titles[true])
    #expect(off > 20, "titles drawn: \(off)")
    #expect(
      on > off + 20, "'measured' reaches the body only when the panel's flag is on: \(on) vs \(off)"
    )
  }

  @Test func theViewOutlivesNothingItNeedsToKeep() throws {
    // the host builds a new view for every switch of kind: a new controller finds the model the
    // first one started, with its history, and reads the same measured reader
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, first) = try settled(rig, source: .deck("A"), measured: true, seconds: 3)
    let model = try #require(first.model)
    let reader = try #require(first.reader)
    let fires = model.fires
    let second = SpectroController(cache: sharedKernels, readers: MeasuredReaderStore())
    try rig.run(seconds: 0.5)
    second.update(feed: feed, engine: rig.dj, measured: false)
    #expect(second.model === model && model.fires > fires)
    #expect(second.reader == nil, "not measured: no reader asked for")
    #expect(reader.frames.count > 20)
  }
}
