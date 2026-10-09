import Testing

@testable import DJCore

// Pinned literals: the arithmetic of beats' stage.js (`distributeEvenly`, `layoutRing`, ...) run
// in node (scratchpad oracle), 17 significant digits. Hand-computed values are marked.

struct StageDistributeTests {
  /// `distributeEvenly([0, 1, ..., n-1])` from stage.js.
  static let expected: [Int: [Int]] = [
    4: [0, 3, 2, 1],
    5: [0, 3, 1, 4, 2],
    6: [0, 5, 4, 3, 2, 1],
    7: [0, 5, 3, 1, 6, 4, 2],
    8: [0, 3, 6, 1, 4, 7, 2, 5],
    9: [0, 7, 5, 3, 1, 8, 6, 4, 2],
    10: [0, 7, 4, 1, 8, 5, 2, 9, 6, 3],
    12: [0, 5, 10, 3, 8, 1, 6, 11, 4, 9, 2, 7],
    16: [0, 7, 14, 5, 12, 3, 10, 1, 8, 15, 6, 13, 4, 11, 2, 9],
    20: [0, 3, 6, 9, 12, 15, 18, 1, 4, 7, 10, 13, 16, 19, 2, 5, 8, 11, 14, 17],
  ]

  @Test(arguments: [4, 5, 6, 7, 8, 9, 10, 12, 16, 20]) func matchesTheJS(_ n: Int) {
    #expect(StagePanelLayout.distributeEvenly(Array(0..<n)) == Self.expected[n]!)
  }

  /// The stride picked for n = 4...20 (the coprime integer in 2..<n closest to n * 0.381966).
  static let strides = [
    4: 3, 5: 2, 6: 5, 7: 3, 8: 3, 9: 4, 10: 3, 11: 4, 12: 5, 13: 5, 14: 5, 15: 7, 16: 7, 17: 6,
    18: 7, 19: 7, 20: 7,
  ]

  @Test(arguments: Array(4...20)) func theStrideIsTheGoldenRatioCoprime(_ n: Int) {
    #expect(StagePanelLayout.stride(count: n) == Self.strides[n]!)
  }

  @Test(arguments: Array(4...20)) func isADeterministicPermutation(_ n: Int) {
    let ids = Array(0..<n)
    let out = StagePanelLayout.distributeEvenly(ids)
    #expect(out.sorted() == ids, "every panel appears exactly once")
    #expect(out == StagePanelLayout.distributeEvenly(ids), "same input, same output")
    // item i sits at (i * stride) mod n: consecutive items are `stride` places apart
    let at = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1, $0) })
    let s = StagePanelLayout.stride(count: n)
    for i in 0..<(n - 1) {
      #expect((at[i + 1]! - at[i]! + n) % n == s, "n=\(n): \(i) -> \(i + 1)")
    }
  }

  @Test func fewerThanFourKeepTheirOrder() {
    #expect(StagePanelLayout.distributeEvenly([Int]()) == [])
    #expect(StagePanelLayout.distributeEvenly(["a"]) == ["a"])
    #expect(StagePanelLayout.distributeEvenly(["a", "b", "c"]) == ["a", "b", "c"])
  }
}

