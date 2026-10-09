import DJCore
import SwiftUI
import Testing

@testable import DJViews

private let bg = (5, 10, 20)  // #050a14
private let grid = (26, 42, 58)  // #1a2a3a
private let barLine = (47, 74, 106)  // #2f4a6a
private let amber = (245, 166, 35)  // #f5a623
private let sectionRed = (233, 69, 96)  // #e94560
private let kickRed = (233, 69, 96)  // kick lane
private let melodyGreen = (46, 204, 113)  // #2ecc71
// rgba(74,144,217,0.6) over the background
private let envelope = (46, 90, 138)
private let textGrey = (136, 153, 170)  // #8899aa

/// A scene painted on the scope background and nothing else: positions are the ones worked out by
/// hand in LiveScopeSceneTests (W 800, H 300, 8 s window ending at 10 s, 12.5 px per step).
private struct SceneOnly: View {
  let scene: LiveScopeScene
  var body: some View {
    Canvas { ctx, size in
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)), with: .color(ScopeColors.background.color))
      LiveScopePainter.paint(scene, in: &ctx)
    }
  }
}

@MainActor
struct ScopeLiveViewTests {
  // MARK: the painter, on a hand-made scene

  private func handScene(
    hasBlocks: Bool = true, running: Bool = true, kickName: String = "kick"
  ) -> LiveScopeScene {
    let axis = ScopeTimeAxis(
      tickSec: 0.125, tNow: 10,
      anchor: ScopeAnchor(time: 8, frame: 0, step: 32, tempo: 120, generation: 1), x0: 0, w: 800)
    // columns 430 ... 432: a steady block of peak 0.5 / -0.25 and rms 0.25 (disp 0.5: 138 px/unit)
    var ring = LiveScopeBlockRing()
    for t in [6.305, 6.315, 6.325] {
      ring.push(LiveScopeBlock(t: t, min: -0.25, max: 0.5, meanSq: 0.0625))
    }
    var columns = LiveScopeColumns()
    columns.reduce(ring, axis: axis, width: 800)
    func lane(_ key: String, drum: Bool, color: String) -> ScopeLane {
      ScopeLane(
        key: key, ids: [key], channel: drum ? 10 : 1, group: "x", drum: drum, instrument: "",
        notes: [], durationsMs: [], lo: 48, hi: 72, color: ScopeColor(hex: color)!, deck: "A")
    }
    var log = ScopeFireLog()
    func fire(_ t: Double, _ l: Int, note: Int = 60, vel: Int = 127, dur: Double = 0.1) {
      log.append(
        ScopeFire(
          time: t, frame: 0, lane: l, net: l, transition: 0, note: note, velocity: vel,
          durSec: dur, channel: 1, step: 0, generation: 1))
    }
    fire(9.0, 0)  // the kick spike at x 700
    fire(6.0, 1, note: 60, dur: 0.5)  // the dash at x 400
    return LiveScopeScene.make(
      width: 800, height: 300, axis: axis, columns: columns,
      gain: LiveScopeGain(peak: 0.5, disp: 0.5),
      lanes: [
        lane(kickName, drum: true, color: "#e94560"),
        lane("melody", drum: false, color: "#2ecc71"),
      ],
      fires: log, sections: [ScopeSection(step: 24, name: "chorus")], hasBlocks: hasBlocks,
      running: running)
  }

