// BandsScene: everything to paint in one frame of the Bands scope (SPEC mode 5, scope.js
// `drawBands` at beats-bitwrap-io 095d030), as numbers. Pure: no SwiftUI, a function of its
// arguments. The numbers behind it are `BandsModel`.
//
// Layout (canvas points, y down; `W` the width). Gutter 44 (the row labels), row 14, block title
// 12, gap 8, a cell is `cw - 1` x `rh - 1` so cells are 1 px apart:
//
//   avail = W - 44 - 4          cw = max(3, min(22, avail / nBars))          nBars = maxBar + 1
//   shown = max(1, min(nBars, floor(avail / cw)))          b0 = nBars - shown   (the newest `shown`)
//
//   y 0        model block      title "model  Σ v²·‖H_k‖²·|H_fx|²  (0-9, 4 dB/step below band max)"
//                               at (44, y); rows from y + 12: row r (0 = sub) at
//                               y + 12 + (5 - r) * 14, so E is on top; label at (2, yy + 2)
//   (measured on:)
//   y + 96 + 8  measured block  "measured  (AnalyserNode, mean power per bar)"
//   + 96 + 8    residual block  "residual  measured − model, dB (per-band mean removed) · ±LIM dB"
//   under it    bar numbers at y + 1 (once, under the last block), then the tilt line 13 below
//               the last row: "tilt sub +1.2  low -0.3 ..."
//
// A cell is the row's digit colour (VIRIDIS 0 ... 9) or, in the residual block, RdBu 0 ... 32; an
// empty cell is #0a1220. The digit is printed in the cell when `cw >= 11` (white below 6, black
// from 6) at `(x + cw/2 - 3, yy + 2)`. Section starts are 2 px SECTION-coloured strips over the
// rows of every block at `round(44 + (bar - b0) * cw) - 1`, for sections strictly inside
// `(b0, nBars)`. Bar numbers (`b + 1`) every 1 / 4 / 8 bars for `cw >= 18 / >= 8 / else`, and at
// `b0`, at `(44 + (b - b0) * cw, y)`.
//
// The empty state (no bars yet) is one line at (8, 8): the fill-in hint once the model has its
// tables, else the kernel status (or, for a source with no net, the feed's own "needs a net deck").
//
// HEIGHT. The panel is 124 high without "measured" (the layout needs 109) and, in scope.js, 300
// with it, which cuts the residual's bottom row, the bar numbers and the tilt line (they end at
// 329). `ScopeKind` gives `measured` panels `measuredPanelHeight`; see the report's deviations.

import Foundation

public struct BandsScene: Sendable {
  public static let gutter = 44.0
  public static let rowHeight = 14.0
  public static let titleHeight = 12.0
  public static let gap = 8.0
  /// Right margin inside `avail`.
  public static let rightMargin = 4.0
  public static let minCell = 3.0
  public static let maxCell = 22.0
  /// Digits are printed when a cell is at least this wide.
  public static let digitMinCell = 11.0
  /// Digits from this one up are printed black, the ones below white.
  public static let darkDigitFrom = 6
  /// The line height of the 10 px text the scene is drawn in, for the height budget.
  public static let textHeight = 12.0
  /// `#0a1220`: a cell with no level.
  public static let emptyColor = ScopeColor(hex: "#0a1220")!
  /// One block: title + six rows.
  public static let blockHeight = titleHeight + Double(BandsModel.rows) * rowHeight

  public static let modelTitle = "model  Σ v²·‖H_k‖²·|H_fx|²  (0-9, 4 dB/step below band max)"
  public static let measuredTitle = "measured  (AnalyserNode, mean power per bar)"
  public static let waitingText = "bands fill in bar by bar as the track plays"

  public static func residualTitle(limit: Double) -> String {
    "residual  measured − model, dB (per-band mean removed) · ±\(BandsModel.toFixedText(limit, 0)) dB"
  }

  /// The y of the tilt line when "measured" is on: model + gap + measured + gap, the residual's
  /// title, six rows and 13.
  public static let tiltY =
    2 * (blockHeight + gap) + titleHeight + Double(BandsModel.rows) * rowHeight + 13
  /// What a "measured" panel needs so that nothing is cut: the tilt line and its text height.
  public static let measuredContentHeight = tiltY + textHeight
  /// What `ScopeKind` gives a bands panel with "measured" on (scope.js's 300 cut the bottom).
  public static let measuredPanelHeight = 332.0
  /// ... and without (scope.js: 124; the layout needs `blockHeight + 1 + textHeight`).
  public static let modelPanelHeight = 124.0

  // MARK: layout