struct StageRingLayoutTests {
  @Test func aLonePanelIsCentredAt68PercentAndHasNoRing() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 1)
    #expect(l.side == 544 && l.center == StagePoint(x: 500, y: 400))
    #expect(l.panelCenters == [StagePoint(x: 500, y: 400)])
    #expect(!l.hasRing && !l.showsMeta)
    #expect(l.darkPlanetRadius == nil && l.placeR == nil && l.placeCenters.isEmpty)
    // stage.js: left = (w - side) / 2, top = (h - side) / 2
    #expect(l.center.x - l.side / 2 == 228 && l.center.y - l.side / 2 == 128)
  }

  @Test func noPanelsLeaveNothing() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 0)
    #expect(l.panelCenters.isEmpty && !l.hasRing && !l.showsMeta)
  }

  @Test func twoPanels() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 2)
    #expect(stageNear(l.side, 336) && stageNear(l.radius, 208))
    #expect(stageNear(l.placeR!, 40.32) && stageNear(l.placeRadius!, 72.8))
    #expect(stageNear(l.darkPlanetRadius!, 28.48))
    #expect(stageNear(l.panelCenters[0], 500, 192) && stageNear(l.panelCenters[1], 500, 608))
    #expect(stageNear(l.placeCenters[0], 572.8, 400) && stageNear(l.placeCenters[1], 427.2, 400))
    #expect(l.hasRing && l.showsMeta)
  }

  @Test func threePanels() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 3)
    #expect(stageNear(l.side, 336) && stageNear(l.radius, 208))
    #expect(stageNear(l.panelCenters[0], 500, 192))
    #expect(stageNear(l.panelCenters[1], 680.1332839871633, 504, 1e-9))
    #expect(stageNear(l.panelCenters[2], 319.86671601283683, 504, 1e-9))
    #expect(stageNear(l.placeCenters[0], 563.0466493955071, 363.6))
    #expect(stageNear(l.placeCenters[1], 500, 472.8))
    #expect(stageNear(l.placeCenters[2], 436.95335060449287, 363.6))
  }

  @Test func fourPanels() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 4)
    #expect(stageNear(l.side, 240) && stageNear(l.radius, 256))
    #expect(
      stageNear(l.placeR!, 28.8) && stageNear(l.placeRadius!, 89.6)
        && stageNear(l.darkPlanetRadius!, 56.8))
    #expect(stageNear(l.panelCenters[1], 756, 400) && stageNear(l.panelCenters[2], 500, 656))
    #expect(stageNear(l.placeCenters[0], 563.3567675943146, 336.64323240568535))
  }

  @Test func sixPanels() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 6)
    #expect(stageNear(l.side, 192) && stageNear(l.radius, 280))
    #expect(
      stageNear(l.placeR!, 23.04) && stageNear(l.placeRadius!, 98)
        && stageNear(l.darkPlanetRadius!, 70.96))
    let want: [(Double, Double)] = [
      (500, 120), (742.4871130596428, 260), (742.4871130596429, 540), (500, 680),
      (257.51288694035725, 540.0000000000001), (257.5128869403572, 260),
    ]
    for (i, w) in want.enumerated() {
      #expect(stageNear(l.panelCenters[i], w.0, w.1, 1e-9), "panel \(i)")
    }
    let places: [(Double, Double)] = [
      (549, 315.129510429125), (598, 400), (549, 484.870489570875), (451, 484.87048957087495),
      (402, 400), (450.99999999999994, 315.12951042912505),
    ]
    for (i, w) in places.enumerated() {
      #expect(stageNear(l.placeCenters[i], w.0, w.1, 1e-9), "place \(i)")
    }
  }

  @Test func theScaleSelectChangesTheSideAndTheRadius() {
    // (scale, side, radius, placeR, placeRadius, darkPlanetRadius) for n = 6 at 1000 x 800
    let rows: [(StageScale, Double, Double, Double, Double, Double)] = [
      (.loop, 192, 280, 23.04, 98, 70.96),
      (.s, 86.4, 332.8, 22, 116.48, 90.48),
      (.m, 144, 304, 22, 106.4, 80.4),
      (.l, 307.2, 222.4, 36.864, 77.84, 36.976),
      (.xl, 460.8, 145.6, 55.296, 50.96, 18),  // 18: the floor
    ]
    for (scale, side, radius, placeR, placeRadius, dark) in rows {
      let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 6, scale: scale)
      #expect(stageNear(l.side, side, 1e-9), "\(scale) side \(l.side)")
      #expect(stageNear(l.radius, radius, 1e-9), "\(scale) radius")
      #expect(stageNear(l.placeR!, placeR, 1e-9), "\(scale) placeR")
      #expect(stageNear(l.placeRadius!, placeRadius, 1e-9), "\(scale) placeRadius")
      #expect(stageNear(l.darkPlanetRadius!, dark, 1e-9), "\(scale) dark planet")
    }
  }

  @Test func ninePanelsAndTheSideCaps() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 9)
    #expect(stageNear(l.side, 160) && stageNear(l.radius, 296) && stageNear(l.placeR!, 22))
    #expect(stageNear(l.placeRadius!, 103.6) && stageNear(l.darkPlanetRadius!, 77.6))
    #expect(stageNear(l.panelCenters[1], 690.2651324672156, 173.2508448367825, 1e-9))
    #expect(stageNear(l.placeCenters[2], 602.0260832120648, 417.989951206294, 1e-9))
    // xl: 160 * 2.4 = 384 < maxSide 520; 9 panels at s: 160 * 0.45 = 72
    #expect(
      stageNear(
        StagePanelLayout.layoutRing(width: 1000, height: 800, count: 9, scale: .xl).side, 384))
    #expect(
      stageNear(StagePanelLayout.layoutRing(width: 1000, height: 800, count: 9, scale: .s).side, 72)
    )
    // the floor: 60, and the cap: 65% of the short side
    #expect(
      stageNear(StagePanelLayout.layoutRing(width: 200, height: 200, count: 9, scale: .s).side, 60))
    #expect(
      stageNear(
        StagePanelLayout.layoutRing(width: 1000, height: 800, count: 2, scale: .xl).side, 520))
  }

  @Test func theMetaNetIsDrawnFor2To16PanelsOnly() {
    for n in 2...16 {
      #expect(StagePanelLayout.layoutRing(width: 1000, height: 800, count: n).showsMeta, "n=\(n)")
    }
    let l17 = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 17)
    #expect(!l17.showsMeta && l17.hasRing && l17.panelCenters.count == 17)
    #expect(stageNear(l17.side, 160) && stageNear(l17.panelCenters[0], 500, 104))
  }

  @Test func panelsStartAtTwelveOClockAndGoClockwise() {
    let l = StagePanelLayout.layoutRing(width: 1000, height: 1000, count: 4)
    #expect(stageNear(l.panelCenters[0].x, 500) && l.panelCenters[0].y < 500)
    #expect(l.panelCenters[1].x > 500 && stageNear(l.panelCenters[1].y, 500))
  }
}

