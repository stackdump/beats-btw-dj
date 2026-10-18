import Testing

@testable import DJCore

// The "Blocks" visualizer's model against the control timeline of a real composed song (techno
// 42, standard structure: intro 0, buildup 64, drop 256, verse 448, drop 640, outro 832).

@MainActor
@Suite struct StageMinecraftModelTests {
  static let timeline = TimelineFixture.timeline()
  /// A step at 300 BPM.
  static let tickSec = 0.05

  private func context(
    now: Double, dt: Double = 1.0 / 60, fires: [StageFire] = [], panels: [StagePanel] = [],
    level: Int = 0
  ) -> StageContext {
    StageContext(
      width: 1000, height: 600,
      layout: StagePanelLayout.layoutRing(width: 1000, height: 600, count: panels.count),
      panels: panels, now: now, dt: dt, fires: fires, selection: .minecraft,
      visualizer: .minecraft, vizLevel: level)
  }

  /// A model that has played from `from` to `to` in steps of `by`, a frame each (60 fps of wall
  /// clock whatever the step size).
  private func played(
    _ m: StageMinecraftModel = StageMinecraftModel(), from: Double, to: Double, by: Double = 0.5,
    macro: Bool = false, panels: [StagePanel] = []
  ) -> StageMinecraftModel {
    var s = from
    var now = 100.0
    while s <= to + 1e-9 {
      m.advance(
        context(now: now, panels: panels), timeline: Self.timeline, step: s,
        tickSec: Self.tickSec, macroActive: macro)
      s += by
      now += 1.0 / 60
    }
    return m
  }

  private func at(_ step: Double, now: Double = 100, fires: [StageFire] = [], level: Int = 0)
    -> StageMinecraftScene
  {
    let m = StageMinecraftModel()
    m.advance(
      context(now: now, fires: fires, level: level), timeline: Self.timeline, step: step,
      tickSec: Self.tickSec, macroActive: false)
    return m.scene
  }

  private func panel(_ net: String, riffGroup: String = "", muted: Bool) -> StagePanel {
    let shape = StageNetShape(
      netId: net, placeIds: ["p"], placeX: [0], placeY: [0], transitionIds: ["t"],
      transitionX: [10], transitionY: [10])
    return StagePanel(
      id: "A/\(net)", deck: "A", netId: net, label: net, channel: 1, riffGroup: riffGroup,
      center: StagePoint(x: 500, y: 300), ring: nil, side: 100, angle: 0, view: nil,
      muted: muted, opacity: 1, shape: shape, tokens: [0], firedAt: [-.infinity])
  }

  // MARK: sections

  @Test func theBiomeFollowsTheSections() {
    let t = Self.timeline
    #expect(t.sections.map(\.name) == ["intro", "buildup", "drop", "verse", "drop", "outro"])
    #expect(at(10).biome == .plains)
    #expect(at(100).biome == .dusk)
    #expect(at(300).biome == .night)
    #expect(at(500).biome == .forest)
    #expect(at(850).biome == .sunset)
    #expect(StageBiome.of(section: "breakdown") == .cave)
    // the sky really changes, and night has stars and a moon
    let day = at(500)
    let night = at(300)
    #expect(day.skyTop != night.skyTop && night.skyTop.b < day.skyTop.b)
    #expect(night.isMoon && night.stars > 0.9 && day.stars == 0)
    // a section change cross-fades over two beats
    let edge = at(448)
    #expect(edge.skyTop == StageBiome.night.sky.top, "the verse starts from the drop's sky")
    #expect(at(456).skyTop == StageBiome.forest.sky.top)
  }

  // MARK: buildup -> drop