  public struct Layout: Equatable, Sendable {
    /// `maxBar + 1`.
    public var barCount: Int
    /// `W - 44 - 4`.
    public var avail: Double
    /// Width of a bar's column.
    public var cw: Double
    /// Bars on screen, the newest.
    public var shown: Int
    /// The first bar on screen.
    public var first: Int
    /// A bar number every this many bars.
    public var every: Int
    /// Are digits printed in the cells?
    public var showsDigits: Bool { cw >= BandsScene.digitMinCell }
    /// The bars on screen.
    public var bars: Range<Int> { first..<barCount }
    /// x of the left edge of bar `b`'s cell.
    public func x(ofBar b: Int) -> Double { BandsScene.gutter + Double(b - first) * cw }
  }

  /// `drawBands`'s `avail`, `cw`, `shown`, `b0` and the axis step, for `barCount` (> 0) bars.
  public static func layout(width: Double, barCount n: Int) -> Layout {
    let avail = width - gutter - rightMargin
    let cw = max(minCell, min(maxCell, avail / Double(n)))
    // `floor(avail / cw)`; a width that is not a number (never from a canvas) shows one bar
    let fit = (avail / cw).rounded(.down)
    let shown = max(1, min(n, fit.isFinite ? Int(max(-1e9, min(1e9, fit))) : 1))
    return Layout(
      barCount: n, avail: avail, cw: cw, shown: shown, first: n - shown,
      every: cw >= 18 ? 1 : cw >= 8 ? 4 : 8)
  }

  // MARK: contents

  /// One cell. `index` is the digit (model, measured) or the RdBu entry (residual); nil: empty.
  public struct Cell: Equatable, Sendable {
    public var rect: LiveScopeRect
    public var index: Int?
    public var color: ScopeColor
  }

  /// A digit printed in a cell: `x`, `y` is the text's top-left.
  public struct Digit: Equatable, Sendable {
    public var digit: Int
    public var x: Double
    public var y: Double
    /// White below 6, black from 6.
    public var dark: Bool { digit >= BandsScene.darkDigitFrom }
  }

  public enum Kind: Equatable, Sendable {
    case model
    case measured
    case residual
  }

  /// One block of six rows.
  public struct Block: Equatable, Sendable {
    public var kind: Kind
    public var title: LiveScopeText
    /// The six row labels, E first (top to bottom).
    public var labels: [LiveScopeText]
    /// Row by row from the top (E), each from the oldest bar on screen to the newest.
    public var cells: [Cell]
    public var digits: [Digit]
    /// Section strips (2 px), SECTION colour.
    public var sections: [LiveScopeRect]
    /// The rows' top and bottom.
    public var top: Double
    public var bottom: Double
  }

  public var width: Double
  /// nil until there is a bar.
  public var layout: Layout?
  /// The empty-state line.
  public var message: LiveScopeText?
  public var blocks: [Block] = []
  /// Bar numbers, once, under the last block.
  public var axis: [LiveScopeText] = []
  public var tilt: LiveScopeText?
  /// The residual's scale (dB) and the statistics, when "measured" is on and there are bars.
  public var residualLimit: Double?
  public var stats: BandsStats?
  /// The lowest y anything is drawn at (the bottom of the last text).
  public var contentHeight = 0.0
  /// Set by the controller: increases with every scene it builds, for painters that cache.
  public var revision = 0

  public init(width: Double) { self.width = width }

  /// What a frame is made from.
  public struct Input: Sendable {
    public var model: BandsModel
    public var sections: [ScopeSection]
    /// The panel's "measured".
    public var measured: Bool
    /// Shown while there are no bars.
    public var emptyText: String
    /// For the statistics (`model`, `fires`).
    public var modelStatus: String
    public var fires: Int

    public init(
      model: BandsModel, sections: [ScopeSection] = [], measured: Bool = false,
      emptyText: String = BandsScene.waitingText, modelStatus: String = "", fires: Int = 0
    ) {
      self.model = model
      self.sections = sections
      self.measured = measured
      self.emptyText = emptyText
      self.modelStatus = modelStatus
      self.fires = fires
    }
  }

  // MARK: building

