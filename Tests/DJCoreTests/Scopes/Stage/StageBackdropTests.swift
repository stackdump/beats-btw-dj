import Testing

@testable import DJCore

// The numbers of the stage backgrounds (SPEC mode 18): the generators, the twinkle, the ring and
// gradient geometry, the aurora table. Literals marked "(node)" were computed by running the
// pinned stage.js expressions in node.

struct StageBackdropTests {
  private func colorNear(_ a: ScopeColor?, _ b: ScopeColor, _ tol: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return stageNear(a.r, b.r, tol) && stageNear(a.g, b.g, tol) && stageNear(a.b, b.b, tol)
      && stageNear(a.a, b.a, tol)
  }

  // MARK: stars

  @Test func theStarfieldIs150StarsInTheRangesOfSpawnStars() {
    let stars = StageBackdrop.makeStars(random: backdropRandom(seed: 3))
    #expect(stars.count == 150 && StageBackdrop.starCount == 150)
    for s in stars {
      #expect(s.x >= 0 && s.x < 1 && s.y >= 0 && s.y < 1)
      #expect(s.size >= 0.6 && s.size < 2.0)
      #expect(s.bright >= 0.25 && s.bright < 0.80)
      #expect(s.twinkleRate >= 0.3 && s.twinkleRate < 1.4)
      #expect(s.phase >= 0 && s.phase < Double.pi * 2)
    }
    // a real spread, not 150 copies
    #expect(Set(stars.map(\.x)).count == 150)
    #expect(stars.map(\.x).min()! < 0.1 && stars.map(\.x).max()! > 0.9)
  }

  @Test func starsDrawTheirSixNumbersInTheOrderOfTheJS() {
    // x, y, size, bright, rate, phase, per star, star after star
    let script = BackdropScript([
      0.1, 0.2, 0.5, 0.5, 0.5, 0.25, 0.9, 0.8, 0.0, 1.0 - 1e-9, 0.0, 0.5,
    ])
    let stars = StageBackdrop.makeStars(random: script.next)
    #expect(script.calls == 150 * 6)
    let a = stars[0]
    #expect(stageNear(a.x, 0.1) && stageNear(a.y, 0.2))
    #expect(stageNear(a.size, 0.6 + 0.5 * 1.4) && stageNear(a.bright, 0.25 + 0.5 * 0.55))
    #expect(stageNear(a.twinkleRate, 0.3 + 0.5 * 1.1) && stageNear(a.phase, 0.25 * Double.pi * 2))
    let b = stars[1]
    #expect(stageNear(b.x, 0.9) && stageNear(b.y, 0.8) && stageNear(b.size, 0.6))
    #expect(stageNear(b.bright, 0.25 + 0.55, 1e-6) && stageNear(b.twinkleRate, 0.3))
    #expect(stageNear(b.phase, 0.5 * Double.pi * 2))
  }