  @Test func thePainterPutsEveryElementWhereTheSceneSaysAndInItsColour() throws {
    let view = SceneOnly(scene: handScene())
    savePNG(view, width: 800, height: 300, name: "scope-live-hand")
    let px = try #require(renderPixels(view, width: 800, height: 300))
    // background between grid lines, and the top row of the window
    #expect(px.near(225, 1, bg, tol: 2), "bg \(px.color(225, 1))")
    #expect(px.near(770, 60, bg, tol: 2), "bg \(px.color(770, 60))")
    // beat lines every 50 px in #1a2a3a, bar lines every 200 px in #2f4a6a
    #expect(px.near(250, 1, grid, tol: 2), "beat line \(px.color(250, 1))")
    #expect(px.near(350, 1, grid, tol: 2))
    #expect(px.near(200, 1, barLine, tol: 2), "bar line \(px.color(200, 1))")
    #expect(px.near(600, 1, barLine, tol: 2))
    // the grid runs down to the axis strip (288) and stops there
    #expect(px.near(250, 280, grid, tol: 2), "grid \(px.color(250, 280))")
    #expect(px.near(250, 291, bg, tol: 2), "nothing below the axis strip \(px.color(250, 291))")
    // the section marker: 2 px wide at x 499 ... 500, full height of the grid, in #e94560
    #expect(px.near(499, 20, sectionRed, tol: 6) && px.near(500, 20, sectionRed, tol: 6))
    #expect(px.near(498, 20, bg, tol: 40) && px.near(501, 20, bg, tol: 40))
    // envelope: column 430 is filled from y 3 to 106.5 with rgba(74,144,217,.6)
    #expect(px.near(430, 50, envelope, tol: 6), "envelope \(px.color(430, 50))")
    #expect(px.near(430, 100, envelope, tol: 6))
    #expect(px.near(430, 1, bg, tol: 2), "above it (top = 3) nothing")
    #expect(px.near(430, 130, bg, tol: 2), "and below it (bottom = 106.5)")
    #expect(px.near(429, 50, bg, tol: 40) && px.near(433, 50, bg, tol: 40), "one column wide")
    // RMS: amber lines at 72 -/+ 34.5 = 37.5 and 106.5, 1.2 wide
    #expect(px.near(431, 37, amber, tol: 30), "rms upper \(px.color(431, 37))")
    #expect(px.near(431, 106, amber, tol: 30), "rms lower \(px.color(431, 106))")
    #expect(!px.near(431, 72, amber, tol: 60), "nothing amber at the centre line")
    // 1.2 wide: the row under the line (37.5 +/- 0.6 reaches 38.1) is a tenth amber over the
    // envelope, not the half a 2.0 stroke would give
    #expect(px.near(431, 38, envelope, tol: 40), "rms edge \(px.color(431, 38))")
    #expect(px.near(431, 105, envelope, tol: 40), "rms edge \(px.color(431, 105))")
    // lane separators in GRID at 146, 217, 288 (full width)
    #expect(px.near(60, 146, grid, tol: 4) && px.near(60, 217, grid, tol: 4))
    #expect(px.near(760, 288, grid, tol: 4), "separator \(px.color(760, 288))")
    // the separator is painted over the section marker, as drawLive does
    #expect(px.near(499, 146, grid, tol: 6), "separator over marker \(px.color(499, 146))")
    // the kick spike: x 700 (1.5 wide), from 156.65 to 217, in the lane's colour
    #expect(px.near(700, 190, kickRed, tol: 6), "spike \(px.color(700, 190))")
    #expect(px.near(700, 200, kickRed, tol: 6) && px.near(700, 216, kickRed, tol: 6))
    #expect(px.near(700, 154, grid, tol: 6), "above its top (156.65) only the grid line")
    #expect(px.near(702, 190, bg, tol: 4), "1.5 wide: x 700 and half of 701, not 702")
    // the melody dash: x 400 ... 449, rows 251.5 ... 253.5 in #2ecc71
    #expect(px.near(420, 252, melodyGreen, tol: 6), "dash \(px.color(420, 252))")
    #expect(px.near(448, 252, melodyGreen, tol: 6) && !px.near(452, 252, melodyGreen, tol: 40))
    // text: the corner label (grey, top right), a section name (red), bar numbers (grey, below)
    func lit(_ x: Range<Int>, _ y: Range<Int>, _ c: (Int, Int, Int)) -> Int {
      px.count(inX: x, y: y) { r, g, b in
        abs(r - c.0) < 40 && abs(g - c.1) < 40 && abs(b - c.2) < 40
      }
    }
    #expect(lit(730..<800, 2..<14, textGrey) > 12, "x · ±0.50")
    #expect(lit(504..<560, 2..<14, sectionRed) > 12, "chorus")
    #expect(lit(203..<212, 289..<299, textGrey) > 3, "bar number 1")
    #expect(lit(603..<612, 289..<299, textGrey) > 3, "bar number 3")
    // lane names on dark plates, in the lane colours
    #expect(lit(4..<36, 147..<158, kickRed) > 8, "kick label")
    #expect(lit(4..<56, 218..<229, melodyGreen) > 8, "melody label")
    // no empty-state text while there are blocks
    #expect(lit(6..<100, 67..<80, textGrey) == 0)
  }

