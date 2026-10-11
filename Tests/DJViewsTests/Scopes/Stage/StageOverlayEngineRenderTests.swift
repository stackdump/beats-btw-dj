import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// The overlay layers fed by a real offline engine (StageViewRig: deck A plays a composed song at
// 300 BPM, the stage model reads the feed): the fires the engine reports become pulse particles,
// flame beams and bolts, and the full stage draws them. Each layer's contribution is isolated by
// DIFFERENCE: the same frame rendered with that layer's model emptied (`reset()`), so what
// differs is that layer's paint and nothing else.

@MainActor
struct StageOverlayEngineRenderTests {
  func render(_ rig: StageViewRig) throws -> Pixels {
    try #require(
      renderPixels(
        StageScene(model: rig.model, context: rig.model.context), width: Int(rig.width),
        height: Int(rig.height)))
  }

  /// Run `seconds` in 50 ms frames and hand back every frame's context.
  func frames(_ rig: StageViewRig, seconds: Double) throws -> [StageContext] {
    var out: [StageContext] = []
    var left = seconds
    while left > 1e-9 {
      let s = min(0.05, left)
      try rig.run(seconds: s)
      out.append(rig.model.context)
      left -= s
    }
    return out
  }

  @Test func engineFiresBecomeRedDotsFlyingToTheCentre() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.overlays = [.pulse]
    let ctxs = try frames(rig, seconds: 2.0)
    let last = try #require(ctxs.last)
    // one particle per audible fire of the last 700 ms that has a ring position
    var expected = 0
    for c in ctxs {
      for f in c.fires {
        guard let p = f.panel, c.panels[p].ring != nil, f.wallTime * 1000 + 700 > last.nowMs
        else { continue }
        expected += 1
      }
    }
    let pulse = rig.model.layers.pulse
    #expect(expected > 4, "the song fires several times in 700 ms (\(expected))")
    #expect(pulse.particles.count == expected, "one particle per fire (\(pulse.particles.count))")
    let centre = last.ringCenter
    #expect(pulse.particles.allSatisfy { $0.cx == centre.x && $0.cy == centre.y })
    let want = pulse.dots(nowMs: last.nowMs)
    #expect(want.count == expected)

    // The stage with and without them differs by the dots, and they are red. (Some edge pixels of
    // the panels move by up to twenty levels when the pulse canvas has something on it, a SwiftUI
    // compositing detail: the threshold is above that, and below what any dot with an alpha of
    // 0.15 or more changes.) The freshest dots start under their transition's node, which is
    // drawn over them, so only dots in the open are probed for their exact colour.
    let with = try render(rig)
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-pulse-engine")
    pulse.reset()
    let without = try render(rig)
    let changed = OverlaySwatch.changed(without, with, tol: 32)
    #expect(changed.count > 150, "dots are drawn (\(changed.count) changed pixels)")
    #expect(changed.allSatisfy { $0.color.r > without.color($0.x, $0.y).r + 20 }, "all redder")
    let strays = changed.filter { px in
      !want.contains {
        hypot(Double(px.x) + 0.5 - $0.x, Double(px.y) + 0.5 - $0.y) <= $0.radius + 1
      }
    }
    #expect(strays.isEmpty, "no changed pixel outside the dots (\(strays.count))")
    var probed = 0
    for d in want where d.alpha > 0.3 && d.radius >= 4 {
      let c = Sw.ipt(StagePoint(x: d.x, y: d.y))
      guard without.near(c.0, c.1, Sw.background, tol: 6) else { continue }
      let blend = OverlaySwatch.over(Sw.red, d.alpha, Sw.background)
      #expect(
        with.near(c.0, c.1, blend, tol: 10), "dot at \(c): \(with.color(c.0, c.1)) vs \(blend)")
      probed += 1
    }
    #expect(probed >= 3, "several dots are in the open (\(probed))")
  }

  @Test func engineFiresBecomeBeamsAmberAtTheBaseFromTheRingCentre() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    rig.model.settings.overlays = [.flame]
    let ctxs = try frames(rig, seconds: 1.5)
    let last = try #require(ctxs.last)
    let flame = rig.model.layers.flame
    let beams = flame.beams(in: last)
    #expect(beams.count >= 2, "several panels are lit (\(beams.count))")
    #expect(Set(beams.map(\.panelId)).isSubset(of: Set(last.panels.map(\.id))))
    let with = try render(rig)
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-flame-engine")
    flame.reset()
    let without = try render(rig)
    let changed = OverlaySwatch.changed(without, with, tol: 32)
    #expect(changed.count > 300, "beams are drawn (\(changed.count) changed pixels)")
    // every changed pixel is inside a beam: close to its axis, between its base and its tip
    let c = last.ringCenter
    let inner = StageFlame.innerRadius(centre: c)
    let strays = changed.filter { px in
      let x = Double(px.x) + 0.5 - c.x
      let y = Double(px.y) + 0.5 - c.y
      return !beams.contains { b in
        let along = x * cos(b.theta) + y * sin(b.theta)
        let across = abs(-x * sin(b.theta) + y * cos(b.theta))
        return along >= inner - 2 && along <= b.barLength + 2 && across <= 8
      }
    }
    #expect(strays.isEmpty, "no changed pixel outside the beams (\(strays.count))")
    // the brightest beam is amber just outside its base, where nothing else is drawn
    let top = try #require(beams.max { $0.energy < $1.energy })
    let d = inner + 6
    let x = Int((c.x + d * cos(top.theta)).rounded())
    let y = Int((c.y + d * sin(top.theta)).rounded())
    let px = with.color(x, y)
    let before = without.color(x, y)
    #expect(
      px.r > before.r + 40 && px.r > px.b + 40 && px.g > before.g + 15, "amber at the base: \(px)")
    // and its tip end is nearly gone: dimmer than the base, the hue drifting toward blue
    let tipD = top.barLength - 6
    let tx = Int((c.x + tipD * cos(top.theta)).rounded())
    let ty = Int((c.y + tipD * sin(top.theta)).rounded())
    #expect(with.color(tx, ty).r < px.r, "the tip is dimmer")
  }

  @Test func aMacroOnARealDeckThrowsBoltsThatSparkTheDarkPlanetAndLightTheHalo() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    let bolts = rig.model.layers.bolts
    try rig.run(seconds: 0.5)
    #expect(bolts.bolts.isEmpty && bolts.seeds.isEmpty, "quiet before the macro")
    #expect(!rig.model.context.macroRunning)
    rig.dj["A"]!.fire(.beatRepeat, duration: 1)  // one bar, 0.8 s
    var frames = 0
    while (bolts.bolts.count < 3 || bolts.seeds.isEmpty) && frames < 40 {
      try rig.run(seconds: 0.05)
      frames += 1
    }
    let ctx = rig.model.context
    #expect(ctx.macroRunning, "the engine says a macro is in effect")
    #expect(
      bolts.bolts.count >= 3 && !bolts.seeds.isEmpty, "bolts and sparks (\(bolts.bolts.count))")
    let strokes = bolts.strokes(in: ctx)
    let glow = StageBolts.glow(energy: bolts.energy)
    let with = try render(rig)
    savePNG(rig.scene(), width: 1000, height: 800, name: "stage-bolts-engine")
    let seedDots = bolts.seedDots(in: ctx)
    bolts.reset()
    let without = try render(rig)
    // The bolts' paint is the difference: plenty of it, and bright blue-white.
    let changed = OverlaySwatch.changed(without, with, tol: 32)
    #expect(changed.count > 200, "bolts are drawn (\(changed.count) changed pixels)")
    let brightBlue = changed.filter { $0.color.b > 180 && $0.color.b > $0.color.r + 10 }.count
    #expect(brightBlue >= 40, "bright blue-white pixels (\(brightBlue))")
    // every bolt's polyline is on the bright line at most of its vertices (panels draw over some)
    for stroke in strokes where stroke.alpha > 0.5 {
      let lit = stroke.points.dropFirst().dropLast().filter { p in
        let x = Int(p.x.rounded())
        let y = Int(p.y.rounded())
        return Sw.anyNear(with, x, y, r: 1, (200, 225, 255), tol: 70)
          && with.color(x, y).b > without.color(x, y).b + 30
      }.count
      #expect(lit >= 6, "a bolt at alpha \(stroke.alpha) is on its line (\(lit) of 11 vertices)")
    }
    // the halo condenses over the planet, in the strength the bolts' energy sets
    let c = Sw.ipt(ctx.ringCenter)
    let base = without.color(c.0, c.1)
    let want = OverlaySwatch.over((150, 190, 255), 0.22 * glow, (base.r, base.g, base.b))
    #expect(glow > 0.5)
    #expect(
      with.near(c.0, c.1, want, tol: 10), "halo at the centre: \(with.color(c.0, c.1)) vs \(want)")
    // and a spark is warm white where a fresh one sits on the planet's surface
    var warm = 0
    for d in seedDots where d.alpha > 0.5 {
      let p = Sw.ipt(StagePoint(x: d.x, y: d.y))
      let px = with.color(p.0, p.1)
      if px.r > 170 && px.r >= px.b { warm += 1 }
    }
    #expect(warm >= 1, "a warm spark (\(warm) of \(seedDots.count))")
  }

  @Test func whenTheMacroEndsTheBoltsTheSparksAndTheHaloAreGone() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    // Only what bolts need (they are thrown inside the flame branch): the pulse dots of the song's
    // own hits converge on the very pixel probed below.
    rig.model.settings.overlays = [.flame, .bolts]
    let bolts = rig.model.layers.bolts
    try rig.run(seconds: 0.4)
    rig.dj["A"]!.fire(.beatRepeat, duration: 1)
    try rig.run(seconds: 0.6)
    #expect(!bolts.bolts.isEmpty)
    try rig.run(seconds: 2.5)  // the macro ends at 0.8 s; bolts live 480 ms, sparks 1100 ms
    #expect(!rig.model.context.macroRunning)
    #expect(bolts.bolts.isEmpty && bolts.seeds.isEmpty && bolts.energy == 0)
    let px = try render(rig)
    let c = Sw.ipt(rig.model.context.ringCenter)
    #expect(px.near(c.0, c.1, Sw.background, tol: 5), "no halo: \(px.color(c.0, c.1))")
    // without a macro running at all no bolts were thrown in the quiet stretch either
    let other = try StageViewRig()
    defer { other.stop() }
    try other.run(seconds: 2)
    #expect(other.model.layers.bolts.bolts.isEmpty)
  }
}