  public static func make(width: Double, input: Input) -> BandsScene {
    var s = BandsScene(width: width)
    let data = input.model
    let n = data.maxBar + 1
    guard n > 0 else {
      s.message = LiveScopeText(input.emptyText, x: 8, y: 8)
      s.contentHeight = 8 + textHeight
      return s
    }
    let lay = layout(width: width, barCount: n)
    s.layout = lay

    var y = 0.0
    // model
    let refM = data.rowRefs(.model)
    var model = heatBlock(
      .model, title: modelTitle, y: y, side: .model, refs: refM, data: data, lay: lay)
    model.sections = sectionStrips(input.sections, lay: lay, top: model.top, bottom: model.bottom)
    y = model.bottom
    s.blocks.append(model)
    guard input.measured else {
      s.axis = axisLabels(lay: lay, y: y + 1)
      s.contentHeight = y + 1 + textHeight
      return s
    }
    // measured
    y += gap
    let refX = data.rowRefs(.measured)
    var meas = heatBlock(
      .measured, title: measuredTitle, y: y, side: .measured, refs: refX, data: data, lay: lay)
    meas.sections = sectionStrips(input.sections, lay: lay, top: meas.top, bottom: meas.bottom)
    y = meas.bottom + gap
    s.blocks.append(meas)
    // residual
    let ag = data.agreement()
    let stats = data.stats(agreement: ag, modelStatus: input.modelStatus, fires: input.fires)
    let lim = data.residualLimit(bars: lay.bars, agreement: ag)
    s.stats = stats
    s.residualLimit = lim
    var res = residualBlock(y: y, data: data, agreement: ag, limit: lim, lay: lay)
    res.sections = sectionStrips(input.sections, lay: lay, top: res.top, bottom: res.bottom)
    s.blocks.append(res)
    s.axis = axisLabels(lay: lay, y: res.bottom + 1)
    s.contentHeight = res.bottom + 1 + textHeight
    if let t = stats.tiltText {
      s.tilt = LiveScopeText(t, x: gutter, y: res.bottom + 13)
      s.contentHeight = res.bottom + 13 + textHeight
    }
    return s
  }

  /// The model or the measured block: digits against each row's own loudest bar.
  private static func heatBlock(
    _ kind: Kind, title: String, y: Double, side: BandsSide, refs: [Double], data: BandsModel,
    lay: Layout
  ) -> Block {
    var block = Self.emptyBlock(kind, title: title, y: y)
    for r in stride(from: BandsModel.rows - 1, through: 0, by: -1) {
      let yy = block.top + Double(BandsModel.rows - 1 - r) * Self.rowHeight
      block.labels.append(LiveScopeText(BandsModel.labels[r], x: 2, y: yy + 2))
      for b in lay.bars {
        let x = lay.x(ofBar: b)
        let rect = LiveScopeRect(x: x, y: yy, w: lay.cw - 1, h: Self.rowHeight - 1)
        guard let d = BandsModel.digit(value: data.db(side, bar: b, row: r), ref: refs[r]) else {
          block.cells.append(Cell(rect: rect, index: nil, color: Self.emptyColor))
          continue
        }
        block.cells.append(Cell(rect: rect, index: d, color: ScopeColors.digitColors[d]))
        if lay.showsDigits {
          block.digits.append(Digit(digit: d, x: x + lay.cw / 2 - 3, y: yy + 2))
        }
      }
    }
    return block
  }

  /// The residual block: `measured - model`, per-row means removed, RdBu.
  private static func residualBlock(
    y: Double, data: BandsModel, agreement ag: BandsModel.Agreement, limit lim: Double, lay: Layout
  ) -> Block {
    var block = Self.emptyBlock(.residual, title: Self.residualTitle(limit: lim), y: y)
    for r in stride(from: BandsModel.rows - 1, through: 0, by: -1) {
      let yy = block.top + Double(BandsModel.rows - 1 - r) * Self.rowHeight
      block.labels.append(LiveScopeText(BandsModel.labels[r], x: 2, y: yy + 2))
      for b in lay.bars {
        let rect = LiveScopeRect(x: lay.x(ofBar: b), y: yy, w: lay.cw - 1, h: Self.rowHeight - 1)
        guard let d = data.residual(bar: b, row: r, agreement: ag) else {
          block.cells.append(Cell(rect: rect, index: nil, color: Self.emptyColor))
          continue
        }
        let i = BandsModel.residualIndex(d, limit: lim)
        block.cells.append(Cell(rect: rect, index: i, color: ScopeColors.residualColors[i]))
      }
    }
    return block
  }

  private static func emptyBlock(_ kind: Kind, title: String, y: Double) -> Block {
    let top = y + titleHeight
    return Block(
      kind: kind, title: LiveScopeText(title, x: gutter, y: y), labels: [], cells: [], digits: [],
      sections: [], top: top, bottom: top + Double(BandsModel.rows) * rowHeight)
  }

  /// scope.js `sections(y0, y1)`.
  static func sectionStrips(
    _ sections: [ScopeSection], lay: Layout, top: Double, bottom: Double
  ) -> [LiveScopeRect] {
    var out: [LiveScopeRect] = []
    for sec in sections {
      let bar = Double(sec.step) / 16
      if bar <= Double(lay.first) || bar >= Double(lay.barCount) { continue }
      let x = jsRound(gutter + (bar - Double(lay.first)) * lay.cw) - 1
      out.append(LiveScopeRect(x: x, y: top, w: 2, h: bottom - top))
    }
    return out
  }

  /// scope.js `axis(y)`.
  static func axisLabels(lay: Layout, y: Double) -> [LiveScopeText] {
    var out: [LiveScopeText] = []
    for b in lay.bars where (b + 1) % lay.every == 0 || b == lay.first {
      out.append(LiveScopeText(String(b + 1), x: lay.x(ofBar: b), y: y))
    }
    return out
  }
}
