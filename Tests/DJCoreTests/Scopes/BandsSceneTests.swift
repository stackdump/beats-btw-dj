import Darwin
import Testing

@testable import DJCore

// The geometry of the Bands scope (BandsScene): the layout rule against scope.js run by node, then
// every block, row, cell, digit, section strip, axis number and the tilt line of a frame whose
// numbers are known (BandsOracleData: 14 bars, bars 1 ... 12 full).

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

struct BandsLayoutTests {
  @Test func cwShownAndFirstFollowDrawBandsAtEveryBarCount() {
    // W = 800: avail 752. From node: (cw, shown, b0, every) of drawBands' arithmetic.
    let table: [(n: Int, cw: Double, shown: Int, first: Int, every: Int)] = [
      (1, 22, 1, 0, 1), (2, 22, 2, 0, 1), (10, 22, 10, 0, 1),
      (35, 21.485714285714284, 35, 0, 1), (36, 20.88888888888889, 36, 0, 1),
      (69, 10.898550724637682, 69, 0, 4), (70, 10.742857142857142, 70, 0, 4),
      (100, 7.52, 100, 0, 8), (101, 7.445544554455446, 101, 0, 8),
      (150, 5.013333333333334, 150, 0, 8), (250, 3.008, 250, 0, 8), (251, 3, 250, 1, 8),
      (1000, 3, 250, 750, 8), (1024, 3, 250, 774, 8),
    ]
    for t in table {
      let l = BandsScene.layout(width: 800, barCount: t.n)
      #expect(l.avail == 752)
      #expect(l.cw == t.cw, "n \(t.n): cw \(l.cw)")
      #expect(l.shown == t.shown && l.first == t.first && l.every == t.every, "n \(t.n): \(l)")
      #expect(l.bars == t.first..<t.n)
    }
  }

  @Test func narrowAndNegativeWidthsStillShowTheNewestBar() {
    let table: [(w: Double, cw: Double, shown: Int, first: Int)] = [
      (300, 22, 5, 0), (100, 10.4, 5, 0), (48, 3, 1, 4), (40, 3, 1, 4),
    ]
    for t in table {
      let l = BandsScene.layout(width: t.w, barCount: 5)
      #expect(l.cw == t.cw && l.shown == t.shown && l.first == t.first, "W \(t.w): \(l)")
    }
  }

  @Test func theAxisStepAndTheDigitsFollowTheCellWidth() {
    // node: n 40 -> cw 18.8 (every 1), 42 -> 17.9 (4), 68 -> 11.06 (digits), 69 -> 10.9, 94 -> 8
    // (4), 95 -> 7.9 (8)
    let table: [(n: Int, every: Int, digits: Bool)] = [
      (40, 1, true), (41, 1, true), (42, 4, true), (43, 4, true), (67, 4, true), (68, 4, true),
      (69, 4, false), (94, 4, false), (95, 8, false),
    ]
    for t in table {
      let l = BandsScene.layout(width: 800, barCount: t.n)
      #expect(l.every == t.every && l.showsDigits == t.digits, "n \(t.n): cw \(l.cw)")
    }
  }

  @Test func theGeometryConstantsAreTheJsOnes() {
    #expect(BandsScene.gutter == 44 && BandsScene.rowHeight == 14)
    #expect(BandsScene.titleHeight == 12 && BandsScene.gap == 8)
    #expect(BandsScene.blockHeight == 96, "12 + 6 * 14")
    #expect(BandsScene.emptyColor.rgb8 == (10, 18, 32), "#0a1220")
  }

  @Test func thePanelHeightsHoldWhatTheLayoutDraws() {
    // without measured: model block 96, bar numbers at 97, 12 high text
    let model = BandsScene.make(
      width: 800, input: BandsScene.Input(model: BandsOracleData.make(.main)))
    #expect(model.contentHeight == 109)
    #expect(
      model.contentHeight
        <= ScopeKind.bands.height(measured: false, laneCount: 0, windowHeight: 800))
    // with measured: the tilt line at 317 is the lowest thing, 329 with its text height; the JS's
    // 300 would cut the residual's last row (290 ... 303) and everything under it
    let all = BandsScene.make(
      width: 800, input: BandsScene.Input(model: BandsOracleData.make(.main), measured: true))
    #expect(BandsScene.tiltY == 317 && BandsScene.measuredContentHeight == 329)
    #expect(all.contentHeight == BandsScene.measuredContentHeight)
    let panel = ScopeKind.bands.height(measured: true, laneCount: 0, windowHeight: 800)
    #expect(panel == 332 && all.contentHeight <= panel)
    #expect(all.blocks.last!.bottom == 304 && 304 > 300, "the JS panel is 4 px short of the rows")
  }
}

