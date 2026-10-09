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
}
