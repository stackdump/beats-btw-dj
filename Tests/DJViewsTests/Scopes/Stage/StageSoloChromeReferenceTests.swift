import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The solo visualizers against a REAL canvas. scripts/stage-solo-chrome-reference.html runs the
// bodies of stage.js's renderCorona, renderSonar and renderPetal in headless Chrome on an
// 800 x 600 stage, at a device pixel ratio of 1 and of 2, and prints the RGB of probe pixels and
// runs of pixels through each glow; the literals below are its output (`#dpr=1`, `#dpr=2`). The
// Swift painters draw the same scenes, at the same ratios, and must land within a few levels of
// every probe. That pins what no hand arithmetic can: the canvas's glow (a Gaussian of blur/2
// DEVICE pixels, so half as wide in points on a Retina screen), the two-circle gradient of the
// petal fill, the leak of one petal's shadow into the next petal's fill, and "a zero-length line
// draws nothing".
//
// There is no fitted constant in the painter, so these are the only thing between it and Chrome:
// the glow profiles are compared pixel by pixel (a glow of the wrong width, strength or ratio
// fails), not just at a few points.
//
// Probes on an antialiased edge (a round cap's end, a petal's tip) are left out: they differ by
// the two rasterisers' coverage, not by anything the port decides.

private typealias RGB = (Int, Int, Int)
private typealias Probe = (String, Int, Int, RGB)

@MainActor
struct StageSoloChromeReferenceTests {
  private let center = StagePoint(x: 400, y: 300)
  private static let background = 10  // #0a0a1a: red and green; blue is 26

  private func ring(_ raws: [Double], _ channels: [Int]) -> [PetalShape] {
    var out: [PetalShape] = []
    for (i, raw) in raws.enumerated() {
      var p = StagePetals.shape(
        index: i, count: raws.count, raw: raw, hue: ScopeColors.channelHue(channels[i]),
        center: center, width: 800, height: 600)
      if let before = out.last {  // stage.js's loop leaves the previous petal's shadow on the fill
        p.fillShadow = before.shadow
        p.fillShadowBlur = before.shadowBlur
      }
      out.append(p)
    }
    return out
  }

