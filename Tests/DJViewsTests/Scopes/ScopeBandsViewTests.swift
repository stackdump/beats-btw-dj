import DJCore
import Darwin
import SwiftUI
import Testing

@testable import DJViews

// The Bands view: the painter on hand-made scenes (colours, digits, rows, the three blocks), then
// the view over a real offline engine and inside the panel. `DJ_SHOT_DIR=/some/dir` also writes
// PNGs of every case for a human.

private let bg = (5, 10, 20)  // #050a14
private let textGrey = (136, 153, 170)  // #8899aa
private let sectionRed = (233, 69, 96)  // #e94560
private let emptyCell = (10, 18, 32)  // #0a1220

private func lit(_ px: Pixels, _ x: Range<Int>, _ y: Range<Int>, _ c: (Int, Int, Int), tol: Int)
  -> Int
{
  px.count(inX: x, y: y) { r, g, b in
    abs(r - c.0) <= tol && abs(g - c.1) <= tol && abs(b - c.2) <= tol
  }
}

private func rgb(_ c: ScopeColor) -> (Int, Int, Int) { c.rgb8 }

/// A point just inside the cell of bar `bar` (22 px a bar, as in a 14 bar scene at 800) and row
/// `row` (0 = sub, 5 = E) of the block whose rows start at `top`, clear of the digit and of the
/// section strip at its left edge.
private func inCell(bar: Int, row: Int, top: Int) -> (x: Int, y: Int) {
  let x: Int = 44 + 22 * bar + 3
  let y: Int = top + 14 * (5 - row) + 1
  return (x, y)
}

private func cellIs(
  _ px: Pixels, bar: Int, row: Int, top: Int, _ c: (Int, Int, Int), tol: Int = 3
) -> Bool {
  let p = inCell(bar: bar, row: row, top: top)
  return px.near(p.x, p.y, c, tol: tol)
}

/// A scene painted on the scope background and nothing else.
private struct SceneOnly: View {
  let scene: BandsScene
  var cache: BandsImageCache?
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    Canvas { ctx, size in
      MainActor.assumeIsolated {
        ctx.fill(
          Path(CGRect(origin: .zero, size: size)), with: .color(ScopeColors.background.color))
        BandsPainter.paint(
          scene, in: &ctx, size: size, scale: displayScale, cache: cache ?? BandsImageCache())
      }
    }
  }
}

/// `bars` bars; the model level of bar b, row r is `-4 * ((3b + 5r) % 10)` dB, so the digit is
/// `9 - ((3b + 5r) % 10)` (each row visits every residue within 10 bars: its loudest is 0 dB).
private func digitModel(bars: Int = 14) -> BandsModel {
  var m = [Double](repeating: 0, count: ModelGrid.maxBars * 6)
  for b in 0..<bars {
    for r in 0..<6 { m[b * 6 + r] = pow(10, -0.4 * Double((3 * b + 5 * r) % 10)) }
  }
  return BandsModel(modelBars: m, modelMaxBar: bars - 1, modelFrom: 0)
}

private func digit(_ b: Int, _ r: Int) -> Int { 9 - (3 * b + 5 * r) % 10 }

/// 12 bars of 0 dB on the model side; measured: 0 dB except bar 4 (+12 dB) and bar 8 (-12 dB).
/// Every bar is full. The residual of bar 4 is +12 dB (the deepest red, scale 12), bar 8 -12 (the
/// deepest blue), the rest 0 (the neutral).
private func divergentModel() -> BandsModel {
  var m = [Double](repeating: 0, count: ModelGrid.maxBars * 6)
  var x = m
  for b in 0..<12 {
    let g = b == 4 ? 16.0 : b == 8 ? 1 / 16.0 : 1
    for r in 0..<6 {
      m[b * 6 + r] = 1
      x[b * 6 + r] = g
    }
  }
  return BandsModel(
    modelBars: m, modelMaxBar: 11, modelFrom: 0, measBars: x,
    measCnt: [Float](repeating: 1, count: ModelGrid.maxBars), measMaxBar: 11, measFrom: 0,
    measAt: 12 * 16)
}