struct StageEligibilityTests {
  typealias D = StagePanelLayout.NetDesc

  @Test func controlAndEmptyNetsGetNoPanel() {
    let nets = [
      D(id: "kick", deck: "A", channel: 10),
      D(id: "struct-kick", deck: "A", role: "control"),
      D(id: "hollow", deck: "A", placeCount: 0),
      D(id: "no-transitions", deck: "A", transitionCount: 0),
    ]
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/kick"])
  }

  @Test func hitNetsGetAPanelOnlyWhileUnmuted() {
    let nets = [
      D(id: "hit1", deck: "A", channel: 20, muted: true),
      D(id: "hit2", deck: "A", channel: 21, muted: false),
      D(id: "hat", deck: "A", channel: 12),
    ]
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/hat", "A/hit2"])
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: true) == ["A/hat", "A/hit2"])
  }

  @Test func aMutedPanelStaysInTheRing() {
    let nets = [
      D(id: "bass", deck: "A", channel: 6, muted: true), D(id: "kick", deck: "A", channel: 10),
    ]
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/bass", "A/kick"])
  }

  @Test func riffVariantsCollapseToTheUnmutedOne() {
    let nets = [
      D(id: "bass-0", deck: "A", riffGroup: "bass", channel: 6, muted: true),
      D(id: "bass-1", deck: "A", riffGroup: "bass", channel: 6, muted: false),
      D(id: "bass-2", deck: "A", riffGroup: "bass", channel: 6, muted: false),
      D(id: "kick", deck: "A", channel: 10),
    ]
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/bass-1", "A/kick"])
  }

  @Test func ifEveryVariantIsMutedTheFirstShows() {
    let nets = [
      D(id: "bass-0", deck: "A", riffGroup: "bass", channel: 6, muted: true),
      D(id: "bass-1", deck: "A", riffGroup: "bass", channel: 6, muted: true),
    ]
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/bass-0"])
  }

  @Test func expandingShowsEveryVariantInChannelOrderThenSpreadsThem() {
    let nets = [
      D(id: "kick-0", deck: "A", riffGroup: "kick", channel: 10),
      D(id: "kick-1", deck: "A", riffGroup: "kick", channel: 10, muted: true),
      D(id: "snare", deck: "A", channel: 11),
      D(id: "hit2", deck: "A", channel: 21),
    ]
    // sorted: kick-0, kick-1, snare, hit2; n = 4 -> [0, 3, 2, 1]
    #expect(
      StagePanelLayout.eligibleKeys(nets, expandVariants: true)
        == ["A/kick-0", "A/hit2", "A/snare", "A/kick-1"])
  }

  @Test func sortedByChannelStably() {
    let nets = [
      D(id: "a", deck: "A", channel: 5), D(id: "b", deck: "A", channel: 5),
      D(id: "c", deck: "A", channel: 1),
    ]
    // fewer than four: no spreading, just the sort
    #expect(StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/c", "A/a", "A/b"])
  }

  @Test func theRingOrderIsTheChannelSortSpreadByTheStride() {
    // the techno `standard` song: melody 4, bass 6, harmony 7, kick 10, snare 11, hihat 12
    let nets = [
      D(id: "snare", deck: "A", channel: 11), D(id: "harmony", deck: "A", channel: 7),
      D(id: "kick", deck: "A", channel: 10), D(id: "hihat", deck: "A", channel: 12),
      D(id: "bass", deck: "A", channel: 6), D(id: "melody", deck: "A", channel: 4),
    ]
    // n = 6, stride 5: out[(i * 5) % 6] = sorted[i]
    #expect(
      StagePanelLayout.eligibleKeys(nets, expandVariants: false)
        == ["A/melody", "A/hihat", "A/snare", "A/kick", "A/harmony", "A/bass"])
  }

  @Test func riffGroupsLiveInTheirDecksNamespace() {
    let nets = [
      D(id: "bass-0", deck: "A", riffGroup: "bass", channel: 6),
      D(id: "bass-0", deck: "B", riffGroup: "bass", channel: 6),
    ]
    #expect(
      StagePanelLayout.eligibleKeys(nets, expandVariants: false) == ["A/bass-0", "B/bass-0"],
      "two decks' bass are two panels")
  }

  @Test func theSlotFlipFollowsTheUnmutedVariant() {
    let nets = [
      D(id: "bass-0", deck: "A", riffGroup: "bass", muted: true),
      D(id: "bass-1", deck: "A", riffGroup: "bass"),
      D(id: "bass-2", deck: "A", riffGroup: "bass"),
      D(id: "bass-0", deck: "B", riffGroup: "bass"),
    ]
    func swap(_ on: String, group: String = "bass", deck: String = "A", expand: Bool = false)
      -> String?
    {
      StagePanelLayout.variantSwap(
        panelNetId: on, riffGroup: group, deck: deck, nets: nets, expandVariants: expand)
    }
    #expect(swap("bass-0") == "bass-1", "A -> B at a section boundary: the first unmuted")
    #expect(swap("bass-1") == nil, "already showing it")
    #expect(swap("bass-2") == "bass-1", "shows the FIRST unmuted of the group")
    #expect(swap("bass-0", expand: true) == nil, "expanded: each variant owns a panel")
    #expect(swap("kick", group: "") == nil, "no riff group, no flip")
    #expect(swap("bass-0", deck: "B") == nil, "deck B's bass-0 is itself unmuted")
    let allMuted = nets.map { n -> D in
      var m = n
      m.muted = true
      return m
    }
    #expect(
      StagePanelLayout.variantSwap(
        panelNetId: "bass-1", riffGroup: "bass", deck: "A", nets: allMuted, expandVariants: false)
        == nil, "nothing active: keep what is shown")
  }
}