  @Test func theStarfieldIsDeterministicForASeedAndDiffersAcrossSeeds() {
    let a = StageBackdrop.makeStars(random: backdropRandom(seed: 11))
    let b = StageBackdrop.makeStars(random: backdropRandom(seed: 11))
    let c = StageBackdrop.makeStars(random: backdropRandom(seed: 12))
    #expect(a == b)
    #expect(a != c)
    #expect(
      StageBackdrop.makePlanets(random: backdropRandom(seed: 11))
        == StageBackdrop.makePlanets(random: backdropRandom(seed: 11)))
  }

  @Test func theStarsAreRgba210220250() {
    // `rgba(210, 220, 250, alpha)`: pinned by its literal, not by the constant the renderer reads
    let c = StageBackdrop.starColor.rgb8
    #expect(c.r == 210 && c.g == 220 && c.b == 250)
    #expect(StageBackdrop.starColor == ScopeColor(r8: 210, g8: 220, b8: 250))
    #expect(StageBackdrop.starColor.a == 1)
  }

  @Test func twinklingIsPointFiveFivePlusPointFortyFiveSine() {
    let s = StageStar(x: 0.5, y: 0.5, size: 1, bright: 0.6, twinkleRate: 0.9, phase: 1.1)
    // (node) 0.55 + 0.45 * Math.sin(3.7 * 0.9 + 1.1) and (0.6 * that).toFixed(3)
    #expect(stageNear(s.twinkle(at: 3.7), 0.11782338029400552))
    #expect(stageNear(s.alpha(at: 3.7), 0.071))
    // at the sine's extremes the star is at its brightest (1.0 x bright) and dimmest (0.1 x bright)
    let peak = (Double.pi / 2 - 1.1) / 0.9
    #expect(stageNear(s.twinkle(at: peak), 1.0) && stageNear(s.alpha(at: peak), 0.6))
    let trough = (3 * Double.pi / 2 - 1.1) / 0.9
    #expect(stageNear(s.twinkle(at: trough), 0.1) && stageNear(s.alpha(at: trough), 0.06))
    // at t = 0 the phase alone decides
    #expect(stageNear(s.twinkle(at: 0), 0.55 + 0.45 * bdSin(1.1)))
  }

  // MARK: planets

  @Test func planetsAreTwoOrThreeInDistinctCornerSlotsWithinTheRanges() {
    var counts: Set<Int> = []
    var slotsUsed: Set<Int> = []
    var palettesUsed: Set<Int> = []
    var signs: Set<Bool> = []
    for seed in 0..<300 {
      let planets = StageBackdrop.makePlanets(random: backdropRandom(seed: UInt64(seed)))
      counts.insert(planets.count)
      #expect((2...3).contains(planets.count))
      #expect(Set(planets.map(\.slot)).count == planets.count, "distinct slots")
      for p in planets {
        slotsUsed.insert(p.slot)
        let slot = StageBackdrop.planetSlots[p.slot]
        #expect(bdAbs(p.x - slot.x) <= 0.025 + 1e-12 && bdAbs(p.y - slot.y) <= 0.025 + 1e-12)
        #expect(p.r >= 22 && p.r < 48)
        #expect(p.ringRatio >= 1.8 && p.ringRatio < 2.4)
        #expect(p.ringWidth >= 0.18 && p.ringWidth < 0.30)
        #expect(p.tilt >= 0 && p.tilt < Double.pi)
        #expect(bdAbs(p.tiltRate) >= 0.03 && bdAbs(p.tiltRate) < 0.07)
        signs.insert(p.tiltRate < 0)
        let k = StageBackdrop.planetPalette.firstIndex { $0.body == p.body }
        #expect(k != nil && StageBackdrop.planetPalette[k!].ring == p.ring)
        palettesUsed.insert(k ?? -1)
      }
    }
    #expect(counts == [2, 3], "both counts occur")
    #expect(slotsUsed == [0, 1, 2, 3], "every slot gets used")
    #expect(palettesUsed == [0, 1, 2, 3])
    #expect(signs == [true, false], "rings turn both ways")
  }

  @Test func theSlotsAndPaletteAreTheOnesInTheJS() {
    #expect(StageBackdrop.planetSlots.count == 4)
    let slots = StageBackdrop.planetSlots.map { [$0.x, $0.y] }
    #expect(slots == [[0.12, 0.18], [0.88, 0.22], [0.18, 0.82], [0.84, 0.78]])
    let bodies = StageBackdrop.planetPalette.map(\.body)
    #expect(
      bodies == [
        ScopeColor(r8: 0x5a, g8: 0x3e, b8: 0x8c), ScopeColor(r8: 0x3e, g8: 0x5a, b8: 0x8c),
        ScopeColor(r8: 0x8c, g8: 0x5a, b8: 0x3e), ScopeColor(r8: 0x3e, g8: 0x8c, b8: 0x6d),
      ])
    let rings = StageBackdrop.planetPalette.map(\.ring)
    #expect(
      rings == [
        ScopeColor(r8: 200, g8: 180, b8: 240), ScopeColor(r8: 170, g8: 200, b8: 240),
        ScopeColor(r8: 240, g8: 200, b8: 170), ScopeColor(r8: 170, g8: 240, b8: 210),
      ])
  }

  @Test func planetsDrawTheirNumbersInTheOrderOfTheJS() {
    // shuffle: 0, 0, 0 swaps the last slot in turn to the front: [1, 2, 3, 0]
    // then the count (0.2: two), then nine numbers per planet
    let script = BackdropScript(
      [
        0, 0, 0,
        0.2,
        // planet 0: palette, x, y, r, ratio, width, tilt, sign, rate
        0.3, 0.75, 0.25, 0.5, 0.5, 0.5, 0.5, 0.25, 0.5,
        // planet 1: everything at the middle
        0.5,
      ])
    let planets = StageBackdrop.makePlanets(random: script.next)
    #expect(script.calls == 3 + 1 + 2 * 9)
    #expect(planets.count == 2)
    let a = planets[0]
    #expect(a.slot == 1)
    #expect(a.body == StageBackdrop.planetPalette[1].body)  // floor(0.3 * 4)
    #expect(stageNear(a.x, 0.88 + 0.25 * 0.05) && stageNear(a.y, 0.22 - 0.25 * 0.05))
    #expect(stageNear(a.r, 35) && stageNear(a.ringRatio, 2.1) && stageNear(a.ringWidth, 0.24))
    #expect(stageNear(a.tilt, Double.pi / 2))
    #expect(stageNear(a.tiltRate, -0.05), "0.25 < 0.5: counter-clockwise")
    let b = planets[1]
    #expect(b.slot == 2)
    #expect(b.body == StageBackdrop.planetPalette[2].body)  // floor(0.5 * 4)
    #expect(stageNear(b.x, 0.18) && stageNear(b.y, 0.82))
    #expect(stageNear(b.tiltRate, 0.05), "0.5 is not < 0.5: clockwise")
  }

  @Test func aThirdPlanetComesWhenTheCountDrawIsHalfOrMore() {
    let script = BackdropScript([0, 0, 0, 0.5, 0.5])
    #expect(StageBackdrop.makePlanets(random: script.next).count == 3)
    #expect(script.calls == 3 + 1 + 3 * 9)
  }

  @Test func theRingIsAFlattenedAnnulusAroundTheBody() {
    let p = StagePlanet(
      x: 0.5, y: 0.5, r: 30, ringRatio: 2, ringWidth: 0.2, tilt: 0.5, tiltRate: -0.04,
      body: StageBackdrop.skyGlow, ring: StageBackdrop.starColor)
    #expect(stageNear(p.ringOuter, 60) && stageNear(p.ringInner, 48))
    #expect(stageNear(p.ringMid, 54) && stageNear(p.ringThickness, 12))
    #expect(stageNear(p.ringY, 54 * 0.22))
    // the slow turn: tilt + t * tiltRate
    #expect(stageNear(p.tilt(at: 0), 0.5) && stageNear(p.tilt(at: 10), 0.5 - 0.4))
    #expect(StagePlanet.backAlpha == 0.18 && StagePlanet.frontAlpha == 0.42)
    #expect(stageNear(p.center(width: 800, height: 600), 400, 300))
  }

  @Test func theRingOutlineIsTheOffsetCurvesOfTheEllipseArcJoinedByButtCaps() {
    let p = StagePlanet(
      x: 0.5, y: 0.5, r: 30, ringRatio: 2, ringWidth: 0.2, tilt: 0, tiltRate: 0,
      body: StageBackdrop.skyGlow, ring: StageBackdrop.starColor)
    // mid 54, ringY 11.88, thickness 12: half a stroke is 6
    let n = 192
    for half in [StagePlanet.RingHalf.back, .front] {
      let o = p.ringOutline(half)
      #expect(o.count == 2 * (n + 1))
      let outer = Array(o[0...n])
      let inner = Array(o[(n + 1)...].reversed())
      let start = half == .back ? Double.pi : 0
      for i in 0...n {
        let a = start + Double.pi * Double(i) / Double(n)
        let centre = StagePoint(x: p.ringMid * bdCos(a), y: p.ringY * bdSin(a))
        // both curves are half a stroke from the ellipse point, on opposite sides of it
        #expect(stageNear(bdHypot(outer[i].x - centre.x, outer[i].y - centre.y), 6, 1e-9))
        #expect(stageNear(bdHypot(inner[i].x - centre.x, inner[i].y - centre.y), 6, 1e-9))
        #expect(stageNear((outer[i].x + inner[i].x) / 2, centre.x, 1e-9))
        #expect(stageNear((outer[i].y + inner[i].y) / 2, centre.y, 1e-9))
      }
    }
    // the front half starts at the right tip (mid, 0) and ends at the left one; the back half
    // starts at the left tip and ends at the right one
    let f = p.ringOutline(.front)
    #expect(stageNear(f[0], 54 + 6, 0) && stageNear(f[n], -54 - 6, 0))
    #expect(stageNear(f[n + 1], -54 + 6, 0) && stageNear(f[2 * n + 1], 54 - 6, 0))
    let b = p.ringOutline(.back)
    #expect(stageNear(b[0], -54 - 6, 0) && stageNear(b[n], 54 + 6, 0))
    // at the apex the outer curve is half a stroke beyond the ellipse's top (front: below)
    #expect(stageNear(f[n / 2], 0, p.ringY + 6) && stageNear(b[n / 2], 0, -p.ringY - 6))
  }

  @Test func theRingOutlineClosesWithCapsSquareToTheTangentAtTheEllipseTips() {
    // A butt cap is square to the curve's tangent where the stroke starts and ends. At the
    // ellipse's tips (+-ringMid, 0) the tangent is vertical, so each cap is a horizontal chord of
    // length `ringThickness` centred on the tip. (A polyline of 96 chords starts 4 degrees off,
    // a flattened cubic more: that was the seam between the halves that the canvas does not have.)
    let p = StagePlanet(
      x: 0.5, y: 0.5, r: 30, ringRatio: 2.3, ringWidth: 0.25, tilt: 1, tiltRate: 0,
      body: StageBackdrop.skyGlow, ring: StageBackdrop.starColor)
    for half in [StagePlanet.RingHalf.back, .front] {
      for segments in [8, 192] {
        let o = p.ringOutline(half, segments: segments)
        let n = segments
        // the start cap joins the last inner point to the first outer one (the polygon closes
        // from its last point to its first), the end cap the last outer point to the first inner
        let startCap = (o[0], o[2 * n + 1])
        let endCap = (o[n], o[n + 1])
        for (a, c) in [startCap, endCap] {
          #expect(stageNear(a.y, 0, 1e-9) && stageNear(c.y, 0, 1e-9), "\(half): cap is level")
          #expect(stageNear(bdAbs(a.x - c.x), p.ringThickness, 1e-9))
        }
        let sign: Double = half == .back ? -1 : 1
        #expect(stageNear((startCap.0.x + startCap.1.x) / 2, sign * p.ringMid, 1e-9))
        #expect(stageNear((endCap.0.x + endCap.1.x) / 2, -sign * p.ringMid, 1e-9))
      }
    }
  }

  @Test func theRingOutlineFoldsOverAtTheTipsWhereTheStrokeIsWiderThanTheCurvatureRadius() {
    // the canvas fills the offset outline as it is; the fold (the inner curve crossing back over
    // itself) is there and is kept, not trimmed away
    let p = StagePlanet(
      x: 0.5, y: 0.5, r: 40, ringRatio: 2, ringWidth: 0.25, tilt: 0, tiltRate: 0,
      body: StageBackdrop.skyGlow, ring: StageBackdrop.starColor)
    // curvature radius at the tip = ringY^2 / ringMid = 3.39; half a stroke = 10
    #expect(p.ringY * p.ringY / p.ringMid < p.ringThickness / 2)
    let o = p.ringOutline(.front)
    let inner = Array(o[193...].reversed())
    // the inner offset starts at the tip's inside (mid - 10, 0), and moves BACK past it: its x
    // goes up before it comes down (a fold), instead of decreasing steadily
    #expect(stageNear(inner[0].x, p.ringMid - 10, 1e-9))
    #expect(inner.dropFirst().prefix(10).contains { $0.x > inner[0].x })
  }

  // MARK: the gradients

  @Test func theBodyIsShadedFromTheUpperLeftToTheSkysDarkest() {
    let p = StagePlanet(
      x: 0.5, y: 0.5, r: 40, ringRatio: 2, ringWidth: 0.2, tilt: 0, tiltRate: 0,
      body: StageBackdrop.planetPalette[0].body, ring: StageBackdrop.starColor)
    let g = p.bodyGradient(width: 800, height: 600)
    // createRadialGradient(cx - 0.35r, cy - 0.35r, 0.1r, cx, cy, r)
    #expect(stageNear(g.start, 400 - 14, 300 - 14) && stageNear(g.startRadius, 4))
    #expect(stageNear(g.end, 400, 300) && stageNear(g.endRadius, 40))
    #expect(g.stops.map(\.offset) == [0, 1])
    #expect(g.stops[0].color == p.body && g.stops[1].color == StageBackdrop.skyDark)
    // inside the start circle: the body colour exactly; on the rim: the dark end
    #expect(g.color(at: StagePoint(x: 386, y: 286)) == p.body)
    #expect(colorNear(g.color(at: StagePoint(x: 440, y: 300)), StageBackdrop.skyDark))
    #expect(colorNear(g.color(at: StagePoint(x: 400, y: 340)), StageBackdrop.skyDark))
    // the lit side is lighter than the shadow side at the same distance from the centre
    let lit = g.color(at: StagePoint(x: 400 - 20, y: 300 - 20))!
    let shadow = g.color(at: StagePoint(x: 400 + 20, y: 300 + 20))!
    #expect(lit.r > shadow.r && lit.b > shadow.b)
  }

  @Test func theParameterOfATwoCircleGradientIsWhereItsCircleTouchesThePoint() {
    let g = StageBackdrop.sky(width: 800, height: 600)
    var rng = StageSeededRandom(seed: 9)
    for _ in 0..<200 {
      let p = StagePoint(x: rng.next() * 1600 - 400, y: rng.next() * 1200 - 300)
      let t = g.parameter(at: p)
      #expect(t != nil)
      guard let t else { continue }
      let cx = g.start.x + t * (g.end.x - g.start.x)
      let cy = g.start.y + t * (g.end.y - g.start.y)
      let r = g.startRadius + t * (g.endRadius - g.startRadius)
      #expect(r >= 0)
      #expect(stageNear(bdHypot(p.x - cx, p.y - cy), r, 1e-6))
    }
  }

  @Test func theSkyIsTheStopsOfRenderStarsOnItsTwoOffsetCircles() {
    let g = StageBackdrop.sky(width: 800, height: 600)
    // createRadialGradient(0.5w, 0.32h, 0, 0.5w, 0.5h, max(w, h) * 0.85)
    #expect(stageNear(g.start, 400, 192) && g.startRadius == 0)
    #expect(stageNear(g.end, 400, 300) && stageNear(g.endRadius, 680))
    #expect(g.stops.map(\.offset) == [0, 0.6, 1])
    #expect(
      g.stops.map(\.color) == [StageBackdrop.skyGlow, StageBackdrop.skyMid, StageBackdrop.skyDark])
    #expect(StageBackdrop.skyGlow == ScopeColor(r8: 0x16, g8: 0x15, b8: 0x30))
    #expect(StageBackdrop.skyMid == ScopeColor(r8: 0x0c, g8: 0x0b, b8: 0x20))
    #expect(StageBackdrop.skyDark == ScopeColor(r8: 0x05, g8: 0x04, b8: 0x1a))
    // the glow's centre is its first stop
    #expect(g.color(at: StagePoint(x: 400, y: 192)) == StageBackdrop.skyGlow)
    // the circle at t = 0.6 has centre (400, 192 + 0.6 * 108) and radius 0.6 * 680: its bottom
    // point is the middle stop
    #expect(
      colorNear(
        g.color(at: StagePoint(x: 400, y: 192 + 0.6 * 108 + 0.6 * 680)), StageBackdrop.skyMid))
    // far outside, the last stop; the lower edge is darker than the upper centre because the glow
    // sits above the middle
    #expect(g.color(at: StagePoint(x: 5000, y: 5000)) == StageBackdrop.skyDark)
    let above = g.color(at: StagePoint(x: 400, y: 100))!
    let below = g.color(at: StagePoint(x: 400, y: 500))!
    #expect(above.b > below.b, "lighter toward the upper centre")
  }

  @Test func colourStopsInterpolateWithoutPremultiplyingAlpha() {
    let g = StageTwoCircleGradient(
      start: StagePoint(x: 0, y: 0), startRadius: 0, end: StagePoint(x: 0, y: 0), endRadius: 10,
      stops: [
        StageGradientStop(offset: 0, color: ScopeColor(r: 1, g: 0, b: 0, a: 1)),
        StageGradientStop(offset: 1, color: ScopeColor(r: 0, g: 0, b: 1, a: 0)),
      ])
    let m = g.color(at: StagePoint(x: 5, y: 0))!
    // a straight blend: the colour is halfway between red and blue AND the alpha is halved; a
    // premultiplied blend would leave it mostly red
    #expect(stageNear(m.r, 0.5) && stageNear(m.b, 0.5) && stageNear(m.a, 0.5))
  }

  @Test func resampledStopsFollowTheStraightBlendEvenWhenInterpolatedPremultiplied() {
    let b = StageBackdrop.auroraBlobs(phase: 0)[2]  // rgba(12, 45, 90, 0.18) -> rgba(7, 6, 26, 0)
    let g = b.gradient(width: 800, height: 600)
    let stops = g.sampledStops(segments: 16)
    #expect(stops.count == 17 && stops.first!.offset == 0 && stops.last!.offset == 1)
    #expect(stops.first!.color == b.color && colorNear(stops.last!.color, StageBackdrop.auroraFade))
    #expect(stageNear(stops[8].offset, 0.5) && stageNear(stops[8].color.a, 0.09))
    // a renderer that blends premultiplied colours between those stops: colour * alpha, linear
    func premultiplied(at t: Double) -> (Double, Double, Double) {
      let k = t * 16
      let i = min(15, Int(k))
      let f = k - Double(i)
      func pm(_ c: ScopeColor) -> (Double, Double, Double) { (c.r * c.a, c.g * c.a, c.b * c.a) }
      let a = pm(stops[i].color)
      let z = pm(stops[i + 1].color)
      return (a.0 + (z.0 - a.0) * f, a.1 + (z.1 - a.1) * f, a.2 + (z.2 - a.2) * f)
    }
    var worst = 0.0
    for n in 0...200 {
      let t = Double(n) / 200
      let want = g.color(at: t)
      let got = premultiplied(at: t)
      worst = max(
        worst, bdAbs(got.0 - want.r * want.a), bdAbs(got.1 - want.g * want.a),
        bdAbs(got.2 - want.b * want.a))
    }
    #expect(worst < 0.25 / 255, "worst premultiplied error \(worst * 255) of 255")
    // the two stops alone would be a visibly different curve (that is why they are resampled)
    var coarse = 0.0
    for n in 0...200 {
      let t = Double(n) / 200
      let want = g.color(at: t)
      let c0 = b.color
      coarse = max(coarse, bdAbs(c0.b * c0.a * (1 - t) - want.b * want.a))
    }
    #expect(coarse > 2.0 / 255)
  }

  // MARK: the aurora

  @Test func theAuroraBlobsAtPhaseZero() {
    let b = StageBackdrop.auroraBlobs(phase: 0)
    #expect(b.count == 4)
    // (node) 0.25 + 0.12 sin(0), 0.30 + 0.15 cos(0), ...
    let expected: [(Double, Double, Double)] = [
      (0.25, 0.44999999999999996, 0.55),
      (0.87974949866040553, 0.35006237961434294, 0.50),
      (0.52540160145077608, 0.85403023058681404, 0.60),
      (0.54404765065689009, 0.25, 0.45),
    ]
    for (i, e) in expected.enumerated() {
      #expect(stageNear(b[i].cx, e.0, 1e-12) && stageNear(b[i].cy, e.1, 1e-12))
      #expect(b[i].r == e.2)
    }
  }

  @Test func theAuroraBlobsAtPhaseTen() {
    let b = StageBackdrop.auroraBlobs(phase: 10)
    // (node) the same table at p = 10
    let expected: [(Double, Double)] = [
      (0.34399922915529801, 0.41472632809267324),
      (0.83155013718214643, 0.29717334959572633),
      (0.43685901901586843, 0.77727979053069129),
      (0.51009900954344711, 0.20816830894638835),
    ]
    for (i, e) in expected.enumerated() {
      #expect(stageNear(b[i].cx, e.0, 1e-12) && stageNear(b[i].cy, e.1, 1e-12))
    }
  }

  @Test func theAuroraBlobColoursAreTheDarkMutedOnes() {
    let b = StageBackdrop.auroraBlobs(phase: 3)
    #expect(
      b.map(\.color) == [
        ScopeColor(r8: 30, g8: 22, b8: 90, a: 0.18), ScopeColor(r8: 90, g8: 18, b8: 60, a: 0.14),
        ScopeColor(r8: 12, g8: 45, b8: 90, a: 0.18), ScopeColor(r8: 70, g8: 30, b8: 10, a: 0.10),
      ])
    #expect(b.map(\.r) == [0.55, 0.50, 0.60, 0.45])
    #expect(StageBackdrop.auroraBase == ScopeColor(r8: 7, g8: 6, b8: 26))
    #expect(StageBackdrop.auroraFade == ScopeColor(r8: 7, g8: 6, b8: 26, a: 0))
  }

  @Test func eachBlobIsARadialGradientOfMaxSideTimesItsRadiusFadingToTheBase() {
    let b = StageBackdrop.auroraBlobs(phase: 0)[0]
    let g = b.gradient(width: 800, height: 600)
    #expect(stageNear(g.start, 0.25 * 800, 0.45 * 600) && stageNear(g.end, g.start.x, g.start.y))
    #expect(g.startRadius == 0 && stageNear(g.endRadius, 0.55 * 800))
    // the centre has the blob's colour; halfway out the colour and alpha are halfway to the fade
    let centre = g.color(at: g.start)!
    #expect(stageNear(centre.a, 0.18) && stageNear(centre.r, 30.0 / 255))
    let half = g.color(at: StagePoint(x: g.start.x + 0.55 * 800 / 2, y: g.start.y))!
    #expect(stageNear(half.a, 0.09))
    #expect(
      stageNear(half.r, (30.0 / 255 + 7.0 / 255) / 2)
        && stageNear(half.b, (90.0 / 255 + 26.0 / 255) / 2))
    // at and past the radius it adds nothing
    #expect(
      stageNear(g.color(at: StagePoint(x: g.start.x + 0.55 * 800, y: g.start.y))!.a, 0, 1e-12))
    #expect(g.color(at: StagePoint(x: g.start.x + 2000, y: g.start.y))!.a == 0)
  }
}
