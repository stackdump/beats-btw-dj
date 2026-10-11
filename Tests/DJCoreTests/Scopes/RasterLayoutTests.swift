import Testing

@testable import DJCore

// RasterLayout is the arithmetic of scope.js `drawRaster`. The expected values are worked out by
// hand for a layout where they are round numbers (W 1088, H 188, four lanes, 256 steps: 4 px a
// step, 40 px a lane), and a few awkward ones were produced by evaluating the JS expressions in
// node (the `// node:` literals), so the last bit has to agree too.

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

private func close(_ r: RasterRect?, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
  guard let r else { return false }
  return close(r.x, x) && close(r.y, y) && close(r.w, w) && close(r.h, h)
}

/// 16 bars of 4 px a step: x(step) = 64 + 4·step. Lanes are 40 px high.
private let round4 = RasterLayout(width: 1088, height: 188, laneCount: 4, steps: 256)

struct RasterLayoutTests {
  // MARK: the frame

  @Test func theFrameConstantsAreTheJs() {
    #expect(RasterLayout.gut == 64 && RasterLayout.top == 14 && RasterLayout.axisH == 14)
    #expect(round4.pw == 1024 && round4.plotHeight == 160 && round4.lh == 40)
    #expect(round4.bars == 16 && round4.pxBar == 64 && round4.total == 256)
    #expect(round4.x(step: 0) == 64 && round4.x(step: 8) == 96 && round4.x(step: 256) == 1088)
  }

  @Test func noLanesMeansNoLaneHeightAndAnEmptyRasterStillHasOneStep() {
    let none = RasterLayout(width: 500, height: 200, laneCount: 0, steps: 0)
    #expect(none.lh == 0 && none.total == 1, "max(1, steps)")
    #expect(none.x(step: 1) == 500)
  }

  // MARK: bar lines and labels

  @Test(
    arguments: [
      // plot width, bars, line every, label every
      (384.0, 64, 1, 8), (383.9, 64, 4, 8), (96.0, 64, 4, 32), (95.9, 64, 16, 32),
      (1024.0, 16, 1, 1), (416.0, 16, 1, 1), (415.0, 16, 1, 2), (13.0, 4, 4, 8),
      (64.0, 1024, 16, 128), (512.0, 1024, 16, 64), (1024.0, 1024, 16, 32), (100.0, 100, 16, 32),
      (300.0, 100, 4, 16),
    ] as [(Double, Int, Int, Int)])
  func theLineAndLabelStepsFollowThePixelsPerBar(pw: Double, bars: Int, line: Int, label: Int) {
    let l = RasterLayout(width: 64 + pw, height: 100, laneCount: 1, steps: bars * 16)
    #expect(l.lineEvery == line, "pxBar \(l.pxBar)")
    #expect(l.labelEvery == label, "pxBar \(l.pxBar)")
  }

  @Test func theThresholdsAreInclusive() {
    // pxBar exactly 6 and exactly 1.5 take the finer step; 26 px for a label
    #expect(RasterLayout(width: 64 + 6 * 8, height: 100, laneCount: 1, steps: 128).lineEvery == 1)
    #expect(RasterLayout(width: 64 + 1.5 * 8, height: 100, laneCount: 1, steps: 128).lineEvery == 4)
    let l = RasterLayout(width: 64 + 26 * 8, height: 100, laneCount: 1, steps: 128)
    #expect(l.labelEvery == 1 && l.pxBar == 26)
  }

  @Test func barLinesSitOnRoundedBarStartsAndTheFourthIsBrighter() {
    let lines = round4.barLines()
    #expect(lines.map(\.bar) == Array(0...16), "every bar, the last one included")
    #expect(lines.map(\.rect.x) == (0...16).map { 64 + 64 * Double($0) })
    #expect(lines.allSatisfy { $0.rect.y == 14 && $0.rect.w == 1 && $0.rect.h == 160 })
    #expect(lines.filter(\.major).map(\.bar) == [0, 4, 8, 12, 16])
    // sparse: three bars over 100 px, x rounded
    let sparse = RasterLayout(width: 164, height: 100, laneCount: 1, steps: 48)
    #expect(sparse.lineEvery == 1)
    #expect(sparse.barLines().map(\.rect.x) == [64, 97, 131, 164])  // 97.33, 130.67 rounded
    // every 16th when the bars are hair-thin: 1024 bars over 640 px
    let thin = RasterLayout(width: 704, height: 100, laneCount: 1, steps: 16_384)
    #expect(thin.lineEvery == 16)
    #expect(thin.barLines().count == 65 && thin.barLines().last?.bar == 1024)
    let all = thin.barLines()
    #expect(all.allSatisfy { $0.major }, "multiples of 16 are all multiples of 4")
  }

