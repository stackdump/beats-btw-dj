import Darwin
import Testing

@testable import DJCore

// SPEC mode 10, the sonar: the rate limits and the cap exactly as `stageOnTransitionFired` has
// them (millisecond times pinned at the boundaries), the ring geometry and colours of
// `renderSonar`, the channel colours, the reset on a visualizer switch, and the model fed by the
// stage on a real engine.

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

/// `StageSonar` behind a reference, so a call to its mutating methods can sit inside `#expect`.
private final class SonarBox {
  var sonar = StageSonar()
  var rings: [SonarRing] { sonar.rings }
  @discardableResult
  func fire(channel: Int, nowMs: Double) -> Bool { sonar.fire(channel: channel, nowMs: nowMs) }
  func prune(nowMs: Double) { sonar.prune(nowMs: nowMs) }
  func reset() { sonar.reset() }
  func arcs(nowMs: Double, center: StagePoint, width: Double, height: Double) -> [SonarArc] {
    sonar.arcs(nowMs: nowMs, center: center, width: width, height: height)
  }
}

struct StageSonarRulesTests {
  @Test func theConstantsAreTheOnesInStageJs() {
    #expect(StageSonar.life == 900 && StageSonar.channelGap == 250 && StageSonar.anyGap == 80)
    #expect(StageSonar.capBeforePush == 8 && StageSonar.radiusFraction == 0.55)
    #expect(StageSonar.shadowBlur == 8)
  }

  @Test func aRingIsBornWithItsChannelsHueAndAnInitialLifeOf900() {
    let s = SonarBox()
    #expect(s.fire(channel: 3, nowMs: 5000))
    #expect(s.rings == [SonarRing(born: 5000, hue: 200, life: 900)])
    #expect(s.fire(channel: 99, nowMs: 6000))
    #expect(s.rings[1].hue == 333, "99 * 47 mod 360: the hash for a channel the table lacks")
    #expect(s.fire(channel: 21, nowMs: 7000))
    #expect(s.rings[2].hue == 60, "stage.js knows channels 20...23 as well")
    #expect(s.fire(channel: 10, nowMs: 8000))
    #expect(s.rings[3].hue == 0)
  }

  @Test func aChannelRingsAtMostOnceEvery250ms() {
    let s = SonarBox()
    #expect(s.fire(channel: 1, nowMs: 10_000))
    #expect(!s.fire(channel: 1, nowMs: 10_249.999), "249.999 ms after its own last ring")
    #expect(s.rings.count == 1)
    #expect(s.fire(channel: 1, nowMs: 10_250), "exactly 250 ms: allowed (>=)")
    #expect(s.rings.count == 2)
  }

  @Test func anyRingBlocksTheNext80ms() {
    let s = SonarBox()
    #expect(s.fire(channel: 1, nowMs: 10_000))
    #expect(!s.fire(channel: 2, nowMs: 10_079.999), "another channel, but inside 80 ms")
    #expect(s.fire(channel: 2, nowMs: 10_080), "exactly 80 ms: allowed (>=)")
    #expect(s.rings.map(\.born) == [10_000, 10_080])
  }