  @Test func theEmptyStateIsWrittenInTheMiddleOfAnEmptyWaveform() throws {
    for (running, _) in [(true, "waiting for audio…"), (false, "press play")] {
      let scene = handScene(hasBlocks: false, running: running)
      let view = SceneOnly(scene: scene)
      let px = try #require(renderPixels(view, width: 800, height: 300))
      let lit = px.count(inX: 6..<110, y: 67..<80) { r, g, b in
        abs(r - 136) < 50 && abs(g - 153) < 50 && abs(b - 170) < 50
      }
      #expect(lit > 20, "the message is drawn at (6, mid - 5) (\(lit))")
    }
    // a waiting message is longer than the pause message
    func width(_ running: Bool) throws -> Int {
      let px = try #require(
        renderPixels(
          SceneOnly(scene: handScene(hasBlocks: false, running: running)), width: 800, height: 300))
      var right = 0
      for x in 6..<300 {
        let hit = px.count(inX: x..<(x + 1), y: 67..<80) { r, g, b in r + g + b > 250 }
        if hit > 0 { right = x }
      }
      return right
    }
    #expect(try width(true) > width(false) + 30)
  }

  @Test func aLaneNameSitsOnADarkPlateThatDimsWhatIsBehindIt() throws {
    // a long name reaches over the beat lines at x 50 and 100 (drawn first); the plate is
    // rgba(5,10,20,0.7) over them: 0.7 * bg + 0.3 * grid
    let view = SceneOnly(scene: handScene(kickName: "a-very-long-lane-name"))
    let px = try #require(renderPixels(view, width: 800, height: 300))
    let dimmed = (11, 20, 31)
    for x in [50, 100] {
      let n = lit(px, x..<(x + 1), 147..<158, dimmed, tol: 7)
      #expect(n >= 3, "plate over the beat line at x \(x): \(n) rows (\(px.color(x, 148)))")
    }
    // outside the plate (the plate is 11 high from y 147, the name's lane starts at 146) the beat
    // line keeps its colour
    #expect(px.near(50, 130, grid, tol: 4) && px.near(50, 210, grid, tol: 4))
    // and the lane below has its own, narrower plate: "melody" does not reach x 100
    #expect(px.near(100, 220, grid, tol: 4), "no plate at \(px.color(100, 220))")
  }

  @Test func overlappingHitsOfTwoLanesAreLayeredLikeTheJs() throws {
    // Two dashes at the same height whose rects overlap on x 750 ... 799: lane 1's note is above
    // its range, so its dash climbs into lane 0's band and meets lane 0's dash there. The JS
    // paints newest first, so the OLDER hit ends up on top, whatever the lane numbers.
    let axis = ScopeTimeAxis(
      tickSec: 0.125, tNow: 10,
      anchor: ScopeAnchor(time: 8, frame: 0, step: 32, tempo: 120, generation: 1), x0: 0, w: 800)
    func lane(_ key: String, color: String) -> ScopeLane {
      ScopeLane(
        key: key, ids: [key], channel: 1, group: "x", drum: false, instrument: "", notes: [],
        durationsMs: [], lo: 48, hi: 72, color: ScopeColor(hex: color)!, deck: "A")
    }
    var log = ScopeFireLog()
    func fire(_ t: Double, _ l: Int, note: Int) {
      log.append(
        ScopeFire(
          time: t, frame: 0, lane: l, net: l, transition: 0, note: note, velocity: 100,
          durSec: 1.0, channel: 1, step: 0, generation: 1))
    }
    fire(9.0, 0, note: 66)  // older, lane 0: y = 217 - 71 * 0.7 = 167.3
    fire(9.5, 1, note: 96)  // newer, lane 1: y = 288 - 71 * 1.7 = 167.3 (two octaves up)
    let scene = LiveScopeScene.make(
      width: 800, height: 300, axis: axis, columns: LiveScopeColumns(),
      gain: LiveScopeGain(peak: 0.5, disp: 0.5),
      lanes: [lane("low", color: "#e94560"), lane("high", color: "#2ecc71")], fires: log,
      sections: [], hasBlocks: true, running: true)
    #expect(scene.events.map(\.lane) == [1, 0], "newest first")
    #expect(abs(scene.events[0].rect.y - scene.events[1].rect.y) < 1e-9)
    let view = SceneOnly(scene: scene)
    savePNG(view, width: 800, height: 300, name: "scope-live-overlap")
    let px = try #require(renderPixels(view, width: 800, height: 300))
    #expect(px.near(725, 167, kickRed, tol: 6), "lane 0 alone \(px.color(725, 167))")
    #expect(
      px.near(775, 167, kickRed, tol: 6), "overlap: the older hit on top \(px.color(775, 167))")
  }

  @Test func aSceneWithoutAnAxisPaintsOnlyTheBackground() throws {
    let axis = ScopeTimeAxis(tickSec: 0.125, tNow: .nan, anchor: nil, x0: 0, w: 800)
    let scene = LiveScopeScene.make(
      width: 800, height: 300, axis: axis, columns: LiveScopeColumns(), gain: LiveScopeGain(),
      lanes: [], fires: ScopeFireLog(), sections: [], hasBlocks: true, running: true)
    let px = try #require(renderPixels(SceneOnly(scene: scene), width: 800, height: 300))
    let off = px.count(inX: 0..<800, y: 0..<300) { r, g, b in
      abs(r - 5) > 2 || abs(g - 10) > 2 || abs(b - 20) > 2
    }
    #expect(off == 0)
  }

  // MARK: the view, over a real offline engine

  /// A rig whose deck A has played for `seconds`, a model that has watched it and settled.
  private func settled(
    _ rig: ScopeViewRig, source: ScopeSource, seconds: Double = 3
  ) throws -> (feed: ScopeFeed, model: LiveScopeModel, wall: Double) {
    let feed = rig.hub.feed(source)
    feed.acquire()
    let model = LiveScopeModel()
    var wall = 5.0
    model.update(feed: feed, wall: wall)
    var left = seconds
    while left > 0 {
      try rig.run(seconds: 0.5)
      wall += 0.5
      model.update(feed: feed, wall: wall)
      left -= 0.5
    }
    // the spring settles over a few hundred ms of frames; the audio keeps coming meanwhile, so
    // the peak is held up as it is in a live scope (silence would release it and the picture
    // would be drawn 1.4x too big)
    for _ in 0..<90 {
      try rig.run(seconds: 1.0 / 30)
      wall += 1.0 / 30
      model.update(feed: feed, wall: wall)
    }
    return (feed, model, wall)
  }

  private func lit(_ px: Pixels, _ x: Range<Int>, _ y: Range<Int>, _ c: (Int, Int, Int), tol: Int)
    -> Int
  {
    px.count(inX: x, y: y) { r, g, b in
      abs(r - c.0) <= tol && abs(g - c.1) <= tol && abs(b - c.2) <= tol
    }
  }

  @Test func aNetDeckFeedShowsTheWaveformTheGridAndItsHits() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let s = try settled(rig, source: .deck("A"))
    let wall = s.wall  // the clock the view reads is frozen: dt 0, the gain stays settled
    let view = ScopeLiveView(feed: s.feed, hub: rig.hub, model: s.model) { wall }
    savePNG(view, width: 800, height: 300, name: "scope-live-engine-deck")
    let px = try #require(renderPixels(view, width: 800, height: 300))
    // the scene the view painted, from the same model state
    let scene = s.model.scene(feed: s.feed, width: 800, height: 300)
    #expect(scene.ok && !scene.envelope.isEmpty)
    // beat and bar lines at their computed x: a column of grid colour wherever nothing is drawn
    // over it (the waveform, the hits and the lane separators cover parts of it)
    let beat = try #require(scene.gridLines.first { !$0.bar && $0.rect.x > 30 && $0.rect.x < 700 })
    let beats = lit(px, Int(beat.rect.x)..<(Int(beat.rect.x) + 1), 0..<288, grid, tol: 2)
    #expect(beats > 20, "beat line at \(beat.rect.x): \(beats) grid pixels")
    let bar = try #require(
      scene.gridLines.first { g in
        g.bar && g.rect.x > 30 && g.rect.x < 700
          && !scene.sections.contains { abs($0.rect.x - g.rect.x) < 4 }
      })
    let bars = lit(px, Int(bar.rect.x)..<(Int(bar.rect.x) + 1), 0..<288, barLine, tol: 2)
    #expect(bars > 20, "bar line at \(bar.rect.x): \(bars) bar-line pixels")
    // the axis strip under the lanes is plain background, bar numbers apart
    #expect(px.near(Int(beat.rect.x) + 20, 295, bg, tol: 2))
    #expect(px.near(5, 295, bg, tol: 2) && px.near(790, 295, bg, tol: 2))
    // the settled picture is fitted to its band: about half the band high, nothing near the lanes
    let top = scene.envelope.map(\.y).min() ?? 0
    let bottom = scene.envelope.map { $0.y + $0.h }.max() ?? 0
    #expect(top > -0.12 * scene.hTop && bottom < 1.12 * scene.hTop, "extent \(top) ... \(bottom)")
    #expect(bottom - top > 0.4 * scene.hTop, "and it fills the band: \(top) ... \(bottom)")
    // the waveform band is lit with the envelope and the amber RMS
    let blue = lit(px, 0..<800, 3..<141, envelope, tol: 14)
    #expect(blue > 300, "envelope pixels in the waveform band: \(blue)")
    let rms = px.count(inX: 0..<800, y: 3..<141) { r, g, b in
      r > 190 && g > 120 && g < 200 && b < 100
    }
    #expect(rms > 60, "amber RMS pixels: \(rms)")
    // lanes: the feed has some, each separated by a GRID row, below the band
    let n = s.feed.lanes.count
    #expect(n > 0 && scene.laneLines.count == n + 1)
    let sep = Int(scene.laneLines[0].y)
    let sepPixels = lit(px, 0..<800, sep..<(sep + 1), grid, tol: 24)
    #expect(sepPixels > 300, "separator row \(sep): \(sepPixels) grid-coloured pixels")
    // a hit is in its lane's colour at its computed place
    let hit = try #require(scene.events.first { $0.rect.w >= 1.5 && $0.rect.h >= 2 })
    let colour = scene.laneColors[hit.lane].rgb8
    let r = hit.rect
    let found = lit(
      px, Int(r.x)..<min(800, Int(r.x + r.w) + 2), Int(r.y)..<min(300, Int(r.y + r.h) + 2),
      (colour.r, colour.g, colour.b), tol: 70)
    #expect(found > 0, "no \(scene.laneColors[hit.lane]) pixel at \(r)")
    // the corner label has text, the lane names are on plates
    #expect(lit(px, 730..<800, 2..<14, textGrey, tol: 60) > 8)
    if scene.laneHeight >= 8 {
      let first = scene.laneColors[0].rgb8
      #expect(lit(px, 4..<40, 147..<158, (first.r, first.g, first.b), tol: 60) > 3, "lane name")
    }
  }

  @Test func theMasterFeedDrawsToo() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let s = try settled(rig, source: .master)
    let view = ScopeLiveView(feed: s.feed, hub: rig.hub, model: s.model) { s.wall }
    savePNG(view, width: 800, height: 300, name: "scope-live-engine-master")
    let px = try #require(renderPixels(view, width: 800, height: 300))
    #expect(lit(px, 0..<800, 3..<141, envelope, tol: 14) > 300)
    #expect(s.feed.lanes.count > 0, "the net deck's lanes")
    #expect(s.feed.lanes.allSatisfy { $0.deck == "A" })
    #expect(s.feed.history.count > 8000 && !s.feed.masterTapSilent)
  }

  @Test func aSampleDeckShowsAWaveformAndNoLanes() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let s = try settled(rig, source: .deck("B"))
    #expect(!s.feed.hasNet && s.feed.lanes.isEmpty)
    let view = ScopeLiveView(feed: s.feed, hub: rig.hub, model: s.model) { s.wall }
    savePNG(view, width: 800, height: 300, name: "scope-live-engine-sample")
    let px = try #require(renderPixels(view, width: 800, height: 300))
    #expect(lit(px, 0..<800, 3..<141, envelope, tol: 14) > 300, "the waveform")
    // no anchors, no grid, no lanes: nothing below the band is GRID coloured
    let grids = lit(px, 0..<800, 146..<290, grid, tol: 3)
    #expect(grids == 0, "no lane separators, no grid lines (\(grids))")
  }

  @Test func withNothingPlayedYetTheViewSaysWhyInTheMiddleOfTheEmptyBand() throws {
    for (play, message) in [(true, "waiting for audio…"), (false, "press play")] {
      let rig = try ScopeViewRig()
      defer { rig.stop() }
      rig.dj["A"]!.setPlaying(play)
      let feed = rig.hub.feed(.deck("A"))
      feed.acquire()
      try renderOffline(rig.dj, frames: 128)  // the transport starts; not a whole block yet
      let model = LiveScopeModel()
      let view = ScopeLiveView(feed: feed, hub: rig.hub, model: model) { 0 }
      savePNG(view, width: 800, height: 300, name: play ? "scope-live-waiting" : "scope-live-empty")
      let px = try #require(renderPixels(view, width: 800, height: 300))
      // (the view's own frame pumped the hub, so the transport is known by now)
      #expect(feed.clock.playing == play)
      let scene = model.scene(feed: feed, width: 800, height: 300)
      #expect(scene.emptyMessage?.text == message)
      let text = lit(px, 6..<130, 67..<80, textGrey, tol: 50)
      #expect(text > 20, "'\(message)' at (6, mid - 5): \(text)")
      #expect(lit(px, 0..<800, 3..<141, envelope, tol: 14) == 0, "and no waveform")
    }
  }

  @Test func aViewCreatedOverALiveFeedIsFittedFromItsFirstFrame() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 2)
    // a brand new model, a clock that has not moved: this is the very first frame of the view,
    // e.g. after flipping to another scope view and back. Starting at disp 0.1 against a peak of
    // several tenths it would paint the waveform 5x too big over the lanes and the labels.
    let model = LiveScopeModel()
    let view = ScopeLiveView(feed: feed, hub: rig.hub, model: model) { 0 }
    savePNG(view, width: 800, height: 300, name: "scope-live-first-frame")
    let px = try #require(renderPixels(view, width: 800, height: 300))
    let scene = model.scene(feed: feed, width: 800, height: 300)
    let settled = (scene.hTop / 2 - 3) / model.gain.peak
    #expect(model.gain.peak > 0.3 && scene.scale <= 1.01 * settled, "scale \(scene.scale)")
    let top = scene.envelope.map(\.y).min() ?? 0
    let bottom = scene.envelope.map { $0.y + $0.h }.max() ?? 0
    #expect(top > -0.15 * scene.hTop && bottom < 1.15 * scene.hTop, "extent \(top) ... \(bottom)")
    // no envelope-coloured pixel among the lanes
    #expect(lit(px, 0..<800, 150..<286, envelope, tol: 14) < 20)
  }

  @Test func theHostsViewKeepsItsWaveformAndGainWhenItIsBuiltAgain() throws {
    // ScopePanelView builds a new ScopeLiveView for every switch of kind or source (and every
    // 0.25 s of its own refresh): the view made by the host's initialiser takes its model from
    // the store, so what the first one learned is not lost
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 2)
    let first = ScopeLiveView(feed: feed, measured: false, hub: rig.hub)
    _ = try #require(renderPixels(first, width: 800, height: 300))
    let model = LiveScopeStore.shared.model(for: feed)
    let held = model.blocks.ring.count
    let gain = model.gain
    #expect(model.started && held > 100 && gain.peak > 0.3)
    try rig.run(seconds: 1)  // audio goes on while another kind is shown
    let second = ScopeLiveView(feed: feed, measured: false, hub: rig.hub)
    let px = try #require(renderPixels(second, width: 800, height: 300))
    #expect(LiveScopeStore.shared.model(for: feed) === model)
    #expect(model.blocks.ring.count > held + 40, "the blocks of the first view are still there")
    #expect(model.gain.peak >= gain.peak * 0.95, "the gain did not restart at 0.1")
    #expect(lit(px, 0..<800, 150..<286, envelope, tol: 14) < 20, "no oversize flash")
  }

  @Test func theViewInTheHostIsTheRealScopeNotThePlaceholder() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.feed(.master).acquire()
    try rig.run(seconds: 2)
    let panel = VStack(spacing: 0) {
      ScopePanelView(
        hub: rig.hub, kind: .constant(.live), source: .constant(.master),
        measured: .constant(false),
        windowHeight: 800)
      Spacer(minLength: 0)
    }
    savePNG(panel, width: 900, height: 700, name: "scope-live-host")
    let px = try #require(renderPixels(panel, width: 900, height: 700))
    // the placeholder drew a red title and nothing blue; the real scope draws the envelope
    let blue = lit(px, 0..<900, 20..<300, envelope, tol: 30)
    #expect(blue > 100, "waveform pixels under the header: \(blue)")
  }
}