@MainActor
struct ScopeBandsPainterTests {
  private func render(
    _ scene: BandsScene, name: String, height: Int = 332, cache: BandsImageCache? = nil
  ) throws -> Pixels {
    let view = SceneOnly(scene: scene, cache: cache)
    // (a cache that is watched must not see the PNG's 2x render)
    if cache == nil { savePNG(view, width: 800, height: height, name: name) }
    return try #require(renderPixels(view, width: 800, height: height))
  }

  private func modelScene(
    _ data: BandsModel, measured: Bool = false, sections: [ScopeSection] = []
  ) -> BandsScene {
    BandsScene.make(
      width: 800, input: BandsScene.Input(model: data, sections: sections, measured: measured))
  }

  @Test func everyCellIsItsDigitsViridisColourWithETheTopRow() throws {
    let scene = modelScene(digitModel())
    let px = try render(scene, name: "scope-bands-model-hand", height: 124)
    // cell (bar b, row r): x 44 + 22 b, y 12 + 14 (5 - r), 21 x 13; sample inside, clear of the
    // digit (at x + 8)
    var checked = 0
    for b in [0, 1, 2, 5, 9, 13] {
      for r in 0..<6 {
        let d = digit(b, r)
        let want = rgb(ScopeColors.digitColors[d])
        #expect(cellIs(px, bar: b, row: r, top: 12, want), "bar \(b) row \(r) digit \(d)")
        checked += 1
      }
    }
    #expect(checked == 36)
    // E is the top row, sub the bottom one: the first row of cells starts at y 12, the last ends
    // at 95; above 12 is the title strip and below 96 the axis strip
    #expect(cellIs(px, bar: 0, row: 5, top: 12, rgb(ScopeColors.digitColors[digit(0, 5)])))
    #expect(cellIs(px, bar: 0, row: 0, top: 12, rgb(ScopeColors.digitColors[digit(0, 0)])))
    // the 1 px between cells and rows is the background
    #expect(px.near(65, 20, bg, tol: 2), "the gap right of a cell: \(px.color(65, 20))")
    #expect(px.near(50, 25, bg, tol: 2), "the gap under a row: \(px.color(50, 25))")
    // the gutter holds only the labels
    #expect(px.near(40, 20, bg, tol: 2))
  }

  @Test func theDigitIsPrintedWhiteBelowSixAndBlackFromSixWhenTheCellIsWideEnough() throws {
    let scene = modelScene(digitModel())
    let px = try render(scene, name: "scope-bands-digits-hand", height: 124)
    var whites = 0
    var blacks = 0
    for b in 0..<10 {
      for r in 0..<6 {
        let d = digit(b, r)
        let x0 = 44 + 22 * b + 6
        let y0 = 12 + 14 * (5 - r) + 1
        let white = px.count(inX: x0..<(x0 + 12), y: y0..<(y0 + 12)) { r, g, b in
          r > 200 && g > 200 && b > 200
        }
        // black text is anti-aliased at 10 px: count the pixels that are much darker than the fill
        let fill = rgb(ScopeColors.digitColors[d])
        let half = (fill.0 + fill.1 + fill.2) / 2
        let black = px.count(inX: x0..<(x0 + 12), y: y0..<(y0 + 12)) { r, g, b in
          r + g + b < half
        }
        if d < 6 {
          #expect(white > 3, "bar \(b) row \(r): white digit \(d) (\(white) px)")
          whites += 1
        } else {
          #expect(black > 3, "bar \(b) row \(r): black digit \(d) (\(black) px)")
          #expect(white == 0)
          blacks += 1
        }
      }
    }
    #expect(whites > 10 && blacks > 10, "\(whites) white, \(blacks) black")
  }

  /// Rows (top, bottom, inclusive) of the pixels in x, y that are glyph ink, nil for none.
  private func inkRows(_ px: Pixels, x: Range<Int>, y: Range<Int>, _ ink: (Int, Int, Int) -> Bool)
    -> (top: Int, bottom: Int)?
  {
    var rows: [Int] = []
    for yy in y where px.count(inX: x, y: yy..<(yy + 1), where: ink) > 0 { rows.append(yy) }
    guard let first = rows.first, let last = rows.last else { return nil }
    return (first, last)
  }