struct StagePanelViewTests {
  @Test func aBigNetShrinksToFitItsBox() {
    let v = StagePanelView.fit(
      bounds: StageBounds(minX: 0, minY: 0, maxX: 300, maxY: 300), width: 120, height: 120)
    // netW = 300 + 80, scale = 120 / 380 (hand computed)
    #expect(stageNear(v.scale, 120.0 / 380.0))
    #expect(stageNear(v.cx, 150) && stageNear(v.cy, 150))
    #expect(stageNear(v.tx, 60 - 150 * 120.0 / 380.0) && stageNear(v.ty, v.tx))
    // the centre of the net is the centre of the box, whatever the turn
    for angle in [0.0, 37, 90, -123, 360] {
      #expect(stageNear(v.apply(x: 150, y: 150, angleDegrees: angle), 60, 60), "angle \(angle)")
    }
  }

  @Test func aSmallNetIsNeverScaledUp() {
    let v = StagePanelView.fit(
      bounds: StageBounds(minX: 0, minY: 0, maxX: 100, maxY: 100), width: 600, height: 600)
    #expect(v.scale == 1)  // min(1, 600 / 180)
    #expect(stageNear(v.tx, 250) && stageNear(v.ty, 250))  // 300 - 50
  }

  @Test func theBoxIsFlooredAt120() {
    #expect(StagePanelView.contentSize(side: 60) == 120)
    #expect(StagePanelView.contentSize(side: 119.9) == 120)
    #expect(StagePanelView.contentSize(side: 300) == 300)
  }

