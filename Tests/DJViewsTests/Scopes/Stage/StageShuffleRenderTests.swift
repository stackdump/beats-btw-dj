import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

// Shuffle (SPEC mode 12) on the whole stage, rendered: `StageSoloRenderTests` has the swap between
// the corona and the constellation; here it lands on the SONAR and on the PETAL (the two that need
// the engine's fires to show anything), and the arrow keys walk the five pictures both ways,
// ending the shuffle. The shuffle's random source is replaced: stage.js
// `pickShuffleNext` takes `choices[floor(random * n)]` over the real visualizers without the one
// showing, in the order constellation, corona, sonar, petal (then dj's blocks). Shuffle starts
// from the constellation, so 0.0 picks the corona, 0.4 the sonar, 0.6 the petal, 0.8 the blocks.
@MainActor
struct StageShuffleLandingRenderTests {
  private func shuffling(random value: Double) throws -> StageViewRig {
    let rig = try StageViewRig()
    rig.model.layers.solo.random = { value }
    rig.model.settings.visualizer = .shuffle
    rig.model.settings.menuCollapsed = false
    return rig
  }

  private func picture(_ rig: StageViewRig, name: String) throws -> Pixels {
    savePNG(rig.scene(), width: 1000, height: 800, name: name)
    return try #require(renderPixels(rig.scene(), width: 1000, height: 800))
  }

  /// Sonar rings that are on screen where the model says, on the ring centre.
  private func ringsSeen(_ rig: StageViewRig, _ px: Pixels) -> Int {
    let ctx = rig.model.context
    var seen = 0
    for ring in rig.model.layers.solo.sonar.rings {
      let arc = StageSonar.arc(
        ring, nowMs: ctx.nowMs, center: ctx.ringCenter, width: ctx.width, height: ctx.height)
      guard arc.stroke.a > 0.15, arc.radius > 5 else { continue }
      let x = Int((ctx.ringCenter.x + arc.radius).rounded())
      let y = Int(ctx.ringCenter.y.rounded())
      guard x < Int(ctx.width) - 4 else { continue }
      var best = 0
      for yy in (y - 2)...(y + 2) {
        for xx in (x - 2)...(x + 2) { best = max(best, SoloSwatch.lift(px.color(xx, yy))) }
      }
      if best > 20 { seen += 1 }
    }
    return seen
  }

  /// Petals with colour half way up their axis.
  private func petalsLit(_ rig: StageViewRig, _ px: Pixels) -> (lit: Int, of: Int) {
    let ctx = rig.model.context
    guard case .petal(let shapes) = rig.model.layers.solo.paint(ctx) else { return (0, 0) }
    var lit = 0
    for p in shapes {
      let x = Int((p.center.x + cos(p.angle) * p.length * 0.6).rounded())
      let y = Int((p.center.y + sin(p.angle) * p.length * 0.6).rounded())
      if SoloSwatch.lift(px.color(x, y)) > 6 { lit += 1 }
    }
    return (lit, shapes.count)
  }

  /// Corona bars standing on the inner circle, of 128.
  private func coronaBars(_ rig: StageViewRig, _ px: Pixels) -> Int {
    let ctx = rig.model.context
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
    return lit
  }