  @Test func aPartialBarGetsOnlyTheLinesInsideIt() {
    let half = RasterLayout(width: 164, height: 100, laneCount: 1, steps: 8)
    #expect(half.bars == 0.5 && half.pxBar == 100, "a bar counts as at least one")
    #expect(half.barLines().map(\.bar) == [0])
    #expect(half.axisLabels().map(\.text) == ["1"])
    let oneAndAHalf = RasterLayout(width: 164, height: 100, laneCount: 1, steps: 24)
    #expect(oneAndAHalf.barLines().map(\.bar) == [0, 1])
    #expect(oneAndAHalf.axisLabels().map(\.text) == ["1", "2"])
  }

  @Test func barNumbersStartAtOneAndSitUnderThePlot() {
    let labels = round4.axisLabels()
    #expect(labels.map(\.text) == (1...16).map(String.init), "bars 1...16, not the line at 16")
    #expect(labels.first == RasterLabel(text: "1", x: 66, y: 176))
    #expect(labels.last == RasterLabel(text: "16", x: 64 + 64 * 15 + 2, y: 176))
    // 128 bars over 512 px: 4 px a bar, so a number every 8 bars (8 · 4 >= 26)
    let tight = RasterLayout(width: 64 + 512, height: 100, laneCount: 1, steps: 128 * 16)
    #expect(tight.labelEvery == 8 && tight.lineEvery == 4)
    let wanted: [String] = (0..<16).map { (i: Int) -> String in String(i * 8 + 1) }
    #expect(tight.axisLabels().map(\.text) == wanted)
  }

  // MARK: lanes

  @Test func laneSeparatorsAndNames() {
    #expect(round4.laneSeparator(0) == RasterRect(x: 64, y: 14, w: 1024, h: 1))
    #expect(round4.laneSeparator(3) == RasterRect(x: 64, y: 134, w: 1024, h: 1))
    #expect(round4.laneLabel(1, key: "bass") == RasterLabel(text: "bass", x: 2, y: 54 + 15))
    #expect(round4.laneLabel(2, key: "percussion-long").text == "percussio", "9 characters")
    // a lane shorter than 10 px puts its name at the lane's top
    let tiny = RasterLayout(width: 500, height: 14 + 14 + 8 * 6, laneCount: 8, steps: 64)
    #expect(tiny.lh == 6 && tiny.laneLabel(3, key: "x").y == 14 + 3 * 6)
    // node: Math.round(14 + 3 * lh) with lh = 26.178571428571427 is 93 (92.54 rounds up)
    let odd = RasterLayout(width: 997.5, height: 211.25, laneCount: 7, steps: 1000)
    #expect(odd.lh == 26.178571428571427)
    #expect(odd.laneSeparator(3).y == 93)
    #expect(odd.laneLabel(2, key: "k").y == 74.446428571428569)  // node
  }

  // MARK: events

  @Test func aDrumIsASpikeOnTheLaneFloor() {
    // lane 1: floor at 14 + 2·40 = 94; full velocity is 0.8 of the lane
    let loud = round4.eventRect(
      step: 8, lane: 1, note: 36, vel: 127, dur: 1, drum: true, lo: 36, hi: 36)
    #expect(close(loud, 96, 94 - 32 - 1, 1, 32))
    // node: 64/127 · 40 · 0.8
    let soft = round4.eventRect(
      step: 8, lane: 1, note: 36, vel: 64, dur: 1, drum: true, lo: 0, hi: 0)
    #expect(soft == RasterRect(x: 96, y: 76.874015748031496, w: 1, h: 16.125984251968504))
    // the note and the length do not matter to a drum
    let other = round4.eventRect(
      step: 8, lane: 1, note: 99, vel: 64, dur: 30, drum: true, lo: 0, hi: 12)
    #expect(other == soft)
  }