struct BandsSceneTests {
  private func scene(
    measured: Bool = true, sections: [ScopeSection] = [], width: Double = 800,
    data: BandsModel = BandsOracleData.make(.main)
  ) -> BandsScene {
    BandsScene.make(
      width: width,
      input: BandsScene.Input(
        model: data, sections: sections, measured: measured, modelStatus: "model · 15 kernels",
        fires: 9))
  }

  @Test func theModelBlockIsATitleAndSixRowsWithETheTopRow() throws {
    let s = scene(measured: false)
    let b = try #require(s.blocks.first)
    #expect(s.blocks.count == 1 && b.kind == .model)
    #expect(b.title == LiveScopeText(BandsScene.modelTitle, x: 44, y: 0))
    #expect(b.top == 12 && b.bottom == 96)
    // labels at x 2, y = row top + 2; E first (the top), sub last
    #expect(b.labels.map(\.text) == ["E", "high", "himid", "lomid", "low", "sub"])
    #expect(b.labels.map(\.y) == [14, 28, 42, 56, 70, 84] && b.labels.allSatisfy { $0.x == 2 })
    // 14 bars at cw 22: the cell of bar b, row r is at x 44 + 22 b, y 12 + 14 (5 - r), 21 x 13
    #expect(b.cells.count == 6 * 14)
    #expect(b.cells[0].rect == LiveScopeRect(x: 44, y: 12, w: 21, h: 13))
    #expect(b.cells[1].rect == LiveScopeRect(x: 66, y: 12, w: 21, h: 13))
    #expect(b.cells[14].rect == LiveScopeRect(x: 44, y: 26, w: 21, h: 13), "the next row down")
    #expect(b.cells[6 * 14 - 1].rect == LiveScopeRect(x: 44 + 13 * 22, y: 82, w: 21, h: 13))
  }

  @Test func eachCellIsItsRowsDigitInViridisAndTheLoudestBarIsNine() throws {
    let d = BandsOracleData.make(.main)
    let s = scene(measured: false, data: d)
    let b = try #require(s.blocks.first)
    let refs = d.rowRefs(.model)
    for r in 0..<6 {
      let row = 5 - r  // E (5) is the first row of cells
      let cells = Array(b.cells[row * 14..<(row + 1) * 14])
      for bar in 0..<14 {
        let want = BandsModel.digit(value: d.modelDb(bar: bar, row: r), ref: refs[r])
        #expect(cells[bar].index == want, "bar \(bar) row \(r)")
        #expect(cells[bar].color == ScopeColors.digitColors[want!])
      }
      #expect(cells.contains { $0.index == 9 }, "row \(r) has its loudest bar")
    }
    // viridis: digit 0 is the dark purple, 9 the yellow
    #expect(ScopeColors.digitColors[0].rgb8 == (68, 1, 84))
    #expect(ScopeColors.digitColors[9].rgb8 == (253, 231, 37))
  }

  @Test func theDigitsAreTextInTheCellsWhenTheyAreWideEnough() throws {
    let s = scene(measured: false)
    let b = try #require(s.blocks.first)
    // cw 22 >= 11: every cell has its digit at (x + cw/2 - 3, yy + 2), white below 6, black from 6
    #expect(b.digits.count == 84)
    for (c, d) in zip(b.cells, b.digits) {
      #expect(d.digit == c.index && d.x == c.rect.x + 8 && d.y == c.rect.y + 2)
      #expect(d.dark == (d.digit >= 6))
    }
    // 69 bars: cw 10.9 < 11, no digits, the cells are still there
    var model = [Double](repeating: 0, count: 70 * 6)
    for i in 0..<model.count { model[i] = 1 + Double(i % 7) }
    let wide = BandsModel(modelBars: model, modelMaxBar: 68, modelFrom: 0)
    let narrow = BandsScene.make(width: 800, input: BandsScene.Input(model: wide))
    #expect(narrow.layout!.cw < 11 && narrow.blocks[0].digits.isEmpty)
    #expect(narrow.blocks[0].cells.count == 6 * 69)
  }

