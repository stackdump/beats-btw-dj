import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The "Blocks" visualizer, rendered: the layer on a synthetic context driven through a real
// composed song's control timeline (techno 42, standard: intro 0, buildup 64, drop 256, verse
// 448, drop 640, outro 832), and once on the whole stage over a running engine. Set DJ_SHOT_DIR to
// also write the frames as PNGs.

@MainActor
@Suite struct StageMinecraftRenderTests {
  static let w = 1000
  static let h = 600

  static func timeline(structure: String = "standard", seed: Double = 42) -> StageControlTimeline {
    let spec = TrackSpec(genre: "techno", seed: seed, structure: structure)
    return StageControlTimeline.build(DJMusicality.apply(spec.project(), spec: spec))
  }

  static func context(now: Double, fires: [StageFire] = []) -> StageContext {
    StageContext(
      width: Double(w), height: Double(h),
      layout: StagePanelLayout.layoutRing(width: Double(w), height: Double(h), count: 0),
      now: now, dt: 1.0 / 30, fires: fires, selection: .minecraft, visualizer: .minecraft)
  }

  /// The model after playing up to `step` (from `step - lead`, two steps a frame), so creatures
  /// have spawned as they would have live.
  static func model(
    at step: Double, timeline t: StageControlTimeline, lead: Double = 40, macro: Bool = false,
    fires: [StageFire] = []
  ) -> (StageMinecraftModel, StageContext) {
    let m = StageMinecraftModel()
    var s = max(0, step - lead)
    var now = 100.0
    while s < step {
      m.advance(context(now: now), timeline: t, step: s, tickSec: 0.05, macroActive: macro)
      s += 2
      now += 1.0 / 30
    }
    let ctx = context(now: now, fires: fires)
    m.advance(ctx, timeline: t, step: step, tickSec: 0.05, macroActive: macro)
    return (m, ctx)
  }

  static func scene(_ ctx: StageContext, _ m: StageMinecraftModel) -> some View {
    ZStack {
      StagePalette.background.color
      StageMinecraftLayer(context: ctx, model: m)
    }
  }

  static func frame(
    _ step: Double, timeline t: StageControlTimeline = timeline(), name: String? = nil,
    macro: Bool = false, fires: [StageFire] = []
  ) throws -> (Pixels, StageMinecraftModel) {
    let (m, ctx) = model(at: step, timeline: t, macro: macro, fires: fires)
    if let name { savePNG(scene(ctx, m), width: w, height: h, name: "blocks-\(name)") }
    return (try #require(renderPixels(scene(ctx, m), width: w, height: h)), m)
  }

  /// Mean colour of the sky's top band (a few rows under the top edge, across the window).
  static func sky(_ px: Pixels) -> (r: Int, g: Int, b: Int) {
    var r = 0
    var g = 0
    var b = 0
    var n = 0
    for x in stride(from: 10, to: w - 10, by: 23) {
      let c = px.color(x, 6)
      r += c.r
      g += c.g
      b += c.b
      n += 1
    }
    return (r / n, g / n, b / n)
  }

  static func meanLuma(_ px: Pixels) -> Double {
    var sum = 0.0
    var n = 0
    for y in stride(from: 0, to: px.height, by: 7) {
      for x in stride(from: 0, to: px.width, by: 7) {
        let c = px.color(x, y)
        sum += 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)
        n += 1
      }
    }
    return sum / Double(n)
  }

  /// Distinct colours (quantised to 4 bits a channel) in a grid sample: a real picture has many.
  static func variety(_ px: Pixels) -> Int {
    var seen = Set<Int>()
    for y in stride(from: 0, to: px.height, by: 5) {
      for x in stride(from: 0, to: px.width, by: 5) {
        let c = px.color(x, y)
        seen.insert((c.r >> 4) << 8 | (c.g >> 4) << 4 | (c.b >> 4))
      }
    }
    return seen.count
  }

  @Test func everySectionDrawsAWorld() throws {
    let t = Self.timeline()
    for (step, name) in [
      (20.0, "intro-plains"), (120, "buildup-dusk"), (300, "drop-night"), (520, "verse-forest"),
      (860, "outro-sunset"),
    ] {
      let (px, m) = try Self.frame(step, timeline: t, name: name)
      #expect(Self.variety(px) > 25, "\(name): a picture, not a wash (\(Self.variety(px)))")
      #expect(m.scene.voxels.count > 200)
      // the ground is blocks: the bottom rows are not the sky's colour
      let ground = px.color(500, Self.h - 10)
      let s = Self.sky(px)
      let dr: Int = abs(ground.r - s.r)
      let dg: Int = abs(ground.g - s.g)
      let db: Int = abs(ground.b - s.b)
      let apart: Int = dr + dg + db
      #expect(apart > 40, "\(name)")
    }
  }