  @Test func applyTurnsTheNetAboutItsBoxCentreThenScalesAndShifts() {
    let v = StagePanelView.fit(
      bounds: StageBounds(minX: 0, minY: 0, maxX: 300, maxY: 300), width: 120, height: 120)
    let s = 120.0 / 380.0
    let t = 60 - 150 * s
    // angle 0: plain scale and shift
    #expect(stageNear(v.apply(x: 300, y: 150, angleDegrees: 0), 300 * s + t, 150 * s + t))
    // angle 90: (dx, dy) = (150, 0) -> (0, 150): the point swings from east to south (y is down)
    #expect(stageNear(v.apply(x: 300, y: 150, angleDegrees: 90), 150 * s + t, 300 * s + t, 1e-9))
    // angle 180: to the west
    #expect(stageNear(v.apply(x: 300, y: 150, angleDegrees: 180), 0 * s + t, 150 * s + t, 1e-9))
  }

  func panel(angle: Double) -> StagePanel {
    let shape = StageNetShape(
      netId: "n", placeIds: ["p0", "p1"], placeX: [0, 100], placeY: [0, 0],
      transitionIds: ["t0", "t1"], transitionX: [50, 50], transitionY: [0, 100])
    let view = StagePanelView.fit(bounds: shape.bounds!, width: 120, height: 120)
    return StagePanel(
      id: "A/n", deck: "A", netId: "n", label: "n", channel: 1, riffGroup: "",
      center: StagePoint(x: 200, y: 300), ring: StagePoint(x: 200, y: 300), side: 100,
      angle: angle, view: view, muted: false, opacity: 1, shape: shape, tokens: [0, 0],
      firedAt: [-.infinity, -.infinity])
  }

