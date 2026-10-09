import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The three backgrounds drawn (SPEC mode 18), by rendering the layer and comparing pixels with
// what the DJCore numbers say they should be. `DJ_SHOT_DIR=/some/dir` also writes PNGs.

@MainActor
struct StageBackdropRenderTests {
  // MARK: void

  @Test func voidIsTheFlatStageColour() throws {
    let rig = BackdropRig(.void, seconds: 3)
    let px = try rig.pixels()
    var y = 0
    while y < rig.height {
      var x = 0
      while x < rig.width {
        #expect(px.near(x, y, (10, 10, 26), tol: 0), "(\(x), \(y)) \(backdropRGB(px, x, y))")
        x += 29
      }
      y += 23
    }
    rig.savePNG("backdrop-void")
  }

  // MARK: stars

  @Test func theSkyIsTheTwoCircleGradientAndLighterTowardTheUpperCentre() throws {
    let rig = BackdropRig(.stars, seconds: 1)
    let px = try rig.pixels()
    let points = BackdropOracle.clearPoints(rig, count: 60)
    #expect(points.count >= 30)
    var differsFromVoid = 0
    for (x, y) in points {
      let want = BackdropOracle.sky(x, y, w: rig.w, h: rig.h)
      #expect(px.near(x, y, want, tol: 2), "(\(x), \(y)) \(backdropRGB(px, x, y)) vs \(want)")
      if !px.near(x, y, (10, 10, 26), tol: 3) { differsFromVoid += 1 }
    }
    #expect(differsFromVoid > points.count / 2, "it is not the void colour")
    // the glow centre (400, 192) is the first stop #161530 (nothing else is there)
    #expect(
      px.near(400, 192, (0x16, 0x15, 0x30), tol: 8)
        || !BackdropOracle.isClear(400, 192, model: rig.model, w: rig.w, h: rig.h))
    // lighter above the middle than at the bottom edge
    #expect(backdropRGB(px, 400, 120).2 > backdropRGB(px, 400, 590).2 - 1)
    rig.savePNG("backdrop-stars")
  }

  @Test func eachStarTwinklesToItsAlphaOfTheMoment() throws {
    let rig = BackdropRig(.stars, seconds: 0)
    for second in [0.0, 2.7, 5.1] {
      if second > 0 { rig.show(.stars, dt: second - rig.model.phase) }
      let phase = rig.model.phase
      #expect(abs(phase - second) < 1e-9)
      let px = try rig.pixels()
      let stars = rig.isolatedStars()
      #expect(stars.count >= 5, "t=\(second): only \(stars.count) isolated stars to check")
      for s in stars {
        let x = Int((s.x * rig.w).rounded(.down))
        let y = Int((s.y * rig.h).rounded(.down))
        let sky = BackdropOracle.sky(x, y, w: rig.w, h: rig.h)
        let want = BackdropOracle.over(StageBackdrop.starColor, s.alpha(at: phase), sky)
        #expect(
          px.near(x, y, want, tol: 4),
          "star at (\(x), \(y)) t=\(second): \(backdropRGB(px, x, y)) vs \(want) (alpha \(s.alpha(at: phase)))"
        )
      }
    }
    rig.savePNG("backdrop-stars-late")
  }

  @Test func theStarsAreSmallAndMostOfTheSkyIsEmpty() throws {
    let rig = BackdropRig(.stars, seconds: 1)
    let px = try rig.pixels()
    var starPixels = 0
    for y in 0..<rig.height {
      for x in 0..<rig.width {
        let want = BackdropOracle.sky(x, y, w: rig.w, h: rig.h)
        if !px.near(x, y, want, tol: 12) { starPixels += 1 }
      }
    }
    // an upper bound from the model: every star's disc (a pixel of reach for the edge) and every
    // planet's body and ring (the ellipse of its outer radius and its tilted flattening, a
    // thickness of reach)
    var bound = 0.0
    for s in rig.model.stars { bound += Double.pi * (s.size + 1) * (s.size + 1) }
    for p in rig.model.planets {
      bound += Double.pi * p.r * p.r
      bound += Double.pi * (p.ringOuter + 1) * (p.ringY + p.ringThickness / 2 + 1)
    }
    #expect(starPixels > 150 && Double(starPixels) <= bound, "\(starPixels) pixels, bound \(bound)")
  }

  @Test func aStarIsADiscOfItsOwnRadius() throws {
    // one disc of area PI r^2: a star drawn too big or too small is caught, which a look at its
    // centre pixel cannot do
    let sizes: [Double] = [0.9, 1.4, 2.0, 1.7, 1.1]
    let stars = sizes.enumerated().map { i, size in
      BackdropScene.star(x: 100 + 90 * Double(i) + 0.3, y: 120 + 17 * Double(i) + 0.7, size: size)
    }
    let rig = BackdropRig(stars: stars, planets: [])
    let px = try rig.pixels()
    for star in stars {
      let area = backdropStarArea(
        px, star: star, alpha: star.alpha(at: 0), w: rig.w, h: rig.h,
        base: { BackdropOracle.sky($0, $1, w: rig.w, h: rig.h) })
      let want = Double.pi * star.size * star.size
      #expect(
        abs(area - want) <= 0.08 * want + 0.1,
        "star of radius \(star.size): covers \(area) pixels, a disc has \(want)")
    }
  }

  @Test func starsAreInFrontOfThePlanetsBodyAndRing() throws {
    // the planets sit under the stars so the twinkles are foreground: a star over the body, over
    // the ring where it crosses the body, and over the ring beyond the body is the star at its
    // alpha over what is beneath it (drawn the other way round, the body hides the first, and the
    // ring tints the other two)
    let p = BackdropScene.planet
    let onBody = BackdropScene.star(x: 400.5, y: 285.5, size: 2)
    let onRingOverBody = BackdropScene.star(x: 400.5, y: 315.5, size: 2)
    let onRingOverSky = BackdropScene.star(x: 455.5, y: 310.5, size: 2)
    let rig = BackdropRig(
      stars: [onBody, onRingOverBody, onRingOverSky, BackdropScene.parked], planets: [p])
    let px = try rig.pixels()
    let alpha = onBody.alpha(at: 0)
    #expect(alpha == 0.75)
    let ring = p.ring
    let bases: [(String, Int, Int, BackdropRGB)] = [
      ("body", 400, 285, BackdropOracle.body(p, 400, 285, w: rig.w, h: rig.h)),
      (
        "ring over body", 400, 315,
        BackdropOracle.over(
          ring, StagePlanet.frontAlpha, BackdropOracle.body(p, 400, 315, w: rig.w, h: rig.h))
      ),
      (
        "ring over sky", 455, 310,
        BackdropOracle.over(
          ring, StagePlanet.frontAlpha, BackdropOracle.sky(455, 310, w: rig.w, h: rig.h))
      ),
    ]
    for (name, x, y, base) in bases {
      let want = BackdropOracle.over(StageBackdrop.starColor, alpha, base)
      #expect(px.near(x, y, want, tol: 4), "star over \(name): \(backdropRGB(px, x, y)) vs \(want)")
      // and it is well clear of what is beneath it alone
      #expect(!px.near(x, y, base, tol: 40), "the star shows over the \(name)")
    }
    rig.savePNG("backdrop-star-over-planet")
  }

  @Test func eachPlanetShowsItsBodyItsBackRingBehindItAndItsFrontRingOnIt() throws {
    let rig = BackdropRig(.stars, seconds: 2)
    let px = try rig.pixels()
    let phase = rig.model.phase
    #expect((2...3).contains(rig.model.planets.count))
    for p in rig.model.planets {
      // (the ring ellipse is flatter than the body is round: ringY < r, so its middle crosses the disc)
      // back half, hidden: the body was drawn on top, so the pixel is the plain body
      let hidden = BackdropOracle.ringPoint(p, a: 1.5 * Double.pi, phase: phase, w: rig.w, h: rig.h)
      let hx = Int(hidden.x.rounded(.down))
      let hy = Int(hidden.y.rounded(.down))
      guard rig.starFree(hidden.x, hidden.y) else { continue }
      let plain = BackdropOracle.body(p, hx, hy, w: rig.w, h: rig.h)
      #expect(
        px.near(hx, hy, plain, tol: 4),
        "hidden back ring at (\(hx), \(hy)) \(backdropRGB(px, hx, hy)) vs \(plain)")
      // front half over the body: the body blended with the ring at 0.42
      let onBody = BackdropOracle.ringPoint(p, a: 0.5 * Double.pi, phase: phase, w: rig.w, h: rig.h)
      let ox = Int(onBody.x.rounded(.down))
      let oy = Int(onBody.y.rounded(.down))
      if rig.starFree(onBody.x, onBody.y) {
        let want = BackdropOracle.over(
          p.ring, StagePlanet.frontAlpha, BackdropOracle.body(p, ox, oy, w: rig.w, h: rig.h))
        #expect(
          px.near(ox, oy, want, tol: 5),
          "front ring on the body at (\(ox), \(oy)) \(backdropRGB(px, ox, oy)) vs \(want)")
      }
      // outside the body: the back half is dim (0.18), the front half brighter (0.42), both over the sky
      let back = BackdropOracle.ringPoint(
        p, a: 2 * Double.pi - 0.5, phase: phase, w: rig.w, h: rig.h)
      let front = BackdropOracle.ringPoint(p, a: 0.5, phase: phase, w: rig.w, h: rig.h)
      for (pt, alpha, name) in [
        (back, StagePlanet.backAlpha, "back"), (front, StagePlanet.frontAlpha, "front"),
      ] {
        let x = Int(pt.x.rounded(.down))
        let y = Int(pt.y.rounded(.down))
        guard rig.starFree(pt.x, pt.y),
          x >= 0, y >= 0, x < rig.width, y < rig.height
        else { continue }
        let want = BackdropOracle.over(p.ring, alpha, BackdropOracle.sky(x, y, w: rig.w, h: rig.h))
        #expect(
          px.near(x, y, want, tol: 5),
          "\(name) ring at (\(x), \(y)) \(backdropRGB(px, x, y)) vs \(want)")
      }
    }
    rig.savePNG("backdrop-planets")
  }

  @Test func theRingIsAsWideAsItsThicknessAcrossItsBand() throws {
    // BackdropScene.planet: stroke 20 wide. At x = 400 the front half is the band
    // y = 305.4...325.4 over the body (the ellipse's normal is vertical at its apex), so the rows
    // 306...324 are body under ring at 0.42 and the rows 304 and before, 326 and after, are the
    // plain body: a stroke half as wide or twice as wide moves those edges by 5 or 10 rows
    let p = BackdropScene.planet
    let rig = BackdropRig(stars: [BackdropScene.parked], planets: [p])
    let px = try rig.pixels()
    for y in [306, 309, 315, 321, 324] {
      let want = BackdropOracle.over(
        p.ring, StagePlanet.frontAlpha, BackdropOracle.body(p, 400, y, w: rig.w, h: rig.h))
      #expect(
        px.near(400, y, want, tol: 3),
        "row \(y) inside the band: \(backdropRGB(px, 400, y)) vs \(want)")
    }
    for y in [296, 300, 304, 326, 330, 336] {
      let want = BackdropOracle.body(p, 400, y, w: rig.w, h: rig.h)
      // (the back half is under the redrawn body, so only the front band can tint it)
      #expect(
        px.near(400, y, want, tol: 3),
        "row \(y) outside the band: \(backdropRGB(px, 400, y)) vs \(want)")
    }
    rig.savePNG("backdrop-ring-thickness")
  }

  @Test func theRingHalvesMeetSquareOnTheMajorAxisAtBothTips() throws {
    // The ellipse's tips are at (330, 300) and (470, 300) and the stroke is 20 wide, so the
    // front half ends in a cap along the row y = 300 and the back half starts from the same line:
    // the pixel row 300 is front only (0.42), row 299 back only (0.18), at both ends, with no
    // gap or double layer between them, and nothing is drawn beyond the outer radius (the cap
    // is square to the tangent: a cap tilted by a few degrees leaves such a gap and overlap).
    let p = BackdropScene.planet
    let rig = BackdropRig(stars: [BackdropScene.parked], planets: [p])
    let px = try rig.pixels()
    for x in [322, 326, 330, 334, 338, 462, 466, 470, 474, 478] {
      let sky300 = BackdropOracle.sky(x, 300, w: rig.w, h: rig.h)
      let sky299 = BackdropOracle.sky(x, 299, w: rig.w, h: rig.h)
      let front = BackdropOracle.over(p.ring, StagePlanet.frontAlpha, sky300)
      let back = BackdropOracle.over(p.ring, StagePlanet.backAlpha, sky299)
      #expect(
        px.near(x, 300, front, tol: 3),
        "(\(x), 300) front half: \(backdropRGB(px, x, 300)) vs \(front)")
      #expect(
        px.near(x, 299, back, tol: 3),
        "(\(x), 299) back half: \(backdropRGB(px, x, 299)) vs \(back)")
    }
    for x in [316, 318, 482, 484] {
      for y in [299, 300] {
        let want = BackdropOracle.sky(x, y, w: rig.w, h: rig.h)
        #expect(
          px.near(x, y, want, tol: 2), "(\(x), \(y)) is beyond the ring: \(backdropRGB(px, x, y))")
      }
    }
  }

  @Test func theRingsTurnSlowlyWithThePhase() throws {
    let rig = BackdropRig(.stars, seconds: 0)
    let before = try rig.pixels()
    let p = try #require(rig.model.planets.first)
    let t0 = rig.model.phase
    // a ring point of the first planet at phase 0, outside the body
    let at0 = BackdropOracle.ringPoint(p, a: 2 * Double.pi - 0.5, phase: t0, w: rig.w, h: rig.h)
    let x = Int(at0.x.rounded(.down))
    let y = Int(at0.y.rounded(.down))
    let sky = BackdropOracle.sky(x, y, w: rig.w, h: rig.h)
    let want = BackdropOracle.over(p.ring, StagePlanet.backAlpha, sky)
    if rig.starFree(at0.x, at0.y) {
      #expect(before.near(x, y, want, tol: 5))
    }
    // after 30 s the ring has turned tiltRate * 30 radians (0.9 to 2.1): it has left that pixel
    rig.show(.stars, dt: 30)
    let after = try rig.pixels()
    #expect(abs(rig.model.phase - 30) < 1e-9)
    #expect(abs(p.tilt(at: 30) - p.tilt(at: 0)) > 0.8)
    if rig.starFree(at0.x, at0.y) {
      #expect(
        !after.near(x, y, want, tol: 5), "the ring pixel at phase 0 is still ring at phase 30")
    }
    // and it is on the ring where the formula says at phase 30
    let at30 = BackdropOracle.ringPoint(p, a: 2 * Double.pi - 0.5, phase: 30, w: rig.w, h: rig.h)
    let x30 = Int(at30.x.rounded(.down))
    let y30 = Int(at30.y.rounded(.down))
    if rig.starFree(at30.x, at30.y), x30 >= 0, y30 >= 0, x30 < rig.width, y30 < rig.height {
      let want30 = BackdropOracle.over(
        p.ring, StagePlanet.backAlpha, BackdropOracle.sky(x30, y30, w: rig.w, h: rig.h))
      #expect(after.near(x30, y30, want30, tol: 5), "\(backdropRGB(after, x30, y30)) vs \(want30)")
    }
    rig.savePNG("backdrop-stars-t30")
  }

  // MARK: aurora

  @Test func theAuroraIsATintedDarkWashOfFourBlobs() throws {
    let rig = BackdropRig(.aurora, seconds: 10)
    let px = try rig.pixels()
    #expect(rig.model.stars.isEmpty, "the aurora has no stars")
    var tinted = 0
    var brightest = 0
    var y = 3
    while y < rig.height {
      var x = 3
      while x < rig.width {
        let want = BackdropOracle.aurora(x, y, w: rig.w, h: rig.h, phase: rig.model.phase)
        #expect(px.near(x, y, want, tol: 2), "(\(x), \(y)) \(backdropRGB(px, x, y)) vs \(want)")
        let c = backdropRGB(px, x, y)
        brightest = max(brightest, c.0, c.1, c.2)
        if !px.near(x, y, (7, 6, 26), tol: 1) { tinted += 1 }
        x += 37
      }
      y += 31
    }
    #expect(tinted > 100, "the blobs tint the base")
    #expect(brightest < 70, "barely-there: the brightest channel is \(brightest)")
    // a blob's centre sits over the base: blob 1 at phase 10 is at (0.344, 0.415)
    let blob = StageBackdrop.auroraBlobs(phase: rig.model.phase)[0]
    let cx = Int(blob.cx * rig.w)
    let cy = Int(blob.cy * rig.h)
    #expect(backdropRGB(px, cx, cy).2 > 26 + 8, "\(backdropRGB(px, cx, cy))")
    rig.savePNG("backdrop-aurora")
  }

  @Test func theAuroraDriftsWithThePhase() throws {
    let rig = BackdropRig(.aurora, seconds: 0)
    let a = try rig.pixels()
    rig.show(.aurora, dt: 40)
    let b = try rig.pixels()
    var moved = 0
    var y = 3
    while y < rig.height {
      var x = 3
      while x < rig.width {
        if abs(backdropRGB(a, x, y).2 - backdropRGB(b, x, y).2) > 1 { moved += 1 }
        let want = BackdropOracle.aurora(x, y, w: rig.w, h: rig.h, phase: 40)
        #expect(b.near(x, y, want, tol: 2))
        x += 53
      }
      y += 47
    }
    #expect(moved > 20, "the wash has moved (\(moved) samples changed)")
    rig.savePNG("backdrop-aurora-t40")
  }

  // MARK: switching

  @Test func switchingBackgroundLeavesNoPixelOfTheOldOne() throws {
    let rig = BackdropRig(.stars, seconds: 1)
    // an isolated bright star: its pixel is lit on the stars background
    let star = try #require(
      rig.isolatedStars(minSize: 1.5).first { $0.alpha(at: rig.model.phase) > 0.3 })
    let sx = Int((star.x * rig.w).rounded(.down))
    let sy = Int((star.y * rig.h).rounded(.down))
    let starry = try rig.pixels()
    let sky = BackdropOracle.sky(sx, sy, w: rig.w, h: rig.h)
    #expect(!starry.near(sx, sy, sky, tol: 3), "the star shows on the stars background")

    rig.show(.aurora, dt: 0.1)
    let wash = try rig.pixels()
    let aurora = BackdropOracle.aurora(sx, sy, w: rig.w, h: rig.h, phase: rig.model.phase)
    #expect(wash.near(sx, sy, aurora, tol: 2), "\(backdropRGB(wash, sx, sy)) vs \(aurora)")

    rig.show(.void, dt: 0.1)
    let flat = try rig.pixels()
    #expect(flat.near(sx, sy, (10, 10, 26), tol: 0))
    #expect(flat.near(rig.width / 2, rig.height / 2, (10, 10, 26), tol: 0))
  }

  // MARK: the bitmaps

  @Test func theBitmapsAreMadeOncePerSizeAndPlanet() throws {
    let cache = StageBackdropCache()
    let a = cache.sky(width: 400, height: 300)
    let b = cache.sky(width: 400, height: 300)
    #expect(a != nil && a === b && cache.builds == 1)
    let wider = cache.sky(width: 401, height: 300)
    #expect(cache.builds == 2 && wider!.width == 401, "a new size makes a new sky")
    #expect(a!.width == 400 && a!.height == 300, "a small stage: one pixel per point")
    // a big stage (a Retina full screen) gets a bitmap of a bounded number of pixels, whatever
    // the display scale: it is stretched, and a resize that remakes it every frame stays cheap
    let big = try #require(cache.sky(width: 2560, height: 1440))
    #expect(cache.builds == 3)
    #expect(big.width * big.height <= StageBackdropImages.skyMaxPixels * 101 / 100)
    #expect(big.width * big.height >= StageBackdropImages.skyMaxPixels * 99 / 100)
    #expect(abs(Double(big.width) / Double(big.height) - 2560.0 / 1440.0) < 0.01)
    #expect(StageBackdropImages.skyScale(width: 512, height: 512) == 1)
    #expect(StageBackdropImages.skyScale(width: 1024, height: 512) < 1)
    #expect(cache.sky(width: 0, height: 0) == nil, "the stage's first frame has no size yet")
    let rig = BackdropRig(.stars)
    let p = try #require(rig.model.planets.first)
    let s1 = try #require(cache.body(p, width: 800, height: 600, scale: 1))
    let s2 = try #require(cache.body(p, width: 800, height: 600, scale: 1))
    #expect(s1.image === s2.image && cache.builds == 4)
    // whole points, so it lands on the pixel grid, and it holds the whole disc
    #expect(
      s1.rect.origin.x == s1.rect.origin.x.rounded()
        && s1.rect.origin.y == s1.rect.origin.y.rounded())
    #expect(s1.rect.width == s1.rect.width.rounded() && Int(s1.rect.width) == s1.image.width)
    let c = p.center(width: 800, height: 600)
    #expect(s1.rect.minX < c.x - p.r && s1.rect.maxX > c.x + p.r)
    #expect(s1.rect.minY < c.y - p.r && s1.rect.maxY > c.y + p.r)
    // a bigger scale doubles the pixels, not the points
    let s3 = try #require(cache.body(p, width: 800, height: 600, scale: 2))
    #expect(s3.image.width == s1.image.width * 2 && s3.rect == s1.rect)
  }

  @Test func theBigStageSkyStillMatchesTheGradientOnceStretched() throws {
    // a 1000 x 800 stage is more than the sky bitmap's pixel budget, so it is drawn from a
    // smaller bitmap stretched up: the gradient is smooth, and it must not show
    let rig = BackdropRig(.stars, width: 1000, height: 800, seconds: 1)
    let cache = StageBackdropCache()
    let image = try #require(cache.sky(width: rig.w, height: rig.h))
    #expect(image.width < rig.width, "it is the stretched case")
    let px = try rig.pixels()
    let points = BackdropOracle.clearPoints(rig, count: 80, step: 53)
    #expect(points.count >= 40)
    for (x, y) in points {
      let want = BackdropOracle.sky(x, y, w: rig.w, h: rig.h)
      #expect(px.near(x, y, want, tol: 2), "(\(x), \(y)) \(backdropRGB(px, x, y)) vs \(want)")
    }
  }

  // MARK: the Retina path

  @Test func atTwoPixelsPerPointTheSkyBodyAndRingLandOnTheSamePoints() throws {
    // renderPixels is 1x; a Retina display draws the sky from the same bitmap stretched twice as
    // far, and the planet body from a sprite of twice the pixels: compare at 2x
    let seeded = BackdropRig(.stars, seconds: 1)
    // (renderPixelsScaled is RenderProbes.swift's; the layer reads `displayScale`, set here too)
    let at2 = try #require(
      renderPixelsScaled(
        seeded.scene.environment(\.displayScale, 2), width: seeded.width, height: seeded.height,
        scale: 2))
    #expect(at2.width == 2 * seeded.width && at2.height == 2 * seeded.height)
    let sky = BackdropOracle.clearPoints(seeded, count: 60)
    #expect(sky.count >= 30)
    for (x, y) in sky {
      let (x2, y2) = (2 * x + 1, 2 * y)
      let want = BackdropOracle.sky(x2, y2, w: seeded.w, h: seeded.h, scale: 2)
      #expect(
        at2.near(x2, y2, want, tol: 2), "(\(x2), \(y2)) \(backdropRGB(at2, x2, y2)) vs \(want)")
    }

    let p = BackdropScene.planet
    let fixed = BackdropRig(stars: [BackdropScene.parked], planets: [p])
    let px = try #require(
      renderPixelsScaled(
        fixed.scene.environment(\.displayScale, 2), width: fixed.width, height: fixed.height,
        scale: 2))
    // body: the lit upper left, the middle, and the shaded lower side (clear of the front band,
    // which is y = 305.4...325.4, rows 611...650)
    for (x2, y2) in [(761, 541), (800, 560), (780, 530), (800, 668), (820, 664)] {
      let want = BackdropOracle.body(p, x2, y2, w: fixed.w, h: fixed.h, scale: 2)
      #expect(
        px.near(x2, y2, want, tol: 3), "body (\(x2), \(y2)) \(backdropRGB(px, x2, y2)) vs \(want)")
    }
    // the front ring over the body, a row inside each edge of the band (y = 305.4...325.4)
    for y2 in [614, 630, 648] {
      let want = BackdropOracle.over(
        p.ring, StagePlanet.frontAlpha,
        BackdropOracle.body(p, 800, y2, w: fixed.w, h: fixed.h, scale: 2))
      #expect(
        px.near(800, y2, want, tol: 3), "band row \(y2) \(backdropRGB(px, 800, y2)) vs \(want)")
    }
    for y2 in [608, 654] {
      let want = BackdropOracle.body(p, 800, y2, w: fixed.w, h: fixed.h, scale: 2)
      #expect(
        px.near(800, y2, want, tol: 3), "outside the band, row \(y2) \(backdropRGB(px, 800, y2))")
    }
    // the tip: front half on the row below y = 300, back half on the row above, sky beyond 480
    let front = BackdropOracle.over(
      p.ring, StagePlanet.frontAlpha, BackdropOracle.sky(950, 600, w: fixed.w, h: fixed.h, scale: 2)
    )
    let back = BackdropOracle.over(
      p.ring, StagePlanet.backAlpha, BackdropOracle.sky(950, 599, w: fixed.w, h: fixed.h, scale: 2))
    #expect(px.near(950, 600, front, tol: 3) && px.near(950, 599, back, tol: 3))
    #expect(
      px.near(966, 600, BackdropOracle.sky(966, 600, w: fixed.w, h: fixed.h, scale: 2), tol: 2))
  }

  // MARK: the layer in the stage

  @Test func theToolbarsBackgroundReachesTheLayerThroughTheStage() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    let bg = rig.model.layers.background
    func render() throws -> Pixels {
      try #require(
        renderPixels(rig.scene(), width: Int(rig.width), height: Int(rig.height)))
    }
    // the window's margins: no panel of the ring reaches them
    let margins: (Int, Int) -> Bool = { x, y in (x < 70 && y > 70) || x > 930 || y > 755 }
    let w = Int(rig.width)
    let h = Int(rig.height)

    // void (the default): the stage's own colour, no field made
    try rig.run(seconds: 0.5)
    #expect(bg.mode == .void && bg.stars.isEmpty && bg.phase == 0)
    var px = try render()
    #expect(px.near(960, 20, (10, 10, 26), tol: 0) && px.near(960, 780, (10, 10, 26), tol: 0))

    // stars
    rig.model.settings.bgMode = .stars
    try rig.run(seconds: 1.0)
    #expect(rig.model.context.bgMode == .stars && bg.mode == .stars)
    #expect(bg.stars.count == 150 && (2...3).contains(bg.planets.count))
    #expect(abs(bg.phase - 1.0) < 1e-6, "the clock is the frames' dt: \(bg.phase)")
    px = try render()
    var points = BackdropOracle.clearPoints(
      model: bg, width: w, height: h, count: 40, step: 23, where: margins)
    #expect(points.count >= 20)
    for (x, y) in points {
      let want = BackdropOracle.sky(x, y, w: rig.width, h: rig.height)
      #expect(px.near(x, y, want, tol: 3), "(\(x), \(y)) \(backdropRGB(px, x, y)) vs \(want)")
    }
    savePNG(rig.scene(), width: w, height: h, name: "backdrop-stage-stars")

    // aurora
    let stars = bg.stars
    rig.model.settings.bgMode = .aurora
    try rig.run(seconds: 0.5)
    #expect(bg.mode == .aurora && abs(bg.phase - 1.5) < 1e-6 && bg.stars == stars)
    px = try render()
    points = BackdropOracle.clearPoints(
      model: bg, width: w, height: h, count: 40, step: 23, where: margins)
    for (x, y) in points {
      let want = BackdropOracle.aurora(x, y, w: rig.width, h: rig.height, phase: bg.phase)
      #expect(px.near(x, y, want, tol: 2), "(\(x), \(y)) \(backdropRGB(px, x, y)) vs \(want)")
    }
    savePNG(rig.scene(), width: w, height: h, name: "backdrop-stage-aurora")

    // back to void: flat again, and the clock stood still
    rig.model.settings.bgMode = .void
    let phase = bg.phase
    try rig.run(seconds: 0.5)
    #expect(bg.phase == phase)
    px = try render()
    for (x, y) in points { #expect(px.near(x, y, (10, 10, 26), tol: 0)) }
  }

  @Test func theBackgroundDoesNotTurnWithTheDiagram() throws {
    let syn = try SyntheticStage()
    var ctx = syn.context
    ctx.bgMode = .stars
    ctx.dt = 0
    let background = syn.model.layers.background
    background.advance(ctx)
    ctx.dt = 1
    background.advance(ctx)
    func render(_ rotation: Double) throws -> Pixels {
      var c = ctx
      c.metaRotation = rotation
      return try #require(
        renderPixels(StageScene(model: syn.model, context: c), width: 600, height: 600))
    }
    let still = try render(0)
    let turned = try render(90)
    // the ring panel covers the middle of this 600 x 600 stage: compare the outer margin
    var compared = 0
    var y = 4
    while y < 600 {
      var x = 4
      while x < 600 {
        let inPanel = x > 90 && x < 510 && y > 90 && y < 510
        if !inPanel {
          #expect(still.near(x, y, backdropRGB(turned, x, y), tol: 0), "(\(x), \(y))")
          compared += 1
        }
        x += 17
      }
      y += 13
    }
    #expect(compared > 500)
    // and the sky is there at all
    let want = BackdropOracle.sky(300, 40, w: 600, h: 600)
    #expect(
      still.near(300, 40, want, tol: 12)
        || !BackdropOracle.isClear(300.5, 40.5, model: background, w: 600, h: 600))
    savePNG(
      StageScene(model: syn.model, context: ctx), width: 600, height: 600,
      name: "backdrop-stage-synthetic")
  }

  @Test func theCardLayerDrawsNothingWhateverTheFlagsSay() throws {
    let syn = try SyntheticStage()
    var ctx = syn.context
    func render(_ c: StageContext) throws -> Pixels {
      try #require(renderPixels(StageScene(model: syn.model, context: c), width: 600, height: 600))
    }
    func differing(_ a: Pixels, _ b: Pixels) -> Int {
      var n = 0
      for y in 0..<600 {
        for x in 0..<600 where backdropRGB(a, x, y) != backdropRGB(b, x, y) { n += 1 }
      }
      return n
    }
    let plain = try render(ctx)
    // (two renders of one frame already differ in a few dozen anti-aliased pixels: the noise floor)
    let again = try render(ctx)
    ctx.cardOnChange = true
    ctx.trackChanged = true
    let flagged = try render(ctx)
    let noise = differing(plain, again)
    // the JS card is a 70%-wide box in the top right: it would change thousands of pixels
    #expect(
      differing(plain, flagged) <= noise + 60,
      "no card box appears (the share-card flash is not ported): \(differing(plain, flagged)) vs noise \(noise)"
    )
    // and nothing is lit where the box would be (top right, from y = 56, 14 px off the edge)
    let box = flagged.count(inX: 200..<580, y: 60..<200) { r, g, b in r > 60 || g > 60 || b > 80 }
    let boxPlain = plain.count(inX: 200..<580, y: 60..<200) { r, g, b in r > 60 || g > 60 || b > 80
    }
    #expect(box <= boxPlain + 60)
  }
}