  @Test func theDigitAndTheLabelsSitWhereScopeJsPutsThemNotThreePointsLower() throws {
    // Chrome puts the baseline of a 10 px `textBaseline = 'top'` Menlo text 7.6 px below its y,
    // on a whole device pixel: a digit printed at `yy + 2` in a 13 px cell covers yy + 3 ... yy + 9
    // (measured on scope.js drawBands in Chrome: top row yy + 2.3, bottom yy + 9.6). A Canvas
    // `Text` anchored `.topLeading` put it at yy + 5 ... yy + 12, hard against the cell's edge.
    let scene = modelScene(digitModel())
    let px = try render(scene, name: "scope-bands-text-origin", height: 124)
    var checked = 0
    for b in 0..<10 {
      for r in 0..<6 {
        let d = digit(b, r)
        let yy = 12 + 14 * (5 - r)
        let x0 = 44 + 22 * b + 4
        let fill = rgb(ScopeColors.digitColors[d])
        // ink: a pixel that differs from the cell's fill (the glyph is anti-aliased at 10 px)
        let rows = inkRows(px, x: x0..<(x0 + 14), y: yy..<(yy + 13)) { r, g, b in
          max(abs(r - fill.0), abs(g - fill.1), abs(b - fill.2)) > 60
        }
        let ink = try #require(rows, "bar \(b) row \(r): digit \(d) has ink")
        #expect(
          ink.top - yy >= 2 && ink.top - yy <= 4, "bar \(b) row \(r): top row \(ink.top - yy)")
        #expect(
          ink.bottom - yy >= 8 && ink.bottom - yy <= 10,
          "bar \(b) row \(r): bottom \(ink.bottom - yy)")
        // centred in the 13 px cell to within a point
        let centre = Double(ink.top + ink.bottom + 1) / 2 - Double(yy)
        #expect(abs(centre - 6.5) <= 1, "bar \(b) row \(r): centre \(centre)")
        checked += 1
      }
    }
    #expect(checked == 60)
    // a row label (at yy + 2) and the first line of the title (at 0) the same way
    for r in 0..<6 {
      let yy = 12 + 14 * (5 - r)
      let ink = try #require(
        inkRows(px, x: 1..<14, y: yy..<(yy + 14)) { r, g, b in r > 90 && g > 100 && b > 110 })
      #expect(ink.top - yy >= 2 && ink.top - yy <= 4 && ink.bottom - yy <= 11, "label \(5 - r)")
    }
    let title = try #require(
      inkRows(px, x: 44..<500, y: 0..<12) { r, g, b in r > 90 && g > 100 && b > 110 })
    #expect(title.top <= 2 && title.bottom >= 7 && title.bottom <= 10, "title rows \(title)")
  }

  @Test func noDigitsAreDrawnWhenTheCellsAreNarrowerThanEleven() throws {
    let scene = modelScene(digitModel(bars: 69))
    let l = try #require(scene.layout)
    #expect(l.cw < 11 && l.cw > 10)
    let px = try render(scene, name: "scope-bands-narrow-hand", height: 124)
    // every pixel of every sampled cell is the one fill colour: no glyph on any of them
    var cells = 0
    for b in [0, 7, 30, 60, 68] {
      for r in 0..<6 {
        let cell = scene.blocks[0].cells[(5 - r) * 69 + b]
        let want = rgb(cell.color)
        let x0 = Int(cell.rect.x.rounded(.up)) + 1
        let y0 = Int(cell.rect.y) + 1
        let off = px.count(inX: x0..<(x0 + 8), y: y0..<(y0 + 11)) { r, g, b in
          abs(r - want.0) > 6 || abs(g - want.1) > 6 || abs(b - want.2) > 6
        }
        #expect(off == 0, "bar \(b) row \(r): \(off) pixels that are not the fill")
        cells += 1
      }
    }
    #expect(cells == 30)
  }

  @Test func anEmptyCellIsTheDarkBlueAndLabelsAndTitleAreInTheTextGrey() throws {
    var m = digitModel().modelBars
    m[2 * 6 + 3] = 0  // bar 2, himid
    let scene = modelScene(BandsModel(modelBars: m, modelMaxBar: 13, modelFrom: 0))
    let px = try render(scene, name: "scope-bands-empty-cell", height: 124)
    let p = inCell(bar: 2, row: 3, top: 12)
    #expect(px.near(p.x, p.y, emptyCell, tol: 2), "\(px.color(p.x, p.y))")
    #expect(px.near(p.x + 8, p.y + 5, emptyCell, tol: 2), "and no digit on it")
    // the title is one long line at (44, 0)
    #expect(lit(px, 44..<500, 0..<12, textGrey, tol: 50) > 150, "title")
    // a label per row at x 2
    for r in 0..<6 {
      let y0 = 12 + 14 * r + 1
      #expect(lit(px, 1..<30, y0..<(y0 + 13), textGrey, tol: 50) > 5, "label of row \(5 - r)")
    }
    // the bar numbers under the block
    #expect(lit(px, 44..<500, 97..<109, textGrey, tol: 50) > 25, "bar numbers")
  }

  @Test func withMeasuredOnTheResidualShowsRedWhereMeasuredIsLouderAndBlueWhereQuieter() throws {
    let scene = BandsScene.make(
      width: 800, input: BandsScene.Input(model: divergentModel(), measured: true))
    // the largest residual is 16x: 10 log10 16 = 12.04 dB, so the scale is that and not 12
    let want = 10 * log10(16.0)
    #expect(
      abs((scene.residualLimit ?? 0) - want) < 1e-9, "\(String(describing: scene.residualLimit))")
    let px = try render(scene, name: "scope-bands-residual-hand")
    // residual rows start at y 220; bar b at x 44 + 22 b
    let red = rgb(ScopeColors.residualColors[32])
    let blue = rgb(ScopeColors.residualColors[0])
    let neutral = rgb(ScopeColors.residualColors[16])
    for r in 0..<6 {
      #expect(cellIs(px, bar: 4, row: r, top: 220, red), "red \(r)")
      #expect(cellIs(px, bar: 8, row: r, top: 220, blue), "blue \(r)")
      for b in [0, 3, 5, 11] {
        #expect(cellIs(px, bar: b, row: r, top: 220, neutral), "bar \(b) row \(r)")
      }
    }
    #expect(rgb(ScopeColors.residualColors[32]) == (178, 24, 43))
    #expect(rgb(ScopeColors.residualColors[0]) == (33, 102, 172))
    // the model block above is all nine (constant levels); the measured one has the +12 dB bar
    // at digit 9 and the -12 dB bar six digits (24 dB) below it at 3
    #expect(cellIs(px, bar: 4, row: 3, top: 116, rgb(ScopeColors.digitColors[9])))
    #expect(cellIs(px, bar: 0, row: 3, top: 116, rgb(ScopeColors.digitColors[6])), "12 dB below")
    #expect(cellIs(px, bar: 8, row: 3, top: 116, rgb(ScopeColors.digitColors[3])), "24 dB below")
    #expect(cellIs(px, bar: 5, row: 5, top: 12, rgb(ScopeColors.digitColors[9])))
    // every block has its six row labels in the gutter: the model's rows start at 12, the
    // measured's at 116, the residual's at 220
    for top in [12, 116, 220] {
      for r in 0..<6 {
        let y0 = top + 14 * r + 1
        #expect(lit(px, 1..<30, y0..<(y0 + 13), textGrey, tol: 50) > 5, "label at \(top) row \(r)")
      }
    }
    // the titles of all three blocks (y 0, 104, 208), the scale in the residual's
    for y in [0, 104, 208] {
      #expect(lit(px, 44..<400, y..<(y + 12), textGrey, tol: 50) > 100, "title at \(y)")
    }
    // bar numbers once, under the residual (y 305), none between the blocks
    #expect(lit(px, 44..<400, 305..<317, textGrey, tol: 50) > 25, "bar numbers")
    #expect(
      lit(px, 44..<400, 97..<104, textGrey, tol: 50) == 0
        && lit(px, 44..<400, 201..<208, textGrey, tol: 50) == 0)
    // the tilt line under them: the model and measured sides differ by 0 dB on average, so 0 in
    // every band
    #expect(scene.tilt?.text == "tilt sub 0  low 0  lomid 0  himid 0  high 0")
    #expect(lit(px, 44..<400, 317..<329, textGrey, tol: 50) > 40, "tilt line is inside the panel")
  }

  @Test func sectionStartsAreRedStripsOverEveryBlockButNotOverTheGutter() throws {
    let scene = BandsScene.make(
      width: 800,
      input: BandsScene.Input(
        model: divergentModel(), sections: [ScopeSection(step: 5 * 16, name: "chorus")],
        measured: true))
    let px = try render(scene, name: "scope-bands-sections-hand")
    // round(44 + 5 * 22) - 1 = 153, 2 px wide, over the rows of all three blocks
    for y in [20, 60, 130, 170, 230, 290] {
      #expect(px.near(153, y, sectionRed, tol: 6) && px.near(154, y, sectionRed, tol: 6), "y \(y)")
      #expect(!px.near(152, y, sectionRed, tol: 30) && !px.near(155, y, sectionRed, tol: 30))
    }
    // not in the titles' rows or between the blocks
    #expect(px.near(153, 100, bg, tol: 2) || px.near(153, 100, textGrey, tol: 60))
    #expect(!px.near(153, 204, sectionRed, tol: 30))
  }

  @Test func withoutBarsOnlyTheOneLineHintIsDrawn() throws {
    let scene = BandsScene.make(width: 800, input: BandsScene.Input(model: .empty))
    let px = try render(scene, name: "scope-bands-empty", height: 124)
    #expect(lit(px, 8..<300, 8..<20, textGrey, tol: 50) > 60, "bands fill in bar by bar…")
    let off = px.count(inX: 0..<800, y: 20..<124) { r, g, b in
      abs(r - 5) > 2 || abs(g - 10) > 2 || abs(b - 20) > 2
    }
    #expect(off == 0, "nothing else")
  }

  @Test func aCachedPaintIsTheSamePictureAsAFreshOne() throws {
    var scene = BandsScene.make(
      width: 800, input: BandsScene.Input(model: divergentModel(), measured: true))
    scene.revision = 7
    let cache = BandsImageCache()
    let fresh = try render(scene, name: "scope-bands-cache-fresh")
    let first = try render(scene, name: "scope-bands-cache-1", cache: cache)
    #expect(cache.builds == 1)
    let again = try render(scene, name: "scope-bands-cache-2", cache: cache)
    #expect(cache.builds == 1, "a held scene is blitted, not drawn again")
    #expect(sameSamples(fresh.rgba, first.rgba) == .identical)
    #expect(sameSamples(first.rgba, again.rgba) == .identical)
    // a different scene with a new revision replaces the bitmap
    var other = BandsScene.make(width: 800, input: BandsScene.Input(model: digitModel()))
    other.revision = 8
    let px = try render(other, name: "scope-bands-cache-3", height: 124, cache: cache)
    #expect(cache.builds == 2)
    #expect(cellIs(px, bar: 0, row: 5, top: 12, rgb(ScopeColors.digitColors[digit(0, 5)])))
  }

  @Test func theBitmapIsKeyedByRevisionSizeAndScaleAndASceneWithoutARevisionIsNeverKept() {
    var scene = BandsScene.make(width: 800, input: BandsScene.Input(model: digitModel()))
    let size = CGSize(width: 800, height: 124)
    let cache = BandsImageCache()
    // revision 0 (a scene that is not from a controller): drawn every time
    _ = cache.image(for: scene, size: size, scale: 1)
    _ = cache.image(for: scene, size: size, scale: 1)
    #expect(cache.builds == 2)
    scene.revision = 3
    let a = cache.image(for: scene, size: size, scale: 1)
    let b = cache.image(for: scene, size: size, scale: 1)
    #expect(cache.builds == 3 && a === b)
    // a new size or scale is another bitmap, at device resolution
    let two = cache.image(for: scene, size: size, scale: 2)
    #expect(cache.builds == 4 && two?.width == 1600 && two?.height == 248)
    _ = cache.image(for: scene, size: CGSize(width: 801, height: 124), scale: 2)
    #expect(cache.builds == 5)
    // nothing to draw on: no bitmap
    #expect(cache.image(for: scene, size: .zero, scale: 2) == nil)
  }
}