  @Test func theSkyChangesWithTheSection() throws {
    let t = Self.timeline()
    let (intro, _) = try Self.frame(20, timeline: t)
    let (verse, _) = try Self.frame(520, timeline: t)
    let (drop, _) = try Self.frame(300, timeline: t)
    let (dusk, _) = try Self.frame(120, timeline: t)
    let i = Self.sky(intro)
    let v = Self.sky(verse)
    let d = Self.sky(drop)
    let k = Self.sky(dusk)
    #expect(v.b > 200 && v.b > v.r + 80, "day: a blue sky \(v)")
    #expect(d.r + d.g + d.b < 120, "drop: night \(d)")
    #expect(i.r + i.g + i.b > 300 && i != v, "dawn: light, not the day's blue \(i)")
    #expect(k.r + k.g + k.b < i.r + i.g + i.b && k.b > k.g, "dusk: a deep violet top \(k)")
  }

  @Test func theFuseFramesAndTheExplosionAreASequence() throws {
    let t = Self.timeline()
    let (lit, mLit) = try Self.frame(100, timeline: t, name: "tnt-fuse-early")
    let (late, mLate) = try Self.frame(244, timeline: t, name: "tnt-fuse-late")
    let (gap, _) = try Self.frame(252, timeline: t, name: "tnt-drop-gap-flash")
    let (before, _) = try Self.frame(255.5, timeline: t)
    let (boom, mBoom) = try Self.frame(256, timeline: t, name: "drop-explosion")
    let (debris, mDebris) = try Self.frame(262, timeline: t, name: "drop-debris")
    _ = (lit, late, gap, debris)
    #expect((mLit.scene.fuse ?? 1) < (mLate.scene.fuse ?? 0))
    #expect(mBoom.scene.explosionAge == 0 && mDebris.scene.explosionAge != nil)
    let lb = Self.meanLuma(before)
    let lx = Self.meanLuma(boom)
    #expect(lx > 200, "the explosion frame is (nearly) white: \(lx)")
    #expect(lx > lb + 120, "and far brighter than the frame before: \(lb) -> \(lx)")
    #expect(Self.meanLuma(debris) < lx - 100, "the flash is over by the debris frame")
    // the TNT is on screen while lit: its red is in the picture
    #expect(Self.redPixels(lit) > 30 && Self.redPixels(late) > 30)
  }

  static func redPixels(_ px: Pixels) -> Int {
    px.count(inX: 0..<w, y: 0..<h) { r, g, b in r > 140 && g < 70 && b < 70 }
  }

  @Test func weatherAndFireworks() throws {
    let t = Self.timeline()
    _ = try Self.frame(560, timeline: t, name: "verse-rain-macro", macro: true)
    let sting = StageFire(
      time: 0, wallTime: 100.5, panel: nil, deck: "A", netId: "hit1", transitionId: "t",
      transition: nil, origin: nil, note: 72, velocity: 110, channel: 1, durSec: 0.2,
      macroRunning: false, isStinger: true)
    let (_, plain) = try Self.frame(540, timeline: t)
    let (fw, m) = try Self.frame(540, timeline: t, name: "verse-firework", fires: [sting])
    let glows = { (m: StageMinecraftModel) in m.scene.voxels.filter { $0.style == .glow }.count }
    #expect(glows(m) >= glows(plain) + 16, "a burst of sparks")
    let (bare, _) = try Self.frame(540, timeline: t)
    #expect(Self.variety(fw) > Self.variety(bare), "the burst adds colours")
  }

  @Test func theCaveOfABreakdown() throws {
    // a structure with a breakdown, if the blueprints have one
    for structure in ["extended", "build", "jam", "ab"] {
      let t = Self.timeline(structure: structure)
      guard let k = t.sections.firstIndex(where: { $0.name == "breakdown" || $0.name == "bridge" })
      else { continue }
      let s = t.sections[k]
      let (px, m) = try Self.frame(
        Double(s.startTick + s.steps / 2), timeline: t, name: "breakdown-cave-\(structure)")
      #expect(m.scene.biome == .cave && m.scene.celestial == nil)
      let top = Self.sky(px)
      #expect(top.r + top.g + top.b < 300, "a stone ceiling, not a sky: \(top)")
      return
    }
    Issue.record("no blueprint with a breakdown")
  }

  @Test func theWholeStageShowsBlocksOverARunningEngine() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.visualizer = .minecraft
    try rig.run(seconds: 1.0)
    let ctx = rig.model.context
    #expect(ctx.visualizer == .minecraft && ctx.isSolo)
    let m = rig.model.layers.minecraft
    #expect(m.timeline.count(.section) > 0, "the timeline came from the feed's project")
    #expect(m.scene.voxels.count > 200)
    savePNG(rig.scene(), width: 1000, height: 800, name: "blocks-stage")
    let px = try #require(renderPixels(rig.scene(), width: 1000, height: 800))
    #expect(Self.variety(px) > 25)
    #expect(SoloSwatch.lift(px.color(900, 220)) > 60, "the sky, not the stage's dark")
  }
}
