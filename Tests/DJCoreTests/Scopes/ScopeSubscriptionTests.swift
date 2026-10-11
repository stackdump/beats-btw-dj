import Testing

@testable import DJCore

@MainActor
struct ScopeSubscriptionTests {
  /// Which taps are switched on: deck A, deck B, master.
  func taps(_ rig: ScopeRig) -> [Bool] {
    [rig.dj["A"]!.tap.isEnabled, rig.dj["B"]!.tap.isEnabled, rig.dj.masterTap.isEnabled]
  }

  @Test func theSubscriptionFollowsThePanelThroughItsLife() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let sub = ScopeSubscription()
    #expect(sub.feed == nil && taps(rig) == [false, false, false] && rig.hub.activeFeeds.isEmpty)
    // appear on deck A
    sub.move(to: rig.hub.feed(.deck("A")))
    #expect(taps(rig) == [true, false, false])
    #expect(rig.dj["A"]!.tap.subscribers == 1 && sub.feed === rig.hub.feed(.deck("A")))
    // the same source again (an onChange that did not change the feed): no second acquire
    sub.move(to: rig.hub.feed(.deck("A")))
    #expect(rig.dj["A"]!.tap.subscribers == 1 && rig.hub.feed(.deck("A")).subscribers == 1)
    // A -> master -> B: the old tap goes off, the new one on
    sub.move(to: rig.hub.feed(.master))
    #expect(taps(rig) == [false, false, true])
    #expect(rig.hub.feed(.deck("A")).subscribers == 0 && rig.hub.feed(.master).subscribers == 1)
    sub.move(to: rig.hub.feed(.deck("B")))
    #expect(taps(rig) == [false, true, false])
    #expect(rig.hub.activeFeeds.count == 1)
    // the feed it holds is pumped: it has data after a render
    rig.render(frames: 4096)
    rig.hub.pump()
    #expect(rig.hub.feed(.deck("B")).history.count == 4096)
    // disappear: everything is off, a second release changes nothing
    sub.release()
    #expect(sub.feed == nil && taps(rig) == [false, false, false] && rig.hub.activeFeeds.isEmpty)
    sub.release()
    sub.move(to: nil)
    #expect(taps(rig) == [false, false, false] && rig.dj["B"]!.tap.subscribers == 0)
    // and it can come back
    sub.move(to: rig.hub.feed(.master))
    #expect(taps(rig) == [false, false, true])
    sub.release()
    #expect(taps(rig) == [false, false, false])
  }

  @Test func twoPanelsOnOneFeedKeepItsTapOnUntilTheLastLeaves() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    let one = ScopeSubscription()
    let two = ScopeSubscription()
    one.move(to: feed)
    two.move(to: feed)
    #expect(feed.subscribers == 2 && rig.dj.masterTap.subscribers == 1, "one tap, two readers")
    one.release()
    #expect(feed.subscribers == 1 && rig.dj.masterTap.isEnabled)
    two.release()
    #expect(feed.subscribers == 0 && !rig.dj.masterTap.isEnabled)
  }

  @Test func movingToAnotherFeedStartsItFresh() throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let sub = ScopeSubscription()
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    sub.move(to: a)
    rig.render(frames: 8192)
    rig.hub.pump()
    #expect(a.history.count == 8192 && a.fireCount > 0)
    sub.move(to: b)
    #expect(b.history.isEmpty && b.fireCount == 0 && b.generation != a.generation)
    sub.move(to: a)  // back: it starts over, from now, and says so
    #expect(a.history.isEmpty && a.fireLog.isEmpty && a.nowFrame == 8192)
    sub.release()
  }
}