  @Test func aBlockedFireDoesNotMoveEitherClock() {
    let s = SonarBox()
    #expect(s.fire(channel: 1, nowMs: 10_000))
    #expect(!s.fire(channel: 1, nowMs: 10_200), "inside the channel's 250 ms")
    // the refused fire at 10_200 did not restart the channel's 250 ms nor the 80 ms
    #expect(s.fire(channel: 1, nowMs: 10_250))
    #expect(!s.fire(channel: 2, nowMs: 10_300), "inside the 80 ms of the ring at 10_250")
    #expect(
      s.fire(channel: 2, nowMs: 10_330), "and 80 ms after 10_250, not after the refused 10_300")
    #expect(s.rings.map(\.born) == [10_000, 10_250, 10_330])
  }

  @Test func theTwoLimitsAreIndependentOfEachOther() {
    let s = SonarBox()
    for (i, ch) in [1, 2, 3, 4].enumerated() {
      #expect(s.fire(channel: ch, nowMs: 20_000 + Double(i) * 100), "channel \(ch)")
    }
    #expect(!s.fire(channel: 1, nowMs: 20_349), "its own 250 ms are over, the global 80 are not")
    #expect(!s.fire(channel: 3, nowMs: 20_400), "the global 80 are over, its own 250 are not")
    #expect(s.fire(channel: 1, nowMs: 20_400), "both over")
    #expect(s.rings.map(\.born) == [20_000, 20_100, 20_200, 20_300, 20_400])
  }

  @Test func theCapDropsTheOldestBeforeThePushSoNineCanExist() {
    let s = SonarBox()
    var counts: [Int] = []
    for i in 0..<12 {  // twelve channels, 100 ms apart: every one passes both limits
      #expect(s.fire(channel: i + 1, nowMs: 30_000 + Double(i) * 100))
      counts.append(s.rings.count)
    }
    #expect(counts == [1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 9], "length > 8 shifts BEFORE pushing")
    #expect(s.rings.first?.born == 30_300 && s.rings.last?.born == 31_100)
    #expect(s.rings.count == 9)
    #expect(s.rings.map(\.born) == (3..<12).map { 30_000 + Double($0) * 100 })
  }

  @Test func deadRingsLeaveWhenPrunedNotWhenTheCapIsReached() {
    let s = SonarBox()
    s.fire(channel: 1, nowMs: 1000)
    s.fire(channel: 2, nowMs: 1100)
    s.prune(nowMs: 1900)  // 900 ms old: exactly its life, still drawn
    #expect(s.rings.count == 2)
    s.prune(nowMs: 1900.5)
    #expect(s.rings.map(\.born) == [1100], "older than its life: gone")
    s.prune(nowMs: 2000.001)
    #expect(s.rings.isEmpty)
  }

  @Test func aVisualizerSwitchForgetsTheRingsAndTheRateLimits() {
    let s = SonarBox()
    s.fire(channel: 1, nowMs: 10_000)
    s.reset()
    #expect(s.rings.isEmpty)
    #expect(s.fire(channel: 1, nowMs: 10_001), "the 250 ms of the old ring and the 80 ms are gone")
  }
}

struct StageSonarGeometryTests {
  private let center = StagePoint(x: 400, y: 300)

  @Test func theRadiusGrowsToFiftyFivePercentOfTheDiagonal() {
    #expect(near(StageSonar.maxRadius(width: 800, height: 600), 550))
    #expect(near(StageSonar.maxRadius(width: 1000, height: 800), hypot(1000, 800) * 0.55))
  }

  @Test func aRingAtHalfItsLifeIsAtHalfTheRadiusAndFadedAccordingly() {
    let ring = SonarRing(born: 1000, hue: 200, life: 900)
    let a = StageSonar.arc(ring, nowMs: 1450, center: center, width: 800, height: 600)
    #expect(near(a.t, 0.5) && near(a.radius, 275))
    #expect(near(a.lineWidth, 3) && near(a.stroke.a, 0.425))
    #expect(a.stroke.rgb8 == (56, 185, 250), "hsla(200, 95%, 60%)")
    #expect(near(a.shadow.a, 0.2125) && a.shadow.rgb8 == (31, 177, 249), "hsla(200, 95%, 55%)")
    #expect(near(a.shadowBlur, 8) && a.cx == 400 && a.cy == 300)
  }

  @Test func atBirthItIsAPointAtFullStrengthAndAtTheEndAWideInvisibleCircle() {
    let ring = SonarRing(born: 1000, hue: 333, life: 900)
    let born = StageSonar.arc(ring, nowMs: 1000, center: center, width: 800, height: 600)
    #expect(near(born.t, 0) && near(born.radius, 0) && near(born.lineWidth, 5))
    #expect(near(born.stroke.a, 0.85) && near(born.shadow.a, 0.425))
    #expect(born.stroke.rgb8 == (250, 56, 143))
    let end = StageSonar.arc(ring, nowMs: 1900, center: center, width: 800, height: 600)
    #expect(near(end.t, 1) && near(end.radius, 550) && near(end.lineWidth, 1))
    #expect(near(end.stroke.a, 0) && near(end.shadow.a, 0))
  }