  @Test func theFuseBurnsThroughTheBuildup() {
    #expect(at(63).fuse == nil, "no TNT before the buildup")
    #expect(at(64).fuse == 0)
    var last = -1.0
    for step in stride(from: 64.0, to: 256, by: 8) {
      let f = at(step).fuse ?? -1
      #expect(f > last, "the fuse only burns down: \(step)")
      last = f
    }
    #expect(abs((at(160).fuse ?? 0) - 0.5) < 1e-9, "half way through the buildup")
    #expect((at(255).fuse ?? 0) > 0.99)
    #expect(at(256).fuse == nil, "gone on the drop")
    // the TNT flashes on the beats of the drop gap (252..<256), not before
    #expect(at(250).tntFlash == 0)
    #expect(at(252).tntFlash == 1 && at(254).tntFlash < 0.01)
    // the camera holds on the TNT through the buildup (its phrases do not pan)
    let held = at(80).cameraX
    #expect(at(240).cameraX == held && at(256 + 30).cameraX == held)
    #expect(at(256 + 64 + 30).cameraX > held, "the drop's next phrase moves on")
  }

  @Test func theTNTExplodesOnTheDropsFirstTick() {
    let before = at(255.9)
    #expect(before.explosionAge == nil && before.flash < 0.2)
    let blast = at(256)
    #expect(blast.explosionAge == 0 && blast.flash > 0.85, "white on the drop's first tick")
    let later = at(256 + 10)  // half a second at 300 BPM
    #expect(abs((later.explosionAge ?? -1) - 0.5) < 1e-9)
    #expect(later.flash == 0)
    // the debris flies: blocks are scattered further from the blast than on its first tick
    func spread(_ s: StageMinecraftScene) -> Double {
      s.voxels.filter { $0.style == .block && $0.w < s.block * 0.8 }.map {
        abs($0.x - 500) + abs($0.y - 300)
      }.max() ?? 0
    }
    #expect(spread(later) > spread(blast) + 100)
    #expect(at(256 + 60).explosionAge == nil, "three seconds on, the sky is clear")
    // a minimal visual level throws fewer blocks
    let full = at(256 + 4).voxels.count
    let minimal = at(256 + 4, level: 2).voxels.count
    #expect(minimal < full)
  }

  // MARK: roles

  @Test func mobsSpawnAndDespawnWithTheStructure() {
    // the bass enters at 64 and leaves at 831
    let m = played(from: 0, to: 40)
    let bassBefore = m.scene.mobs.first { $0.role == "bass" }
    #expect(bassBefore == nil, "no critter before the bass plays")
    _ = played(m, from: 64, to: 100)
    let bass = m.scene.mobs.first { $0.role == "bass" }
    #expect(bass?.kind == .critter && (bass?.presence ?? 0) > 0.9 && bass?.active == true)
    #expect(m.scene.mobs.contains { $0.role == "harmony" && $0.kind == .cloud })
    #expect(m.scene.mobs.contains { $0.role == "melody" && $0.kind == .bird })
    _ = played(m, from: 832, to: 870)
    #expect(m.scene.mobs.first { $0.role == "bass" } == nil, "the bass left with the outro")
    // the kick thumps the ground on the beat, and sits out the kick out
    let k = played(from: 0, to: 30)
    _ = k
    let onBeat = played(from: 0, to: 32)
    #expect(onBeat.scene.thump > 0.9)
    let offBeat = played(from: 0, to: 34)
    #expect(offBeat.scene.thump < onBeat.scene.thump)
    #expect(played(from: 230, to: 244).scene.thump == 0, "the kick out")
  }

  @Test func liveMutesWinOverTheSchedule() {
    // the timeline says the bass plays in the drop; the DJ has muted its panel
    let muted = [panel("bass-0", riffGroup: "bass", muted: true)]
    let m = played(from: 300, to: 340, panels: muted)
    #expect(m.scene.mobs.first { $0.role == "bass" } == nil)
    // unmuted, the critter comes back
    let open = [panel("bass-0", riffGroup: "bass", muted: false)]
    _ = played(m, from: 340, to: 380, panels: open)
    #expect((m.scene.mobs.first { $0.role == "bass" }?.presence ?? 0) > 0.9)
    // a role only a panel knows (not in the structure) gets a creature too
    let extra = [panel("cowbell", muted: false)]
    let e = played(from: 300, to: 320, panels: extra)
    #expect(e.roles.contains("cowbell"))
    #expect(e.scene.mobs.contains { $0.role == "cowbell" && $0.kind == .walker })
  }

