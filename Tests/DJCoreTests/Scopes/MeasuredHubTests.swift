import Testing

@testable import DJCore

// The hub feeds the measured reader whenever "measured" is ticked, in whichever view is on
// (beats-bitwrap-io 095d030 scope.js `frame()`: `if (s.measured) readMeasured(...)` runs for every
// view, not only the ones that draw the measured half). No view controller is involved here:
// these tests only pump the hub, as the canvas of Scope/Live or Raster does.
@MainActor
struct MeasuredHubTests {
  private func pump(_ rig: ScopeRig, seconds: Double) {
    for _ in 0..<Int((seconds * 10).rounded()) {
      rig.render(seconds: 0.1)
      rig.hub.pump()
    }
  }

  @Test func aTickedFeedIsReadOnEveryPumpWithNoModeControllerAtAll() throws {
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = rig.readers.reader(for: feed)
    pump(rig, seconds: 1)
    #expect(reader.reads == 0 && !rig.hub.isMeasured(feed), "unticked: nothing is read")
    rig.hub.setMeasured(true, for: feed)
    pump(rig, seconds: 4)
    #expect(rig.hub.isMeasured(feed))
    #expect(reader.reads >= 38, "one read per pump with new audio: \(reader.reads)")
    #expect(reader.maxBar >= 3 && reader.measFrom.isFinite)
    let first = Int(reader.measFrom / 16)
    // every bar between the first and the last has its ~8 reads (0.8 s a bar, a pump every 0.1 s);
    // the first one is entered part-way and the last is still filling
    #expect(reader.measCnt[first] >= 1)
    for bar in (first + 1)..<reader.maxBar {
      #expect(reader.measCnt[bar] >= 6, "bar \(bar) has \(reader.measCnt[bar]) reads")
    }
  }

  @Test func aSecondCallInTheSameFrameReadsNothingTwice() throws {
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.setMeasured(true, for: feed)
    pump(rig, seconds: 1)
    let reader = rig.readers.reader(for: feed)
    let reads = reader.reads
    rig.hub.pump()
    reader.update(feed: feed, enabled: true)  // a mode controller in the same frame
    #expect(reader.reads == reads)
  }

  @Test func untickingStopsTheReadsAndTickingAgainStartsAFreshCoverageWindow() throws {
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.setMeasured(true, for: feed)
    pump(rig, seconds: 2)
    let reader = rig.readers.reader(for: feed)
    let reads = reader.reads
    let from = reader.measFrom
    #expect(reads > 10 && from.isFinite)
    rig.hub.setMeasured(false, for: feed)
    pump(rig, seconds: 1)
    #expect(reader.reads == reads && !rig.hub.isMeasured(feed))
    // re-ticked: scope.js `if (s.measured) s.measFrom = Infinity` — a window of its own
    rig.hub.setMeasured(true, for: feed)
    pump(rig, seconds: 0.2)
    #expect(reader.reads > reads)
    #expect(reader.measFrom > from, "restarted at the step it came back on: \(reader.measFrom)")
  }

  @Test func onlyTheTickedFeedsAreRead() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    a.acquire()
    b.acquire()
    rig.hub.setMeasured(true, for: a)
    pump(rig, seconds: 1)
    #expect(rig.readers.reader(for: a).reads > 5 && rig.readers.reader(for: b).reads == 0)
  }

  @Test func theSubscriptionKeepsTheHubReadingTheFeedItHolds() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let sub = ScopeSubscription()
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    // appear on A with "measured" ticked
    sub.move(to: a)
    sub.syncMeasured(true, hub: rig.hub)
    #expect(rig.hub.isMeasured(a) && sub.measuredFeed === a)
    sub.syncMeasured(true, hub: rig.hub)  // nothing changed
    #expect(rig.hub.isMeasured(a))
    pump(rig, seconds: 1)
    #expect(rig.readers.reader(for: a).reads > 5)
    // the source changes: the reading follows it
    sub.move(to: b)
    sub.syncMeasured(true, hub: rig.hub)
    #expect(!rig.hub.isMeasured(a) && rig.hub.isMeasured(b) && sub.measuredFeed === b)
    // unticked while the panel stays
    sub.syncMeasured(false, hub: rig.hub)
    #expect(!rig.hub.isMeasured(b) && sub.measuredFeed == nil && sub.feed === b)
    // ticked again and then the panel goes away (the host unsyncs first)
    sub.syncMeasured(true, hub: rig.hub)
    sub.syncMeasured(false, hub: rig.hub)
    sub.release()
    #expect(!rig.hub.isMeasured(a) && !rig.hub.isMeasured(b) && rig.hub.activeFeeds.isEmpty)
  }
}