  /// Lit pixels round the kick panel's centre (the constellation draws the panels).
  private func kickPanelLit(_ rig: StageViewRig, _ px: Pixels) -> Int {
    guard let p = rig.model.context.panels.first(where: { $0.netId == "kick-0" }) else { return 0 }
    let c = Sw.ipt(p.center)
    return px.count(inX: (c.0 - 55)..<(c.0 + 55), y: (c.1 - 55)..<(c.1 + 55)) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
    }
  }

  /// What is on screen, as the visualizers it can be told apart by.
  private func shows(_ rig: StageViewRig, _ px: Pixels, _ v: StageVisualizer) -> Bool {
    switch v {
    case .constellation: kickPanelLit(rig, px) > 300 && ringsSeen(rig, px) == 0
    case .corona: coronaBars(rig, px) > 100 && kickPanelLit(rig, px) < 50
    case .sonar: ringsSeen(rig, px) >= 1 && kickPanelLit(rig, px) < 50
    case .petal:
      // (the petals lie over the panels' places: the kick panel's patch is no tell here)
      petalsLit(rig, px) == (6, 6) && ringsSeen(rig, px) == 0
    case .minecraft:
      // the blocky world's sky fills the top of the window, where the stage is otherwise dark
      SoloSwatch.lift(px.color(500, 20)) > 60 && rig.model.layers.minecraft.scene.voxels.count > 100
    case .shuffle: false
    }
  }

  @Test func shuffleLandsOnTheSonarAndDrawsItsRingsWhileTheSelectSaysShuffle() throws {
    let rig = try shuffling(random: 0.4)
    defer { rig.stop() }
    try rig.run(seconds: 0.6)
    let ctx = rig.model.context
    #expect(ctx.selection == .shuffle && ctx.visualizer == .sonar, "\(ctx.visualizer)")
    #expect(rig.model.settings.visualizer == .shuffle, "the select is untouched by the swap")
    #expect(ctx.isSolo && ctx.panels.count > 1)
    let px = try picture(rig, name: "shuffle-sonar")
    #expect(rig.model.layers.solo.sonar.rings.count >= 1)
    #expect(shows(rig, px, .sonar), "rings \(ringsSeen(rig, px)), panel \(kickPanelLit(rig, px))")
    #expect(px.near(5, 400, Sw.background, tol: 3), "the panel grid and its controls are not here")
  }

  @Test func shuffleLandsOnThePetalAndDrawsAFlowerOfTheNets() throws {
    let rig = try shuffling(random: 0.6)
    defer { rig.stop() }
    try rig.run(seconds: 0.6)
    let ctx = rig.model.context
    #expect(ctx.selection == .shuffle && ctx.visualizer == .petal, "\(ctx.visualizer)")
    #expect(rig.model.settings.visualizer == .shuffle)
    #expect(ctx.isSolo && ctx.panels.count == 6)
    let px = try picture(rig, name: "shuffle-petal")
    let petals = petalsLit(rig, px)
    #expect(petals.of == 6 && petals.lit == 6, "every petal is drawn: \(petals)")
    #expect(shows(rig, px, .petal))
  }

  @Test func theArrowKeysWalkTheFivePicturesBothWaysAndEndTheShuffle() throws {
    // lands on the sonar; Right is the petal and the blocks, Left goes back through the petal
    // and the sonar to the corona, the constellation and round to the blocks (wrapping), and
    // Right wraps from the blocks to the constellation. (The sonar is checked early: its rings
    // need the song's fires, and the order keeps it where the original four-step walk had it.)
    let rig = try shuffling(random: 0.4)
    defer { rig.stop() }
    try rig.run(seconds: 0.6)
    var px = try picture(rig, name: "shuffle-arrows-0-sonar")
    #expect(rig.model.context.visualizer == .sonar && shows(rig, px, .sonar))
    let walk: [(StageKey, StageVisualizer)] = [
      (.right, .petal), (.right, .minecraft), (.left, .petal), (.left, .sonar),
      (.left, .corona), (.left, .constellation), (.left, .minecraft), (.right, .constellation),
    ]
    for (i, (key, want)) in walk.enumerated() {
      #expect(rig.model.handleKey(key))
      #expect(rig.model.settings.visualizer == want, "step \(i + 1): the select follows the key")
      try rig.run(seconds: 0.5)
      let ctx = rig.model.context
      #expect(ctx.selection == want && ctx.visualizer == want, "step \(i + 1): \(ctx.visualizer)")
      px = try picture(rig, name: "shuffle-arrows-\(i + 1)-\(want)")
      #expect(shows(rig, px, want), "step \(i + 1): \(want) is what is on screen")
    }
    // the shuffle ended with the first key: many more fires than its 64 swap nothing
    try rig.run(seconds: 4)
    #expect(rig.model.context.visualizer == .constellation)
    #expect(rig.model.settings.visualizer == .constellation)
  }
}
