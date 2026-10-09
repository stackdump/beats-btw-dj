import Darwin
import Testing

@testable import DJCore

// The geometry of a Spectro frame (SpectroScene), worked out by hand on one axis: tickSec 0.125,
// "now" at 10 s, the anchor putting step 32 at 8 s, so the 8 s window starts at t0 = 2 s (step
// -16) and 12.5 steps are 770 / 64 = 12.03 px each in a plot that starts at x 30 and is 770 wide.

private func axis(tNow: Double = 10, anchor: Bool = true) -> ScopeTimeAxis {
  ScopeTimeAxis(
    tickSec: 0.125, tNow: tNow,
    anchor: anchor ? ScopeAnchor(time: 8, frame: 0, step: 32, tempo: 120, generation: 1) : nil,
    x0: 30, w: 770)
}

private func scene(
  width: Double = 800, height: Double = 330, axis ax: ScopeTimeAxis = axis(),
  sections: [ScopeSection] = [], running: Bool = true, hasNet: Bool = true,
  hasTables: Bool = true, measured: MeasuredFrameRing? = nil, fx: String? = nil,
  columns: SpectroColumns = oracleColumns()
) -> SpectroScene {
  SpectroScene.make(
    width: width, height: height,
    input: SpectroScene.Input(
      axis: ax, sections: sections, running: running, hasNet: hasNet, hasTables: hasTables,
      columns: columns, measured: measured, fxLabel: fx))
}

struct SpectroSceneTests {
  // MARK: layout

  @Test func aModelOnlyFrameIsOneBlockOverTheAxisStrip() throws {
    let s = scene()
    #expect(s.ok && s.measured == nil)
    #expect(s.blockHeight == 318, "330 - 12")
    let m = try #require(s.model)
    #expect(m.y0 == 0 && m.height == 318)
    #expect(m.clip == LiveScopeRect(x: 30, y: 0, w: 770, h: 318))
    #expect(m.title == LiveScopeText("model", x: 690, y: 2), "W - 110, 2")
  }

  @Test func measuredAddsASecondBlockSixPointsBelowAndHalvesBoth() throws {
    let s = scene(measured: oracleFrames())
    #expect(s.blockHeight == 156, "(330 - 12 - 6) / 2")
    let m = try #require(s.model)
    let x = try #require(s.measured)
    #expect(m.height == 156 && m.clip == LiveScopeRect(x: 30, y: 0, w: 770, h: 156))
    #expect(x.y0 == 162, "156 + 6")
    #expect(x.clip == LiveScopeRect(x: 30, y: 162, w: 770, h: 156))
    #expect(x.imageRect == x.clip, "160 slices over the whole plot")
    #expect(x.title == LiveScopeText("measured", x: 690, y: 164), "(W - 110, y0 + 2)")
    #expect(x.bitmap?.width == 160 && x.bitmap?.height == 28)
  }

  @Test func withoutAUsableAxisOrRoomOnlyTheBackgroundIsLeft() {
    #expect(!scene(axis: axis(tNow: .nan)).ok, "no finite now")
    #expect(!scene(height: 12).ok && !scene(height: 5).ok, "no room for a block")
    #expect(!scene(height: 18, measured: oracleFrames()).ok, "two blocks need 12 + 6 + 2 bh")
    #expect(scene(height: 13).ok, "one pixel high is still a block")
    let off = scene(axis: axis(tNow: .nan))
    #expect(off.model == nil && off.measured == nil)
  }

  // MARK: the model image's stretch

  @Test func theModelImageIsStretchedBetweenTheTimesOfItsFirstAndLastColumn() throws {
    // first = floor(stepOf(2 s)) = -16; the column of step -16 starts at 2 s = x 30 and the
    // column after the last (step -16 + 66 = 50) at 10.25 s = 30 + 8.25 / 8 * 770
    let m = try #require(scene().model)
    let r = try #require(m.imageRect)
    #expect(r.x == 30 && r.y == 0 && r.h == 318)
    #expect(abs(r.w - 794.0625) < 1e-9, "66 steps: \(r.w)")
    #expect(m.bitmap?.width == 66 && m.bitmap?.height == 28)
  }

