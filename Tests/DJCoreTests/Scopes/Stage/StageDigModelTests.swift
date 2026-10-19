import Testing

@testable import DJCore

// The "Dig" visualizer's model against the control timeline of a real composed song (techno 42,
// standard structure: intro 0, buildup 64, drop 256, verse 448, drop 640, outro 832).

@MainActor
@Suite struct StageDigModelTests {
  static let timeline = TimelineFixture.timeline()
  /// A step at 300 BPM.
  static let tickSec = 0.05

  private func context(now: Double = 100, level: Int = 0) -> StageContext {
    StageContext(
      width: 1000, height: 600,
      layout: StagePanelLayout.layoutRing(width: 1000, height: 600, count: 0),
      now: now, dt: 1.0 / 60, selection: .dig, visualizer: .dig, vizLevel: level)
  }

  private func at(_ step: Double, _ m: StageDigModel = StageDigModel(), now: Double = 100)
    -> StageDigScene
  {
    m.advance(context(now: now), timeline: Self.timeline, step: step, tickSec: Self.tickSec)
    return m.scene
  }

  @Test func aBlockBreaksEveryTwoBarsHeadThenFeetThenAStride() {
    #expect(StageDigModel.stepsPerBlock == 32, "two bars of sixteenths")
    for (step, mined, col, head) in [
      (0.0, 0, 0, true), (31.9, 0, 0, true), (32.0, 1, 0, false), (63.9, 1, 0, false),
      (64.0, 2, 1, true), (96.0, 3, 1, false), (300.0, 9, 4, false),
    ] {
      let s = at(step)
      #expect(s.mined == mined && s.faceColumn == col && s.headNext == head, "step \(step)")
    }
    // the crack runs through every stage over the block's two bars
    #expect(at(0).crack == 0 && at(16).crack == 5 && at(31.9).crack == 9 && at(32).crack == 0)
  }

  @Test func thePickaxeStrikesOnTheBeat() {
    // just after the beat it is at the face (a small knock back), late in the beat it is raised
    #expect(at(36.0).swing < 0.05)
    #expect(at(39.4).swing > 1)
    #expect(at(36.6).swing < at(38.0).swing && at(38.0).swing < at(39.4).swing, "rising")
  }

  @Test func whatABlockHoldsIsWhatTheMusicDoesWhenItBreaks() throws {
    let m = StageDigModel()
    m.setTimeline(Self.timeline)
    // the drops at 256 and 640 are blocks 7 and 19; the other section starts are gold
    #expect(m.ores[7] == .diamond && m.ores[19] == .diamond)
    #expect(m.ores[1] == .gold && m.ores[13] == .gold && m.ores[25] == .gold)
    // a fill makes redstone, and nothing else is diamond or gold
    let fill = try #require(Self.timeline.count(.fill) > 0 ? Self.timeline.event(.fill, 0) : nil)
    #expect(m.ores[(fill.end - 1) / StageDigModel.stepsPerBlock] != .stone)
    #expect(m.ores.contains(.redstone))
    for (k, o) in m.ores.enumerated() where ![1, 7, 13, 19, 25].contains(k) {
      #expect(o != .diamond && o != .gold, "block \(k): \(o)")
    }
    // the face shows the diamond while it is being dug, before the drop
    #expect(at(230).faceOre == .diamond)
  }

  @Test func theDiamondFlashesAsItBreaksAndTheHotbarCountsIt() {
    #expect(at(250).flash == 0)
    #expect(at(258).flash > 0.2, "the drop's diamond")
    #expect(at(300).flash == 0)
    // a model that played through the break lets go of the flash too (the buffers are reused)
    let m = StageDigModel()
    for step in stride(from: 250.0, through: 300, by: 0.5) { _ = at(step, m) }
    #expect(m.scene.flash == 0)
    let slot = { (o: StageOre) in StageOre.kept.firstIndex(of: o)! }
    let before = at(250)
    #expect(before.inventory[slot(.diamond)] == 0 && before.inventory[slot(.gold)] == 1)
    let after = at(300)
    #expect(after.inventory[slot(.diamond)] == 1 && after.inventory[slot(.gold)] == 1)
    #expect(after.slots.count == StageOre.kept.count)
  }

  @Test func theWallsAreTheSongsSections() {
    let m = StageDigModel()
    m.setTimeline(Self.timeline)
    // a column is two blocks, 64 steps: column 0 intro, 1 to 3 buildup, 4 drop, 7 verse
    #expect(m.rock(column: 0) == .stone)
    #expect(m.rock(column: 1) == .granite && m.rock(column: 3) == .granite)
    #expect(m.rock(column: 4) == .deepslate)
    #expect(m.rock(column: 7) == .stone)
  }

  @Test func thePickaxeIsHeldUpThroughARest() throws {
    let gap = try #require(Self.timeline.next(.dropGap, after: 0))
    let s = at(Double(gap.tick) + 0.5)
    #expect(s.holding && s.swing > 1)
    // and through the kick out, the buildup's last bar; swinging again before it
    let out = try #require(Self.timeline.next(.kickOut, after: 0))
    #expect(at(Double(out.tick) + 1).holding)
    #expect(!at(Double(out.tick) - 12).holding)
  }

  @Test func theTunnelIsAPureFunctionOfTheStep() {
    // played there frame by frame, or jumped to: the same picture
    let played = StageDigModel()
    var s = 0.0
    while s < 300 {
      _ = at(s, played)
      s += 0.75
    }
    #expect(at(300, played) == at(300))
    // and it digs on the clock alone with no song
    let loop = StageDigModel()
    loop.advance(context(), timeline: .empty, step: 70, tickSec: 0.1)
    #expect(loop.scene.mined == 2 && loop.scene.voxels.count > 100)
  }

  @Test func onlyTheDigAdvancesTheDig() {
    let m = StageDigModel()
    let ctx = StageContext(
      width: 1000, height: 600,
      layout: StagePanelLayout.layoutRing(width: 1000, height: 600, count: 0),
      now: 1, dt: 1.0 / 60, selection: .minecraft, visualizer: .minecraft)
    m.advance(ctx)
    #expect(m.scene.width == 0)
  }
}