  private func pixels<V: View>(_ scene: V, scale: Int) throws -> Pixels {
    try #require(
      renderPixelsAt(
        scale: CGFloat(scale),
        ZStack {
          StagePalette.background.color
          scene
        }, width: 800, height: 600))
  }

  private func petalPixels(_ shapes: [PetalShape], scale: Int) throws -> Pixels {
    try pixels(Canvas { gc, _ in StageSoloPainter.drawPetals(gc, petals: shapes) }, scale: scale)
  }

  /// Every probe (at CSS x, y: the device pixel (x * scale, y * scale)) within `tol` levels of
  /// Chrome's value, per channel.
  private func check(
    _ px: Pixels, _ probes: [Probe], scale: Int, tol: Int, _ what: String
  ) {
    for (name, x, y, want) in probes {
      let c = px.color(x * scale, y * scale)
      let worst = max(abs(c.r - want.0), abs(c.g - want.1), abs(c.b - want.2))
      #expect(
        worst <= tol,
        "\(what) @\(scale)x \(name) at (\(x), \(y)): ours (\(c.r), \(c.g), \(c.b)), Chrome \(want)"
      )
    }
  }

  /// A run of `n` device pixels from CSS (x, y) along +x (`across` false) or +y, one channel.
  private func run(
    _ px: Pixels, x: Int, y: Int, n: Int, vertical: Bool, scale: Int,
    channel: (Pixels, Int, Int) -> Int
  ) -> [Int] {
    (0..<n).map { channel(px, x * scale + (vertical ? 0 : $0), y * scale + (vertical ? $0 : 0)) }
  }

  /// Our run against Chrome's: pixel by pixel within `tol` levels, except where the shape's own
  /// edge is (a pixel whose Chrome value is more than `edge` levels above the background, and
  /// the one on each side of it: the two rasterisers' coverage of an edge differs by more than
  /// the glow does), and the glow outside it (the lift above the background) summing to
  /// `ratio` of Chrome's.
  private func compareProfile(
    ours: [Int], chrome: [Int], background: Int, edge: Int, tol: Int, ratio: ClosedRange<Double>,
    _ what: String
  ) {
    #expect(ours.count == chrome.count)
    var near = Set<Int>()
    for i in chrome.indices where chrome[i] - background > edge {
      for j in max(0, i - 1)...min(chrome.count - 1, i + 1) { near.insert(j) }
    }
    var theirs = 0.0
    var mine = 0.0
    for i in chrome.indices where !near.contains(i) {
      let d = abs(ours[i] - chrome[i])
      #expect(d <= tol, "\(what) pixel \(i): ours \(ours[i]), Chrome \(chrome[i])")
      theirs += Double(chrome[i] - background)
      mine += Double(ours[i] - background)
    }
    guard theirs > 20 else { return }
    #expect(
      ratio.contains(mine / theirs),
      "\(what): the glow sums to \(mine / theirs) of Chrome's (want \(ratio))")
  }

  // MARK: petal

  private static let petalGradient: [Int: [Probe]] = [
    1: [
      ("s-10", 390, 300, (19, 13, 37)),
      ("s5", 405, 300, (24, 15, 43)),
      ("s10", 410, 300, (23, 15, 42)),
      ("s20", 420, 300, (23, 15, 42)),
      ("s30", 430, 300, (23, 15, 42)),
      ("s52", 452, 300, (23, 15, 42)),
      ("s94", 494, 300, (23, 15, 42)),
      ("s100", 500, 300, (23, 14, 42)),
      ("s110", 510, 300, (10, 10, 26)),
    ],
    2: [
      ("s-10", 390, 300, (19, 13, 37)),
      ("s5", 405, 300, (23, 14, 43)),
      ("s10", 410, 300, (23, 15, 42)),
      ("s20", 420, 300, (23, 15, 42)),
      ("s30", 430, 300, (23, 15, 42)),
      ("s52", 452, 300, (23, 15, 42)),
      ("s94", 494, 300, (23, 15, 42)),
      ("s100", 500, 300, (23, 15, 42)),
      ("s110", 510, 300, (10, 10, 26)),
    ],
  ]

  /// Petal 1 of 4 at raw energy 0.01 (hue 280): on its axis the fill is the END colour from a few
  /// points out to its tip, because the gradient's second circle is centred on the tip.
  @Test(arguments: [1, 2])
  func theFillOfAPetalIsTheEndColourAlongItsAxis(scale: Int) throws {
    let px = try petalPixels(ring([0, 0.01, 0, 0], [4, 4, 4, 4]), scale: scale)
    check(px, Self.petalGradient[scale]!, scale: scale, tol: 4, "petal gradient")
  }

  private static let petalLeak: [Int: [Probe]] = [
    1: [
      ("fillRight60", 460, 300, (19, 17, 37)),
      ("fillRight30", 430, 300, (18, 16, 36)),
      ("fillRight100", 500, 300, (10, 10, 26)),
      ("up100", 400, 200, (82, 31, 42)),
      ("tipUp", 400, 22, (234, 98, 99)),
    ],
    2: [
      ("fillRight60", 460, 300, (20, 17, 37)),
      ("fillRight30", 430, 300, (20, 17, 37)),
      ("fillRight100", 500, 300, (10, 10, 26)),
      ("up100", 400, 200, (82, 31, 42)),
      ("tipUp", 400, 22, (237, 99, 100)),
    ],
  ]

  /// A full-energy red petal, then a resting blue one: the blue one's FILL wears the red one's
  /// glow (stage.js leaves the shadow state set), and the red tip is exact.
  @Test(arguments: [1, 2])
  func thePetalLoopLeaksTheShadowIntoTheNextFill(scale: Int) throws {
    let px = try petalPixels(ring([1, 0, 0, 0], [10, 2, 2, 2]), scale: scale)
    check(px, Self.petalLeak[scale]!, scale: scale, tol: 4, "petal leak")
  }

  private static let petalLengths: [Int: [Probe]] = [
    1: [
      ("right120", 520, 300, (52, 22, 55)),
      ("right181", 581, 300, (171, 73, 144)),
      ("down200", 400, 500, (46, 51, 103)),
      ("down278", 400, 578, (97, 141, 231)),
      ("left60", 340, 300, (19, 34, 60)),
    ],
    2: [
      ("right120", 520, 300, (52, 22, 55)),
      ("right181", 581, 300, (180, 75, 150)),
      ("down200", 400, 500, (46, 51, 103)),
      ("down278", 400, 578, (98, 143, 235)),
      ("left60", 340, 300, (19, 34, 60)),
    ],
  ]

  @Test(arguments: [1, 2])
  func petalsOfDifferentEnergiesHaveTheLengthsAndColoursOfTheCanvas(scale: Int) throws {
    let px = try petalPixels(ring([0, 0.25, 1, 0.04], [10, 5, 2, 3]), scale: scale)
    check(px, Self.petalLengths[scale]!, scale: scale, tol: 4, "petal lengths")
  }

  /// The red channel along a row through a full-energy red petal (x 400 ... 520, y 200): the
  /// fill, the outline, and the outline's glow falling away outside it.
  private static let petalRed: [Int: [Int]] = [
    1: [
      82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82,
      83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 84, 83, 85, 84, 85, 85, 87, 86, 88, 88, 90,
      90, 92, 91, 94, 94, 95, 95, 97, 109, 235, 233, 229, 136, 30, 29, 28, 26, 25, 24, 23, 21, 20,
      19, 17, 16, 15, 14, 13, 12, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10,
    ],
    2: [
      82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82,
      83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83,
      82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82,
      83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 82, 83, 83, 84,
      84, 85, 85, 86, 87, 89, 90, 92, 93, 96, 96, 99, 100, 102, 104, 106, 106, 118, 237, 237, 237,
      235, 231, 231, 230, 122, 45, 43, 41, 39, 36, 34, 31, 29, 26, 23, 21, 19, 17, 16, 14, 13, 12,
      11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    ],
  ]

  @Test(arguments: [1, 2])
  func aPetalOutlineGlowFallsAwayAsInTheCanvas(scale: Int) throws {
    let px = try petalPixels(ring([1, 0, 0, 0], [10, 2, 2, 2]), scale: scale)
    let ours = run(px, x: 400, y: 200, n: 120 * scale, vertical: false, scale: scale) {
      $0.color($1, $2).r
    }
    compareProfile(
      ours: ours, chrome: Self.petalRed[scale]!, background: Self.background, edge: 100, tol: 3,
      ratio: 0.94...1.06, "petal row @\(scale)x")
  }

  // MARK: corona

  private func coronaPixels(_ db: [Float], scale: Int) throws -> Pixels {
    let rays = StageCorona.rays(
      decibels: db, center: center, planetRadius: nil, width: 800, height: 600)
    return try pixels(
      Canvas { gc, _ in StageSoloPainter.drawCorona(gc, rays: rays) }, scale: scale)
  }

  private func fourBins() -> [Float] {
    var db = [Float](repeating: -.infinity, count: 128)
    db[0] = -75
    db[32] = -50
    db[64] = -25
    db[96] = 0
    return db
  }

  private static let corona: [Int: [Probe]] = [
    1: [
      ("bar32mid", 514, 300, (42, 165, 47)),
      ("bar32off4", 514, 304, (11, 27, 26)),
      ("bar32off8", 514, 308, (10, 17, 26)),
      ("bar32off14", 514, 314, (10, 10, 26)),
      ("bar96mid", 238, 300, (225, 169, 57)),
      ("bar64mid", 400, 438, (147, 194, 52)),
      ("bar0mid", 400, 210, (35, 132, 108)),
      ("beyondEnd12", 574, 300, (10, 10, 26)),
    ],
    2: [
      ("bar32mid", 514, 300, (43, 173, 48)),
      ("bar32off4", 514, 304, (11, 26, 26)),
      ("bar32off8", 514, 308, (10, 10, 26)),
      ("bar32off14", 514, 314, (10, 10, 26)),
      ("bar96mid", 238, 300, (228, 171, 57)),
      ("bar64mid", 400, 438, (151, 201, 52)),
      ("bar0mid", 400, 210, (36, 140, 113)),
      ("beyondEnd12", 574, 300, (10, 10, 26)),
    ],
  ]

  private static let beyondEnd5: [Int: RGB] = [1: (9, 14, 25), 2: (9, 13, 25)]

  /// Bins 0, 32, 64 and 96 at -75, -50, -25 and 0 dB, the rest silent.
  @Test(arguments: [1, 2])
  func theCoronaBarsAndTheirGlowAreTheCanvasOnes(scale: Int) throws {
    let px = try coronaPixels(fourBins(), scale: scale)
    check(px, Self.corona[scale]!, scale: scale, tol: 4, "corona")
    check(
      px, [("beyondEnd5", 567, 300, Self.beyondEnd5[scale]!)], scale: scale, tol: 10, "corona")
  }

  /// The green channel down from the middle of bin 32's bar (x 514, y 300 ... 330).
  private static let coronaGreen: [Int: [Int]] = [
    1: [
      165, 165, 32, 30, 27, 24, 22, 19, 17, 15, 13, 12, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10,
    ],
    2: [
      173, 173, 172, 140, 43, 38, 34, 30, 26, 21, 18, 15, 13, 11, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    ],
  ]

  /// The glow of a bar, pixel by pixel: its width is blur/2 DEVICE pixels, so at 2x it is half as
  /// many points as at 1x, and its strength is the shadow colour's alpha times the bar's.
  @Test(arguments: [1, 2])
  func aCoronaBarsGlowIsTheCanvasOneAtEachDevicePixelRatio(scale: Int) throws {
    let px = try coronaPixels(fourBins(), scale: scale)
    let ours = run(px, x: 514, y: 300, n: 30 * scale, vertical: true, scale: scale) {
      $0.color($1, $2).g
    }
    compareProfile(
      ours: ours, chrome: Self.coronaGreen[scale]!, background: Self.background, edge: 100, tol: 3,
      ratio: 0.94...1.06, "corona column @\(scale)x")
  }

  private static let nearSilent: [Int: Int] = [1: 4002, 2: 10209]

  /// Chrome draws no pixel at all for a spectrum at the floor or silent (a zero-length line has no
  /// caps), and a dot with a glow for each bin a hair above it.
  @Test(arguments: [1, 2])
  func aFloorSpectrumLeavesTheCanvasUntouchedAndAHushLeavesDots(scale: Int) throws {
    func lit(_ px: Pixels) -> Int {
      px.count(inX: 0..<800 * scale, y: 0..<600 * scale) { SoloSwatch.lift(($0, $1, $2, 255)) > 2 }
    }
    #expect(lit(try coronaPixels([Float](repeating: -.infinity, count: 128), scale: scale)) == 0)
    #expect(lit(try coronaPixels([Float](repeating: -100, count: 128), scale: scale)) == 0)
    let hush = lit(try coronaPixels([Float](repeating: -99.9999, count: 128), scale: scale))
    let chrome = Self.nearSilent[scale]!
    #expect(
      abs(hush - chrome) < chrome / 3,
      "128 dots and their glow @\(scale)x: \(hush) pixels, Chrome \(chrome)")
  }

  // MARK: sonar

  private func sonarPixels(scale: Int) throws -> Pixels {
    let arc = StageSonar.arc(
      SonarRing(born: 0, hue: 200, life: 900), nowMs: 450, center: center, width: 800,
      height: 600)
    return try pixels(Canvas { gc, _ in StageSoloPainter.drawSonar(gc, arcs: [arc]) }, scale: scale)
  }

  private static let sonar: [Int: [Probe]] = [
    1: [
      ("axis675", 675, 300, (29, 85, 123)),
      ("axis674", 674, 300, (29, 85, 123)),
      ("axis676", 676, 300, (18, 48, 74)),
      ("axis677", 677, 300, (9, 12, 30)),
      ("axis680", 680, 300, (9, 11, 27)),
      ("axis670", 670, 300, (9, 11, 28)),
      ("axis685", 685, 300, (10, 10, 26)),
      ("axis665", 665, 300, (10, 10, 26)),
      ("centre", 400, 300, (10, 10, 26)),
    ],
    2: [
      ("axis675", 675, 300, (29, 87, 126)),
      ("axis674", 674, 300, (29, 87, 125)),
      ("axis676", 676, 300, (28, 86, 124)),
      ("axis677", 677, 300, (9, 14, 32)),
      ("axis680", 680, 300, (10, 10, 26)),
      ("axis670", 670, 300, (9, 10, 26)),
      ("axis685", 685, 300, (10, 10, 26)),
      ("axis665", 665, 300, (10, 10, 26)),
      ("centre", 400, 300, (10, 10, 26)),
    ],
  ]

  /// A ring of hue 200 at t = 0.5 (radius 275, width 3, alpha 0.425) on the axis.
  @Test(arguments: [1, 2])
  func aSonarRingAndItsGlowAreTheCanvasOnes(scale: Int) throws {
    check(
      try sonarPixels(scale: scale), Self.sonar[scale]!, scale: scale, tol: 4, "sonar")
  }

  /// The blue channel along the axis, out through the ring (x 670 ... 700, y 300).
  private static let sonarBlue: [Int: [Int]] = [
    1: [
      28, 29, 30, 77, 123, 123, 74, 30, 29, 28, 27, 27, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
      26, 26, 26, 26, 26, 26, 26,
    ],
    2: [
      26, 27, 28, 29, 31, 32, 33, 125, 125, 126, 126, 125, 124, 33, 32, 30, 29, 28, 27, 26, 26, 26,
      26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
      26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
    ],
  ]

  /// The ring's glow is faint (alpha 0.425 * 0.2125), a few levels over a 26 background: pixel by
  /// pixel within 3 levels, no sum (a ratio of a few levels is rounding).
  @Test(arguments: [1, 2])
  func aSonarRingsGlowIsTheCanvasOneAtEachDevicePixelRatio(scale: Int) throws {
    let px = try sonarPixels(scale: scale)
    let ours = run(px, x: 670, y: 300, n: 30 * scale, vertical: false, scale: scale) {
      $0.color($1, $2).b
    }
    compareProfile(
      ours: ours, chrome: Self.sonarBlue[scale]!, background: 26, edge: 40, tol: 3,
      ratio: 0...100, "sonar axis @\(scale)x")
  }
}
