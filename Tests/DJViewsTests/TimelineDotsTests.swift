import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 23 on screen: dots at the x the numbers say, in their part's colour at the alpha the
// fade says; and the real strip fed by a real deck.
@MainActor
struct TimelineDotsRenderTests {
  let width = 400
  let height = Int(TimelineGeometry.stripHeight)
  /// The row through the centre of the dots' heads.
  let headRow = Int(TimelineGeometry.headY)
  /// `#050a14`, the scope background the strip is drawn on.
  let bg = (r: 5.0, g: 10.0, b: 20.0)

  func blend(
    _ c: ScopeColor, alpha: Double, over bg: (r: Double, g: Double, b: Double)? = nil
  ) -> (Int, Int, Int) {
    let under = bg ?? self.bg
    let k = c.rgb8
    func mix(_ f: Int, _ b: Double) -> Int { Int((alpha * Double(f) + (1 - alpha) * b).rounded()) }
    return (mix(k.r, under.r), mix(k.g, under.g), mix(k.b, under.b))
  }

  func strip(_ draws: [TimelineDotDraw]) -> some View {
    Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ScopeColors.background.color))
      TimelineDotsPainter.paint(&ctx, draws)
    }
  }

  @Test func syntheticDotsLandWhereTheNumbersPutThem() throws {
    let red = ScopeColors.laneColors["kick"]!
    let green = ScopeColors.laneColors["melody"]!
    let blue = ScopeColors.laneColors["bass"]!
    // 120 bpm, window 2000 ms, 400 wide: ages 1000 / 500 / 1900 ms
    let t = 100.0
    var h = TimelineDots()
    h.add(TimelineDot(time: t - 1.9, color: blue))
    h.add(TimelineDot(time: t - 1.0, color: red))
    h.add(TimelineDot(time: t - 0.5, color: green))
    let draws = h.layout(now: t, width: Double(width), tempo: 120)
    #expect(
      zip(draws.map(\.x), [20, 200, 300]).allSatisfy { abs($0 - $1) < 1e-6 }, "\(draws.map(\.x))")
    let px = try #require(renderPixels(strip(draws), width: width, height: height))
    // the head's right half (past the streak): colour blended at the dot's alpha
    func head(_ x: Int, _ c: ScopeColor, _ alpha: Double, _ what: String) {
      let want = blend(c, alpha: alpha)
      #expect(
        px.near(x + 2, headRow, want, tol: 14),
        "\(what): \(px.color(x + 2, headRow)) vs \(want)")
    }
    head(200, red, 0.7, "kick at 50 %")
    head(300, green, 0.7, "melody at 25 %")
    // pct 0.95: alpha 0.7 * (1 - 0.1 / 0.15) = 0.2333, a faint blue near the left edge
    head(20, blue, 0.7 * (1 - 0.1 / 0.15), "bass fading")
    // the streak trails to the left of the head for 20 pt, brighter towards the head...
    let near = px.color(200 - 3, headRow)
    let far = px.color(200 - 17, headRow)
    #expect(near.r > far.r && far.r > 20, "streak brightens towards the head: \(far) -> \(near)")
    // ...and ends there: 25 pt to the left is the background again
    #expect(px.near(200 - 25, headRow, (5, 10, 20), tol: 8))
    // the head is a disc of radius 4 centred on (200, 6): its right edge is x = 204, its rows
    // are 2...9; nothing above it, nothing below, nothing past its edge
    let red70 = blend(red, alpha: 0.7)
    #expect(px.near(203, headRow, red70, tol: 14), "inside: \(px.color(203, headRow))")
    #expect(px.near(204, headRow, (5, 10, 20), tol: 8), "outside: \(px.color(204, headRow))")
    #expect(px.near(200, 2, red70, tol: 20), "top row of the head \(px.color(200, 2))")
    #expect(px.near(200, 9, red70, tol: 20), "bottom row of the head \(px.color(200, 9))")
    #expect(px.near(200, 1, (5, 10, 20), tol: 8) && px.near(200, 10, (5, 10, 20), tol: 8))
    savePNG(strip(draws), width: width, height: height, name: "timeline-dots-synthetic")
  }

  @Test func theFadeLeavesNothingAtTheLeftEdge() throws {
    let red = ScopeColors.laneColors["kick"]!
    var h = TimelineDots()
    h.add(TimelineDot(time: 100 - 2.0, color: red))  // pct 1: alpha 0, x = 0
    let draws = h.layout(now: 100, width: Double(width), tempo: 120)
    #expect(draws.count == 1 && draws[0].alpha == 0 && draws[0].x == 0)
    let px = try #require(renderPixels(strip(draws), width: width, height: height))
    #expect(px.near(2, headRow, (5, 10, 20), tol: 6), "alpha 0: invisible \(px.color(2, headRow))")
  }

  @Test func theRealStripDrawsTheKicksOfARealDeck() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    for r in a.roles where r != "kick" { a.setRole(r, on: false) }  // only the kick sounds
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    // its model starts at the present
    let view = TimelineDotsView(feed: feed, hub: rig.hub, active: true)
    let from = feed.fireCount
    try rig.run(seconds: 1.5)
    let fires = (from..<feed.fireCount).compactMap { feed.fireLog.fire(number: $0) }
    #expect(fires.count >= 5, "4-on-the-floor at 300 bpm: a kick every 200 ms (\(fires.count))")
    #expect(fires.allSatisfy { feed.lanes[$0.lane].key == "kick" })
    let px = try #require(renderPixels(view, width: width, height: height))
    let kick = ScopeColors.laneColors["kick"]!
    // the strip is transparent apart from a 30 % black track, and the readback is premultiplied:
    // a head of alpha 0.7 reads as 0.7 of its colour
    let want = blend(kick, alpha: 0.7, over: (0, 0, 0))
    // window = 2000 ms at 300 bpm; a dot younger than 1.7 s holds alpha 0.7
    var hits = 0
    var drawn = 0
    for f in fires {
      let ageMs = (feed.nowTime - f.time) * 1000
      guard ageMs < 1700 else { continue }
      drawn += 1
      let x = Double(width) - ageMs / 2000 * Double(width)
      if px.near(Int(x) + 2, headRow, want, tol: 16) { hits += 1 }
    }
    #expect(drawn >= 5 && hits == drawn, "\(hits) of \(drawn) kick heads are where they belong")
    savePNG(view, width: width, height: height, name: "timeline-dots-engine")
  }

  @Test func aStoppedDeckDrawsNoDots() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let view = TimelineDotsView(feed: feed, hub: rig.hub, active: true)
    try rig.run(seconds: 1)
    rig.dj["A"]!.setPlaying(false)
    try rig.run(seconds: 0.3)
    let px = try #require(renderPixels(view, width: width, height: height))
    #expect(
      px.count(inX: 0..<width, y: 0..<height) { r, g, b in r > 30 || g > 30 || b > 40 } == 0,
      "the viz loop only runs while the transport does")
  }

  @Test func aStripOverAStoppedDeckIsEmptySpace() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    // made first, so its model sees the fires that follow: dots would be there if it drew
    let view = TimelineDotsView(feed: feed, hub: rig.hub, active: false)
    try rig.run(seconds: 1)
    let px = try #require(renderPixels(view, width: width, height: height))
    #expect(px.rgba.allSatisfy { $0 == 0 }, "no dots and no track: just space in the window")
  }

  @Test func aRunningStripHasItsDarkTrack() throws {
    let rig = try ScopeViewRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    let view = TimelineDotsView(feed: feed, hub: rig.hub, active: true)
    let px = try #require(renderPixels(view, width: width, height: height))
    // 30 % black: alpha 77 of 255, no colour (premultiplied)
    let p = px.color(200, 1)
    #expect(p.a > 70 && p.a < 85 && p.r < 5, "the track: \(p)")
  }
}