  @Test func nodeCenterInStageReplaysTheAffine() {
    // box: side 100 centred (200, 300) -> origin (150, 250); content 120; net 100 x 100:
    // netW = 180, scale = 120 / 180 = 2/3, tx = 60 - 50 * 2/3
    let p = panel(angle: 0)
    #expect(p.origin == StagePoint(x: 150, y: 250))
    let t = 60 - 50 * (2.0 / 3.0)
    #expect(
      stageNear(
        p.nodeCenterInStage(transition: 1)!, 150 + 50 * (2.0 / 3.0) + t, 250 + 100 * (2.0 / 3.0) + t
      ))
    #expect(
      stageNear(p.nodeCenterInStage(transitionId: "t0")!, 150 + 50 * (2.0 / 3.0) + t, 250 + t))
    // turned by 180 degrees: (50, 100) swings to (50, 0)
    let q = panel(angle: 180)
    #expect(
      stageNear(q.nodeCenterInStage(transition: 1)!, 150 + 50 * (2.0 / 3.0) + t, 250 + 0 + t, 1e-9))
    #expect(p.nodeCenterInStage(transition: 2) == nil)
    #expect(p.nodeCenterInStage(transitionId: "nope") == nil)
  }

  @Test func aNetWithoutPlacesOrTransitionsHasNoBox() {
    let empty = StageNetShape(
      netId: "e", placeIds: [], placeX: [], placeY: [], transitionIds: [], transitionX: [],
      transitionY: [])
    #expect(empty.bounds == nil)
  }

  @Test func theFlashLastsAHundredMillisecondsOfAudioTime() {
    var p = panel(angle: 0)
    p.firedAt = [10.0, -.infinity]
    #expect(stageNear(p.flash(transition: 0, now: 10.0), 1))
    #expect(stageNear(p.flash(transition: 0, now: 10.05), 0.5))
    #expect(p.flash(transition: 0, now: 10.1) == 0)
    #expect(p.flash(transition: 0, now: 10.3) == 0)
    #expect(p.flash(transition: 0, now: 9.9) == 0, "a fire in the future is not lit yet")
    #expect(p.flash(transition: 1, now: 10.0) == 0, "never fired")
    #expect(p.flash(transition: 7, now: 10.0) == 0)
  }

  @Test func theLitNodePulsesInScale() {
    var p = panel(angle: 0)
    p.firedAt = [10.0, -.infinity]
    #expect(stageNear(p.pulseScale(transition: 0, now: 10.0), 1))
    #expect(stageNear(p.pulseScale(transition: 0, now: 10.05), 1.1))  // keyframe 50%
    #expect(stageNear(p.pulseScale(transition: 0, now: 10.1), 1))  // over
    // a quarter of the way: 1 + 0.1 * ease-out(0.5)
    #expect(stageNear(p.pulseScale(transition: 0, now: 10.025), 1 + 0.1 * 0.6846431874274606, 1e-9))
    #expect(
      stageNear(p.pulseScale(transition: 0, now: 10.075), 1.1 - 0.1 * 0.6846431874274606, 1e-9))
    #expect(p.pulseScale(transition: 1, now: 10.0) == 1)
  }
}

struct StageFadeAndPacerTests {
  @Test func easeMatchesTheCSSCurves() {
    #expect(StageFade.ease(0) == 0 && StageFade.ease(1) == 1)
    #expect(stageNear(StageFade.ease(0.5), 0.802403387584857, 1e-9))
    #expect(stageNear(StageFade.ease(0.25), 0.40851059135539586, 1e-9))
    #expect(stageNear(StageFade.easeOut(0.5), 0.6846431874274606, 1e-9))
    #expect(stageNear(StageFade.easeOut(0.25), 0.37813813082510966, 1e-9))
    #expect(stageNear(StageFade.easeOut(0.75), 0.9065353492811752, 1e-9))
  }

  @Test func aMutedPanelDimsOver280Milliseconds() {
    var f = StageFade()
    #expect(f.value == 1 && f.isSettled)
    f.retarget(StageFade.mutedOpacity)
    #expect(!f.isSettled && f.value == 1)
    f.advance(dt: 0.14)  // half way in time: ease(0.5)
    #expect(stageNear(f.value, 1 - 0.75 * 0.802403387584857, 1e-9))
    f.advance(dt: 0.14)
    #expect(stageNear(f.value, 0.25) && f.isSettled)
    f.retarget(0.25)  // same target: nothing restarts
    #expect(f.isSettled)
    f.retarget(1)
    f.advance(dt: 0.5)
    #expect(stageNear(f.value, 1))
  }

  @Test func aNewTargetMidFadeStartsFromWhereItIs() {
    var f = StageFade()
    f.retarget(0.25)
    f.advance(dt: 0.14)
    let mid = f.value
    f.retarget(1)
    #expect(f.value == mid, "no jump")
    f.advance(dt: 0.0)
    #expect(f.value == mid)
    f.advance(dt: 0.28)
    #expect(stageNear(f.value, 1))
  }

  @Test func theStagePacerHasItsOwnCaps() {
    #expect(StageFramePacer.minIntervals == [0, 1.0 / 30, 1.0 / 15, 1.0 / 4])
    #expect(StageFramePacer.minInterval(level: 0) == 0)
    #expect(StageFramePacer.minInterval(level: 3) == 0.25)
    #expect(StageFramePacer.minInterval(level: 9) == 0.25, "clamped, like Math.min(3, ...)")
    #expect(StageFramePacer.minInterval(level: -1) == 0)
    #expect(
      StageFramePacer.showsFireEffects(level: 0) && StageFramePacer.showsFireEffects(level: 1))
    #expect(
      !StageFramePacer.showsFireEffects(level: 2) && !StageFramePacer.showsFireEffects(level: 3))
  }
}

