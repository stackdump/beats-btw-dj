import Testing

@testable import DJCore

// Expected values come from running scope.js's own `lut` / `lutCss` and stage.js's
// `channelHue` in node (scratchpad f2a/lut.mjs), and the CSS Color spec's hsl algorithm.

private func rgb(_ l: ScopeLUT, _ i: Int) -> [Int] {
  let c = l.rgb(at: i)
  return [Int(c.r), Int(c.g), Int(c.b)]
}

private func checksum(_ l: ScopeLUT) -> (sum: Int, hash: UInt32) {
  var h: UInt32 = 0
  var s = 0
  for b in l.bytes {
    h = h &* 31 &+ UInt32(b)
    s += Int(b)
  }
  return (s, h)
}

struct ScopeColorsTests {
  @Test func magmaMatchesTheJsLookupTable() {
    let m = ScopeColors.magma
    #expect(m.bytes.count == 768)
    let want: [Int: [Int]] = [
      0: [0, 0, 4], 1: [1, 0, 6], 2: [2, 1, 8], 17: [19, 5, 41], 36: [40, 11, 83],
      37: [41, 11, 84], 73: [101, 21, 110], 100: [144, 37, 102], 127: [185, 57, 83],
      128: [186, 57, 82], 129: [188, 58, 81], 200: [247, 158, 30], 254: [252, 251, 187],
      255: [252, 253, 191],
    ]
    for (i, c) in want { #expect(rgb(m, i) == c, "magma[\(i)]") }
    let k = checksum(m)
    #expect(k.sum == 81949 && k.hash == 1_978_372_079, "all 256 entries, not just the sampled ones")
  }

  @Test func viridisMatchesTheJsLookupTable() {
    let v = ScopeColors.viridis
    let want: [Int: [Int]] = [
      0: [68, 1, 84], 1: [68, 2, 85], 2: [68, 4, 87], 17: [70, 24, 106], 36: [69, 49, 125],
      37: [69, 50, 125], 73: [55, 91, 140], 100: [43, 118, 142], 127: [35, 144, 140],
      128: [34, 144, 139], 129: [34, 145, 139], 200: [114, 207, 85], 254: [250, 231, 37],
      255: [253, 231, 37],
    ]
    for (i, c) in want { #expect(rgb(v, i) == c, "viridis[\(i)]") }
    let k = checksum(v)
    #expect(k.sum == 84770 && k.hash == 1_954_929_638)
  }

  @Test func rdbuMatchesTheJsLookupTable() {
    let r = ScopeColors.rdbu
    let want: [Int: [Int]] = [
      0: [33, 102, 172], 1: [35, 104, 173], 2: [36, 105, 174], 17: [61, 129, 186],
      36: [92, 159, 202], 37: [94, 160, 202], 73: [179, 212, 231], 100: [222, 235, 242],
      127: [247, 247, 247], 128: [247, 247, 246], 129: [247, 246, 245], 200: [243, 162, 128],
      254: [179, 27, 44], 255: [178, 24, 43],
    ]
    for (i, c) in want { #expect(rgb(r, i) == c, "rdbu[\(i)]") }
    let k = checksum(r)
    #expect(k.sum == 141373 && k.hash == 899_964_589)
  }

  @Test func lookupClampsTheIndexLikeLutCss() {
    let m = ScopeColors.magma
    #expect(rgb(m, -5) == rgb(m, 0))
    #expect(rgb(m, 999) == rgb(m, 255))
    #expect(m.css(at: 255) == "rgb(252,253,191)")
  }

  @Test func theStopsThemselvesArePassedThroughByTheInterpolation() {
    // Two stops: the ends are exact and the middle rounds half up (127.5 -> 128).
    let l = ScopeLUT(stops: [[0, 0, 0], [255, 100, 1]])
    #expect(rgb(l, 0) == [0, 0, 0])
    #expect(rgb(l, 255) == [255, 100, 1])
    #expect(rgb(l, 1) == [1, 0, 0])
  }

  @Test func digitColorsAreViridisAtNinthsOf255() {
    let want = [
      "rgb(68,1,84)", "rgb(72,40,120)", "rgb(62,73,137)", "rgb(49,104,142)", "rgb(38,130,142)",
      "rgb(31,157,137)", "rgb(53,183,121)", "rgb(109,206,88)", "rgb(179,222,44)",
      "rgb(253,231,37)",
    ]
    #expect(ScopeColors.digitColors.map(\.css) == want)
  }

  @Test func residualColorsAreRdbuAtThirtySecondsOf255() {
    let r = ScopeColors.residualColors
    #expect(r.count == 33)
    let want: [Int: String] = [
      0: "rgb(33,102,172)", 1: "rgb(45,113,178)", 7: "rgb(134,187,217)", 11: "rgb(211,230,240)",
      16: "rgb(247,247,247)", 17: "rgb(248,242,239)", 21: "rgb(253,221,202)",
      26: "rgb(241,148,111)", 31: "rgb(189,45,53)", 32: "rgb(178,24,43)",
    ]
    for (i, c) in want { #expect(r[i].css == c, "RES_CSS[\(i)]") }
  }

  @Test func laneColorsFollowVizColorForNet() {
    #expect(ScopeColors.laneColor(forNet: "kick").css == "rgb(233,69,96)")
    #expect(ScopeColors.laneColor(forNet: "kick-0") == ScopeColors.laneColor(forNet: "kick"))
    #expect(ScopeColors.laneColor(forNet: "hihat-12").css == "rgb(248,231,28)")
    #expect(ScopeColors.laneColor(forNet: "arp").css == "rgb(0,210,255)")
    #expect(ScopeColors.laneColor(forNet: "bass-3").css == "rgb(74,144,217)")
    // not in the table, and only ONE trailing -digits is stripped
    #expect(ScopeColors.laneColor(forNet: "pad") == ScopeColors.defaultLaneColor)
    #expect(ScopeColors.laneColor(forNet: "melody-1-2") == ScopeColors.defaultLaneColor)
    #expect(ScopeColors.defaultLaneColor.css == "rgb(136,136,136)")
    #expect(ScopeColors.fallbackLaneColors.count == 8)
    #expect(ScopeColors.fallbackLaneColors[7].css == "rgb(230,126,34)")
  }

  @Test func stripTrailingDashDigitsIsTheRegex() {
    let f = ScopeColors.stripTrailingDashDigits
    #expect(f("kick-0") == "kick")
    #expect(f("a-1-2") == "a-1")
    #expect(f("a--5") == "a-")
    #expect(f("-5") == "")
    #expect(f("kick") == "kick")
    #expect(f("kick-") == "kick-")
    #expect(f("kick5") == "kick5")
    #expect(f("kick-5x") == "kick-5x")
    #expect(f("") == "")
  }

  @Test func channelHueIncludesTheStageEntriesAndTheHash() {
    let known: [Int: Double] = [
      1: 50, 2: 220, 3: 200, 4: 280, 5: 320, 6: 180, 7: 140, 8: 30, 9: 100, 10: 0, 11: 12,
      12: 24, 13: 35, 14: 350, 20: 50, 21: 60, 22: 40, 23: 30,
    ]
    for (ch, h) in known { #expect(ScopeColors.channelHue(ch) == h, "channel \(ch)") }
    #expect(ScopeColors.channelHue(nil) == 200)
    #expect(ScopeColors.channelHue(15) == 345)  // 15*47 = 705 mod 360
    #expect(ScopeColors.channelHue(16) == 32)
    #expect(ScopeColors.channelHue(24) == 48)
    #expect(ScopeColors.channelHue(0) == 0)
  }

  @Test func sectionColours() {
    #expect(ScopeColors.section("intro").css == "rgb(74,144,217)")
    #expect(ScopeColors.section("verse").css == "rgb(46,204,113)")
    #expect(ScopeColors.section("chorus").css == "rgb(233,69,96)")
    #expect(ScopeColors.section("bridge").css == "rgb(155,89,182)")
    #expect(ScopeColors.section("outro").css == "rgb(245,166,35)")
    #expect(ScopeColors.section("drop") == ScopeColors.defaultLaneColor)
  }

  @Test func hexParsing() throws {
    let c = try #require(ScopeColor(hex: "#e94560"))
    #expect(c.rgb8 == (233, 69, 96) && c.a == 1)
    let short = try #require(ScopeColor(hex: "#888"))
    let upper = try #require(ScopeColor(hex: "#050A14"))
    #expect(short.rgb8 == (136, 136, 136))
    #expect(upper.rgb8 == (5, 10, 20))
    #expect(ScopeColor(hex: "e94560") == nil)
    #expect(ScopeColor(hex: "#12") == nil)
    #expect(ScopeColor(hex: "#gggggg") == nil)
    #expect(ScopeColor(hex: "") == nil)
  }

  @Test func chromeColoursAreTheScopeJsConstants() {
    #expect(ScopeColors.background.rgb8 == (5, 10, 20))
    #expect(ScopeColors.grid.rgb8 == (26, 42, 58))
    #expect(ScopeColors.barLine.rgb8 == (47, 74, 106))
    #expect(ScopeColors.sectionLine.rgb8 == (233, 69, 96))
    #expect(ScopeColors.text.rgb8 == (136, 153, 170))
    #expect(ScopeColors.envelope.css == "rgba(74,144,217,0.6)")
    #expect(ScopeColors.rms.rgb8 == (245, 166, 35))
  }

  @Test func hslaMatchesTheCssAlgorithm() {
    // reference: CSS Color 4 sample code, run in node
    let cases: [(Double, Double, Double, (Int, Int, Int))] = [
      (0, 100, 50, (255, 0, 0)), (120, 100, 50, (0, 255, 0)), (200, 90, 60, (61, 184, 245)),
      (40, 90, 60, (245, 184, 61)), (120, 90, 60, (61, 245, 61)), (300, 50, 25, (96, 32, 96)),
      (-60, 100, 50, (255, 0, 255)), (420, 100, 50, (255, 255, 0)), (210, 0, 50, (128, 128, 128)),
    ]
    for (h, s, l, want) in cases {
      let c = ScopeColor.hsla(h, s, l, 0.5)
      #expect(c.rgb8 == want, "hsl(\(h), \(s)%, \(l)%)")
      #expect(c.a == 0.5)
    }
    #expect(ScopeColor.hsla(200, 90, 60, 0.35).css == "rgba(61,184,245,0.35)")
    #expect(ScopeColor.hsla(0, 100, 50).css == "rgb(255,0,0)")
  }

  @Test func withAlphaKeepsTheColour() {
    let c = ScopeColors.rms.withAlpha(0.25)
    #expect(c.rgb8 == ScopeColors.rms.rgb8 && c.a == 0.25)
    #expect(c.css == "rgba(245,166,35,0.25)")
  }
}
