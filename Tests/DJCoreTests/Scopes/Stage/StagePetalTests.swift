import Darwin
import Testing

@testable import DJCore

// SPEC mode 11, the petal: the energy rules (+0.45 per fire capped at 1, exp(-2.3 dt), dropped
// below 0.005), the petal geometry and colours pinned against stage.js's own arithmetic run in
// node (including the shadow state its loop leaks into the next petal's fill), the model fed by
// the stage's fires, and the whole stage on a real engine.

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

private func near(_ p: StagePoint, _ x: Double, _ y: Double, _ tol: Double = 1e-9) -> Bool {
  near(p.x, x, tol) && near(p.y, y, tol)
}

private func key(_ net: String, deck: String = "A") -> PetalKey { PetalKey(deck: deck, netId: net) }

/// `StagePetals` behind a reference, so mutating calls can sit inside `#expect`.
private final class PetalBox {
  var petals = StagePetals()
  func fire(_ k: PetalKey) { petals.fire(k) }
  func decay(dt: Double) { petals.decay(dt: dt) }
  func raw(_ k: PetalKey) -> Double { petals.raw(k) }
}

struct StagePetalEnergyTests {
  @Test func theConstantsAreTheOnesInStageJs() {
    #expect(StagePetals.bump == 0.45 && StagePetals.decayRate == 2.3 && StagePetals.floor == 0.005)
    #expect(StagePetals.baseFraction == 0.08 && StagePetals.maxFraction == 0.42)
  }

  @Test func eachFireAddsAFairlyBigBumpCappedAtOne() {
    let p = PetalBox()
    p.fire(key("a"))
    #expect(near(p.raw(key("a")), 0.45))
    p.fire(key("a"))
    #expect(near(p.raw(key("a")), 0.9))
    p.fire(key("a"))
    #expect(p.raw(key("a")) == 1, "min(1, 0.9 + 0.45)")
    #expect(p.raw(key("b")) == 0, "other nets are untouched")
  }

  @Test func energyDecaysByExpOfMinus2Point3PerSecond() {
    let p = PetalBox()
    p.fire(key("a"))
    p.decay(dt: 1.0 / 60)
    #expect(near(p.raw(key("a")), 0.45 * exp(-2.3 / 60), 1e-12))
    #expect(near(p.raw(key("a")), 0.4330764405, 1e-9))
    // halves every ln 2 / 2.3 = 301.4 ms, however the time is cut into frames
    let half = PetalBox()
    half.fire(key("a"))
    half.decay(dt: 0.1)
    half.decay(dt: 0.1)
    half.decay(dt: 0.1013)
    #expect(
      near(half.raw(key("a")), 0.225, 0.0005), "halved after about 301 ms: \(half.raw(key("a")))")
  }

  @Test func anEnergyBelowPointZeroZeroFiveIsDropped() {
    let p = PetalBox()
    p.petals = {
      var s = StagePetals()
      for _ in 0..<2 { s.fire(key("a")) }  // 0.9
      return s
    }()
    // 0.9 * exp(-2.3 * t) < 0.005 once t > 2.2527 s
    for _ in 0..<135 { p.decay(dt: 1.0 / 60) }  // 2.25 s
    #expect(p.petals.energy[key("a")] != nil && p.raw(key("a")) > 0.005)
    p.decay(dt: 1.0 / 60)
    #expect(p.petals.energy.isEmpty, "gone, not just small: \(p.petals.energy)")
    #expect(p.raw(key("a")) == 0)
  }

  @Test func theThresholdIsStrict() {
    // 0.0052 after a 0.01 s frame is 0.005082: kept; after 0.1 s it is 0.00413: dropped
    for (dt, kept) in [(0.01, true), (0.1, false)] {
      var s = StagePetals()
      s.fire(key("a"))  // 0.45
      s.decay(dt: 5)  // far below: gone
      #expect(s.energy.isEmpty)
      s = StagePetals()
      s.fire(key("a"))
      // walk down to 0.0052: 0.45 * exp(-2.3 t) = 0.0052 at t = ln(0.45 / 0.0052) / 2.3
      s.decay(dt: log(0.45 / 0.0052) / 2.3)
      #expect(near(s.raw(key("a")), 0.0052, 1e-9))
      s.decay(dt: dt)
      #expect((s.energy[key("a")] != nil) == kept, "dt \(dt): \(s.raw(key("a")))")
    }
  }

  @Test func netsAreKeyedByDeckAndNetIdSoTwoDecksNeverShareAPetal() {
    let p = PetalBox()
    p.fire(key("kick", deck: "A"))
    #expect(p.raw(key("kick", deck: "A")) == 0.45 && p.raw(key("kick", deck: "B")) == 0)
  }

  @Test func aResetForgetsEveryEnergy() {
    var s = StagePetals()
    s.fire(key("a"))
    s.reset()
    #expect(s.energy.isEmpty)
  }
}