// MARK: - the view over a real offline engine

/// Kernels are rendered once for the whole file and shared by the tests' controllers.
@MainActor private let bandsKernels = ModelKernelCache()

@MainActor
struct ScopeBandsEngineViewTests {
  /// A controller that has watched `seconds` of the rig, updated every 0.1 s as a 10 Hz UI would.
  private func settled(
    _ rig: ScopeViewRig, source: ScopeSource, measured: Bool, seconds: Double = 10,
    readers: MeasuredReaderStore = MeasuredReaderStore()
  ) throws -> (feed: ScopeFeed, controller: BandsController) {
    let feed = rig.hub.feed(source)
    feed.acquire()
    let controller = BandsController(cache: bandsKernels, readers: readers)
    try rig.run(seconds: 0.5)  // the feed learns the lanes
    controller.update(feed: feed, engine: rig.dj, measured: measured)
    controller.model?.waitForKernels()
    for _ in 0..<Int((seconds * 10).rounded()) {
      try rig.run(seconds: 0.1)
      controller.update(feed: feed, engine: rig.dj, measured: measured)
    }
    return (feed, controller)
  }

  /// Cells of a block that have a level are their colour on screen (sampled clear of the digit
  /// and of the 2 px section strips at the left edge of a cell).
  private func checkCells(_ px: Pixels, _ block: BandsScene.Block, want: Int = 20) -> Int {
    var ok = 0
    var tried = 0
    for c in block.cells where c.index != nil {
      let x = Int(c.rect.x) + 3
      let y = Int(c.rect.y) + 1
      if x >= 800 { continue }
      tried += 1
      if px.near(x, y, rgb(c.color), tol: 4) { ok += 1 }
    }
    #expect(tried >= want, "cells to check: \(tried)")
    #expect(ok == tried, "\(tried - ok) of \(tried) cells are not their colour")
    return ok
  }