  @Test func anEmptyCellIsDarkAndNeverAColourOrADigit() throws {
    // bar 1 has no model power in row 2
    let d = BandsOracleData.make(.main)
    var model = d.modelBars
    model[1 * 6 + 2] = 0
    let cut = BandsModel(modelBars: model, modelMaxBar: 13, modelFrom: 0)
    let s = scene(measured: false, data: cut)
    let b = try #require(s.blocks.first)
    let cell = b.cells[(5 - 2) * 14 + 1]
    #expect(cell.index == nil && cell.color == BandsScene.emptyColor)
    #expect(b.digits.count == 83)
  }

  @Test func withMeasuredOnThreeBlocksStackWithGapsAndTheResidualHasItsScale() throws {
    let s = scene()
    #expect(s.blocks.map(\.kind) == [.model, .measured, .residual])
    let m = s.blocks[0]
    let x = s.blocks[1]
    let r = s.blocks[2]
    #expect(m.title.y == 0 && x.title.y == 104 && r.title.y == 208)
    #expect(m.top == 12 && x.top == 116 && r.top == 220)
    #expect(m.bottom == 96 && x.bottom == 200 && r.bottom == 304)
    #expect(x.title == LiveScopeText(BandsScene.measuredTitle, x: 44, y: 104))
    // the scale is the oracle's (9.4657...), printed with toFixed(0)
    #expect(close(s.residualLimit!, 9.46576174115211))
    #expect(r.title.text == "residual  measured − model, dB (per-band mean removed) · ±9 dB")
    #expect(r.title.x == 44)
    // the measured block is digits of the measured levels against the measured row maxima
    let d = BandsOracleData.make(.main)
    let refs = d.rowRefs(.measured)
    for (i, c) in x.cells.enumerated() {
      let row = 5 - i / 14
      #expect(c.index == BandsModel.digit(value: d.measDb(bar: i % 14, row: row), ref: refs[row]))
    }
    #expect(x.digits.count == 84 && r.digits.isEmpty, "the residual has colours, no digits")
    // every block labels its six rows, E on top, at x 2 and 2 below the row's top
    for block in s.blocks {
      #expect(
        block.labels.map(\.text) == ["E", "high", "himid", "lomid", "low", "sub"], "\(block.kind)")
      #expect(block.labels.allSatisfy { $0.x == 2 }, "\(block.kind)")
      let want: [Double] = (0..<6).map { (i: Int) -> Double in block.top + 14.0 * Double(i) + 2.0 }
      #expect(block.labels.map(\.y) == want, "\(block.kind)")
    }
    #expect(r.labels.map(\.y) == [222, 236, 250, 264, 278, 292])
  }

  @Test func theResidualCellsAreRdBuOfDOverTheScaleAndOnlyFullBarsHaveOne() throws {
    let d = BandsOracleData.make(.main)
    let s = scene(data: d)
    let r = s.blocks[2]
    let ag = d.agreement()
    let lim = s.residualLimit!
    for (i, c) in r.cells.enumerated() {
      let bar = i % 14
      let row = 5 - i / 14
      if let v = d.residual(bar: bar, row: row, agreement: ag) {
        let idx = BandsModel.residualIndex(v, limit: lim)
        #expect(c.index == idx && c.color == ScopeColors.residualColors[idx], "\(bar),\(row)")
      } else {
        #expect(c.index == nil && c.color == BandsScene.emptyColor)
        #expect(bar == 0 || bar == 13, "only the first and the still-playing bar are empty")
      }
    }
    #expect(r.cells.contains { ($0.index ?? 16) < 14 }, "blue cells (measured quieter)")
    #expect(r.cells.contains { ($0.index ?? 16) > 18 }, "red cells (measured louder)")
  }

  @Test func theResidualScaleIsTheLargestDifferenceOnScreenNotInTheBarsScrolledOff() throws {
    // 300 bars at 800: 250 on screen, b0 = 50. Model 0 dB everywhere; measured 0 dB except bar 10
    // (off screen, +16 dB) and bar 200 (on screen, +8 dB). Every row's measured mean is 24/300
    // = 0.08, so D(200) = 7.92 and D(10) = 15.92; the scale is what is on screen: 7.92.
    var model = [Double](repeating: 0, count: ModelGrid.maxBars * 6)
    var meas = model
    for b in 0..<300 {
      for r in 0..<6 {
        model[b * 6 + r] = 1
        meas[b * 6 + r] = b == 10 ? pow(10, 1.6) : b == 200 ? pow(10, 0.8) : 1
      }
    }
    let data = BandsModel(
      modelBars: model, modelMaxBar: 299, modelFrom: 0, measBars: meas,
      measCnt: [Float](repeating: 1, count: ModelGrid.maxBars), measMaxBar: 299, measFrom: 0,
      measAt: 300 * 16)
    let s = BandsScene.make(
      width: 800, input: BandsScene.Input(model: data, measured: true))
    let l = try #require(s.layout)
    #expect(l.first == 50 && l.shown == 250)
    #expect(close(s.residualLimit!, 7.92, 1e-9), "\(s.residualLimit!)")
    #expect(s.blocks[2].title.text.hasSuffix("· ±8 dB"), "not ±16")
    // the on-screen bar is the deepest red (D = lim), a quiet one the neutral entry
    let r = s.blocks[2]
    #expect(r.cells[200 - 50].index == 32)
    #expect(r.cells[100 - 50].index == BandsModel.residualIndex(-0.08, limit: 7.92))
    // the same data with the loud bar on screen: the scale follows it (15.92 -> 16)
    var moved = meas
    for r in 0..<6 {
      moved[10 * 6 + r] = 1
      moved[210 * 6 + r] = pow(10, 1.6)
    }
    let near = BandsModel(
      modelBars: model, modelMaxBar: 299, modelFrom: 0, measBars: moved,
      measCnt: [Float](repeating: 1, count: ModelGrid.maxBars), measMaxBar: 299, measFrom: 0,
      measAt: 300 * 16)
    let t = BandsScene.make(width: 800, input: BandsScene.Input(model: near, measured: true))
    #expect(t.blocks[2].title.text.hasSuffix("· ±16 dB"), "\(t.residualLimit!)")
  }

  @Test func theBarNumbersAreUnderTheLastBlockOnlyAndTheTiltLineUnderThem() throws {
    let model = scene(measured: false)
    #expect(model.axis.count == 14, "cw 22: a number for every bar")
    #expect(model.axis.map(\.text) == (1...14).map(String.init))
    #expect(model.axis.map(\.x) == (0..<14).map { 44 + 22 * Double($0) })
    #expect(model.axis.allSatisfy { $0.y == 97 }, "the model block's bottom + 1")
    #expect(model.tilt == nil && model.stats == nil && model.residualLimit == nil)
    let all = scene()
    #expect(all.axis.allSatisfy { $0.y == 305 }, "the residual's bottom 304 + 1")
    let tilt = try #require(all.tilt)
    #expect(tilt.x == 44 && tilt.y == 317)
    #expect(tilt.text == "tilt sub -8.2  low -0.2  lomid +7.9  himid +13.9  high -13.6")
    #expect(all.stats?.model == "model · 15 kernels" && all.stats?.fires == 9)
  }

  @Test func theBarNumbersThinOutWithNarrowCells() throws {
    // 60 bars at 800: cw 12.53, every 4: numbers 4, 8 ... and the first bar on screen
    var model = [Double](repeating: 1, count: 60 * 6)
    model[0] = 2
    let s = BandsScene.make(
      width: 800,
      input: BandsScene.Input(model: BandsModel(modelBars: model, modelMaxBar: 59, modelFrom: 0)))
    let l = try #require(s.layout)
    #expect(l.every == 4 && l.first == 0 && l.cw > 12)
    let wantAxis: [String] = ["1"] + (1...15).map { (k: Int) -> String in String(k * 4) }
    #expect(s.axis.map(\.text) == wantAxis)
    // and the newest 250 of 300 bars at 3 px: every 8, from bar 51 (index 50)
    let long = BandsModel(
      modelBars: [Double](repeating: 1, count: 300 * 6), modelMaxBar: 299, modelFrom: 0)
    let t = BandsScene.make(width: 800, input: BandsScene.Input(model: long))
    #expect(t.layout?.first == 50 && t.layout?.every == 8)
    #expect(t.axis.first?.text == "51" && t.axis.first?.x == 44)
    #expect(t.axis.map(\.text).dropFirst().first == "56", "then every 8th bar number")
    #expect(t.blocks[0].cells.count == 250 * 6)
  }

  @Test func sectionStartsAreTwoPixelStripsOverTheRowsOfEveryBlock() throws {
    // bar 0 (not > b0), bar 2 (step 32), bar 7.5 (step 120), bar 14 (not < nBars)
    let secs = [
      ScopeSection(step: 0, name: "intro"), ScopeSection(step: 32, name: "verse"),
      ScopeSection(step: 120, name: "chorus"), ScopeSection(step: 224, name: "outro"),
    ]
    let s = scene(sections: secs)
    for b in s.blocks {
      // round(44 + 2 * 22) - 1 = 87; round(44 + 7.5 * 22) - 1 = 208 (209 from the half)
      #expect(b.sections.map(\.x) == [87, 208], "\(b.kind)")
      #expect(b.sections.allSatisfy { $0.w == 2 && $0.y == b.top && $0.h == b.bottom - b.top })
    }
    // model only: one block
    #expect(scene(measured: false, sections: secs).blocks[0].sections.count == 2)
  }

  @Test func theSectionRuleUsesTheBarsOnScreenWhenTheyScroll() {
    // 300 bars at 3 px: b0 = 50. A section at bar 50 is the left edge (not drawn), 51 is at x 47.
    let long = BandsModel(
      modelBars: [Double](repeating: 1, count: 300 * 6), modelMaxBar: 299, modelFrom: 0)
    let secs = [
      ScopeSection(step: 50 * 16, name: "a"), ScopeSection(step: 51 * 16, name: "b"),
      ScopeSection(step: 299 * 16, name: "c"), ScopeSection(step: 300 * 16, name: "d"),
    ]
    let s = BandsScene.make(width: 800, input: BandsScene.Input(model: long, sections: secs))
    // round(44 + 1 * 3) - 1 = 46 and round(44 + 249 * 3) - 1 = 790
    #expect(s.blocks[0].sections.map(\.x) == [46, 790])
  }

  @Test func withoutBarsTheSceneIsOneLineAt8And8() {
    let hint = BandsScene.make(
      width: 800, input: BandsScene.Input(model: .empty, emptyText: BandsScene.waitingText))
    #expect(
      hint.message == LiveScopeText("bands fill in bar by bar as the track plays", x: 8, y: 8))
    #expect(hint.blocks.isEmpty && hint.layout == nil && hint.axis.isEmpty && hint.tilt == nil)
    let status = BandsScene.make(
      width: 800,
      input: BandsScene.Input(
        model: .empty, measured: true, emptyText: "model · rendering 9 kernels…"))
    #expect(status.message?.text == "model · rendering 9 kernels…" && status.blocks.isEmpty)
  }

  @Test func theResidualTitleRoundsTheScaleLikeToFixedZero() {
    #expect(BandsScene.residualTitle(limit: 6).hasSuffix("· ±6 dB"))
    #expect(BandsScene.residualTitle(limit: 24).hasSuffix("· ±24 dB"))
    #expect(BandsScene.residualTitle(limit: 6.5).hasSuffix("· ±7 dB"), "JS toFixed: ties go up")
    #expect(BandsScene.residualTitle(limit: 9.4657).hasSuffix("· ±9 dB"))
  }

  @Test func aMeasuredSceneWithNoFullBarHasEmptyResidualAndNoTilt() throws {
    // measured side not started: nothing is full
    let none = BandsOracleData.make(.main, measFrom: .infinity, measAt: -1)
    let s = scene(data: none)
    let r = s.blocks[2]
    #expect(r.cells.allSatisfy { $0.index == nil })
    #expect(s.residualLimit == 6 && s.tilt == nil)
    #expect(s.stats?.bands.allSatisfy { $0.bars == 0 } == true)
    #expect(s.contentHeight == 305 + 12, "the axis is the lowest text without a tilt line")
  }
}
