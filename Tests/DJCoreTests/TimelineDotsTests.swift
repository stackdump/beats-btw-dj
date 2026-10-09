import Testing

@testable import DJCore

// SPEC mode 23: the numbers of `vizDrawTimeline`, worked out by hand from the pinned JS
// (audio-io.js): window = max(2000, min((240 / max(60, tempo)) * 1000, elapsed + 500)),
// x = w - age / window * w, alpha 0.7 until 85 % of the window then linear to 0,
// streak = min(20, w / window * 120).
struct TimelineDotsMathTests {
  let red = ScopeColor(hex: "#e94560")!

  func dots(agesMs: [Double], now: Double = 100) -> TimelineDots {
    var h = TimelineDots()
    for a in agesMs.sorted(by: >) { h.add(TimelineDot(time: now - a / 1000, color: red)) }
    return h
  }

  func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

  @Test func theWindowIsAtLeastTwoSecondsAndNeverMoreThanFourBars() {
    // empty history: elapsed 0 -> max(2000, min(max, 500)) = 2000
    #expect(TimelineDots().windowMs(now: 5, tempo: 120) == 2000)
    // a fast tempo: four bars at 300 bpm are 0.8 s, so the floor wins whatever the history
    #expect(TimelineGeometry.maxWindowMs(tempo: 300) == 800)
    #expect(dots(agesMs: [5000]).windowMs(now: 100, tempo: 300) == 2000)
    // 120 bpm: four bars are exactly 2 s
    #expect(TimelineGeometry.maxWindowMs(tempo: 120) == 2000)
    #expect(dots(agesMs: [1000]).windowMs(now: 100, tempo: 120) == 2000)
    // 60 bpm: four bars are 4 s, and the window follows the oldest dot + 500 ms in between
    #expect(TimelineGeometry.maxWindowMs(tempo: 60) == 4000)
    #expect(dots(agesMs: [1000]).windowMs(now: 100, tempo: 60) == 2000, "1.5 s < the floor")
    #expect(dots(agesMs: [3000, 10]).windowMs(now: 100, tempo: 60) == 3500, "elapsed + 500")
    #expect(dots(agesMs: [5000]).windowMs(now: 100, tempo: 60) == 4000, "capped at four bars")
    // tempo below 60 counts as 60
    #expect(TimelineGeometry.maxWindowMs(tempo: 20) == 4000)
    #expect(TimelineGeometry.maxWindowMs(tempo: 0) == 4000)
  }

  @Test func aTempoThatIsNotANumberDrawsNothing() {
    let h = dots(agesMs: [100])
    #expect(h.windowMs(now: 100, tempo: .nan) == nil)
    #expect(h.layout(now: 100, width: 400, tempo: .nan).isEmpty)
    var p = h
    p.prune(now: 1000, tempo: .nan)
    #expect(p.count == 1, "and prunes nothing, as the JS returns first")
  }

  @Test func positionAlphaAndStreakFollowTheAge() {
    // 120 bpm: window 2000 ms; strip 400 wide: streak min(20, 400/2000*120 = 24) = 20
    let h = dots(agesMs: [2000, 1850, 1700, 1000, 0])
    let l = h.layout(now: 100, width: 400, tempo: 120)
    #expect(l.count == 5)
    let x = l.map(\.x)
    let a = l.map(\.alpha)
    #expect(near(x[0], 0) && near(x[1], 30) && near(x[2], 60) && near(x[3], 200) && near(x[4], 400))
    // pct 1.0 -> 0; 0.925 -> 0.7 * (1 - 0.5) = 0.35; 0.85 and below -> 0.7
    #expect(near(a[0], 0) && near(a[1], 0.35) && near(a[2], 0.7) && near(a[3], 0.7))
    #expect(near(a[4], 0.7))
    #expect(l.allSatisfy { $0.streakLength == 20 })
    #expect(l.allSatisfy { $0.color == red })
    // a narrow strip: 100 / 2000 * 120 = 6
    #expect(near(h.layout(now: 100, width: 100, tempo: 120)[0].streakLength, 6))
  }