  // MARK: fills, stingers, macros

  @Test func fillsBreakBlocksOffTheGround() {
    // fill-0 is the intro's last beat (60..<64)
    let quiet = at(58).voxels.count
    let fill = at(61).voxels.count
    #expect(fill > quiet, "block-break particles: \(quiet) -> \(fill)")
  }

  @Test func stingersFireFireworksExceptAtMinimalLevels() {
    let sting = StageFire(
      time: 0, wallTime: 100, panel: nil, deck: "A", netId: "hit1", transitionId: "t",
      transition: nil, origin: nil, note: 72, velocity: 110, channel: 1, durSec: 0.2,
      macroRunning: false, isStinger: true)
    let m = StageMinecraftModel()
    m.advance(
      context(now: 100), timeline: Self.timeline, step: 500, tickSec: Self.tickSec,
      macroActive: false)
    let plain = m.scene.voxels.filter { $0.style == .glow }.count
    m.advance(
      context(now: 100.2, fires: [sting]), timeline: Self.timeline, step: 504,
      tickSec: Self.tickSec,
      macroActive: false)
    #expect(m.scene.voxels.filter { $0.style == .glow }.count >= plain + 16)
    // at night it is lightning, with a flash
    let n = StageMinecraftModel()
    n.advance(
      context(now: 100.02, fires: [sting]), timeline: Self.timeline, step: 300,
      tickSec: Self.tickSec, macroActive: false)
    #expect(n.scene.flash > 0.3)
    // level 2 and up: no per-fire effects
    let q = StageMinecraftModel()
    q.advance(
      context(now: 100.2, fires: [sting], level: 2), timeline: Self.timeline, step: 504,
      tickSec: Self.tickSec, macroActive: false)
    #expect(q.scene.voxels.filter { $0.style == .glow }.count == plain)
  }

  @Test func aRunningMacroBringsRainAndHoldsTheSunBack() {
    let dry = played(from: 460, to: 560)
    let wet = played(from: 460, to: 560, macro: true)
    #expect(!dry.scene.raining && wet.scene.raining)
    let sunDry = dry.scene.celestial?.x ?? 0
    let sunWet = wet.scene.celestial?.x ?? 0
    #expect(sunWet < sunDry - 50, "the tape stop slows the day: \(sunWet) vs \(sunDry)")
  }

  // MARK: determinism

  @Test func theSameSongDrawsTheSameWorldAndAnotherSongAnother() {
    let a = played(from: 0, to: 300, by: 3)
    let b = played(from: 0, to: 300, by: 3)
    #expect(a.scene == b.scene)
    let other = StageMinecraftModel()
    other.advance(
      context(now: 100), timeline: TimelineFixture.timeline(seed: 7), step: 500,
      tickSec: Self.tickSec, macroActive: false)
    let same = StageMinecraftModel()
    same.advance(
      context(now: 100), timeline: Self.timeline, step: 500, tickSec: Self.tickSec,
      macroActive: false)
    #expect(other.scene.voxels != same.scene.voxels)
  }

  @Test func onlyWorksWhileShowingAndReusesItsBuffers() {
    let m = StageMinecraftModel()
    var ctx = context(now: 100)
    ctx.visualizer = .corona
    m.advance(ctx)
    #expect(m.scene.voxels.isEmpty, "not showing: nothing composed")
    _ = played(m, from: 500, to: 520)
    let n = m.scene.voxels.count
    #expect(n > 200 && n < 2200, "a frame stays within its reserved capacity: \(n)")
  }
}