  @Test func theArcsComeOldestFirstFromTheStagesRingCentre() {
    let s = SonarBox()
    s.fire(channel: 1, nowMs: 1000)
    s.fire(channel: 2, nowMs: 1200)
    let arcs = s.arcs(nowMs: 1300, center: StagePoint(x: 123, y: 456), width: 800, height: 600)
    #expect(arcs.count == 2 && arcs[0].radius > arcs[1].radius)
    #expect(arcs.allSatisfy { $0.cx == 123 && $0.cy == 456 })
    #expect(near(arcs[0].radius, 300.0 / 900 * 550) && near(arcs[1].radius, 100.0 / 900 * 550))
  }
}

@MainActor
struct StageSonarModelTests {
  private func fire(
    at wall: Double, channel: Int, panel: Int? = nil, netId: String = "n"
  ) -> StageFire {
    StageFire(
      time: 0, wallTime: wall, panel: panel, deck: "A", netId: netId, transitionId: "t",
      transition: nil, origin: nil, note: 60, velocity: 100, channel: channel, durSec: 0.1,
      macroRunning: false)
  }

  private func context(
    _ v: StageVisualizer, now: Double, fires: [StageFire] = [], panels: [StagePanel] = []
  ) -> StageContext {
    StageContext(
      width: 800, height: 600,
      layout: StagePanelLayout.layoutRing(width: 800, height: 600, count: panels.count),
      panels: panels, now: now, dt: 1.0 / 60, fires: fires, selection: v, visualizer: v)
  }

  private func panel(channel: Int) -> StagePanel {
    let shape = StageNetShape(
      netId: "n", placeIds: ["p"], placeX: [0], placeY: [0], transitionIds: ["t"],
      transitionX: [10], transitionY: [10])
    return StagePanel(
      id: "A/n", deck: "A", netId: "n", label: "n", channel: channel, riffGroup: "",
      center: StagePoint(x: 400, y: 300), ring: nil, side: 100, angle: 0, view: nil, muted: false,
      opacity: 1, shape: shape, tokens: [0], firedAt: [-.infinity])
  }

  @Test func ringsAreBornOnTheFiresWallClockInMilliseconds() {
    let m = StageSoloModel()
    // fires read 20 ms and 5 ms before the frame at now = 100 s
    m.advance(
      context(
        .sonar, now: 100, fires: [fire(at: 99.980, channel: 1), fire(at: 99.995, channel: 2)]))
    #expect(m.sonar.rings.count == 1, "the second is 15 ms after the first: inside 80 ms")
    #expect(near(m.sonar.rings[0].born, 99_980, 1e-6) && m.sonar.rings[0].hue == 50)
    // the next frame, 250 ms later, on channel 1 again: allowed
    m.advance(context(.sonar, now: 100.25, fires: [fire(at: 100.240, channel: 1)]))
    #expect(m.sonar.rings.count == 2)
    #expect(near(m.sonar.rings[1].born, 100_240, 1e-6))
  }

  @Test func theChannelIsTheNetsTrackChannelWhenThePanelIsKnown() {
    let m = StageSoloModel()
    let ctx = context(
      .sonar, now: 10,
      fires: [
        fire(at: 9.8, channel: 1, panel: 0),  // played on channel 1, the panel's track is 5
        fire(at: 9.95, channel: 2, panel: nil),  // no panel: the channel that played it
      ], panels: [panel(channel: 5), panel(channel: 6)])
    m.advance(ctx)
    #expect(m.sonar.rings.map(\.hue) == [320, 220], "channelHue(5), channelHue(2)")
  }