  @Test func theFadeIsLinearFromEightyFivePercent() {
    #expect(near(TimelineDots.alpha(atFraction: 0), 0.7))
    #expect(near(TimelineDots.alpha(atFraction: 0.8499), 0.7))
    #expect(near(TimelineDots.alpha(atFraction: 0.85), 0.7))
    #expect(near(TimelineDots.alpha(atFraction: 0.925), 0.35))
    #expect(near(TimelineDots.alpha(atFraction: 0.95), 0.7 * (1 - 0.1 / 0.15)))
    #expect(near(TimelineDots.alpha(atFraction: 1), 0))
  }

  @Test func dotsOlderThanTheWindowAreNotDrawnAndArePruned() {
    var h = dots(agesMs: [2500, 2001, 2000, 500])
    #expect(h.layout(now: 100, width: 400, tempo: 120).count == 2, "2000 is in, 2001 is out")
    h.prune(now: 100, tempo: 120)
    // the oldest dot sets the window: elapsed 2500 + 500 caps at 2000 (120 bpm) -> two dropped
    #expect(h.count == 2)
    #expect(near(h.dots[0].time, 100 - 2.0) && near(h.dots[1].time, 100 - 0.5))
  }

  @Test func theStripIsAsTallAsTheDotsNeedAndNoTaller() {
    let g = TimelineGeometry.self
    #expect(g.stripHeight == 12)
    // everything the painter draws is inside it, with air above and below the head
    #expect(g.headY - g.headRadius == 2 && g.headY + g.headRadius == 10)
    #expect(g.streakY >= 0 && g.streakY + g.streakHeight <= g.stripHeight)
    #expect(g.headY - g.headRadius >= 0 && g.headY + g.headRadius <= g.stripHeight)
  }

  @Test func theHistoryKeepsTwoHundredDots() {
    var h = TimelineDots()
    for i in 0..<250 { h.add(TimelineDot(time: Double(i), color: red)) }
    #expect(h.count == 200)
    #expect(h.dots.first?.time == 50 && h.dots.last?.time == 249, "the oldest shift out")
    h.removeAll()
    #expect(h.isEmpty)
  }

  @Test func theConstantsArePinned() {
    #expect(TimelineGeometry.cap == 200 && TimelineGeometry.minWindowMs == 2000)
    #expect(TimelineGeometry.windowPadMs == 500 && TimelineGeometry.fadeStart == 0.85)
    #expect(TimelineGeometry.baseAlpha == 0.7 && TimelineGeometry.streakMax == 20)
    #expect(TimelineGeometry.streakPerWidth == 120)
    // the JS canvas rows (27 / 30), counted from the row the strip starts at
    #expect(TimelineGeometry.stripTop == 24)
    #expect(TimelineGeometry.streakY + TimelineGeometry.stripTop == 27)
    #expect(TimelineGeometry.headY + TimelineGeometry.stripTop == 30)
    #expect(TimelineGeometry.streakHeight == 6 && TimelineGeometry.headRadius == 4)
    #expect(ScopeFramePacer.fps == [30, 15, 8, 4], "repaint cap levels, owned by the hub's pacer")
  }
}