struct StagePetalGeometryTests {
  // 800 x 600: baseR 48, maxR 252; ring centre (400, 300). Four petals: index 1 points right.
  private let center = StagePoint(x: 400, y: 300)

  private func shape(_ i: Int, raw: Double, hue: Double, n: Int = 4) -> PetalShape {
    StagePetals.shape(
      index: i, count: n, raw: raw, hue: hue, center: center, width: 800, height: 600)
  }

  @Test func aPetalAtHighEnergyMatchesStageJs() {
    // node: renderPetal on petal 0 of 4 (channel 4, hue 280) at raw energy 0.7150802422530007
    let p = shape(0, raw: 0.7150802422530007, hue: 280)
    #expect(near(p.angle, -Double.pi / 2) && near(p.baseRadius, 48))
    #expect(near(p.length, 248.6019647607533) && near(p.energy, 0.7150802422530007.squareRoot()))
    #expect(near(p.halfWidth, Double.pi / 4 * (0.45 + 0.5 * p.energy)))
    #expect(near(p.tip, 400, 51.398035239246695, 1e-9))
    #expect(near(p.left, 296.72758231223787, 173.72032147389675, 1e-9))
    #expect(near(p.right, 503.2724176877622, 173.72032147389677, 1e-9))
    #expect(near(p.gradientStartRadius, 24) && near(p.gradientEndRadius, 248.6019647607533))
    #expect(
      near(p.fillInner.a, 0.715093295244656, 1e-9) && near(p.fillOuter.a, 0.2614060432930254, 1e-9))
    #expect(
      near(p.outline.a, 0.8228120865860509, 1e-9) && near(p.lineWidth, 3.114060432930254, 1e-9))
    #expect(
      near(p.shadow.a, 0.507374503903261, 1e-9) && near(p.shadowBlur, 15.838738424409424, 1e-9))
  }

  @Test func aPetalAtMidEnergyPointsRightAndMatchesStageJs() {
    let p = shape(1, raw: 0.25, hue: 24)
    #expect(near(p.angle, 0) && near(p.energy, 0.5))
    #expect(near(p.length, 181.62) && near(p.halfWidth, Double.pi / 4 * 0.7))
    #expect(near(p.tip, 581.62, 300, 1e-9))
    #expect(near(p.left, 507.68077899644265, 234.0131337634581, 1e-9))
    #expect(near(p.right, 507.68077899644265, 365.9868662365419, 1e-9))
    #expect(near(p.fillInner.a, 0.525) && near(p.fillOuter.a, 0.175))
    #expect(near(p.outline.a, 0.65) && near(p.lineWidth, 2.25))
    #expect(near(p.shadow.a, 0.3) && near(p.shadowBlur, 11))
    #expect(near(p.gradientEndRadius, 181.62))
  }

  @Test func aPetalAtRestIs18PercentOfTheWayOutAndBarelyThereToLookAt() {
    let p = shape(2, raw: 0, hue: 12)
    #expect(near(p.length, 84.72) && near(p.tip, 400, 384.72, 1e-9))
    #expect(near(p.halfWidth, Double.pi / 4 * 0.45))
    #expect(near(p.left, 425.2651606984287, 368.48421475699763, 1e-9))
    #expect(near(p.fillInner.a, 0.25) && near(p.fillOuter.a, 0.05) && near(p.outline.a, 0.4))
    #expect(near(p.lineWidth, 1) && near(p.shadow.a, 0) && near(p.shadowBlur, 4))
    let q = shape(3, raw: 0, hue: 0)
    #expect(
      near(q.tip, 315.28, 300, 1e-9) && near(q.left, 331.51578524300237, 325.2651606984287, 1e-9))
  }

  @Test func theColoursAreTheHslaOfTheChannelHue() {
    let p = shape(0, raw: 0, hue: 200)
    #expect(p.fillInner.rgb8 == ScopeColor.hsla(200, 80, 55).rgb8)
    #expect(p.fillOuter.rgb8 == ScopeColor.hsla(200, 95, 65).rgb8)
    #expect(p.outline.rgb8 == ScopeColor.hsla(200, 95, 70).rgb8)
    #expect(p.outline.rgb8 == (106, 203, 251), "hsla(200, 95%, 70%) from node")
    #expect(p.shadow.rgb8 == (56, 185, 250), "hsla(200, 95%, 60%) from node")
  }

  @Test func fullEnergyReachesPastTheMaxRadiusBecauseTheFormulaDoes() {
    let p = shape(0, raw: 1, hue: 0)
    #expect(near(p.length, 48 + 204 * 1.13))  // 278.52 > maxR 252, as in the JS
    #expect(near(p.halfWidth, Double.pi / 4 * 0.95))
  }

  @Test func theWidthOfAPetalSharesTheRingEvenlyAmongThePanels() {
    for n in [1, 2, 3, 6, 13] {
      let p = StagePetals.shape(
        index: 0, count: n, raw: 0, hue: 0, center: center, width: 800, height: 600)
      #expect(near(p.halfWidth, Double.pi / Double(n) * 0.45), "n = \(n)")
    }
    // angles go clockwise from the top
    let angles = (0..<4).map { shape($0, raw: 0, hue: 0).angle }
    #expect(near(angles[0], -Double.pi / 2) && near(angles[1], 0) && near(angles[2], Double.pi / 2))
    #expect(near(angles[3], Double.pi))
  }

  @Test func theShapesCarryThePreviousPetalsGlowOnTheirFillAsTheJsLeavesIt() {
    var energies = StagePetals()
    for _ in 0..<2 { energies.fire(key("a")) }
    energies.fire(key("b"))
    let shapes = energies.shapes(
      channels: [4, 12, 11], keys: [key("a"), key("b"), key("c")], center: center, width: 800,
      height: 600)
    #expect(shapes.count == 3)
    #expect(shapes[0].fillShadow == nil, "the first petal's fill has the context's default: none")
    #expect(
      shapes[1].fillShadow == shapes[0].shadow && shapes[1].fillShadowBlur == shapes[0].shadowBlur)
    #expect(
      shapes[2].fillShadow == shapes[1].shadow && shapes[2].fillShadowBlur == shapes[1].shadowBlur)
    #expect(near(shapes[0].raw, 0.9) && near(shapes[1].raw, 0.45) && near(shapes[2].raw, 0))
    #expect(shapes.map(\.hue) == [280, 24, 12])
    // an empty ring has no petals
    #expect(
      energies.shapes(channels: [], keys: [], center: center, width: 800, height: 600).isEmpty)
  }
}

