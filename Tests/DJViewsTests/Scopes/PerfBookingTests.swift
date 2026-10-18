import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// Every visual path reports its draw time to the monitor under its own name, and the menu and the
/// notice show what the monitor says.
@MainActor
struct PerfBookingTests {
  /// Calls booked per path since the monitor started.
  func calls(_ perf: PerfMonitor) -> [VizKind: Int] {
    Dictionary(uniqueKeysWithValues: VizKind.allCases.map { ($0, perf.currentViz($0).calls) })
  }

  @Test func theScopePanelModesBookTheScopePath() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    try rig.run(seconds: 1)
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    let live = ScopeLiveView(feed: feed, measured: false, hub: rig.hub)
    _ = try #require(renderPixels(live, width: 400, height: 200))
    let c = calls(rig.hub.perf)
    #expect(c[.scope, default: 0] >= 1, "the draw was timed as the scope path")
    #expect(c[.timeline] == 0 && c[.stage] == 0 && c[.ring] == 0)
    #expect(rig.hub.perf.currentViz(.scope).ms >= 0)
  }

  @Test func theTimelineDotsBookTheTimelinePath() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    let strip = TimelineDotsView(feed: rig.hub.feed(.deck("A")), hub: rig.hub, active: true)
    _ = try #require(renderPixels(strip, width: 300, height: 30))
    let c = calls(rig.hub.perf)
    #expect(c[.timeline, default: 0] >= 1 && c[.scope] == 0)
  }

  @Test func theRingsBookTheRingPathOnlyWhereTheAppGivesThemAHub() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.3)
    let ring = try #require(rig.dj["A"]!.netSnapshot?.rings.first)
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    let plain = RingNetView(ring: ring, tint: .orange)
    _ = try #require(renderPixels(plain, width: 100, height: 100))
    #expect(calls(rig.hub.perf)[.ring] == 0, "no hub in the environment: drawn as before, unbooked")
    let booked = plain.environment(\.scopeHub, rig.hub)
    _ = try #require(renderPixels(booked, width: 100, height: 100))
    #expect(calls(rig.hub.perf)[.ring, default: 0] >= 1)
  }

  @Test func theStagesFrameBooksTheStagePath() throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    rig.hub.perf.start()
    defer { rig.hub.perf.stop() }
    _ = try #require(renderPixels(StageView(model: rig.model), width: 600, height: 400))
    let c = calls(rig.hub.perf)
    #expect(c[.stage, default: 0] >= 1 && c[.scope] == 0)
  }

  /// A stage over an idle offline engine whose monitor reads a clock that ticks `stepMs` at every
  /// reading, and the scene of its first frame.
  func tickingStage(stepMs: Double, rig: StageViewRig) -> (
    perf: PerfMonitor, model: StageModel, scene: StageScene
  ) {
    let clock = TickClock(stepMs: stepMs)
    let perf = PerfMonitor(clock: { clock.read() })
    let hub = ScopeHub(engine: rig.dj, perf: perf)
    let model = StageModel(hub: hub)
    model.advance(now: 1000, dt: 0.05, width: 600, height: 400)
    return (perf, model, StageScene(model: model, context: model.context))
  }

  @Test func everyStageLayerBooksItsDrawAsTheStagePath() throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    let (perf, _, scene) = tickingStage(stepMs: 4, rig: rig)
    perf.start()
    _ = try #require(renderPixels(scene, width: 600, height: 400))
    let v = perf.currentViz(.stage)
    // background, flame, bolts, meta, pulse, panels, empty message, solo: eight canvases, each
    // one span of one 4 ms tick (the model's frame is booked by the host, not by the scene)
    #expect(v.calls == 8, "\(v.calls) booked draws")
    #expect(abs(v.ms - 32) < 1e-6, "\(v.ms) ms")
    #expect(perf.currentViz(.scope).calls == 0 && perf.currentViz(.ring).calls == 0)
  }

  @Test func aStageWhoseLayersDrawSlowlyIsStepDownByTheMonitor() throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    // Each reading of the clock takes 10 ms: a scene's eight draws book 80 ms and the monitor's
    // own readings stretch every frame to ~170 ms. Only a booked draw can make that "the
    // visuals" (47 % of the window) rather than "something else".
    let (perf, model, scene) = tickingStage(stepMs: 10, rig: rig)
    perf.start()
    var frames = 0
    while perf.level == 0 && frames < 60 {
      _ = try #require(renderPixels(scene, width: 600, height: 400))
      perf.frame()
      frames += 1
    }
    #expect(perf.level == 1 && model.hub.vizLevel == 1, "stepped down after \(frames) frames")
    #expect(perf.history.count >= 2 && perf.history.allSatisfy { $0.cause == .visualization })
    #expect((perf.last?.vizMs[VizKind.stage.rawValue] ?? 0) > 100)
    #expect(perf.notice != nil)
  }

  @Test func eachPathHasItsOwnTotal() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let clock = TestClock()
    let perf = PerfMonitor(clock: { clock.now })
    let hub = ScopeHub(engine: rig.dj, perf: perf)
    perf.start()
    hub.timed(.ring) { clock.advance(ms: 3) }
    hub.timed(.ring) { clock.advance(ms: 4) }
    hub.timed(.stage) { clock.advance(ms: 10) }
    #expect(abs(perf.currentViz(.ring).ms - 7) < 1e-6 && perf.currentViz(.ring).calls == 2)
    #expect(abs(perf.currentViz(.stage).ms - 10) < 1e-6 && perf.currentViz(.timeline).calls == 0)
  }

  // MARK: the menu and the notice

  /// A monitor on a hand-moved clock that has stepped down once.
  func reducedMonitor() -> (PerfMonitor, TestClock) {
    let clock = TestClock()
    let perf = PerfMonitor(clock: { clock.now })
    perf.start()
    // 4 s of 40 ms frames, every one a 40 ms scope draw
    for _ in 0..<110 {
      let t0 = perf.vizBegin()
      clock.advance(ms: 40)
      perf.vizEnd(.scope, t0)
      perf.frame()
    }
    return (perf, clock)
  }

  @Test func theMenuTitleSaysWhatIsChosenAndWhereAutoIs() {
    let perf = PerfMonitor()
    #expect(vizQualityTitle(perf) == "Visuals: auto · full")
    perf.setPreference(.reduced)
    #expect(vizQualityTitle(perf) == "Visuals: reduced")
    perf.setPreference(.paused)
    #expect(vizQualityTitle(perf) == "Visuals: paused")
    perf.setPreference(.auto)
    #expect(vizQualityTitle(perf) == "Visuals: auto · paused", "auto keeps the pinned level")
    let (stepped, _) = reducedMonitor()
    #expect(vizQualityTitle(stepped) == "Visuals: auto · reduced")
  }

  /// Pixels that are clearly lit. Views are rendered over a black ground: ImageRenderer hands back
  /// whatever was in a recycled buffer for a view that draws nothing, so a blank render proves
  /// nothing (an empty view over black does).
  func lit(_ px: Pixels) -> Int {
    px.count(inX: 0..<px.width, y: 0..<px.height) { r, g, b in r + g + b > 200 }
  }

  /// Over black as far as the render frame goes (a `.background` would only be as big as `v`).
  func onBlack<V: View>(_ v: V) -> some View {
    ZStack {
      Color.black
      v
    }
  }

  @Test func theNoticeShowsWhileTheMonitorHasOneAndNothingOtherwise() throws {
    let quiet = PerfMonitor()
    #expect(quiet.notice == nil)
    let none = try #require(
      renderPixels(onBlack(VizNoticeView(perf: quiet)), width: 420, height: 24))
    #expect(lit(none) < 20, "no notice: nothing is drawn")
    let (perf, _) = reducedMonitor()
    #expect(perf.notice?.text == "Visuals reduced (reduced) to keep playback smooth")
    let shown = try #require(
      renderPixels(onBlack(VizNoticeView(perf: perf)), width: 420, height: 24))
    #expect(lit(shown) > 300, "the message and its 'Keep full visuals' link are drawn")
    savePNG(onBlack(VizNoticeView(perf: perf)), width: 420, height: 24, name: "perf-notice")
    perf.keepFullVisuals()
    #expect(perf.notice == nil)
    let gone = try #require(
      renderPixels(onBlack(VizNoticeView(perf: perf)), width: 420, height: 24))
    #expect(lit(gone) < 20, "keeping full visuals dismisses it")
  }

  @Test func theMenuFaceIsAGlyphUntilThereIsSomethingToTell() {
    let perf = PerfMonitor()
    #expect(vizQualityBadge(perf) == "◐", "auto, at full: just the glyph")
    perf.setPreference(.reduced)
    #expect(vizQualityBadge(perf) == "◐ reduced (pinned)")
    perf.setPreference(.full)
    #expect(vizQualityBadge(perf) == "◐ full (pinned)", "a pinned full is not the same as auto")
    perf.setPreference(.paused)
    perf.setPreference(.auto)
    #expect(vizQualityBadge(perf) == "◐ paused", "auto keeps the pinned level, and says so")
    let (stepped, _) = reducedMonitor()
    #expect(vizQualityBadge(stepped) == "◐ reduced")
  }

  @Test func theMenuIsDrawnAndFollowsTheMonitor() throws {
    let perf = PerfMonitor()
    let full = try #require(
      renderPixels(onBlack(VizQualityMenu(perf: perf)), width: 260, height: 26))
    #expect(lit(full) > 15, "a pill with the glyph")
    savePNG(onBlack(VizQualityMenu(perf: perf)), width: 260, height: 26, name: "perf-menu")
    savePNG(
      onBlack(VizQualityMenu(perf: perf, onDark: true)), width: 260, height: 40,
      name: "perf-menu-dark")
    perf.setPreference(.minimal)
    let minimal = try #require(
      renderPixels(onBlack(VizQualityMenu(perf: perf)), width: 260, height: 26))
    var differ = 0
    for y in 0..<full.height {
      for x in 0..<full.width where full.color(x, y) != minimal.color(x, y) { differ += 1 }
    }
    #expect(differ > 40, "the face changed with the preference (\(differ) pixels)")
  }

  @Test func theScopePanelHeaderCarriesTheMenuAndFollowsIt() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let perf = PerfMonitor()
    let hub = ScopeHub(engine: rig.dj, perf: perf)
    func panel() -> some View {
      VStack(spacing: 0) {
        ScopePanelView(
          hub: hub, kind: .constant(.live), source: .constant(.master),
          measured: .constant(false), windowHeight: 800)
        Spacer(minLength: 0)
      }
    }
    let auto = try #require(renderPixels(panel(), width: 1100, height: 800))
    savePNG(panel(), width: 1100, height: 800, name: "perf-panel-header")
    perf.setPreference(.minimal)
    let pinned = try #require(renderPixels(panel(), width: 1100, height: 800))
    var differ = 0
    for y in 0..<26 {
      for x in 0..<auto.width where auto.color(x, y) != pinned.color(x, y) { differ += 1 }
    }
    #expect(differ > 100, "the menu's face in the header follows the preference (\(differ))")
  }

  /// The main window (the scope panel's, not the Stage's) is at least 720 pt wide (DJApp's
  /// `WindowRoot(minSize:)`) and pads its content by 16 pt on each side.
  static let headerRoom = 720.0 - 32

  @Test func theHeaderLeavesRoomForTheStatusAtTheWindowsMinimumWidth() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let (stepped, _) = reducedMonitor()
    for (name, perf) in [("auto, full", PerfMonitor()), ("auto, stepped down", stepped)] {
      let hub = ScopeHub(engine: rig.dj, perf: perf)
      for kind in ScopeKind.allCases {
        // the widest the header gets is with a "measured" pill in the on state
        let header = ScopePanelHeader(
          hub: hub, kind: .constant(kind), source: .constant(.master), measured: .constant(true),
          status: "")
        let used = idealSize(of: header).width
        let room = Self.headerRoom - used
        #expect(
          room >= (stepped === perf ? 90 : 150),
          "\(name), \(kind): the pills take \(used) pt, leaving \(room) pt for the status")
      }
    }
    // and the pills win over the status when there is not enough: a long status is what is cut
    let perf = PerfMonitor()
    let hub = ScopeHub(engine: rig.dj, perf: perf)
    let width = Int(Self.headerRoom)
    func header(_ status: String) -> some View {
      ScopePanelHeader(
        hub: hub, kind: .constant(.spectro), source: .constant(.master),
        measured: .constant(true), status: status
      )
      .frame(width: Self.headerRoom, alignment: .leading)
    }
    // The pills (menu included) end where the status's spacer (8 pt minimum) begins.
    let pillsEnd =
      Int(
        idealSize(
          of: ScopePanelHeader(
            hub: hub, kind: .constant(.spectro), source: .constant(.master),
            measured: .constant(true), status: "")
        ).width) - 8
    #expect(pillsEnd > 300 && pillsEnd < width - 90, "the pills end at \(pillsEnd) pt")
    // The process's first render of this text comes out a level or so off in ~30 antialiased
    // pixels (seen: 1/255 in one channel), so render once to warm up before comparing.
    _ = renderPixels(header(""), width: width, height: 24)
    let short = try #require(renderPixels(header(""), width: width, height: 24))
    let long = try #require(
      renderPixels(
        header(String(repeating: "lanes and bpm ", count: 12)), width: width, height: 24))
    // A narrower frame is no squeeze probe: the pills are fixedSize and overflow it, and both
    // renders shift alike. What this catches is the pills losing fixedSize / layoutPriority(-1)
    // on the status (seen: 8097 pixels changed).
    var pillsChanged = 0
    for y in 0..<24 {
      for x in 0..<pillsEnd where short.color(x, y) != long.color(x, y) { pillsChanged += 1 }
    }
    #expect(pillsChanged == 0, "a long status does not squeeze a pill (\(pillsChanged) pixels)")
    savePNG(header("10 lanes · 128 bpm · 4 bars"), width: width, height: 24, name: "header-720")
  }

  // MARK: the Stage

  /// The right-most lit pixel of the toolbar's band in a stage scene.
  func toolbarRightEdge(_ px: Pixels) -> Int {
    var right = 0
    for y in 14..<56 {
      for x in stride(from: px.width - 1, through: 0, by: -1) where px.color(x, y).r > 60 {
        right = max(right, x)
        break
      }
    }
    return right
  }

  @Test func theStageToolbarKeepsItsQualityMenuInsideTheWindowsMinimumWidth() throws {
    let rig = try StageViewRig(width: 760, height: 480, play: false)
    defer { rig.stop() }
    rig.model.settings.menuCollapsed = false
    try rig.run(seconds: 0.2)
    let full = try #require(renderPixels(rig.scene(), width: 760, height: 480))
    savePNG(rig.scene(), width: 760, height: 480, name: "stage-toolbar-min-width")
    let right = toolbarRightEdge(full)
    #expect(
      right > 600 && right < 745, "the toolbar ends at x = \(right), inside the 760 pt window")
    // lit while the visuals are not at full: the glyph button highlights
    rig.hub.perf.setPreference(.reduced)
    try rig.run(seconds: 0.1)
    let reduced = try #require(renderPixels(rig.scene(), width: 760, height: 480))
    var differing = 0
    for y in 12..<60 {
      for x in (right - 40)...right where full.color(x, y) != reduced.color(x, y) { differing += 1 }
    }
    #expect(
      differing > 30, "the last button of the toolbar changed with the preference (\(differing))")
  }

  /// A stage whose monitor has just stepped down once, and its scene.
  func steppedDownStage(rig: StageViewRig) -> (perf: PerfMonitor, scene: StageScene) {
    let clock = TestClock()
    let perf = PerfMonitor(clock: { clock.now })
    let hub = ScopeHub(engine: rig.dj, perf: perf)
    let model = StageModel(hub: hub)
    model.advance(now: 1000, dt: 0.05, width: 760, height: 480)
    let quiet = StageScene(model: model, context: model.context)
    perf.start()
    for _ in 0..<110 {
      let t0 = perf.vizBegin()
      clock.advance(ms: 40)
      perf.vizEnd(.stage, t0)
      perf.frame()
    }
    return (perf, quiet)
  }

  @Test func theStageShowsTheNoticeAtItsFootOnlyWhileThereIsOne() throws {
    let rig = try StageViewRig(width: 760, height: 480, play: false)
    defer { rig.stop() }
    let clock = TestClock()
    let perf = PerfMonitor(clock: { clock.now })
    let hub = ScopeHub(engine: rig.dj, perf: perf)
    let model = StageModel(hub: hub)
    model.advance(now: 1000, dt: 0.05, width: 760, height: 480)
    func scene() -> some View {
      StageScene(model: model, context: model.context)
    }
    func foot(_ px: Pixels) -> Int {
      px.count(inX: 0..<760, y: 380..<480) { r, g, b in r + g + b > 250 }
    }
    let quiet = try #require(renderPixels(scene(), width: 760, height: 480))
    perf.start()
    for _ in 0..<110 {
      let t0 = perf.vizBegin()
      clock.advance(ms: 40)
      perf.vizEnd(.stage, t0)
      perf.frame()
    }
    #expect(perf.notice != nil && hub.vizLevel == 1)
    let shown = try #require(renderPixels(scene(), width: 760, height: 480))
    savePNG(scene(), width: 760, height: 480, name: "stage-notice")
    #expect(foot(shown) > foot(quiet) + 250, "\(foot(shown)) lit pixels vs \(foot(quiet))")
    perf.keepFullVisuals()
    let gone = try #require(renderPixels(scene(), width: 760, height: 480))
    #expect(
      abs(foot(gone) - foot(quiet)) < 40,
      "back to the stats pill alone (\(foot(gone)) vs \(foot(quiet)))")
  }

  /// The bounding box (x0, y0, x1, y1) of the pixels of `a` that differ from `b` by more than
  /// `by` in some channel, within rows `rows`; nil if none.
  func box(_ a: Pixels, against b: Pixels, rows: Range<Int>, by: Int = 6)
    -> (x0: Int, y0: Int, x1: Int, y1: Int)?
  {
    var found: (x0: Int, y0: Int, x1: Int, y1: Int)?
    for y in rows {
      for x in 0..<a.width {
        let p = a.color(x, y)
        let q = b.color(x, y)
        guard max(abs(p.r - q.r), abs(p.g - q.g), abs(p.b - q.b)) > by else { continue }
        if let f = found {
          found = (min(f.x0, x), min(f.y0, y), max(f.x1, x), max(f.y1, y))
        } else {
          found = (x, y, x, y)
        }
      }
    }
    return found
  }

  @Test func theStagesNoticeDoesNotLieOnTheStatsPill() throws {
    // At the window's minimum width the toolbar fills the top; the foot has the stats pill in the
    // middle (bottom 18 pt) and the notice, which used to be drawn on top of it.
    let rig = try StageViewRig(width: 760, height: 480, play: false)
    defer { rig.stop() }
    let (perf, scene) = steppedDownStage(rig: rig)
    let withNotice = try #require(renderPixels(scene, width: 760, height: 480))
    perf.keepFullVisuals()
    let quiet = try #require(renderPixels(scene, width: 760, height: 480))
    // the stats pill's text: the light pixels of the quiet foot
    var pill: (x0: Int, y0: Int, x1: Int, y1: Int)?
    for y in 430..<480 {
      for x in 60..<700 {
        let c = quiet.color(x, y)
        guard c.r + c.g + c.b > 200 else { continue }
        if let f = pill {
          pill = (min(f.x0, x), min(f.y0, y), max(f.x1, x), max(f.y1, y))
        } else {
          pill = (x, y, x, y)
        }
      }
    }
    let p = try #require(pill, "the stats pill is drawn")
    let n = try #require(box(withNotice, against: quiet, rows: 0..<480), "and the notice")
    #expect(p.x1 - p.x0 > 150 && p.y1 - p.y0 > 6, "the pill's text: \(p)")
    #expect(n.x1 - n.x0 > 250 && n.y1 - n.y0 > 12, "the notice: \(n)")
    #expect(n.y1 < p.y0, "the notice (\(n)) is above the pill's text (\(p))")
    #expect(n.x0 >= 0 && n.x1 < 760, "and inside the window")
  }
}