/// The strip's model against a real engine: the dots are the feed's fires.
@MainActor
struct TimelineDotsFeedTests {
  @Test func everyFireTheFeedLogsBecomesOneDotWithItsPartsColour() throws {
    let rig = try ScopeRig(net: ["A"], tempo: 300, block: 512)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = TimelineDotsModel(feed: feed)
    var seen = 0
    for _ in 0..<5 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      model.update(from: feed)
      seen = feed.fireCount
    }
    #expect(seen > 20, "the song fired: \(seen)")
    #expect(model.history.count == min(seen, TimelineGeometry.cap))
    // the newest dots are the newest fires, in time order, coloured by the part's own colour
    let lanes = feed.lanes
    var checked = 0
    var n = feed.fireCount - 1
    for dot in model.history.dots.reversed() {
      let f = try #require(feed.fireLog.fire(number: n))
      #expect(dot.time == f.time)
      #expect(dot.color == ScopeColors.laneColor(forNet: lanes[f.lane].ids[0]))
      n -= 1
      checked += 1
      if checked == 60 { break }
    }
    #expect(model.history.dots.allSatisfy { $0.time <= feed.nowTime })
    let kick = ScopeColors.laneColors["kick"]!
    #expect(model.history.dots.contains { $0.color == kick }, "techno has a kick")
    // looking again with nothing new adds nothing
    let before = model.history
    model.update(from: feed)
    #expect(model.history == before)
  }

  @Test func theStripStartsAtThePresentAndForgetsAnOldSong() throws {
    let rig = try ScopeRig(net: ["A"], tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 1)
    rig.hub.pump()
    #expect(feed.fireCount > 0)
    let model = TimelineDotsModel(feed: feed)
    model.update(from: feed)
    #expect(model.history.isEmpty, "fires from before the strip existed are not dots")
    rig.render(seconds: 1)
    rig.hub.pump()
    model.update(from: feed)
    #expect(!model.history.isEmpty)
    // a new acquire is a new generation: the strip is emptied
    feed.release()
    feed.acquire()
    model.update(from: feed)
    #expect(model.history.isEmpty)
    rig.render(seconds: 1)
    rig.hub.pump()
    model.update(from: feed)
    #expect(!model.history.isEmpty, "and fills again from the new generation")
  }
}

/// The strip holds its deck's feed only while the deck's transport runs: a stopped deck on
/// screen costs no tap, no pump and no redraw.
@MainActor
struct TimelineDotsFollowTests {
  @Test func aStoppedDeckHoldsNoTapAndARunningOneDoes() throws {
    let rig = try ScopeRig(net: ["A"], play: false)  // stopped
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    let sub = ScopeSubscription()
    // the strip appears over a stopped deck
    sub.follow(feed, while: false)
    #expect(sub.feed == nil && !a.tap.isEnabled && rig.hub.activeFeeds.isEmpty)
    rig.render(seconds: 0.2)
    rig.hub.pump()
    #expect(feed.history.isEmpty && feed.subscribers == 0, "nothing is pumped for it")
    // the deck starts: the strip takes the feed, once however often it is asked
    a.setPlaying(true)
    sub.follow(feed, while: true)
    sub.follow(feed, while: true)
    #expect(sub.feed === feed && a.tap.isEnabled && a.tap.subscribers == 1)
    #expect(rig.hub.activeFeeds.count == 1)
    rig.render(seconds: 0.3)
    rig.hub.pump()
    #expect(!feed.history.isEmpty && feed.fireCount > 0, "and it is fed")
    // the deck stops: the feed is let go, the tap is off again
    a.setPlaying(false)
    sub.follow(feed, while: false)
    #expect(sub.feed == nil && !a.tap.isEnabled && rig.hub.activeFeeds.isEmpty)
    // the strip goes off screen
    sub.release()
    #expect(feed.subscribers == 0)
  }

  @Test func anotherSubscriberKeepsTheTapOnWhenTheStripLetsGo() throws {
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    let a = try #require(rig.dj["A"])
    let feed = rig.hub.feed(.deck("A"))
    let panel = ScopeSubscription()
    let strip = ScopeSubscription()
    panel.move(to: feed)
    strip.follow(feed, while: true)
    #expect(feed.subscribers == 2 && a.tap.subscribers == 1)
    strip.follow(feed, while: false)
    #expect(feed.subscribers == 1 && a.tap.isEnabled, "the scope panel still reads the deck")
    panel.release()
    #expect(!a.tap.isEnabled)
  }
}