@MainActor
struct StagePetalModelTests {
  private func fire(_ net: String, deck: String = "A", channel: Int = 1) -> StageFire {
    StageFire(
      time: 0, wallTime: 0, panel: nil, deck: deck, netId: net, transitionId: "t",
      transition: nil, origin: nil, note: 60, velocity: 100, channel: channel, durSec: 0.1,
      macroRunning: false)
  }

  private func panel(_ net: String, deck: String = "A", channel: Int) -> StagePanel {
    let shape = StageNetShape(
      netId: net, placeIds: ["p"], placeX: [0], placeY: [0], transitionIds: ["t"],
      transitionX: [10], transitionY: [10])
    return StagePanel(
      id: "\(deck)/\(net)", deck: deck, netId: net, label: net, channel: channel, riffGroup: "",
      center: StagePoint(x: 400, y: 300), ring: nil, side: 100, angle: 0, view: nil, muted: false,
      opacity: 1, shape: shape, tokens: [0], firedAt: [-.infinity])
  }

  private func context(
    _ v: StageVisualizer, fires: [StageFire] = [], panels: [StagePanel] = [], dt: Double = 1.0 / 60
  ) -> StageContext {
    StageContext(
      width: 800, height: 600,
      layout: StagePanelLayout.layoutRing(width: 800, height: 600, count: panels.count),
      panels: panels, now: 10, dt: dt, fires: fires, selection: v, visualizer: v)
  }

  @Test func eachFireBumpsItsNetThenTheFrameDecaysEveryEnergy() {
    let m = StageSoloModel()
    m.advance(context(.petal, fires: [fire("a"), fire("a"), fire("b")], dt: 0.1))
    // fires first, then the frame's decay, as the JS (events arrive before the render)
    let d = exp(-0.1 * 2.3)
    #expect(near(m.petals.raw(key("a")), 0.9 * d, 1e-12))
    #expect(near(m.petals.raw(key("b")), 0.45 * d, 1e-12))
    m.advance(context(.petal, fires: [fire("a")], dt: 0.1))
    #expect(near(m.petals.raw(key("a")), min(1, 0.9 * d + 0.45) * d, 1e-12))
  }

