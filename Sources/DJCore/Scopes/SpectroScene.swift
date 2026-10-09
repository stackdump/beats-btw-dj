// SpectroScene: everything to paint in one frame of the Spectro scope (SPEC mode 2,
// scope.js `drawSpectro` / `freqLabels` / `drawGrid` at beats-bitwrap-io 095d030), as numbers.
//
// Layout (canvas points, y down). The window is `W x H`; `gutter` = 30 on the left holds the
// frequency labels, `axisH` = 12 at the bottom the bar numbers; the one block is
// `bh = H - 12` tall:
//
//   model block     y 0 ..< bh            the 66-column image stretched between the TIMES of its
//                                         first and last column (so the columns scroll sub-step
//                                         smoothly), clipped to x >= 30; grid with bar numbers;
//                                         frequency labels 50 200 1k 4k 12k at x 2; "model" at
//                                         (W - 110, 2)
//
// Paint order inside a block: image, beat and bar lines (over the image), bar numbers, section
// markers and their names, frequency labels, the block's title.
//
// Additions to the JS, for the app:
//   * `note` under the model block's title: what the model's FX are taken at
//     (`ModelEngine.fxPointLabel`: "pre-fader tap" / "deck output" / "master"). The model's FX
//     point is a documented product decision; the reader should be able to see it.
//   * `message` in the model block when there is no net deck behind the source ("needs a net
//     deck" / "no net deck"): the model has nothing to model there.
//   * A stopped song's grid ends at its newest anchor's step (see LiveScopeScene's header): the
//     engine's clock runs on after the song has stopped, the JS loop did not.

import Foundation

/// The shared grid of the time-based views (scope.js `drawGrid`) for a block from `y0` to `y1`.
public enum SpectroGrid {
  public struct Lines: Equatable, Sendable {
    public var lines: [LiveScopeScene.GridLine] = []
    /// Bar numbers `st / 16 + 1` at `(x + 3, y1 + 1)`; empty unless `labels` was asked for.
    public var barLabels: [LiveScopeText] = []
    public var sections: [LiveScopeScene.SectionMark] = []
  }

  /// A beat line every 4 steps (1 px wide, `y0 ..< y1`, at `round(x)`; a bar line when the step is
  /// a multiple of 16), the bar numbers when `labels`, and the section markers (2 px, name at
  /// `(x + 4, y0 + 2)`). Needs an anchor (`axis.hasAnchor`); a window of more than 4096 steps is
  /// not drawn. `running == false` ends everything at the newest anchor's step.
  public static func make(
    axis ax: ScopeTimeAxis, y0: Double, y1: Double, labels: Bool, sections secs: [ScopeSection],
    running: Bool
  ) -> Lines {
    var out = Lines()
    guard ax.hasAnchor else { return out }
    let sA = (ax.stepOf(ax.t0) / 4).rounded(.up) * 4
    let sB = running ? ax.stepOf(ax.tNow) : Swift.min(ax.stepOf(ax.tNow), ax.aS)
    guard sA.isFinite, sB.isFinite, sB - sA <= 4096 else { return out }
    var st = sA
    while st <= sB {
      defer { st += 4 }
      let x = ax.xOf(ax.timeOf(st))
      guard x.isFinite else { continue }
      let bar = st.truncatingRemainder(dividingBy: 16) == 0
      out.lines.append(
        LiveScopeScene.GridLine(
          rect: LiveScopeRect(x: jsRound(x), y: y0, w: 1, h: y1 - y0), bar: bar))
      if bar && labels && st >= 0 {
        let n = st / 16 + 1
        out.barLabels.append(
          LiveScopeText(abs(n) < 1e15 ? String(Int(n)) : String(n), x: x + 3, y: y1 + 1))
      }
    }
    let left = ax.stepOf(ax.t0)
    for sec in secs {
      let step = Double(sec.step)
      if step < left || step > sB { continue }
      let x = ax.xOf(ax.timeOf(step))
      guard x.isFinite else { continue }
      out.sections.append(
        LiveScopeScene.SectionMark(
          rect: LiveScopeRect(x: jsRound(x) - 1, y: y0, w: 2, h: y1 - y0),
          name: LiveScopeText(sec.name, x: x + 4, y: y0 + 2)))
    }
    return out
  }
}

public struct SpectroScene: Sendable {
  public static let gutter = 30.0
  public static let axisHeight = 12.0
  /// Where the titles sit: `W - 110`.
  public static let titleInset = 110.0
  /// scope.js `freqLabels`: the labelled frequencies.
  public static let labelledFrequencies: [(hz: Double, text: String)] = [
    (50, "50"), (200, "200"), (1000, "1k"), (4000, "4k"), (12000, "12k"),
  ]