  @Test func aPitchedNoteIsATwoPixelBarAtItsPlaceInTheRange() {
    // lane 0 spans 36...48; floor at 14 + 40 = 54; 0.12 + 0.76·frac of the lane up
    let mid = round4.eventRect(
      step: 0, lane: 0, note: 42, vel: 100, dur: 4, drum: false, lo: 36, hi: 48)
    #expect(close(mid, 64, 54 - 20 - 1, 4 / 256 * 1024, 2), "y = 54 - 40·(0.12 + 0.38)")
    let low = round4.eventRect(
      step: 0, lane: 0, note: 36, vel: 100, dur: 1, drum: false, lo: 36, hi: 48)
    let high = round4.eventRect(
      step: 0, lane: 0, note: 48, vel: 100, dur: 1, drum: false, lo: 36, hi: 48)
    #expect(close(low, 64, 54 - 4.8 - 1, 4, 2) && close(high, 64, 54 - 35.2 - 1, 4, 2))
    // lo == hi: the span is 1, the note sits at 0.12
    let flat = round4.eventRect(
      step: 0, lane: 0, note: 60, vel: 1, dur: 1, drum: false, lo: 60, hi: 60)
    #expect(close(flat, 64, 54 - 4.8 - 1, 4, 2))
    // at least a pixel wide: a 0.5-step note over 0.25 px a step
    let narrow = RasterLayout(width: 164, height: 100, laneCount: 1, steps: 400)
    let e = narrow.eventRect(
      step: 0, lane: 0, note: 60, vel: 1, dur: 0.5, drum: false, lo: 60, hi: 72)
    #expect(e?.w == 1)
  }

