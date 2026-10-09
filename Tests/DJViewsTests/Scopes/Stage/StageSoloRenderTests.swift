import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Render tests of the stage's solo visualizers (SPEC modes 9-12). The painter is tested on its
// own (hand-made values over the stage's background, so every position is a coordinate computed
// here), the layer on a synthetic context, and the whole stage once per visualizer on a real
// offline engine. Set DJ_SHOT_DIR to also write PNGs for a human.

/// Colour helpers of the solo tests, namespaced like `StageSwatch`.
enum SoloSwatch {
  /// The hue in degrees (0..<360) of an 8-bit colour, nil for a grey.
  static func hue(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Double? {
    let r = Double(c.r) / 255
    let g = Double(c.g) / 255
    let b = Double(c.b) / 255
    let hi = max(r, g, b)
    let lo = min(r, g, b)
    guard hi - lo > 0.02 else { return nil }
    var h: Double
    if hi == r {
      h = (g - b) / (hi - lo)
    } else if hi == g {
      h = 2 + (b - r) / (hi - lo)
    } else {
      h = 4 + (r - g) / (hi - lo)
    }
    h *= 60
    return h < 0 ? h + 360 : h
  }

  /// Distance between two hues on the colour wheel, degrees.
  static func hueGap(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
  }

  /// How far a pixel is from the stage background, summed over the channels.
  static func lift(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Int {
    abs(c.r - 10) + abs(c.g - 10) + abs(c.b - 26)
  }

  /// A context for a bare solo layer on a `w` x `h` stage with `count` panels' worth of ring.
  @MainActor
  static func context(
    _ visualizer: StageVisualizer, w: Double = 800, h: Double = 600, panels: [StagePanel] = [],
    fires: [StageFire] = [], now: Double = 100, dt: Double = 1.0 / 60
  ) -> StageContext {
    StageContext(
      width: w, height: h,
      layout: StagePanelLayout.layoutRing(width: w, height: h, count: panels.count),
      panels: panels, now: now, dt: dt, fires: fires, selection: visualizer, visualizer: visualizer)
  }

  /// The solo layer for `context` over the stage's background, as pixels.
  @MainActor
  static func pixels(_ context: StageContext, _ model: StageSoloModel) -> Pixels? {
    renderPixels(
      scene(context, model), width: Int(context.width), height: Int(context.height))
  }

  @MainActor
  static func scene(_ context: StageContext, _ model: StageSoloModel) -> some View {
    ZStack {
      StagePalette.background.color
      StageSoloLayer(context: context, model: model)
    }
  }
}

// MARK: - the painter's glow

@MainActor
struct StageSoloGlowTests {
  /// A canvas `shadowBlur` of B is a Gaussian of standard deviation B/2. A wide bar's shadow, at
  /// a distance d outside its edge, has the strength Q(d / sigma) of the shadow colour: with
  /// blur 20 (sigma 10) that is 0.1587 at 10 points and 0.0228 at 20; with sigma 5 it would be
  /// 0.0228 at 10, with sigma 20, 0.3085. This pins the conversion the painter relies on.
  @Test func aCanvasBlurIsAGaussianOfHalfTheNumber() throws {
    let view = ZStack {
      Color.black
      Canvas { gc, _ in
        StageSoloPainter.glow(gc, color: ScopeColor(r: 1, g: 1, b: 1, a: 1), blur: 20) { layer in
          layer.fill(Path(CGRect(x: 100, y: 0, width: 100, height: 200)), with: .color(.black))
        }
      }
    }
    let px = try #require(renderPixels(view, width: 300, height: 200))
    func strength(_ d: Int) -> Double { Double(px.color(200 + d, 100).r) / 255 }
    // (the bar itself is drawn black over its own shadow)
    #expect(abs(strength(1) - 0.46) < 0.04, "next to the edge: \(strength(1))")
    #expect(abs(strength(10) - 0.1587) < 0.035, "one sigma out: \(strength(10))")
    #expect(abs(strength(20) - 0.0228) < 0.02, "two sigma out: \(strength(20))")
    #expect(strength(45) < 0.01)
    // left of the bar the same, mirrored
    #expect(abs(Double(px.color(100 - 10, 100).r) / 255 - 0.1587) < 0.035)
  }
}

// MARK: - corona (mode 9)

@MainActor
struct StageCoronaRenderTests {
  private let w = 800.0
  private let h = 600.0

  /// A spectrum: `db[i]` for the listed bins, silence elsewhere.
  private func spectrum(_ levels: [Int: Float]) -> [Float] {
    var db = [Float](repeating: -.infinity, count: 128)
    for (i, v) in levels { db[i] = v }
    return db
  }

  private func canvas(_ rays: [CoronaRay]) -> some View {
    ZStack {
      StagePalette.background.color
      Canvas { gc, _ in StageSoloPainter.drawCorona(gc, rays: rays) }
    }
  }

  private func rays(_ db: [Float]) -> [CoronaRay] {
    StageCorona.rays(
      decibels: db, center: StagePoint(x: 400, y: 300), planetRadius: nil, width: 800, height: 600)
  }

  /// innerR 66 (48 + 18), maxLen 192, ring at (400, 300)
  @Test func theHueRampsFromColdToWarmWithTheLevel() throws {
    // quarter turns: bin 0 up, 32 right, 64 down, 96 left
    let r = rays(spectrum([0: -75, 32: -50, 64: -25, 96: 0]))
    let px = try #require(renderPixels(canvas(r), width: 800, height: 600))
    savePNG(canvas(r), width: 800, height: 600, name: "corona-hue-ramp")
    // a point halfway along each bar: its norm sets the length, the hue and the alpha
    let probes: [(x: Int, y: Int, hue: Double, alpha: Double)] = [
      (400, 300 - 66 - 24, 160, 0.4875),  // 0.25 * 192 = 48 long: its middle is 24 out
      (400 + 66 + 48, 300, 120, 0.625),  // 0.5 * 192 = 96
      (400, 300 + 66 + 72, 80, 0.7625),  // 0.75 * 192 = 144
      (400 - 66 - 96, 300, 40, 0.9),  // 192
    ]
    for p in probes {
      let c = px.color(p.x, p.y)
      let seen = try #require(SoloSwatch.hue(c), "(\(p.x), \(p.y)) is grey: \(c)")
      #expect(SoloSwatch.hueGap(seen, p.hue) < 12, "hue \(seen), want \(p.hue) at (\(p.x), \(p.y))")
      // alpha: the bar's stroke over the background, plus a little of its own glow underneath
      let want = ScopeColor.hsla(p.hue, 90, 60, p.alpha)
      let blend = Sw.blend(want.rgb8, p.alpha, over: Sw.background)
      let off: Int = abs(c.r - blend.0) + abs(c.g - blend.1) + abs(c.b - blend.2)
      #expect(off < 60, "\(c) vs \(blend) at hue \(p.hue)")
    }
  }

  @Test func aBarIsLongerAndThickerTheLouderItIs() throws {
    let r = rays(spectrum([32: -80, 96: -20]))
    let px = try #require(renderPixels(canvas(r), width: 800, height: 600))
    // bin 32 at norm 0.2: 38.4 long, from x = 466 to 504; bin 96 at 0.8: 153.6, x = 334 down to 180
    /// How far out from the ring's centre the bar on this side reaches along y = 300.
    func reach(left: Bool) -> Double {
      var far = 0
      for step in 0..<400 {
        let x = left ? 400 - step : 400 + step
        if SoloSwatch.lift(px.color(x, 300)) > 90 { far = step }
      }
      return Double(far)
    }
    let quiet = reach(left: false)
    let loud = reach(left: true)
    #expect(quiet > 66 + 25 && quiet < 66 + 38.4 + 12, "quiet bar reaches \(quiet) out")
    #expect(loud > 66 + 140 && loud < 66 + 153.6 + 12, "loud bar reaches \(loud) out")
    // thickness: 2 + 3.5 * norm
    func thickness(atX x: Int) -> Int {
      (250..<350).filter { SoloSwatch.lift(px.color(x, $0)) > 90 }.count
    }
    let thin = thickness(atX: 400 + 66 + 20)
    let thick = thickness(atX: 400 - 66 - 80)
    #expect(thin >= 2 && thin <= 4, "0.2 -> 2.7 points wide: \(thin)")
    #expect(thick >= 4 && thick <= 7, "0.8 -> 4.8 points wide: \(thick)")
  }

  @Test func theCapsAreRoundAndTheBarsStartOnTheInnerCircle() throws {
    let r = rays(spectrum([32: -50]))
    let px = try #require(renderPixels(canvas(r), width: 800, height: 600))
    // the bar spans x 466...562 at y 300; a round cap of radius 1.875 sticks out 1.9 points past
    // each end, a butt cap would not
    #expect(SoloSwatch.lift(px.color(464, 300)) > 60, "the cap at the inner end")
    #expect(SoloSwatch.lift(px.color(563, 300)) > 60, "and at the outer end")
    #expect(SoloSwatch.lift(px.color(560, 300)) > 150)
    // every silent bin is a dot as wide as the line: bin 0 at the top, radius 1, on the circle
    let top = (399..<401).flatMap { x in (232..<235).map { px.color(x, $0) } }
    #expect(top.contains { SoloSwatch.lift($0) > 40 }, "the dot of silent bin 0: \(top)")
    let brightest = try #require(top.max { SoloSwatch.lift($0) < SoloSwatch.lift($1) })
    let hue = try #require(SoloSwatch.hue(brightest))
    #expect(SoloSwatch.hueGap(hue, 200) < 25, "cold end of the ramp: \(brightest)")
  }

  @Test func theBackgroundIsUntouchedAwayFromTheBars() throws {
    let r = rays(spectrum([32: -50]))
    let px = try #require(renderPixels(canvas(r), width: 800, height: 600))
    for (x, y) in [(5, 5), (795, 595), (400, 300), (400, 100), (200, 450), (600, 150)] {
      #expect(px.near(x, y, Sw.background, tol: 2), "(\(x), \(y)): \(px.color(x, y))")
    }
    // the glow: beside the bar it is lifted, far from it it is not
    #expect(SoloSwatch.lift(px.color(520, 306)) > 4, "glow \(px.color(520, 306))")
    #expect(SoloSwatch.lift(px.color(520, 340)) < 4)
  }

  // MARK: the layer

  /// A real sine through the analyser into the layer: the sector of its bin is lit.
  @Test func aSineRaisesTheSectorOfItsBinInTheLayer() throws {
    let model = StageSoloModel()
    let tone: [Float] = (0..<256).map { Float(sin(2 * Double.pi * 32 * Double($0) / 256)) }
    for _ in 0..<30 { model.corona.analyse(samples: tone, dt: 1.0 / 60) }
    let ctx = SoloSwatch.context(.corona)
    let px = try #require(SoloSwatch.pixels(ctx, model))
    savePNG(SoloSwatch.scene(ctx, model), width: 800, height: 600, name: "corona-sine-bin32")
    // bin 32 points right: amplitude 1 is -13.56 dB, norm 0.864: hue 61.7, 166 long from x = 466
    let c = px.color(400 + 66 + 100, 300)
    let hue = try #require(SoloSwatch.hue(c))
    #expect(SoloSwatch.hueGap(hue, 61.7) < 12, "\(c)")
    // the neighbours at +-1 (-4.5 dB) and +-2 (-20 dB) are the same sector, quieter and cooler
    let rise = Int((166 * tan(2 * Double.pi / 128)).rounded())  // bin 31 is 2.8 degrees up
    let up = px.color(400 + 66 + 100, 300 - rise)
    #expect(SoloSwatch.lift(up) > 100, "bin 31 is lit too: \(up)")
    // the opposite side is just dots
    #expect(px.near(400 - 66 - 60, 300, Sw.background, tol: 3))
    // inside the dark planet's gap nothing is drawn
    #expect(px.near(400 + 40, 300, Sw.background, tol: 3))
  }

  @Test func theLayerDrawsNothingUnlessACoronaShows() throws {
    let model = StageSoloModel()
    let tone: [Float] = (0..<256).map { Float(sin(2 * Double.pi * 32 * Double($0) / 256)) }
    for _ in 0..<30 { model.corona.analyse(samples: tone, dt: 1.0 / 60) }
    let ctx = SoloSwatch.context(.constellation)
    let px = try #require(SoloSwatch.pixels(ctx, model))
    #expect(px.count(inX: 0..<800, y: 0..<600) { SoloSwatch.lift(($0, $1, $2, 255)) > 4 } == 0)
  }

  @Test func theDarkPlanetSetsTheInnerRadiusWhenThereIsARing() throws {
    // two panels: a ring with a dark planet of radius max(18, placeRadius - ...) in the middle
    let layout = StagePanelLayout.layoutRing(width: 800, height: 600, count: 6)
    let planet = try #require(layout.darkPlanetRadius)
    let model = StageSoloModel()
    let tone: [Float] = (0..<256).map { Float(sin(2 * Double.pi * 32 * Double($0) / 256)) }
    for _ in 0..<30 { model.corona.analyse(samples: tone, dt: 1.0 / 60) }
    let ctx = StageContext(
      width: 800, height: 600, layout: layout, selection: .corona, visualizer: .corona)
    guard case .corona(let rays) = model.paint(ctx) else {
      Issue.record("no corona paint")
      return
    }
    let d = hypot(rays[32].x0 - ctx.ringCenter.x, rays[32].y0 - ctx.ringCenter.y)
    #expect(abs(d - (planet + 18)) < 1e-9, "starts \(d) out; planet \(planet)")
    let px = try #require(SoloSwatch.pixels(ctx, model))
    #expect(
      px.near(Int(ctx.ringCenter.x + planet), Int(ctx.ringCenter.y), Sw.background, tol: 3))
    #expect(
      SoloSwatch.lift(px.color(Int(ctx.ringCenter.x + planet + 18 + 40), Int(ctx.ringCenter.y)))
        > 100)
  }

