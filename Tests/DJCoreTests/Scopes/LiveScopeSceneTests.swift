import Testing

@testable import DJCore

// The geometry of one frame, worked by hand for an 800 x 300 canvas and an 8 s window:
//
//   tickSec 0.125 s (120 bpm), window 64 steps = 8 s, right edge now = 10 s, so t0 = 2 s
//   100 px per second, 12.5 px per step; the anchor says step 32 began at t = 8 s
//   => x(step) = 600 + 12.5 (step - 32): step -16 is x 0, step 48 is x 800
//   hTop = round((300 - 12) / 2) = 144, mid = 72; lanes start at 146, the axis strip at 288
struct LiveScopeSceneTests {
  private let wide = 800.0
  private let tall = 300.0

  private func axis(anchored: Bool = true, tNow: Double = 10, w: Double = 800) -> ScopeTimeAxis {
    ScopeTimeAxis(
      tickSec: 0.125, tNow: tNow,
      anchor: anchored
        ? ScopeAnchor(time: 8, frame: 8 * 22_050, step: 32, tempo: 120, generation: 1) : nil,
      x0: 0, w: w)
  }

  private func lane(
    _ key: String, drum: Bool, lo: Int = 48, hi: Int = 72, color: String = "#2ecc71"
  ) -> ScopeLane {
    ScopeLane(
      key: key, ids: [key], channel: drum ? 10 : 1, group: drum ? "drums" : "melody", drum: drum,
      instrument: "", notes: [], durationsMs: [], lo: lo, hi: hi, color: ScopeColor(hex: color)!,
      deck: "A")
  }

  private func fire(
    _ t: Double, lane: Int, note: Int = 60, vel: Int = 100, dur: Double = 0.1
  ) -> ScopeFire {
    ScopeFire(
      time: t, frame: Int(t * 22_050), lane: lane, net: lane, transition: 0, note: note,
      velocity: vel, durSec: dur, channel: 1, step: 0, generation: 1)
  }

  private func make(
    axis ax: ScopeTimeAxis? = nil, columns: LiveScopeColumns = LiveScopeColumns(),
    gain: LiveScopeGain = LiveScopeGain(peak: 0.5, disp: 0.5), lanes: [ScopeLane] = [],
    fires: [ScopeFire] = [], sections: [ScopeSection] = [], hasBlocks: Bool = true,
    running: Bool = true, height: Double? = nil
  ) -> LiveScopeScene {
    var log = ScopeFireLog()
    for f in fires { log.append(f) }
    return LiveScopeScene.make(
      width: wide, height: height ?? tall, axis: ax ?? axis(), columns: columns, gain: gain,
      lanes: lanes, fires: log, sections: sections, hasBlocks: hasBlocks, running: running)
  }

  private func close(_ r: LiveScopeRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double)
    -> Bool
  {
    abs(r.x - x) < 1e-6 && abs(r.y - y) < 1e-6 && abs(r.w - w) < 1e-6 && abs(r.h - h) < 1e-6
  }

  // MARK: axis

  @Test func theAxisMapsStepsToPixels() {
    let a = axis()
    #expect(a.win == 8 && a.t0 == 2 && a.tNow == 10)
    #expect(a.stepOf(a.t0) == -16 && a.stepOf(a.tNow) == 48)
    #expect(a.xOf(a.timeOf(-16)) == 0 && a.xOf(a.timeOf(0)) == 200)
    #expect(a.xOf(a.timeOf(32)) == 600 && a.xOf(a.timeOf(48)) == 800)
    #expect(abs(a.timeOf(a.stepOf(7.3)) - 7.3) < 1e-12)
  }

  @Test func theWaveformBandIsHalfTheHeightAboveTheAxisStripRoundedUp() {
    #expect(make().hTop == 144 && make().mid == 72)
    #expect(make(height: 171).hTop == 80, "(171 - 12) / 2 = 79.5 rounds up, like Math.round")
    #expect(make(height: 170).hTop == 79)
    #expect(LiveScopeScene.axisHeight == 12)
  }

