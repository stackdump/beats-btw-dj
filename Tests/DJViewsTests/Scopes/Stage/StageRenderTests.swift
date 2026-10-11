import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

@MainActor
struct StageRenderTests {
  func render(_ rig: StageViewRig, _ ctx: StageContext? = nil) throws -> Pixels {
    let view = StageScene(model: rig.model, context: ctx ?? rig.model.context)
    return try #require(renderPixels(view, width: Int(rig.width), height: Int(rig.height)))
  }

  @Test func theFullStageOnARealNetDeck() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 3)
    let ctx = rig.model.context
    #expect(ctx.panels.count == 6 && ctx.layout.showsMeta)
    let px = try render(rig)
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-full")
    // the stage background, away from everything
    #expect(px.near(5, 400, Sw.background, tol: 3) && px.near(995, 790, Sw.background, tol: 3))
    // not blank: a good deal of the window is drawn on
    let lit = px.count(inX: 0..<1000, y: 0..<800) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
    }
    #expect(lit > 20_000, "panels, arcs and the meta-net are drawn (\(lit) lit pixels)")
    // a lit pixel near every panel's ring point (each panel is a net inside its box)
    for p in ctx.panels {
      let c = Sw.ipt(p.center)
      let n = px.count(inX: (c.0 - 90)..<(c.0 + 90), y: (c.1 - 90)..<(c.1 + 90)) { r, g, b in
        abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
      }
      #expect(n > 300, "\(p.id): drawn around its ring point (\(n))")
    }
    // arcs: #4a90d9 at alpha 0.6 over the background is (48, 90, 141); the kick panel is fully lit
    // (the exact blend is pinned on a synthetic net in StagePaintTests; this is the real net)
    let kick = try #require(ctx.panels.first { $0.netId == "kick-0" })
    let kc = Sw.ipt(kick.center)
    let arcColour = Sw.blend(Sw.arcBlue, StagePalette.arcAlpha, over: Sw.background)
    let arcs = px.count(inX: (kc.0 - 100)..<(kc.0 + 100), y: (kc.1 - 100)..<(kc.1 + 100)) {
      r, g, b in
      abs(r - arcColour.0) <= 4 && abs(g - arcColour.1) <= 4 && abs(b - arcColour.2) <= 4
    }
    #expect(arcs > 100, "arcs in the arc colour at alpha 0.6 (\(arcs))")
    // transition borders and place borders are drawn at full strength
    let borders = px.count(inX: (kc.0 - 100)..<(kc.0 + 100), y: (kc.1 - 100)..<(kc.1 + 100)) {
      r, g, b in
      r > 180 && g < 110 && b < 130
    }
    #expect(borders > 60, "transition borders #e94560 (\(borders))")
    // the toolbar starts folded: just the dot at the top left
    #expect(Sw.anyNear(px, 30, 26, r: 14, (60, 60, 75), tol: 70))
  }

  @Test func aTransitionThatJustFiredGlowsAndNotTwoHundredMillisecondsLater() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    var hit: (panel: Int, transition: Int)?
    for _ in 0..<120 where hit == nil {
      try rig.run(seconds: 0.05)
      if let f = rig.model.context.fires.first(where: { $0.panel != nil && $0.origin != nil }) {
        hit = (f.panel!, f.transition!)
      }
    }
    let h = try #require(hit)
    let lit = rig.model.context
    let at = try #require(lit.panels[h.panel].nodeCenterInStage(transition: h.transition))
    let litFlash = lit.panels[h.panel].flash(transition: h.transition, now: lit.audioNow)
    #expect(litFlash > 0.4, "right after the fire: \(litFlash)")
    // The same frame with the flash taken away: whatever differs is the flash. A transition with a
    // note keeps its two-tone body while it fires (petri-note.css: `.has-midi` is declared after
    // `.firing` at the same specificity), so what shows is the glow in #e94560 round it (and the
    // scale pulse): the pixels near the node turn redder, the centre stays the body.
    var dark = lit
    dark.panels[h.panel].firedAt[h.transition] = -.infinity
    let a = try render(rig, lit)
    let off = try render(rig, dark)
    savePNG(
      StageScene(model: rig.model, context: lit), width: 1000, height: 800, name: "stage-fire-flash"
    )
    let p = Sw.ipt(at)
    var redder = 0
    for y in (p.1 - 40)..<(p.1 + 40) {
      for x in (p.0 - 40)..<(p.0 + 40) where a.color(x, y).r > off.color(x, y).r + 15 {
        redder += 1
      }
    }
    #expect(redder > 60, "the glow tints the pixels round the node (\(redder))")
    #expect(a.color(p.0, p.1).r < 120, "the body is not filled red: \(a.color(p.0, p.1))")
    // 200 ms of audio later (four frames): the same transition is out. Forcing it lit again
    // would change the picture, so it is dark now.
    try rig.run(seconds: 0.2)
    let later = rig.model.context
    #expect(later.panels[h.panel].flash(transition: h.transition, now: later.audioNow) == 0)
    var forced = later
    forced.panels[h.panel].firedAt[h.transition] = later.audioNow
    let b = try render(rig, later)
    let bLit = try render(rig, forced)
    let q = Sw.ipt(try #require(later.panels[h.panel].nodeCenterInStage(transition: h.transition)))
    var glowing = 0
    for y in (q.1 - 40)..<(q.1 + 40) {
      for x in (q.0 - 40)..<(q.0 + 40) where bLit.color(x, y).r > b.color(x, y).r + 15 {
        glowing += 1
      }
    }
    #expect(glowing > 60, "it would glow if it were lit (\(glowing)): so it is dark now")
  }

  @Test func livetokensAreDrawnOnThePlacesThatHoldThem() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 1)
    let ctx = rig.model.context
    let kick = try #require(ctx.panels.first { $0.netId == "kick-0" })
    let held = try #require(kick.tokens.firstIndex { $0 > 0 })
    let empty = try #require(kick.tokens.firstIndex { $0 == 0 })
    let px = try render(rig)
    let a = Sw.ipt(try #require(kick.placeCenterInStage(place: held)))
    let b = Sw.ipt(try #require(kick.placeCenterInStage(place: empty)))
    #expect(px.near(a.0, a.1, Sw.arcBlue, tol: 4), "token dot: \(px.color(a.0, a.1))")
    #expect(px.near(b.0, b.1, Sw.fill, tol: 3), "empty place: \(px.color(b.0, b.1))")
  }

  @Test func aPlaceHoldingSeveralTokensShowsTheCount() throws {
    // synthetic context: one panel, one place with three tokens
    let shape = StageNetShape(
      netId: "n", placeIds: ["p0", "p1"], placeX: [0, 200], placeY: [0, 0],
      transitionIds: ["t0"], transitionX: [100], transitionY: [0])
    let layout = StagePanelLayout.layoutRing(width: 600, height: 600, count: 1)
    let view = StagePanelView.fit(bounds: shape.bounds!, width: layout.side, height: layout.side)
    let panel = StagePanel(
      id: "A/n", deck: "A", netId: "n", label: "n", channel: 1, riffGroup: "",
      center: layout.center, ring: nil, side: layout.side, angle: 0, view: view, muted: false,
      opacity: 1, shape: shape, tokens: [3, 1], firedAt: [-.infinity])
    let ctx = StageContext(width: 600, height: 600, layout: layout, panels: [panel])
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let model = StageModel(hub: ScopeHub(engine: dj))
    let scene = StageScene(model: model, context: ctx)
    let px = try #require(renderPixels(scene, width: 600, height: 600))
    savePNG(scene, width: 600, height: 600, name: "stage-token-count")
    let many = Sw.ipt(try #require(panel.placeCenterInStage(place: 0)))
    let one = Sw.ipt(try #require(panel.placeCenterInStage(place: 1)))
    // the bigger disc is blue around the digit, the single token is a plain dot
    let dotMany = px.count(inX: (many.0 - 14)..<(many.0 + 14), y: (many.1 - 14)..<(many.1 + 14)) {
      r, g, b in
      b > 150 && r < 120
    }
    let dotOne = px.count(inX: (one.0 - 14)..<(one.0 + 14), y: (one.1 - 14)..<(one.1 + 14)) {
      r, g, b in
      b > 150 && r < 120
    }
    #expect(dotMany > dotOne, "r 15 vs r 10 (scaled): \(dotMany) vs \(dotOne)")
    // the digit is drawn in the node fill colour on the blue disc
    let digit = px.count(inX: (many.0 - 10)..<(many.0 + 10), y: (many.1 - 10)..<(many.1 + 10)) {
      r, g, b in
      r < 60 && g < 60 && b < 90
    }
    #expect(digit > 6, "the count \"3\" is drawn (\(digit) dark pixels on the disc)")
  }

  @Test func theToolbarHasEveryControlAndFoldsIntoOneDot() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    func topBar(_ px: Pixels) -> Int {
      px.count(inX: 0..<1000, y: 0..<56) { r, g, b in r + g + b > 220 }
    }
    let folded = try render(rig)
    rig.model.settings.menuCollapsed = false
    try rig.run(seconds: 0.05)
    let open = try render(rig)
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-toolbar")
    #expect(topBar(open) > topBar(folded) + 500, "open \(topBar(open)) vs folded \(topBar(folded))")
    // the accent fill of the active controls: source A, flow, pulse, flame, bolts
    let accent = open.count(inX: 0..<1000, y: 0..<56) { r, g, b in
      abs(r - 22) < 14 && abs(g - 44) < 14 && abs(b - 78) < 18
    }
    #expect(accent > 400, "active toggles carry the blue tint (\(accent))")
    // turning flow off removes one of the tinted discs
    rig.model.settings.toggle(.flow)
    try rig.run(seconds: 0.05)
    let flowOff = try render(rig)
    let accent2 = flowOff.count(inX: 0..<1000, y: 0..<56) { r, g, b in
      abs(r - 22) < 14 && abs(g - 44) < 14 && abs(b - 78) < 18
    }
    #expect(accent2 < accent - 200, "\(accent2) < \(accent)")
    #expect(!rig.model.settings.isOn(.flow))
  }

  @Test func everyToolbarControlWritesItsFlag() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    let s = rig.model.settings
    #expect(s.overlays == [.flow, .pulse, .flame, .bolts] && s.visualizer == .constellation)
    #expect(
      !s.expandVariants && !s.showBacks && !s.showLabels && !s.cardOnChange && s.menuCollapsed)
    #expect(s.bgMode == .void && s.scale == .loop && s.source == .deck("A"))
    for o in StageOverlay.allCases {
      let was = s.isOn(o)
      s.toggle(o)
      #expect(s.isOn(o) == !was)
    }
    try rig.run(seconds: 0.1)
    let c = rig.model.context
    #expect(c.overlays == s.overlays && c.scale == s.scale && c.bgMode == s.bgMode)
    s.scale = .xl
    s.bgMode = .aurora
    s.showBacks = true
    s.showLabels = true
    s.cardOnChange = true
    try rig.run(seconds: 0.1)
    let d = rig.model.context
    #expect(d.scale == .xl && d.bgMode == .aurora && d.showBacks && d.showLabels && d.cardOnChange)
    #expect(d.layout.side > c.layout.side, "xl panels are bigger")
  }

  @Test func theCardButtonIsDisabledWhileTheCardLayerIsUnavailable() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    #expect(!rig.model.layers.card.isAvailable)
    #expect(rig.model.layers.card.unavailableReason.contains("share card"))
    // T falls back to the card toggle only when it is available
    #expect(rig.model.handleKey(.t) == false && !rig.model.settings.cardOnChange)
  }

  @Test func backsAndLabelsAreOptional() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let plain = try render(rig)
    rig.model.settings.showBacks = true
    try rig.run(seconds: 0.05)
    let ctx = rig.model.context
    let backs = try render(rig)
    let p = try #require(ctx.panels.first { $0.netId == "hihat-0" })
    // a spot inside the panel box that nothing else touches (top right): background without
    // backs, and with them the radial gradient's outer colour (#070712) a hair inside the corner
    let corner = (Int(p.origin.x + p.side) - 5, Int(p.origin.y) + 5)
    let plainCorner = plain.color(corner.0, corner.1)
    let backsCorner = backs.color(corner.0, corner.1)
    #expect(plainCorner.r == 10 && plainCorner.g == 10 && plainCorner.b == 26, "\(plainCorner)")
    #expect(abs(backsCorner.r - 7) < 7 && abs(backsCorner.b - 18) < 8, "\(backsCorner)")
    // the centre of the box is the gradient's inner colour (#131a33) rather than the background
    let mid = Sw.ipt(p.center)
    #expect(backs.color(mid.0, mid.1).g > plain.color(mid.0, mid.1).g)
    // labels: uppercase 11 px text at the top left of the box
    rig.model.settings.showLabels = true
    try rig.run(seconds: 0.05)
    let labelled = try render(rig)
    let box = (Int(p.origin.x) + 8)..<(Int(p.origin.x) + 8 + 60)
    let rows = (Int(p.origin.y) + 4)..<(Int(p.origin.y) + 22)
    let before = backs.count(inX: box, y: rows) { r, g, b in r > 90 }
    let after = labelled.count(inX: box, y: rows) { r, g, b in r > 90 }
    #expect(after > before + 20, "the label HIHAT is drawn (\(before) -> \(after))")
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-backs-labels")
  }

  @Test func aMutedPanelIsDim() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let ctx = rig.model.context
    let px = try render(rig)
    func brightest(_ id: String) throws -> Int {
      let p = try #require(ctx.panels.first { $0.id == id })
      let c = Sw.ipt(p.center)
      var m = 0
      for y in max(0, c.1 - 90)..<min(800, c.1 + 90) {
        for x in max(0, c.0 - 90)..<min(1000, c.0 + 90) {
          let q = px.color(x, y)
          m = max(m, q.r + q.g + q.b)
        }
      }
      return m
    }
    let lit = try brightest("A/kick-0")
    let dim = try brightest("A/bass-0")
    #expect(lit > 450, "a live panel reaches full strength (\(lit))")
    #expect(dim < 330, "a muted panel is group-faded to a quarter (\(dim))")
  }

  @Test func aSoloVisualizerHidesThePanelGridAndTheConstellationControls() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.menuCollapsed = false
    try rig.run(seconds: 0.5)
    let grid = try render(rig)
    rig.model.settings.visualizer = .corona
    try rig.run(seconds: 0.05)
    let solo = try render(rig)
    let ctx = rig.model.context
    #expect(ctx.isSolo && ctx.visualizer == .corona)
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-solo-corona")
    let p = try #require(ctx.panels.first { $0.netId == "kick-0" })
    let c = Sw.ipt(p.center)
    func lit(_ px: Pixels) -> Int {
      px.count(inX: (c.0 - 55)..<(c.0 + 55), y: (c.1 - 55)..<(c.1 + 55)) { r, g, b in
        abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
      }
    }
    #expect(
      lit(grid) > 300 && lit(solo) == 0,
      "the grid is hidden (viz-solo): \(lit(grid)) -> \(lit(solo))")
    // meta-net gone as well
    #expect(solo.near(500, 330, Sw.background, tol: 8))
    // the toolbar drops the controls that only mean something for the constellation
    func bar(_ px: Pixels) -> Int {
      px.count(inX: 0..<1000, y: 0..<56) { r, g, b in r + g + b > 220 }
    }
    #expect(bar(solo) < bar(grid) - 300, "\(bar(solo)) < \(bar(grid))")
    // the corona (SPEC mode 9) has taken the placeholder's place: bars round the ring's centre
    // and an empty middle
    try rig.run(seconds: 0.5)
    let corona = try render(rig)
    let bars = corona.count(inX: 300..<700, y: 150..<650) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 40
    }
    #expect(bars > 300, "the corona is drawn (\(bars) lit pixels)")
    #expect(corona.near(500, 400, Sw.background, tol: 8))
  }

  @Test func withoutANetDeckTheStageSaysSo() throws {
    let rig = try StageViewRig(source: .deck("B"))
    defer { rig.stop() }
    try rig.run(seconds: 0.3)
    let ctx = rig.model.context
    #expect(ctx.panels.isEmpty && !ctx.hasNet)
    let px = try render(rig)
    let text = px.count(inX: 250..<750, y: 380..<420) { r, g, b in r > 60 && g > 60 }
    #expect(text > 60, "the message is drawn (\(text))")
    #expect(px.near(5, 5, Sw.background, tol: 3))
  }

  @Test func theStatsPillIsDrawnAtTheBottom() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.3)
    let px = try render(rig)
    let pill = px.count(inX: 300..<700, y: 745..<790) { r, g, b in r > 120 && g > 120 && b > 120 }
    #expect(pill > 150, "the stats text (\(pill))")
    #expect(rig.model.context.stats.hasPrefix("56 bars · 2/40 nets"))
  }

  @Test func theHelpSheetHasItsText() throws {
    // (the sheet scrolls; a ScrollView does not render offscreen, so its content is drawn alone)
    let view = StageHelpContent(close: {}).frame(width: 520).padding(8).background(Color.black)
    let px = try #require(renderPixels(view, width: 540, height: 760))
    savePNG(view, width: 540, height: 760, name: "stage-help-content")
    let text = px.count(inX: 0..<540, y: 0..<760) { r, g, b in r > 140 && g > 140 && b > 140 }
    #expect(text > 2500, "the help text is drawn (\(text) light pixels)")
    // and the card opens over the stage: the dimmed backdrop darkens the panels
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.2)
    let plain = try render(rig)
    let sheet = try #require(
      renderPixels(rig.scene(helpOpen: true), width: 1000, height: 800))
    let brightness = { (p: Pixels) in
      var sum = 0
      for y in stride(from: 0, to: 800, by: 4) {
        for x in stride(from: 0, to: 1000, by: 4) {
          let c = p.color(x, y)
          sum += c.r + c.g + c.b
        }
      }
      return sum
    }
    #expect(brightness(sheet) < brightness(plain) * 3 / 4, "the backdrop dims the stage")
  }

  @Test func theLiveHostRendersItsFirstFrame() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    // StageView = GeometryReader + TimelineView(.animation): the first frame is drawn at once
    let view = StageView(model: rig.model)
    let px = try #require(renderPixels(view, width: 1000, height: 800))
    let lit = px.count(inX: 0..<1000, y: 0..<800) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
    }
    #expect(lit > 15_000, "the live host draws the stage (\(lit))")
    #expect(rig.model.context.width == 1000 && rig.model.context.height == 800)
  }

  @Test func theContainerProjectsWithTheCSSMatrix() throws {
    // a cross-hair at the centre and a marker on the +x axis, tilted by the stage's matrix
    let proj = StageProjection.tilt(rotateX: 18, rotateY: 22, rotateZ: 0)
    func content() -> some View {
      Canvas { gc, size in
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        gc.fill(
          Path(ellipseIn: CGRect(x: 250 - 6, y: 200 - 6, width: 12, height: 12)),
          with: .color(.white))
        gc.fill(
          Path(ellipseIn: CGRect(x: 450 - 6, y: 200 - 6, width: 12, height: 12)), with: .color(.red)
        )
      }
    }
    let view = StageContainer(projection: proj, width: 500, height: 400) { content() }
    let px = try #require(renderPixels(view, width: 500, height: 400))
    savePNG(view, width: 500, height: 400, name: "stage-container-tilt")
    let want = try #require(proj.project(x: 450, y: 200, centerX: 250, centerY: 200))
    let centre = try #require(proj.project(x: 250, y: 200, centerX: 250, centerY: 200))
    #expect(near(centre, 250, 200))
    let w = Sw.ipt(want)
    #expect(
      px.count(inX: (w.0 - 8)..<(w.0 + 8), y: (w.1 - 8)..<(w.1 + 8)) { r, g, b in r > 200 && g < 80
      } > 20,
      "the red marker is where the CSS matrix puts it: \(want)")
    #expect(
      px.count(inX: (450 - 8)..<(450 + 8), y: (200 - 8)..<(200 + 8)) { r, g, b in r > 200 && g < 80
      } == 0,
      "and not where it was")
    #expect(px.near(250, 200, (255, 255, 255), tol: 30), "the pivot stays")
  }

  @Test func aPlanarContainerIsAPlainRotation() throws {
    func content() -> some View {
      Canvas { gc, size in
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        gc.fill(
          Path(ellipseIn: CGRect(x: 450 - 6, y: 200 - 6, width: 12, height: 12)), with: .color(.red)
        )
      }
    }
    let view = StageContainer(projection: .spin(90), width: 500, height: 400) { content() }
    let px = try #require(renderPixels(view, width: 500, height: 400))
    // (450, 200) is 200 right of the centre (250, 200): a quarter turn clockwise puts it 200 below
    #expect(px.count(inX: 242..<258, y: 392..<400) { r, g, b in r > 200 && g < 80 } > 5)
    #expect(
      px.count(inX: (450 - 8)..<(450 + 8), y: (200 - 8)..<(200 + 8)) { r, g, b in r > 200 && g < 80
      } == 0)
  }
}

private func near(_ p: StagePoint, _ x: Double, _ y: Double, _ tol: Double = 1e-9) -> Bool {
  abs(p.x - x) <= tol && abs(p.y - y) <= tol
}