  @Test func awkwardGeometryAgreesWithTheJsToTheLastBit() {
    // node: W 1088, H 188, 4 lanes, 256 steps: tonal on lane 0, lo 36 hi 52, note 45,
    // dur Math.fround(2.5), step 40
    let a = round4.eventRect(
      step: 40, lane: 0, note: 45, vel: 100, dur: Double(Float(2.5)), drum: false, lo: 36, hi: 52)
    #expect(a == RasterRect(x: 224, y: 31.100000000000001, w: 10, h: 2))
    // node: W 997.5, H 211.25, 7 lanes, 1000 steps
    let odd = RasterLayout(width: 997.5, height: 211.25, laneCount: 7, steps: 1000)
    let d = odd.eventRect(step: 37, lane: 3, note: 0, vel: 99, dur: 1, drum: true, lo: 0, hi: 0)
    #expect(
      d == RasterRect(x: 98.539500000000004, y: 101.38875140607423, w: 1, h: 16.32553430821147))
    let t = odd.eventRect(
      step: 37, lane: 5, note: 61, vel: 100, dur: Double(Float(0.3)), drum: false, lo: 48, hi: 70)
    #expect(t == RasterRect(x: 98.539500000000004, y: 155.17344155844154, w: 1, h: 2))
  }

  @Test func aNonFinitePositionHasNoMark() {
    let inf = RasterLayout(width: 500, height: .infinity, laneCount: 2, steps: 64)
    #expect(
      inf.eventRect(step: 0, lane: 0, note: 60, vel: 1, dur: 1, drum: false, lo: 0, hi: 0) == nil)
  }

  // MARK: markers

  @Test func theLoopMarkerAndItsLabel() {
    #expect(round4.loopMarker() == RasterRect(x: 63, y: 12, w: 2, h: 162))
    #expect(round4.loopLabel(cycle: 64) == RasterLabel(text: "loop · 16 bar cycle", x: 67, y: 1))
    let four = RasterLayout(width: 1088, height: 188, laneCount: 4, steps: 64)
    #expect(four.loopLabel(cycle: 64).text == "loop · 4 bar cycle")
    let none = RasterLayout(width: 1088, height: 188, laneCount: 4, steps: 1024)
    #expect(none.loopLabel(cycle: 0).text == "loop · no repeat in 64 bars")
  }

  @Test func sectionMarksStartInsideTheRaster() {
    let marks = round4.sectionMarks([
      ScopeSection(step: 0, name: "intro"), ScopeSection(step: 64, name: "verse"),
      ScopeSection(step: 255, name: "last"), ScopeSection(step: 256, name: "after"),
      ScopeSection(step: 900, name: "gone"),
    ])
    #expect(marks.map(\.label.text) == ["intro", "verse", "last"], "step 256 is not inside")
    #expect(marks[0].rect == RasterRect(x: 63, y: 12, w: 2, h: 162))
    #expect(marks[0].label == RasterLabel(text: "intro", x: 67, y: 1))
    #expect(marks[1].rect == RasterRect(x: 319, y: 12, w: 2, h: 162), "round(320) - 1")
    #expect(marks[1].label == RasterLabel(text: "verse", x: 323, y: 1))
    #expect(marks[2].rect.x == 64 + 1020 - 1)
    // x rounds half up: 64 + 100·(5/16) = 95.25 -> 95; 64 + 100·(8/16) = 114 ; (3/16)·100 = 18.75
    let thin = RasterLayout(width: 164, height: 100, laneCount: 1, steps: 16)
    let m = thin.sectionMarks([ScopeSection(step: 5, name: "a"), ScopeSection(step: 3, name: "b")])
    #expect(m.map(\.rect.x) == [94, 82], "Math.round(95.25) - 1 and Math.round(82.75) - 1")
  }

  @Test func theEmptyAndFailedMessages() {
    #expect(round4.emptyLabel(failed: false) == RasterLabel(text: "no music parts", x: 70, y: 18))
    #expect(
      round4.emptyLabel(failed: true) == RasterLabel(text: "raster unavailable", x: 70, y: 18))
  }

  // MARK: playhead

  @Test func thePlayheadIsTheTickPlusItsPhase() {
    #expect(close(round4.playheadRect(tick: 16, phase: 0.5, playing: true), 130, 14, 1, 160))
    #expect(
      close(round4.playheadRect(tick: 16, phase: 0.5, playing: false), 128, 14, 1, 160),
      "a stopped deck rests at its tick")
    #expect(close(round4.playheadRect(tick: 0, phase: 0, playing: true), 64, 14, 1, 160))
    #expect(round4.playheadRect(tick: 0, phase: 0.7, playing: false) == nil, "stopped at the top")
    // it wraps at the length of the raster
    #expect(close(round4.playheadRect(tick: 260, phase: 0, playing: true), 80, 14, 1, 160))
    #expect(close(round4.playheadRect(tick: 256, phase: 0, playing: false), 64, 14, 1, 160))
    // the phase is clamped like the JS `min(6, ...)`, and a bad one is nothing
    #expect(close(round4.playheadRect(tick: 8, phase: 10, playing: true), 64 + 14 * 4, 14, 1, 160))
    #expect(close(round4.playheadRect(tick: 8, phase: -1, playing: true), 64 + 8 * 4, 14, 1, 160))
    #expect(close(round4.playheadRect(tick: 8, phase: .nan, playing: true), 64 + 8 * 4, 14, 1, 160))
    // node: 997.5 wide, 1000 steps, tick 123 + 0.3333
    let odd = RasterLayout(width: 997.5, height: 211.25, laneCount: 7, steps: 1000)
    #expect(odd.playheadRect(tick: 123, phase: 0.3333, playing: true)?.x == 179.13163555000000)
  }

  // MARK: text

  @Test func numbersPrintTheWayJsPrintsThem() {
    #expect(RasterLayout.numberText(12) == "12" && RasterLayout.numberText(1024) == "1024")
    #expect(RasterLayout.numberText(12.5) == "12.5" && RasterLayout.numberText(0.0625) == "0.0625")
    #expect(RasterLayout.numberText(0) == "0")
  }

  @Test func theStatusLineIsScopeJsUpdateStatus() {
    var r = RasterResult(steps: 64)
    r.loop = true
    r.cycle = 64
    r.step = [0, 1, 2]
    r.ms = 11
    #expect(RasterLayout.statusText(r) == "raster · loop cycle · 3 events · 4 bars · 11 ms")
    r.cycle = 0
    r.steps = 1024
    #expect(RasterLayout.statusText(r) == "raster · loop (no repeat) · 3 events · 64 bars · 11 ms")
    r.loop = false
    r.steps = 24
    #expect(RasterLayout.statusText(r) == "raster · 3 events · 1.5 bars · 11 ms")
    #expect(RasterLayout.statusText(.failure("boom")) == "raster unavailable — boom")
    #expect(RasterLayout.statusText(.failure("")) == "raster unavailable")
    #expect(RasterResult.failure(String(repeating: "x", count: 200)).error.count == 80)
    let f = RasterResult.failure("x")
    #expect(f.steps == 16 && f.count == 0 && f.ms == 0 && f.failed)
  }
}