  @Test func theFiresOfTwoDecksAreKeptApart() {
    let m = StageSoloModel()
    m.advance(context(.petal, fires: [fire("kick", deck: "A")], dt: 0))
    #expect(m.petals.raw(key("kick", deck: "A")) == 0.45)
    #expect(m.petals.raw(key("kick", deck: "B")) == 0)
  }

  @Test func onlyThePetalListensAndAVisualizerSwitchStartsFresh() {
    let m = StageSoloModel()
    m.advance(context(.sonar, fires: [fire("a")]))
    m.advance(context(.corona, fires: [fire("a")]))
    #expect(m.petals.energy.isEmpty, "fires count only while the petal shows")
    m.advance(context(.petal, fires: [fire("a")]))
    #expect(m.petals.energy.count == 1)
    m.advance(context(.constellation))
    m.advance(context(.petal))
    #expect(m.petals.energy.isEmpty, "setVisualizer clears the energies")
  }

  @Test func thePaintHasOnePetalPerPanelInTheirChannelsHueWithTheirOwnEnergy() {
    let m = StageSoloModel()
    let panels = [
      panel("a", channel: 4), panel("b", channel: 12), panel("c", channel: 11),
      panel("d", channel: 10),
    ]
    m.advance(context(.petal, fires: [fire("b"), fire("b")], panels: panels, dt: 0))
    guard case .petal(let shapes) = m.paint(context(.petal, panels: panels)) else {
      Issue.record("not a petal paint")
      return
    }
    #expect(shapes.count == 4 && shapes.map(\.hue) == [280, 24, 12, 0])
    #expect(near(shapes[1].raw, 0.9) && shapes[0].raw == 0 && shapes[2].raw == 0)
    #expect(shapes[1].length > shapes[0].length)
    #expect(m.paint(context(.petal)) == .petal([]), "no panels: nothing to draw")
    #expect(m.paint(context(.constellation, panels: panels)) == .none)
  }

  @Test func aPetalFollowsItsNetWhenThePanelFlipsToAnotherVariant() {
    // energy is per net, so the panel that now shows variant "b" shows b's own energy
    let m = StageSoloModel()
    m.advance(context(.petal, fires: [fire("b")], panels: [panel("a", channel: 4)], dt: 0))
    guard case .petal(let before) = m.paint(context(.petal, panels: [panel("a", channel: 4)]))
    else { return }
    guard case .petal(let after) = m.paint(context(.petal, panels: [panel("b", channel: 4)]))
    else { return }
    #expect(before[0].raw == 0 && near(after[0].raw, 0.45))
  }
}

@MainActor
struct StagePetalEngineTests {
  @Test func theStageBreathesWithTheRealFiresOfItsNets() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.model.settings.visualizer = .petal
    var peak: [String: Double] = [:]
    for _ in 0..<60 {  // 3 s
      h.step()
      for p in h.ctx.panels {
        let raw = h.model.layers.solo.petals.raw(PetalKey(deck: p.deck, netId: p.netId))
        peak[p.netId] = max(peak[p.netId] ?? 0, raw)
      }
    }
    #expect(h.ctx.visualizer == .petal && h.ctx.isSolo)
    #expect(peak.values.filter { $0 > 0.3 }.count >= 2, "nets that fired lit their petals: \(peak)")
    #expect(peak.values.allSatisfy { $0 <= 1 })
    let live = h.model.layers.solo.petals.energy
    #expect(live.values.allSatisfy { $0 >= 0.005 }, "nothing below the floor is kept")
    // and the picture follows: the panel with the most energy has the longest petal
    guard case .petal(let shapes) = h.model.layers.solo.paint(h.ctx) else {
      Issue.record("no petal paint")
      return
    }
    #expect(shapes.count == h.ctx.panels.count)
    let hottest = shapes.indices.max { shapes[$0].raw < shapes[$1].raw }!
    #expect(shapes.allSatisfy { shapes[hottest].length >= $0.length })
    #expect(shapes.map(\.hue) == h.ctx.panels.map { ScopeColors.channelHue($0.channel) })
  }

  @Test func whenTheSongStopsTheFlowerRelaxesToItsResting18Percent() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.model.settings.visualizer = .petal
    h.run(2)
    h.deck.setPlaying(false)
    h.run(4)  // longer than 0.9 * exp(-2.3 t) < 0.005 takes
    #expect(h.model.layers.solo.petals.energy.isEmpty)
    guard case .petal(let shapes) = h.model.layers.solo.paint(h.ctx) else { return }
    let short = min(h.ctx.width, h.ctx.height)
    let resting = short * 0.08 + (short * 0.42 - short * 0.08) * 0.18
    #expect(shapes.allSatisfy { near($0.length, resting, 1e-9) })
  }
}