struct StageProjectionTests {
  @Test func spinIsRotateZAboutTheCentre() {
    let p = StageProjection.spin(90)
    #expect(p.isPlanar)
    let c = p.project(x: 600, y: 400, centerX: 500, centerY: 400)!
    #expect(stageNear(c, 500, 500, 1e-9), "+x swings to +y: clockwise on a y-down screen")
    #expect(stageNear(p.project(x: 500, y: 400, centerX: 500, centerY: 400)!, 500, 400))
    let q = StageProjection.spin(0).project(x: 123, y: 45, centerX: 500, centerY: 400)!
    #expect(stageNear(q, 123, 45))
  }

  @Test func theTiltMatrixHasTheCSSPerspectiveEntry() {
    let m = StageProjection(perspective: 1400).matrix(centerX: 0, centerY: 0)
    #expect(stageNear(m[14], -1.0 / 1400), "m34 = -1/d (row 3, column 2)")
    #expect(m[0] == 1 && m[5] == 1 && m[10] == 1 && m[15] == 1)
    #expect(!StageProjection(perspective: 1400).isPlanar)
    #expect(!StageProjection(rotateX: 10).isPlanar)
  }

  @Test func rotateYMovesAPointOnThePlusXAxisAsTheCSSDefinitionSays() {
    // perspective(1400) rotateY(30) about (0, 0): (100, 0, 0) -> x = 100 cos 30, z = -100 sin 30,
    // w = 1 - z / 1400; node: 83.61624588263545
    let p = StageProjection(rotateY: 30, perspective: 1400).project(
      x: 100, y: 0, centerX: 0, centerY: 0)!
    #expect(stageNear(p, 83.61624588263545, 0, 1e-9))
  }

  @Test func rotateXMovesAPointOnThePlusYAxisAsTheCSSDefinitionSays() {
    let p = StageProjection(rotateX: 20, perspective: 1400).project(
      x: 0, y: 100, centerX: 0, centerY: 0)!
    #expect(stageNear(p, 0, 96.32241977991966, 1e-9))
  }

  @Test func theCentreStaysPutUnderAnyTilt() {
    let p = StageProjection.tilt(rotateX: 18, rotateY: -22, rotateZ: 133)
    #expect(stageNear(p.project(x: 500, y: 400, centerX: 500, centerY: 400)!, 500, 400, 1e-9))
  }

  @Test func theFullStringComposesInCSSOrder() {
    // perspective(1400) rotateX(18) rotateY(22) rotateZ(40) about (0, 0) on (100, 50): rotateZ
    // acts on the point first (node: 41.69961509488882, 103.88426229585049).
    let p = StageProjection.tilt(rotateX: 18, rotateY: 22, rotateZ: 40).project(
      x: 100, y: 50, centerX: 0, centerY: 0)!
    #expect(stageNear(p, 41.69961509488882, 103.88426229585049, 1e-9))
  }

  @Test func aPointBehindTheViewerIsNotProjected() {
    // perspective 100: a point rotated to z = 150 has w = 1 - 1.5 < 0
    let p = StageProjection(rotateX: 90, perspective: 100).project(
      x: 0, y: 150, centerX: 0, centerY: 0)
    #expect(p == nil)
  }
}

struct StageArcArrowTests {
  @Test func theArcArrowheadSitsTwentyFiveBackFromTheTarget() {
    let h = StageArcArrow.head(x1: 0, y1: 0, x2: 100, y2: 0)
    #expect(stageNear(h.tipX, 75) && stageNear(h.tipY, 0))
    #expect(stageNear(h.leftX, 75 - 12 * 0.8660254037844387) && stageNear(h.leftY, 6))
    #expect(stageNear(h.rightX, 75 - 12 * 0.8660254037844387) && stageNear(h.rightY, -6))
    let down = StageArcArrow.head(x1: 0, y1: 0, x2: 0, y2: 100)
    #expect(stageNear(down.tipX, 0, 1e-9) && stageNear(down.tipY, 75))
  }
}