  /// One spectrogram block.
  public struct Block: Sendable {
    /// Top and height of the block.
    public var y0: Double
    public var height: Double
    /// The image, nil when there is nothing to build it from (no anchor for the model image).
    public var bitmap: SpectroBitmap?
    /// Where the image is stretched to; `clip` is what of it shows. Nil with the bitmap.
    public var imageRect: LiveScopeRect?
    public var clip: LiveScopeRect
    public var grid = SpectroGrid.Lines()
    public var freqLabels: [LiveScopeText] = []
    /// "model" / "model (warming up)", TEXT colour.
    public var title: LiveScopeText
    /// A second line under the title (the model's FX point).
    public var note: LiveScopeText?
    /// A line of explanation in the block (no net deck).
    public var message: LiveScopeText?
  }

  public var width: Double
  public var height: Double
  /// Is there a usable time axis and room? When not, only the background is drawn.
  public var ok = false
  /// The height of the block: `H - 12`.
  public var blockHeight = 0.0
  public var model: Block?

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }

  /// What a frame is made from.
  public struct Input: Sendable {
    public var axis: ScopeTimeAxis
    public var sections: [ScopeSection]
    /// The transport plays (`feed.clock.playing`): else the grid ends at the newest anchor.
    public var running: Bool
    public var hasNet: Bool
    /// Any lane's kernels are in (else "model (warming up)").
    public var hasTables: Bool
    public var columns: SpectroColumns
    /// `ModelEngine.fxPointLabel`.
    public var fxLabel: String?
    /// The model block's message when `hasNet` is false.
    public var noNetText: String

    public init(
      axis: ScopeTimeAxis, sections: [ScopeSection] = [], running: Bool = true,
      hasNet: Bool = true, hasTables: Bool = true, columns: SpectroColumns = .empty,
      fxLabel: String? = nil, noNetText: String = "needs a net deck"
    ) {
      self.axis = axis
      self.sections = sections
      self.running = running
      self.hasNet = hasNet
      self.hasTables = hasTables
      self.columns = columns
      self.fxLabel = fxLabel
      self.noNetText = noNetText
    }
  }

  /// scope.js `freqLabels(ctx, x, y0, h)`: the labels at `x`, positioned on the log axis
  /// `30 ... 16000` of a block `h` tall starting at `y0`.
  public static func frequencyLabels(x: Double, y0: Double, h: Double) -> [LiveScopeText] {
    let lo = log(ModelGrid.specEdges[0])
    let hi = log(ModelGrid.specEdges[ModelGrid.ns])
    return labelledFrequencies.map { f in
      let y = y0 + h - (log(f.hz) - lo) / (hi - lo) * h
      return LiveScopeText(f.text, x: x, y: Swift.max(y0, Swift.min(y0 + h - 10, y - 5)))
    }
  }

  /// `drawSpectro` for a window `width x height` (the axis was made with `x0 = gutter` and
  /// `w = width - gutter`).
  public static func make(width: Double, height: Double, input: Input) -> SpectroScene {
    var s = SpectroScene(width: width, height: height)
    let ax = input.axis
    guard ax.ok else { return s }
    let bh = height - axisHeight
    guard bh.isFinite, bh > 0 else { return s }
    s.ok = true
    s.blockHeight = bh
    let titleX = width - titleInset

    // model: one column per step
    var model = Block(
      y0: 0, height: bh,
      clip: LiveScopeRect(x: gutter, y: 0, w: Swift.max(0, width - gutter), h: bh),
      title: LiveScopeText(
        input.hasTables || !input.hasNet ? "model" : "model (warming up)", x: titleX, y: 2))
    if ax.hasAnchor {
      let first = ax.stepOf(ax.t0).rounded(.down)
      if first.isFinite, abs(first) < 1e12 {
        let f = Int(first)
        let xa = ax.xOf(ax.timeOf(Double(f)))
        let xb = ax.xOf(ax.timeOf(Double(f + SpectroImage.modelColumns)))
        if xa.isFinite, xb.isFinite, xb > xa {
          model.bitmap = SpectroImage.model(first: f, columns: input.columns)
          model.imageRect = LiveScopeRect(x: xa, y: 0, w: xb - xa, h: bh)
        }
      }
    }
    model.grid = SpectroGrid.make(
      axis: ax, y0: 0, y1: bh, labels: true, sections: input.sections,
      running: input.running)
    model.freqLabels = frequencyLabels(x: 2, y0: 0, h: bh)
    if input.hasNet, let label = input.fxLabel {
      model.note = LiveScopeText(label, x: titleX, y: 14)
    }
    if !input.hasNet { model.message = LiveScopeText(input.noNetText, x: gutter + 8, y: 8) }
    s.model = model

    return s
  }
}