  @Test func aNetDeckShowsTheModelDigitsAndThePanelsStatusLine() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("A"), measured: false)
    let line = ScopeStatusLine()
    let view = ScopeBandsView(feed: feed, measured: false, hub: rig.hub, controller: controller)
      .environment(\.scopeStatusLine, line)
    savePNG(view, width: 800, height: 124, name: "scope-bands-engine-deck")
    let px = try #require(renderPixels(view, width: 800, height: 124))
    let scene = controller.scene(feed: feed, width: 800, measured: false)
    let l = try #require(scene.layout)
    #expect(l.barCount >= 10, "bars \(l.barCount)")
    let model = scene.blocks[0]
    _ = checkCells(px, model)
    // every row has its loudest bar: the viridis yellow
    for row in 0..<6 {
      let cells = model.cells[row * l.shown..<(row + 1) * l.shown]
      #expect(cells.contains { $0.index == 9 }, "row \(row) has a 9")
    }
    // the kick keeps the low bands present: sub and low have levels in most bars
    let sub = model.cells[5 * l.shown..<6 * l.shown]
    #expect(sub.filter { $0.index != nil }.count >= l.shown - 2)
    #expect(lit(px, 44..<500, 0..<12, textGrey, tol: 50) > 150, "title")
    let text = try #require(line.text)
    #expect(text.hasPrefix("model · ") && text.hasSuffix(" · deck output"), "\(text)")
  }

  @Test func theMasterShowsItToo() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .master, measured: false, seconds: 8)
    let line = ScopeStatusLine()
    let view = ScopeBandsView(feed: feed, measured: false, hub: rig.hub, controller: controller)
      .environment(\.scopeStatusLine, line)
    savePNG(view, width: 800, height: 124, name: "scope-bands-engine-master")
    let px = try #require(renderPixels(view, width: 800, height: 124))
    let scene = controller.scene(feed: feed, width: 800, measured: false)
    #expect((scene.layout?.barCount ?? 0) >= 8)
    _ = checkCells(px, scene.blocks[0])
    #expect(line.text?.hasSuffix(" · master") == true, "\(String(describing: line.text))")
  }

  @Test func measuredAddsTheMeasuredBlockTheResidualAndTheTiltInsideThePanelHeight() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("A"), measured: true, seconds: 10)
    let height = Int(
      ScopeKind.bands.height(measured: true, laneCount: feed.lanes.count, windowHeight: 800))
    #expect(height == 332)
    let view = ScopeBandsView(feed: feed, measured: true, hub: rig.hub, controller: controller)
    savePNG(view, width: 800, height: height, name: "scope-bands-engine-measured")
    let px = try #require(renderPixels(view, width: 800, height: height))
    let scene = controller.scene(feed: feed, width: 800, measured: true)
    #expect(scene.blocks.map(\.kind) == [.model, .measured, .residual])
    for b in scene.blocks { _ = checkCells(px, b) }
    let l = try #require(scene.layout)
    // both halves have their loudest bar per row
    for block in scene.blocks.prefix(2) {
      for row in 0..<6 {
        #expect(block.cells[row * l.shown..<(row + 1) * l.shown].contains { $0.index == 9 })
      }
    }
    // the residual has bars (not the first, not the last) and the stats exist
    let stats = try #require(controller.stats)
    #expect(stats.bars >= 6, "bars with a fit: \(stats.bars)")
    // the bar mapping of the two sides agrees: with each row's mean removed the model follows
    // the analyser to within a few dB in every row (a one-bar shift between them would not),
    // and the offsets (units differ by about -52 dB) are alike across the bands: a small tilt.
    // (3.5 dB: the model's kernels are beats' voices, the deck plays dj's — open hats, filter
    // envelopes, part trims (which the model applies as gains) — so the hi-mid band, where hats
    // and snare meet, follows a little less closely than it did under 3)
    for b in stats.bands {
      #expect((b.rmsResidualDb ?? 99) < 3.5, "\(b.band) rms \(String(describing: b.rmsResidualDb))")
    }
    #expect(
      (stats.tiltDb ?? []).allSatisfy { abs($0.db) < 4 }, "\(String(describing: stats.tiltDb))")
    let res = scene.blocks[2]
    #expect(res.cells.filter { $0.index != nil }.count >= 6 * (stats.bars - 1))
    // the lowest text, the tilt line, ends inside the panel and is on screen
    let tilt = try #require(scene.tilt)
    #expect(tilt.y + BandsScene.textHeight <= Double(height))
    #expect(lit(px, 44..<400, Int(tilt.y)..<Int(tilt.y) + 12, textGrey, tol: 50) > 40, "tilt")
    // the residual's last row (sub) is whole: 290 ... 303 is inside the 332
    let sub = inCell(bar: 3, row: 0, top: 220)
    #expect(px.near(sub.x, sub.y, rgb(res.cells[5 * l.shown + 3].color), tol: 4))
  }

  @Test func aSampleDeckSaysItNeedsANetDeck() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("B"), measured: true, seconds: 2)
    let line = ScopeStatusLine()
    let view = ScopeBandsView(feed: feed, measured: true, hub: rig.hub, controller: controller)
      .environment(\.scopeStatusLine, line)
    savePNG(view, width: 800, height: 332, name: "scope-bands-engine-sample")
    let px = try #require(renderPixels(view, width: 800, height: 332))
    #expect(lit(px, 8..<130, 8..<20, textGrey, tol: 50) > 25, "needs a net deck")
    let off = px.count(inX: 0..<800, y: 22..<332) { r, g, b in
      abs(r - 5) > 2 || abs(g - 10) > 2 || abs(b - 20) > 2
    }
    #expect(off == 0)
    #expect(line.text == "needs a net deck")
  }

  @Test func theHostShowsTheRealBandsNotThePlaceholder() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 0.5)
    // the model is the app's shared one: make it here and wait for its kernels so the panel's
    // own controller (which uses the shared cache) finds the history
    let model = ModelEngine.start(for: feed, engine: rig.dj)
    model.waitForKernels()
    try rig.run(seconds: 9)
    for measured in [false, true] {
      let panel = VStack(spacing: 0) {
        ScopePanelView(
          hub: rig.hub, kind: .constant(.bands), source: .constant(.deck("A")),
          measured: .constant(measured), windowHeight: 800)
        Spacer(minLength: 0)
      }
      savePNG(
        panel, width: 900, height: 420, name: "scope-bands-host-\(measured ? "measured" : "model")")
      let px = try #require(renderPixels(panel, width: 900, height: 420))
      // viridis cells in the body (the placeholder has none)
      let viridis = px.count(inX: 0..<900, y: 20..<420) { r, g, b in
        (abs(r - 68) < 8 && abs(g - 1) < 8 && abs(b - 84) < 8)
          || (abs(r - 253) < 8 && abs(g - 231) < 8 && abs(b - 37) < 8)
          || (abs(r - 38) < 8 && abs(g - 130) < 8 && abs(b - 142) < 8)
      }
      #expect(viridis > 300, "viridis cells in the body (measured \(measured)): \(viridis)")
    }
  }

  @Test func aNewViewFindsTheModelAndTheMeasuredReaderTheLastOneStarted() throws {
    // the host builds a new view (and controller) for every switch of kind; the model is the
    // feed's and the reader the store's, so the history carries over from Spectro to Bands
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let store = MeasuredReaderStore()
    let (feed, first) = try settled(
      rig, source: .deck("A"), measured: true, seconds: 3, readers: store)
    let model = try #require(first.model)
    let reader = try #require(first.reader)
    #expect(reader.reads > 20)
    let bars = reader.maxBar
    let counts = Array(reader.measCnt[0..<(bars + 1)])
    #expect(bars >= 2 && counts.dropFirst().allSatisfy { $0 > 0 })
    let before = first.scene(feed: feed, width: 800, measured: true)

    let second = BandsController(cache: bandsKernels, readers: store)
    try rig.run(seconds: 0.5)
    second.update(feed: feed, engine: rig.dj, measured: true)
    #expect(second.model === model && second.reader === reader, "the same model and reader")
    #expect(reader.maxBar >= bars)
    for (b, n) in counts.enumerated() where b < bars {
      #expect(reader.measCnt[b] == n, "bar \(b) keeps its reads")
    }
    let again = second.scene(feed: feed, width: 800, measured: true)
    #expect((again.layout?.barCount ?? 0) >= (before.layout?.barCount ?? 0))
    #expect(again.blocks.map(\.kind) == [.model, .measured, .residual])

    // a view with "measured" off does not ask for a reader at all
    let third = BandsController(cache: bandsKernels, readers: store)
    third.update(feed: feed, engine: rig.dj, measured: false)
    #expect(third.model === model && third.reader == nil)
  }

  @Test func leavingTheBandsViewTakesItsTextOutOfThePanelHeader() throws {
    // Through the panel host, as the app does it: Bands speaks in the header, the user picks
    // another kind, and the header goes back to the host's own text. (ImageRenderer never runs
    // onDisappear, so this mounts the panel in a window that is never shown.)
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let line = ScopeStatusLine()
    func panel(_ kind: ScopeKind) -> ScopePanelView {
      ScopePanelView(
        hub: rig.hub, kind: .constant(kind), source: .constant(.deck("A")),
        measured: .constant(false), windowHeight: 800, statusLine: line)
    }
    let host = ViewHostHarness(panel(.bands))
    host.settle(0.6)
    let spoken = try #require(
      line.text, "the Bands view speaks in the header while it is on screen")
    #expect(spoken.hasPrefix("model · ") && spoken.contains(" · deck output"), "\(spoken)")
    host.replace(panel(.live))
    host.settle(0.6)
    #expect(
      !(line.text ?? "").contains("deck output"), "Bands' text is gone: \(line.text ?? "nil")")
    host.unmount()
    host.settle()
  }

  @Test func onlyTheOwnerOfTheStatusLineTakesItAwayWhenItsViewGoes() throws {
    // The view clears the line as the owner it set it for; a text that somebody else has spoken
    // since (the next mode's view, built before this one went) stays.
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (feed, controller) = try settled(rig, source: .deck("A"), measured: false, seconds: 1)
    let line = ScopeStatusLine()
    let view = ScopeBandsView(feed: feed, measured: false, hub: rig.hub, controller: controller)
      .environment(\.scopeStatusLine, line)
    let host = ViewHostHarness(view, width: 800, height: 124)
    host.settle()
    line.set("bands says this", owner: controller)
    host.unmount()
    host.settle()
    #expect(line.text == nil, "the owner's text goes with its view")

    let again = ViewHostHarness(view, width: 800, height: 124)
    again.settle()
    let other = BandsController()
    line.set("the next mode's text", owner: other)
    again.unmount()
    again.settle()
    #expect(line.text == "the next mode's text")
  }
}
