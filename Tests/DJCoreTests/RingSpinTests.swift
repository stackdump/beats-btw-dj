import Testing

@testable import DJCore

// SPEC mode 22: the arithmetic of the main ring's extras. Expected values are worked out from
// the pinned JS (runtime.js `autoDjSpin` / `autoDjSpinAnimate`, canvas.js `drawRing`).

struct RingSpinTests {
  func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

  @Test func easingIsACubicEaseOut() {
    #expect(RingSpin.eased(0) == 0)
    #expect(near(RingSpin.eased(0.25), 0.578125))  // 1 - 0.75^3
    #expect(near(RingSpin.eased(0.5), 0.875))  // 1 - 0.5^3
    #expect(RingSpin.eased(1) == 1)
    #expect(RingSpin.eased(-3) == 0 && RingSpin.eased(7) == 1, "t is clamped")
  }

  @Test func aRingThatNeverSpunSitsAtZero() {
    let s = RingSpin()
    #expect(s.angle(at: 0) == 0 && s.angle(at: 1e9) == 0)
    #expect(!s.isSpinning(at: 5) && !s.reverseArrows)
  }

  @Test func theFirstSpinSwingsNinetyDegreesInEightHundredMilliseconds() {
    var s = RingSpin()
    s.spin(at: 10)
    #expect(s.angle(at: 10) == 0, "t = 0")
    #expect(near(s.angle(at: 10.2), 90 * 0.578125), "a quarter of the way in time")
    #expect(near(s.angle(at: 10.4), 78.75), "t = 0.5: 90 * 0.875")
    #expect(near(s.angle(at: 10.8), 90), "t = 1")
    #expect(s.angle(at: 11) == 90 && s.angle(at: 600) == 90, "and it stays")
    #expect(s.angle(at: 9.5) == 0, "before the start it has not moved")
    #expect(s.isSpinning(at: 10.79) && !s.isSpinning(at: 10.8))
  }

  @Test func directionAlternatesBetweenSpinsAndTheArrowsFollow() {
    var s = RingSpin()
    s.spin(at: 0)
    #expect(s.targetAngle == 90 && !s.reverseArrows, "dir +1: arrows forward")
    s.spin(at: 5)
    #expect(s.targetAngle == 0 && s.reverseArrows, "dir -1: back to 0, arrows reversed")
    s.spin(at: 10)
    #expect(s.targetAngle == 90 && !s.reverseArrows)
  }

  @Test func stepsScaleTheSwingAndZeroDoesNothing() {
    var s = RingSpin()
    s.spin(steps: 0, at: 1)
    #expect(s.targetAngle == 0 && s.angle(at: 2) == 0, "autoDjSpin returns for steps <= 0")
    s.spin(steps: 3, at: 1)
    #expect(s.targetAngle == 270)
    #expect(near(s.angle(at: 1.8), 270))
  }

  @Test func aSpinDuringASwingContinuesFromWhereItIs() {
    var s = RingSpin()
    s.spin(at: 10)  // 0 -> 90
    s.spin(at: 10.4)  // from 78.75, target 90 - 90 = 0
    #expect(near(s.angle(at: 10.4), 78.75))
    #expect(near(s.angle(at: 10.8), 78.75 * (1 - 0.875)), "t = 0.5 of the second swing")
    #expect(near(s.angle(at: 11.2), 0))
  }

  @Test func theFirstLookOnlyRecordsAndEachHandOverSpinsOnce() {
    var s = RingSpin()
    s.observe(advances: 7, at: 100)
    #expect(s.targetAngle == 0, "a deck already on its eighth track does not swing")
    s.observe(advances: 7, at: 101)
    #expect(s.targetAngle == 0)
    s.observe(advances: 8, at: 102)
    #expect(s.targetAngle == 90 && s.isSpinning(at: 102.1))
    s.observe(advances: 8, at: 103)
    #expect(s.targetAngle == 90, "same count again: nothing")
    s.observe(advances: 9, at: 104)
    #expect(s.targetAngle == 0)
  }

  @Test func theArcLayerDimsWhilePlaying() {
    let stopped = RingArcs(playing: false)
    let playing = RingArcs(playing: true)
    #expect(stopped.alpha == 1 && playing.alpha == 0.3)
    #expect(stopped.lineWidth() == 2 && playing.lineWidth() == 1)
    #expect(stopped.lineWidth(scale: 0.5) == 4, "(playing ? 1 : 2) / scale")
    #expect(playing.lineWidth(scale: 0.25) == 4)
    #expect(RingArcs.strokeHex == "#4a90d9")
  }

  @Test func arcsCarryTheSpinForAFrame() {
    var s = RingSpin()
    s.spin(at: 0)
    let a = s.arcs(playing: true, at: 0.4)
    #expect(a.playing && !a.reverseArrows && near(a.angleDegrees, 78.75))
    s.spin(at: 2)
    #expect(s.arcs(playing: false, at: 2).reverseArrows)
  }