  @Test func theColumnsScrollBySubStepSteps() throws {
    // half a step later (10.0625 s): the same 66 columns, the first now 6.016 px left of x 30
    let r = try #require(scene(axis: axis(tNow: 10.0625)).model?.imageRect)
    #expect(abs(r.x - 23.984375) < 1e-9, "30 - 0.0625 / 8 * 770 = \(r.x)")
    #expect(abs(r.w - 794.0625) < 1e-9, "the same width")
    // a full step later the window starts one step further on: first = -15, same x
    let n = try #require(scene(axis: axis(tNow: 10.125)).model?.imageRect)
    #expect(abs(n.x - 30) < 1e-9 && abs(n.w - 794.0625) < 1e-9, "x \(n.x)")
    // and the image holds step -15 first: its first column is step -15
    let a = scene(axis: axis(tNow: 10.125))
    #expect(
      a.model?.bitmap == SpectroImage.model(first: -15, columns: oracleColumns()),
      "the first column is the step the left edge is at")
  }

  @Test func theBitmapIsTheModelImageOfTheFirstVisibleStep() throws {
    // t0 = 2 + 0.0625 -> step -15.5 -> floor -16
    let m = try #require(scene(axis: axis(tNow: 10.0625)).model)
    #expect(m.bitmap == SpectroImage.model(first: -16, columns: oracleColumns()))
    // a window further into the song: now = 20 s is step 32 + 12 / 0.125 = 128, left edge 64
    let late = scene(axis: axis(tNow: 20))
    #expect(late.model?.bitmap == SpectroImage.model(first: 64, columns: oracleColumns()))
    #expect(late.model?.bitmap?.levels.contains { $0 != 0 } == true)
  }

  @Test func theMeasuredBitmapIsTheMeasuredImageOfTheWindow() throws {
    let ring = oracleFrames()
    let ax = axis(tNow: 100 + 699.0 / 30 + 0.01)
    let s = scene(axis: ax, measured: ring)
    let x = try #require(s.measured)
    #expect(x.bitmap == SpectroImage.measured(frames: ring, t0: ax.t0, win: ax.win))
  }

  @Test func withoutAnAnchorTheModelHasNoImageAndNoGridButTheMeasuredBlockStillWorks() throws {
    let ring = oracleFrames()
    let s = scene(axis: axis(anchor: false), measured: ring)
    let m = try #require(s.model)
    #expect(m.bitmap == nil && m.imageRect == nil)
    #expect(m.grid.lines.isEmpty && m.grid.barLabels.isEmpty)
    #expect(m.freqLabels.count == 5 && m.title.text == "model", "labels and title stay")
    let x = try #require(s.measured)
    #expect(x.bitmap != nil, "slices depend on time alone")
    #expect(x.grid.lines.isEmpty)
  }

  @Test func aSourceWithNoNetSaysSoAndKeepsTheMeasuredHalf() throws {
    let s = scene(
      axis: axis(anchor: false), hasNet: false, hasTables: false,
      measured: oracleFrames(), fx: "master")
    let m = try #require(s.model)
    #expect(m.message == LiveScopeText("needs a net deck", x: 38, y: 8))
    #expect(m.bitmap == nil && m.note == nil, "no FX point for a model that is not there")
    #expect(m.title.text == "model", "not 'warming up' forever on a sample deck")
    #expect(s.measured?.bitmap != nil)
    // a net deck says nothing of the kind
    #expect(scene().model?.message == nil)
  }

  @Test func theTitleSaysWarmingUpUntilAnyKernelIsIn() {
    #expect(scene(hasTables: false).model?.title.text == "model (warming up)")
    #expect(scene(hasTables: true).model?.title.text == "model")
  }

  @Test func theFxPointIsALineUnderTheTitle() {
    #expect(scene(fx: "pre-fader tap").model?.note == LiveScopeText("pre-fader tap", x: 690, y: 14))
    #expect(scene().model?.note == nil)
  }

  // MARK: labels

  @Test func frequencyLabelsSitOnTheLogAxisInTheGutter() {
    let full = SpectroScene.frequencyLabels(x: 2, y0: 0, h: 318)
    #expect(full.map(\.text) == ["50", "200", "1k", "4k", "12k"])
    #expect(full.allSatisfy { $0.x == 2 })
    for (l, want) in zip(full, SpectroOracle.labelsFull) {
      #expect(abs(l.y - want[0]) < 1e-9, "\(l.text): \(l.y) vs \(want[0])")
    }
    let second = SpectroScene.frequencyLabels(x: 2, y0: 162, h: 156)
    for (l, want) in zip(second, SpectroOracle.labelsSecond) {
      #expect(abs(l.y - want[0]) < 1e-9, "\(l.text): \(l.y) vs \(want[0])")
    }
    // by hand: 1 kHz in 30 ... 16 kHz is ln(1000/30) / ln(16000/30) = 0.5585 of the way up
    let y1k = 318 - log(1000.0 / 30) / log(16000.0 / 30) * 318 - 5
    #expect(abs(full[2].y - y1k) < 1e-9)
  }

  @Test func theLabelsAreKeptInsideTheBlock() {
    // a short block: 12k would be above the top (y0), 50 below the bottom - 10
    let small = SpectroScene.frequencyLabels(x: 2, y0: 0, h: 40)
    for (l, want) in zip(small, SpectroOracle.labelsSmall) {
      #expect(abs(l.y - want[0]) < 1e-9, "\(l.text)")
    }
    #expect(small.allSatisfy { $0.y >= 0 && $0.y <= 30 })
    #expect(small.last?.y == 0 && small.first?.y == 30)
  }

  @Test func theLabelsOfBothBlocksAreAtX2() throws {
    let s = scene(measured: oracleFrames())
    #expect(try #require(s.model).freqLabels.allSatisfy { $0.x == 2 })
    let x = try #require(s.measured)
    #expect(x.freqLabels.count == 5 && x.freqLabels.allSatisfy { $0.x == 2 && $0.y >= 162 })
  }

  // MARK: grid

  @Test func theGridIsABeatLineEveryFourStepsAndABarLineEverySixteen() throws {
    let m = try #require(scene().model)
    let g = m.grid
    // steps -16 ... 48 every 4: 17 lines; bars at -16, 0, 16, 32, 48
    #expect(g.lines.count == 17 && g.lines.filter(\.bar).count == 5)
    // step 0 is at 4 s: x = 30 + 2 / 8 * 770 = 222.5 -> 223 (Math.round, ties up); step 32 at
    // 8 s: 30 + 6 / 8 * 770 = 607.5 -> 608; step -16 at x 30 and 48 at 800
    let bars = g.lines.filter(\.bar).map(\.rect.x)
    #expect(bars == [30, 223, 415, 608, 800], "\(bars)")
    #expect(g.lines.allSatisfy { $0.rect.y == 0 && $0.rect.w == 1 && $0.rect.h == 318 })
    // the line between: step -12 at 30 + 0.5 / 8 * 770 = 78.125 -> 78
    #expect(g.lines[1].rect.x == 78 && !g.lines[1].bar)
  }

  @Test func barNumbersAreUnderTheLastBlockOnly() throws {
    // alone: under the model block, 1 pt below its bottom; bar k is `step / 16 + 1`
    let alone = try #require(scene().model).grid.barLabels
    #expect(alone.map(\.text) == ["1", "2", "3", "4"], "steps 0, 16, 32, 48 (not -16)")
    #expect(alone.map(\.y) == [319, 319, 319, 319], "bh + 1")
    #expect(alone.map(\.x) == [225.5, 418, 610.5, 803], "line x + 3 (unrounded)")
    // with measured: none under the model block, they are under the second
    let both = scene(measured: oracleFrames())
    #expect(try #require(both.model).grid.barLabels.isEmpty)
    let under = try #require(both.measured).grid.barLabels
    #expect(under.map(\.text) == ["1", "2", "3", "4"])
    #expect(under.allSatisfy { $0.y == 162 + 156 + 1 })
    // and the measured block's lines run over its own rows
    #expect(
      try #require(both.measured).grid.lines.allSatisfy { $0.rect.y == 162 && $0.rect.h == 156 })
  }

  @Test func sectionsAreTwoPixelMarkersWithTheirNames() throws {
    let secs = [
      ScopeSection(step: -20, name: "intro"), ScopeSection(step: 24, name: "chorus"),
      ScopeSection(step: 60, name: "outro"),
    ]
    let g = try #require(scene(sections: secs).model).grid
    // only the one inside the window [-16, 48]: step 24 at 7 s = 30 + 5 / 8 * 770 = 511.25
    #expect(g.sections.count == 1)
    let m = g.sections[0]
    #expect(m.rect == LiveScopeRect(x: 510, y: 0, w: 2, h: 318), "round(511.25) - 1")
    #expect(m.name == LiveScopeText("chorus", x: 515.25, y: 2), "(x + 4, y0 + 2)")
    // in the measured block they start at its top
    let x = try #require(scene(sections: secs, measured: oracleFrames()).measured).grid
    #expect(x.sections[0].rect.y == 162 && x.sections[0].name.y == 164)
  }

  @Test func aStoppedSongsGridEndsAtItsNewestAnchor() throws {
    let g = try #require(scene(running: false).model).grid
    // newest anchor: step 32; the lines stop there instead of running on to step 48
    #expect(g.lines.count == 13 && g.lines.last?.rect.x == 608)
    #expect(g.barLabels.map(\.text) == ["1", "2", "3"])
    let secs = [ScopeSection(step: 40, name: "later")]
    #expect(try #require(scene(sections: secs, running: false).model).grid.sections.isEmpty)
    #expect(try #require(scene(sections: secs, running: true).model).grid.sections.count == 1)
  }
}