  @Test func anUnusableAxisDrawsNothing() {
    let nan = make(axis: axis(tNow: .nan), lanes: [lane("kick", drum: true)])
    #expect(!nan.ok && nan.gridLines.isEmpty && nan.corner == nil && nan.laneLines.isEmpty)
    #expect(nan.hTop == 144)
    let zero = ScopeTimeAxis(tickSec: 0, tNow: 10, anchor: nil, x0: 0, w: 800)
    #expect(!make(axis: zero).ok)
  }

  // MARK: grid

  @Test func theGridIsABeatLineEveryFourStepsAndABarLineEverySixteen() {
    let s = make()
    #expect(s.gridLines.count == 17, "steps -16, -12 ... 48")
    let xs = s.gridLines.map(\.rect.x)
    #expect(
      xs == [0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650, 700, 750, 800])
    #expect(s.gridLines.filter(\.bar).map(\.rect.x) == [0, 200, 400, 600, 800], "bars")
    #expect(s.gridLines.allSatisfy { $0.rect.y == 0 && $0.rect.w == 1 && $0.rect.h == 288 })
  }

  @Test func barNumbersStartAtOneAndSkipTheBarsBeforeTheSong() {
    let s = make()
    // steps 0, 16, 32, 48 -> bars 1 ... 4; step -16 has no number; 3 px right, 1 px below the grid
    #expect(s.barLabels.map(\.text) == ["1", "2", "3", "4"])
    #expect(s.barLabels.map(\.x) == [203, 403, 603, 803])
    #expect(s.barLabels.allSatisfy { $0.y == 289 })
  }

  @Test func sectionsInsideTheWindowGetATwoPixelMarkerAndTheirName() {
    let s = make(
      sections: [
        ScopeSection(step: 16, name: "chorus"), ScopeSection(step: -40, name: "gone"),
        ScopeSection(step: -16, name: "edge"), ScopeSection(step: 48, name: "last"),
        ScopeSection(step: 49, name: "future"),
      ])
    #expect(s.sections.map(\.name.text) == ["chorus", "edge", "last"])
    #expect(close(s.sections[0].rect, 399, 0, 2, 288), "round(400) - 1, 2 wide, to the axis strip")
    #expect(s.sections[0].name.x == 404 && s.sections[0].name.y == 2, "x + 4, y0 + 2")
    #expect(s.sections[1].rect.x == -1 && s.sections[2].rect.x == 799)
  }

  @Test func withoutAnAnchorThereAreNoStepsToDrawThoughThereIsStillAWindow() {
    let s = make(axis: axis(anchored: false), sections: [ScopeSection(step: 16, name: "x")])
    #expect(s.ok && s.gridLines.isEmpty && s.barLabels.isEmpty && s.sections.isEmpty)
    #expect(s.corner != nil)
  }

  @Test func aStoppedTransportDrawsNoGridPastItsLastAnchor() {
    // The anchor says step 32 began at t = 8 s and "now" is 2 s later. While the song plays the
    // grid runs on from that anchor at tickSec per step (steps 36 ... 48 are where the song will
    // be). Once it has stopped no step after 32 ever began: the bar numbers must not count on
    // and the grid must not slide on without a song.
    let secs = [ScopeSection(step: 32, name: "at"), ScopeSection(step: 40, name: "late")]
    let playing = make(sections: secs, running: true)
    #expect(playing.gridLines.count == 17 && playing.barLabels.map(\.text) == ["1", "2", "3", "4"])
    #expect(playing.sections.map(\.name.text) == ["at", "late"])
    let stopped = make(sections: secs, running: false)
    #expect(stopped.gridLines.count == 13, "steps -16, -12 ... 32")
    #expect(stopped.gridLines.map(\.rect.x).last == 600, "the last line is the anchor's step")
    #expect(stopped.gridLines.filter(\.bar).map(\.rect.x) == [0, 200, 400, 600])
    #expect(stopped.barLabels.map(\.text) == ["1", "2", "3"], "no bar 4: step 48 never began")
    #expect(stopped.sections.map(\.name.text) == ["at"], "nor does a section after the anchor")
    // the part up to the anchor is identical to the playing frame
    #expect(Array(playing.gridLines.prefix(13)) == stopped.gridLines)
    // 22 s on, the anchor is far left of the window: nothing of the song is in it
    #expect(make(axis: axis(tNow: 30), running: true).gridLines.count == 17)
    let gone = make(axis: axis(tNow: 30), sections: secs, running: false)
    #expect(gone.gridLines.isEmpty && gone.barLabels.isEmpty && gone.sections.isEmpty)
    #expect(gone.ok && gone.corner != nil, "the waveform and the label still draw")
  }

  @Test func aNonFiniteStepDrawsNoGrid() {
    // a tick so short that the step at the window's left edge is infinite
    let anchor = ScopeAnchor(time: 8, frame: 0, step: 32, tempo: 120, generation: 1)
    let tiny = ScopeTimeAxis(tickSec: 1e-310, tNow: 10, anchor: anchor, x0: 0, w: 800)
    #expect(tiny.ok && !tiny.stepOf(tiny.t0).isFinite)
    let s = make(axis: tiny, sections: [ScopeSection(step: 16, name: "x")])
    #expect(s.gridLines.isEmpty && s.sections.isEmpty && s.corner != nil)
  }

  // MARK: waveform

  private func columns(_ blocks: [(Double, Float, Float, Float)]) -> LiveScopeColumns {
    var ring = LiveScopeBlockRing()
    for b in blocks { ring.push(LiveScopeBlock(t: b.0, min: b.1, max: b.2, meanSq: b.3)) }
    var c = LiveScopeColumns()
    c.reduce(ring, axis: axis(), width: wide)
    return c
  }

  @Test func theEnvelopeAndRmsAreScaledByTheDisplayedGain() {
    // disp 0.5: scale = (144 / 2 - 3) / 0.5 = 138 px per unit
    let c = columns([
      (6.0, -0.25, 0.5, 0.0625),  // column 400
      (6.0105, -0.001, 0.001, 1e-6),  // column 401
    ])
    let s = make(columns: c)
    #expect(s.scale == 138)
    #expect(s.envelope.count == 2)
    // top = mid - max * sc = 72 - 69 = 3; h = (0.5 + 0.25) * 138 = 103.5
    #expect(close(s.envelope[0], 400, 3, 1, 103.5))
    // a hair-thin column is still one pixel tall
    #expect(s.envelope[1].x == 401 && s.envelope[1].h == 1)
    // rms = sqrt(0.0625) = 0.25 -> 34.5 px: the -rms line is BELOW the centre line
    #expect(s.rmsLower.count == 2 && s.rmsUpper.count == 2)
    #expect(s.rmsLower[0] == LiveScopePoint(x: 400, y: 106.5))
    #expect(s.rmsUpper[0] == LiveScopePoint(x: 400, y: 37.5))
    #expect(abs(s.rmsUpper[1].y - (72 - 0.001 * 138)) < 1e-6)
  }

  @Test func theRmsIsTheSquareRootOfTheMeanOfTheBlocksMeanSquares() {
    // two blocks in one column: mean squares 0.04 and 0.16 -> mean 0.1 -> rms 0.316228
    let c = columns([(6.0, -0.2, 0.2, 0.04), (6.004, -0.4, 0.4, 0.16)])
    let s = make(columns: c, gain: LiveScopeGain(peak: 1, disp: 1))
    // disp 1: scale 69
    #expect(s.scale == 69)
    #expect(abs(s.rmsUpper[0].y - (72 - 0.1.squareRoot() * 69)) < 1e-4)
    #expect(close(s.envelope[0], 400, 72 - 0.4 * 69, 1, 0.8 * 69))
  }

  @Test func theWaveformIsNotClippedToTheBand() {
    // a loud block against a small displayed scale reaches far past the band
    let c = columns([(6.0, -1, 1, 0.5)])
    let s = make(columns: c, gain: LiveScopeGain(peak: 1, disp: 0.1))
    #expect(s.scale == 690)
    #expect(
      close(s.envelope[0], 400, 72 - 690, 1, 1380), "top is above the canvas; nothing clips it")
  }

  @Test func theCornerLabelPrintsThePeakNotTheDisplayedScale() {
    func label(_ peak: Double, _ disp: Double) -> LiveScopeText? {
      make(gain: LiveScopeGain(peak: peak, disp: disp)).corner
    }
    #expect(label(0.5, 0.9) == LiveScopeText("x · ±0.50", x: 730, y: 2))
    #expect(label(0.1, 0.1)?.text == "x · ±0.10")
    #expect(label(0.123, 5)?.text == "x · ±0.12")
    #expect(label(0.999, 5)?.text == "x · ±1.00")
  }

  @Test func theCornerLabelRoundsATieUpLikeToFixed() {
    // JS `toFixed(2)` works on the exact value of the double and sends an exact tie to the larger
    // n: (0.125).toFixed(2) is "0.13". printf's "%.2f" sends it to the even digit, "0.12". Ties
    // are the odd multiples of 1/8; every expected string below was printed by node.
    func text(_ peak: Double) -> String? {
      make(gain: LiveScopeGain(peak: peak, disp: peak)).corner?.text
    }
    #expect(text(0.125) == "x · ±0.13")
    #expect(text(0.375) == "x · ±0.38")
    #expect(text(0.625) == "x · ±0.63")
    #expect(text(0.875) == "x · ±0.88")
    #expect(text(1.125) == "x · ±1.13")
    // not a tie in binary: the digits of the double decide, as they do in JS
    #expect(text(1.005) == "x · ±1.00", "1.00499999999999989...")
    #expect(text(0.145) == "x · ±0.14")
    #expect(text(0.155) == "x · ±0.15")
    #expect(text(2.675) == "x · ±2.67")
    #expect(text(0.05) == "x · ±0.05")
  }

  @Test func withoutBlocksTheEmptyStateSaysWhy() {
    let waiting = make(hasBlocks: false, running: true)
    #expect(waiting.emptyMessage == LiveScopeText("waiting for audio…", x: 6, y: 67), "mid - 5")
    let stopped = make(hasBlocks: false, running: false)
    #expect(stopped.emptyMessage == LiveScopeText("press play", x: 6, y: 67))
    #expect(make(hasBlocks: true).emptyMessage == nil)
  }

  // MARK: lanes

  private var twoLanes: [ScopeLane] {
    [lane("kick", drum: true, color: "#e94560"), lane("melody", drum: false)]
  }

  @Test func theLaneBandsShareWhatIsLeftBelowTheWaveform() {
    let s = make(lanes: twoLanes)
    // ly0 = hTop + 2 = 146; lh = (300 - 12 - 146) / 2 = 71
    #expect(s.laneTop == 146 && s.laneHeight == 71)
    #expect(s.laneLines.map(\.y) == [146, 217, 288], "round(ly0 + l * lh)")
    #expect(s.laneLines.allSatisfy { $0.x == 0 && $0.w == 800 && $0.h == 1 })
    #expect(s.laneColors == [ScopeColor(hex: "#e94560")!, ScopeColor(hex: "#2ecc71")!])
    #expect(make().laneLines.isEmpty && make().laneHeight == 0, "no lanes, no band")
  }

  @Test func aDrumHitIsASpikeAsHighAsItsVelocity() {
    // kick at t = 9 s -> x 700; vel 127 -> h = 71 * 0.85 = 60.35; yb = 146 + 71 = 217
    let s = make(lanes: twoLanes, fires: [fire(9.0, lane: 0, vel: 127)])
    #expect(s.events.count == 1 && s.events[0].lane == 0)
    #expect(close(s.events[0].rect, 700, 217 - 60.35, 1.5, 60.35))
    let half = make(lanes: twoLanes, fires: [fire(9.0, lane: 0, vel: 64)])
    #expect(
      close(half.events[0].rect, 700, 217 - 64.0 / 127 * 71 * 0.85, 1.5, 64.0 / 127 * 71 * 0.85))
  }

  @Test func aTonalHitIsATwoPixelDashAtItsPitchAsLongAsItsDuration() {
    // melody (lane 1, notes 48 ... 72) at t = 6 s -> x 400, note 60, 0.5 s -> w = 50
    // yb = 146 + 2 * 71 = 288; y = 288 - 71 * (0.1 + 0.8 * 12 / 24) = 252.5; rect (x, y - 1, w - 1, 2)
    let s = make(lanes: twoLanes, fires: [fire(6.0, lane: 1, note: 60, dur: 0.5)])
    #expect(s.events.count == 1 && s.events[0].lane == 1)
    #expect(close(s.events[0].rect, 400, 251.5, 49, 2))
    // the lowest note sits at 10 % of the lane, the highest at 90 %
    let lo = make(lanes: twoLanes, fires: [fire(6.0, lane: 1, note: 48)])
    let hi = make(lanes: twoLanes, fires: [fire(6.0, lane: 1, note: 72)])
    #expect(abs(lo.events[0].rect.y - (288 - 7.1 - 1)) < 1e-6)
    #expect(abs(hi.events[0].rect.y - (288 - 63.9 - 1)) < 1e-9)
    // a lane with one note: span = max(1, 0)
    let one = [lane("kick", drum: true), lane("pad", drum: false, lo: 60, hi: 60)]
    let p = make(lanes: one, fires: [fire(6.0, lane: 1, note: 60)])
    #expect(abs(p.events[0].rect.y - (288 - 71 * 0.1 - 1)) < 1e-9)
  }

  @Test func aDashIsClippedAtTheEdgesAndNeverThinnerThanOneAndAHalf() {
    let s = make(
      lanes: twoLanes,
      fires: [
        fire(1.9, lane: 1, note: 66, dur: 1.0),  // x = -10, w = 100: clipped to 90 -> 89 drawn
        fire(9.5, lane: 1, note: 72, dur: 0.01),  // w = 1 -> max(1.5, 0)
        fire(9.9, lane: 1, note: 48, dur: 1.0),  // x = 790, w = 100: cut to the 10 px left -> 9
      ])
    #expect(s.events.count == 3)
    let byX = s.events.sorted { $0.rect.x < $1.rect.x }
    #expect(close(byX[0].rect, 0, 288 - 71 * 0.7 - 1, 89, 2))
    #expect(close(byX[1].rect, 750, 288 - 71 * 0.9 - 1, 1.5, 2))
    #expect(close(byX[2].rect, 790, 288 - 71 * 0.1 - 1, 9, 2))
  }

  @Test func eventsArePaintedNewestFirstAndOnlyWithinTheWindowPlusFourSeconds() {
    let s = make(
      lanes: twoLanes,
      fires: [
        fire(-3.0, lane: 0, vel: 100),  // older than t0 - 4 = -2: ends the walk
        fire(-1.9, lane: 1, note: 60, dur: 0.1),  // within the margin but wholly left of the canvas
        fire(1.9, lane: 1, note: 66, dur: 1.0),
        fire(6.0, lane: 1, note: 60, dur: 0.5),
        fire(9.0, lane: 0, vel: 127),
        fire(9.9, lane: 1, note: 48, dur: 1.0),
        fire(10.5, lane: 0, vel: 127),  // after "now": skipped
        fire(9.0, lane: 7, vel: 127),  // a lane the feed does not have: skipped
      ])
    // newest first as logged: lane 7 and 10.5 skipped, then 9.9, 9.0, 6.0, 1.9; -1.9 draws
    // nothing (drawn width <= 0), -3.0 is never reached
    #expect(s.events.map(\.lane) == [1, 0, 1, 1])
    #expect(s.events.map(\.rect.x) == [790, 700, 400, 0])
  }

  @Test func aDrumHitLeftOfTheCanvasIsDropped() {
    // x = (2.0 - 2) / 8 * 800 = 0 is the first drawable; t0 - 4 <= t < t0 has x < 0
    let s = make(
      lanes: twoLanes, fires: [fire(1.0, lane: 0, vel: 127), fire(2.0, lane: 0, vel: 127)])
    #expect(s.events.count == 1 && s.events[0].rect.x == 0)
  }

  @Test func eachLaneIsNamedOnADarkPlateWhenItIsAtLeastEightHigh() {
    let s = make(lanes: twoLanes)
    #expect(s.laneLabels.map(\.text) == ["kick", "melody"])
    #expect(s.laneLabels.map(\.y) == [147, 218], "ly0 + l * lh + 1")
    #expect(s.laneLabels.allSatisfy { $0.plateX == 2 && $0.textX == 4 && $0.plateHeight == 11 })
    #expect(s.laneLabels[0].color == ScopeColor(hex: "#e94560")!)
    // 30 lanes in 142 px are 4.7 high each: no labels
    let many = (0..<30).map { lane("l\($0)", drum: false) }
    #expect(make(lanes: many).laneLabels.isEmpty)
    // H = 300 -> 142 px under the waveform: 142 / 8 = 17.75; 17 lanes are 8.35 high
    let seventeen = (0..<17).map { lane("l\($0)", drum: false) }
    let t = make(lanes: seventeen)
    #expect(t.laneHeight > 8 && t.laneLabels.count == 17)
    #expect(abs(t.laneLabels[0].plateHeight - (142.0 / 17 - 1)) < 1e-9, "min(11, lh - 1)")
    let eighteen = (0..<18).map { lane("l\($0)", drum: false) }
    #expect(make(lanes: eighteen).laneLabels.isEmpty, "142 / 18 = 7.9")
  }

  @Test func onTheMasterEachLaneNamesItsDeck() {
    // two decks usually play the same parts: "kick" twice in one colour says nothing
    func on(_ deck: String, _ l: ScopeLane) -> ScopeLane {
      var l = l
      l.deck = deck
      return l
    }
    let master = [
      on("A", lane("kick", drum: true, color: "#e94560")),
      on("A", lane("melody", drum: false)),
      on("B", lane("kick", drum: true, color: "#e94560")),
    ]
    let s = make(lanes: master)
    #expect(s.laneLabels.map(\.text) == ["A·kick", "A·melody", "B·kick"])
    #expect(s.laneLabels.map(\.lane) == [0, 1, 2] && s.laneLabels[2].color == master[2].color)
    // one deck on the master (or a deck feed): the plain names, as in the JS
    let single = make(lanes: master.filter { $0.deck == "A" })
    #expect(single.laneLabels.map(\.text) == ["kick", "melody"])
  }

  // MARK: height rule (the host's, scope.js viewHeight for the live view)

  @Test func theViewHeightFollowsLanesAndRoom() {
    // max(170, min(640, max(110 + 12 L, room))), room = clamp(round(0.55 h), 0, 640)
    func h(_ lanes: Int, _ win: Double?) -> Double {
      ScopeKind.viewHeight(kind: .live, measured: false, laneCount: lanes, windowHeight: win)
    }
    #expect(h(0, 800) == 440 && h(10, 800) == 440 && h(32, 800) == 494)
    #expect(h(5, 300) == 170, "room 165, 110 + 60 = 170")
    #expect(h(3, 400) == 220 && h(0, 100) == 170)
    #expect(h(0, 1500) == 640 && h(40, 100) == 590 && h(60, 100) == 640)
    #expect(h(4, nil) == 440, "unknown window: 800")
  }
}