  // MARK: the whole stage on a real engine

  @Test func theStageShowsTheCoronaOfARealNetDeck() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.visualizer = .corona
    try rig.run(seconds: 3)
    let ctx = rig.model.context
    #expect(ctx.visualizer == .corona && ctx.isSolo)
    let db = rig.model.layers.solo.corona.decibels
    #expect(db.contains { $0 > -60 }, "the deck is making sound: peak \(db.max() ?? 0) dB")
    let px = try #require(renderPixels(rig.scene(), width: 1000, height: 800))
    savePNG(rig.scene(), width: 1000, height: 800, name: "corona-real-deck")
    // the constellation is gone (no panel borders), the corona is round the ring's centre
    let c = ctx.ringCenter
    let inner = StageCorona.innerRadius(
      planetRadius: ctx.darkPlanetRadius, width: ctx.width, height: ctx.height)
    var lit = 0
    for i in 0..<128 {
      let a = StageCorona.angle(index: i, count: 128)
      let x = Int((c.x + cos(a) * (inner + 4)).rounded())
      let y = Int((c.y + sin(a) * (inner + 4)).rounded())
      if SoloSwatch.lift(px.color(x, y)) > 20 { lit += 1 }
    }
    #expect(lit > 100, "bars start on the inner circle all the way round: \(lit) of 128")
    #expect(px.near(Int(c.x), Int(c.y), Sw.background, tol: 3), "the middle is empty")
    #expect(px.near(5, 400, Sw.background, tol: 3))
    #expect(rig.dj.masterLeftTap.subscribers == 0, "deck A is the source: not the master's tap")
    #expect(rig.dj["A"]!.leftTap.subscribers == 1)
  }
}