  @Test func thePlayheadIsTheBeatsGoldWithItsTwoGlows() {
    #expect(RingPlayhead.hex == "#ffd36a")
    #expect(RingPlayhead.rgb8 == (255, 211, 106))
    #expect(RingPlayhead.outerGlowAlpha == 0.7 && RingPlayhead.innerGlowAlpha == 0.35)
  }

  /// The CSS node is 40 px with a 3 px border and glows of 6 px and 4 px; the ring's radius
  /// stands for the box's 20 px half side. So the border is 3/20 of the radius, the glow's
  /// SwiftUI radius (a sigma: half the CSS blur) is 3/20, the inner ramp 4/20 - whatever the
  /// dot size, until a size reaches its one-point floor.
  @Test func thePlayheadSizesAreTheCSSOnesInTheRingsOwnUnits() {
    for base in [4.0, 4.5, 5.0] {  // above the one-point floors
      let r = RingPlayhead.radius(base: base)
      #expect(near(RingPlayhead.lineWidth(base: base) / r, 3.0 / 20), "border 3 px of 20")
      #expect(
        near(RingPlayhead.outerGlowRadius(base: base) / r, 3.0 / 20), "blur 6 px = sigma 3 px")
      #expect(near(RingPlayhead.innerGlowRadius(base: base) / r, 4.0 / 20), "inset blur 4 px")
    }
    // the largest dot (base 5): a 19 pt ring, 0.475 pt to the CSS px
    #expect(near(RingPlayhead.pointsPerPx(base: 5), 0.475))
    #expect(near(RingPlayhead.lineWidth(base: 5), 1.425))
  }

  @Test func thePlayheadSizesNeverFallBelowOnePoint() {
    // a 64-step ring: base 1.5, where 3 px of the CSS node would be 0.43 pt
    #expect(RingPlayhead.lineWidth(base: 1.5) == 1)
    #expect(RingPlayhead.outerGlowRadius(base: 1.5) == 1)
    #expect(RingPlayhead.innerGlowRadius(base: 1.5) == 1)
  }

  @Test func anArrowheadIsDrawnOnlyWhereItFitsBetweenTheDots() {
    // 8 steps in a 66 pt square: chord 2 * 27 * sin(pi/8) = 20.66, dots of 5
    let c8 = 2 * 27 * 0.3826834323650898  // sin(pi/8)
    #expect(near(RingArcs.headLength(chord: c8, base: 5) ?? -1, 4), "wings of min(0.35 chord, 4)")
    // 16 steps in a 66 pt square: chord 10.5, dots of 3.7: tip set-backs and wing don't fit
    let c16 = 2 * 27 * 0.19509032201612825  // sin(pi/16)
    #expect(RingArcs.headLength(chord: c16, base: 3.7) == nil)
    // 16 steps in 130 pt: chord 23, dots of 5: 14 + 4 = 18 fits
    let big = 2 * 59 * 0.19509032201612825
    #expect(RingArcs.headLength(chord: big, base: 5) != nil)
    // a short chord that would fit a head shrinks it: 0.35 of 13 is 4.55 -> 4; of 10 is 3.5
    #expect(near(RingArcs.headLength(chord: 10, base: 1.5) ?? -1, 3.5))
    #expect(RingArcs.headLength(chord: 0, base: 1.5) == nil)
  }

  @Test func theArrowheadIsJSDrawArrowheadScaledToTheRing() {
    #expect(near(RingArcs.wingAngle, Double.pi / 6), "+-30 degrees")
    #expect(near(RingArcs.tipSetBack(base: 5), 7), "the tip stops one dot radius (1.4 base) short")
  }
}

@MainActor
struct DeckAdvanceCountTests {
  @Test func everyHandOverToTheNextTrackCountsOnce() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    dj.deterministic = true  // queueNext composes inline
    let a = try #require(dj["A"])
    a.loadNet(PreparedTrack(spec: TrackSpec(genre: "techno", seed: 1), sampleRate: 22_050))
    #expect(a.advances == 0)
    #expect(!a.advanceToNext() && a.advances == 0, "nothing queued: no hand-over, no count")
    a.queueNext(TrackSpec(genre: "house", seed: 2, structure: "minimal"))
    #expect(a.advanceToNext() && a.advances == 1)
    a.queueNext(TrackSpec(genre: "dnb", seed: 3))
    a.skipToNextTrack()  // the Next button runs inline in deterministic mode
    #expect(a.advances == 2)
    #expect(a.currentSpec?.genre == "dnb")
    // loading a track outright is not a hand-over
    a.loadNet(PreparedTrack(spec: TrackSpec(genre: "lofi", seed: 4), sampleRate: 22_050))
    #expect(a.advances == 2)
  }
}