  @Test func onlyTheSonarListensAndDeadRingsAreSweptEveryFrame() {
    let m = StageSoloModel()
    m.advance(context(.corona, now: 5, fires: [fire(at: 4.9, channel: 1)]))
    m.advance(context(.petal, now: 6, fires: [fire(at: 5.9, channel: 1)]))
    #expect(m.sonar.rings.isEmpty, "fires count only while the sonar shows")
    m.advance(context(.sonar, now: 10, fires: [fire(at: 9.95, channel: 1)]))
    #expect(m.sonar.rings.count == 1)
    m.advance(context(.sonar, now: 10.5))
    #expect(m.sonar.rings.count == 1)
    m.advance(context(.sonar, now: 10.86))  // 910 ms after the fire at 9.95
    #expect(m.sonar.rings.isEmpty)
  }

  @Test func switchingAwayAndBackStartsFresh() {
    let m = StageSoloModel()
    m.advance(context(.sonar, now: 10, fires: [fire(at: 9.99, channel: 1)]))
    #expect(m.sonar.rings.count == 1)
    m.advance(context(.petal, now: 10.01))
    m.advance(context(.sonar, now: 10.02))
    #expect(m.sonar.rings.isEmpty, "setVisualizer clears the rings")
    // and the rate limit memory went with them: a fire 30 ms after the old ring is allowed
    m.advance(context(.sonar, now: 10.03, fires: [fire(at: 10.02, channel: 1)]))
    #expect(m.sonar.rings.count == 1)
  }

  @Test func theAppPaintIsTheArcsAtTheFramesTime() {
    let m = StageSoloModel()
    m.advance(context(.sonar, now: 10, fires: [fire(at: 9.9, channel: 3)]))
    let ctx = context(.sonar, now: 10)
    guard case .sonar(let arcs) = m.paint(ctx) else {
      Issue.record("not a sonar paint")
      return
    }
    #expect(arcs.count == 1)
    #expect(near(arcs[0].t, 0.1 / 0.9, 1e-9) && near(arcs[0].radius, 0.1 / 0.9 * 550, 1e-6))
    #expect(m.paint(context(.constellation, now: 10)) == .none)
  }
}

@MainActor
struct StageSonarEngineTests {
  @Test func theStageSpawnsRingsFromTheRealFiresUnderBothRateLimits() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.model.settings.visualizer = .sonar
    var born: [(ms: Double, hue: Double)] = []
    var fires = 0
    for _ in 0..<80 {  // 4 s of the 300 BPM techno
      h.step()
      fires += h.ctx.fires.count
      let rings = h.model.layers.solo.sonar.rings
      for r in rings where !born.contains(where: { $0.ms == r.born }) {
        born.append((r.born, r.hue))
      }
    }
    #expect(h.ctx.visualizer == .sonar && h.ctx.isSolo)
    #expect(fires > 40, "the song fired \(fires) times")
    #expect(
      born.count > 8 && born.count < fires, "rate limits thinned \(fires) fires to \(born.count)")
    let sorted = born.sorted { $0.ms < $1.ms }
    for (a, b) in zip(sorted, sorted.dropFirst()) {
      #expect(b.ms - a.ms >= 80 - 1e-6, "global limit: \(b.ms - a.ms) ms")
    }
    // hues are channelHue of the panels' channels (4, 12, 11, 10, 7, 6) or a hit track's
    let allowed = Set([4, 6, 7, 10, 11, 12, 13, 14, 15].map { ScopeColors.channelHue($0) })
    #expect(born.allSatisfy { allowed.contains($0.hue) })
    #expect(Set(born.map(\.hue)).count >= 2, "several channels rang")
    #expect(h.model.layers.solo.sonar.rings.count <= 9, "never more than nine at once")
    // nothing is kept past its life: every ring on screen is at most 900 ms old
    let now = h.ctx.nowMs
    #expect(h.model.layers.solo.sonar.rings.allSatisfy { now - $0.born <= 900 })
  }
}