// MARK: - sonar (mode 10)

@MainActor
struct StageSonarRenderTests {
  private func fire(at wall: Double, channel: Int) -> StageFire {
    StageFire(
      time: 0, wallTime: wall, panel: nil, deck: "A", netId: "n", transitionId: "t",
      transition: nil, origin: nil, note: 60, velocity: 100, channel: channel, durSec: 0.1,
      macroRunning: false)
  }

  /// One frame of the solo layer at `now`, after the model saw `fires`.
  private func frame(
    _ model: StageSoloModel, now: Double, fires: [StageFire] = []
  ) throws -> (Pixels, StageContext) {
    let ctx = SoloSwatch.context(.sonar, fires: fires, now: now)
    model.advance(ctx)
    return (try #require(SoloSwatch.pixels(ctx, model)), ctx)
  }

  /// The brightest pixel within `r` points of (x, y).
  private func brightest(_ px: Pixels, _ x: Int, _ y: Int, r: Int = 2) -> (
    r: Int, g: Int, b: Int, a: Int
  ) {
    var best = px.color(x, y)
    for yy in (y - r)...(y + r) {
      for xx in (x - r)...(x + r)
      where SoloSwatch.lift(px.color(xx, yy)) > SoloSwatch.lift(best) {
        best = px.color(xx, yy)
      }
    }
    return best
  }

  /// 800 x 600: ring centre (400, 300), maxR = 550.
  @Test func aRingIsAtItsRadiusInItsChannelsHueCentredOnTheRing() throws {
    let model = StageSoloModel()
    // the fire was read 450 ms before the frame: born at 99.55 s, so t = 0.5
    let (px, ctx) = try frame(model, now: 100, fires: [fire(at: 99.55, channel: 3)])
    savePNG(SoloSwatch.scene(ctx, model), width: 800, height: 600, name: "sonar-one-ring")
    #expect(ctx.ringCenter == StagePoint(x: 400, y: 300))
    // radius 275, width 3, alpha 0.425, hsla(200, 95%, 60%): on the axes, four ways round
    let want = Sw.blend(ScopeColor.hsla(200, 95, 60).rgb8, 0.425, over: Sw.background)
    for (x, y) in [(675, 300), (125, 300), (400, 575), (400, 25)] {
      let c = brightest(px, x, y)
      let off: Int = abs(c.r - want.0) + abs(c.g - want.1) + abs(c.b - want.2)
      #expect(off < 40, "(\(x), \(y)): \(c) vs \(want)")
      let hue = try #require(SoloSwatch.hue(c))
      #expect(SoloSwatch.hueGap(hue, 200) < 10, "channel 3 is hue 200: \(hue)")
    }
    // and nowhere else: inside the ring, just outside it, and the far corner
    for (x, y) in [(400, 300), (500, 300), (660 - 40, 300), (700 + 30, 300), (5, 5), (795, 595)] {
      #expect(SoloSwatch.lift(px.color(x, y)) < 12, "(\(x), \(y)): \(px.color(x, y))")
    }
    // the ring is 3 points wide: its stroke is gone 4 points to each side
    #expect(SoloSwatch.lift(px.color(675 + 5, 300)) < SoloSwatch.lift(px.color(675, 300)) / 2)
  }

  @Test func theRingGrowsAndFadesBetweenTwoFrames() throws {
    let model = StageSoloModel()
    // born at 99.9 s
    let (early, _) = try frame(model, now: 100.0, fires: [fire(at: 99.9, channel: 1)])
    let (late, _) = try frame(model, now: 100.45)
    // t = 0.111 -> radius 61.1, alpha 0.756, width 4.56;  t = 0.611 -> radius 336.1, alpha 0.331
    let a = brightest(early, 400 + 61, 300)
    let b = brightest(late, 400 + 336, 300)
    #expect(SoloSwatch.lift(a) > 60, "early ring on the axis: \(a)")
    #expect(SoloSwatch.lift(b) > 20, "late ring on the axis: \(b)")
    #expect(
      SoloSwatch.lift(a) > SoloSwatch.lift(b) + 30,
      "it faded: \(SoloSwatch.lift(a)) -> \(SoloSwatch.lift(b))")
    #expect(
      SoloSwatch.lift(early.color(400 + 336, 300)) < 8, "the early frame has no ring out there")
    #expect(SoloSwatch.lift(late.color(400 + 61, 300)) < 8, "the late frame has left the centre")
    let hue = try #require(SoloSwatch.hue(a))
    #expect(SoloSwatch.hueGap(hue, 50) < 12, "channel 1 is hue 50")
  }

  @Test func ringsOfDifferentChannelsHaveDifferentHuesAndTheOldestIsBiggest() throws {
    let model = StageSoloModel()
    let (px, ctx) = try frame(
      model, now: 100,
      fires: [fire(at: 99.55, channel: 2), fire(at: 99.8, channel: 5)])
    savePNG(SoloSwatch.scene(ctx, model), width: 800, height: 600, name: "sonar-two-rings")
    // 450 ms old: radius 275, hue 220;  200 ms old: radius 122.2, hue 320
    let big = brightest(px, 400 + 275, 300)
    let small = brightest(px, 400 + 122, 300)
    let bigHue = try #require(SoloSwatch.hue(big))
    let smallHue = try #require(SoloSwatch.hue(small))
    #expect(SoloSwatch.hueGap(bigHue, 220) < 12 && SoloSwatch.hueGap(smallHue, 320) < 12)
    #expect(SoloSwatch.lift(small) > SoloSwatch.lift(big), "the younger ring is stronger")
  }

  @Test func withoutFiresTheStageIsEmpty() throws {
    let model = StageSoloModel()
    let (px, _) = try frame(model, now: 100)
    #expect(px.count(inX: 0..<800, y: 0..<600) { SoloSwatch.lift(($0, $1, $2, 255)) > 4 } == 0)
  }

  @Test func theStageOnARealDeckDrawsRingsOfItsFires() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.visualizer = .sonar
    try rig.run(seconds: 2)
    let solo = rig.model.layers.solo
    #expect(solo.sonar.rings.count >= 2, "\(solo.sonar.rings.count) rings alive")
    let px = try #require(renderPixels(rig.scene(), width: 1000, height: 800))
    savePNG(rig.scene(), width: 1000, height: 800, name: "sonar-real-deck")
    let ctx = rig.model.context
    let c = ctx.ringCenter
    // every ring is on screen at its radius, on the ring's centre
    var seen = 0
    for ring in solo.sonar.rings {
      let arc = StageSonar.arc(
        ring, nowMs: ctx.nowMs, center: c, width: ctx.width, height: ctx.height)
      guard arc.stroke.a > 0.15, arc.radius > 5 else { continue }
      let x = Int((c.x + arc.radius).rounded())
      if x < 1000 - 3, SoloSwatch.lift(brightest(px, x, Int(c.y))) > 20 { seen += 1 }
    }
    #expect(seen >= 1, "a ring is drawn where the model says (\(seen))")
    #expect(ctx.isSolo && ctx.visualizer == .sonar && ctx.panels.count > 1)
  }
}
