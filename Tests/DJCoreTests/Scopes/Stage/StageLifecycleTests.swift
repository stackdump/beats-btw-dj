import Testing

@testable import DJCore

// The stage's feed subscription: "an idle app pays nothing" means the taps are on exactly while a
// stage is attached to the feed of its source, whatever the user does with the source picker.

@MainActor
struct StageLifecycleTests {
  struct Subscribers: Equatable {
    var a = 0
    var b = 0
    var master = 0
  }
  struct Taps: Equatable {
    var a = false
    var b = false
    var master = false
  }

  func subscribers(_ h: StageHarness) -> Subscribers {
    Subscribers(
      a: h.rig.hub.feed(.deck("A")).subscribers, b: h.rig.hub.feed(.deck("B")).subscribers,
      master: h.rig.hub.feed(.master).subscribers)
  }

  func taps(_ h: StageHarness) -> Taps {
    Taps(
      a: h.rig.dj["A"]!.tap.isEnabled, b: h.rig.dj["B"]!.tap.isEnabled,
      master: h.rig.dj.masterTap.isEnabled)
  }

  @Test func theSubscriptionFollowsTheSourceAndNeverLeaksOne() throws {
    let h = try StageHarness(net: ["A", "B"], source: .deck("A"))
    defer { h.stop() }
    h.run(0.1)
    #expect(subscribers(h) == Subscribers(a: 1) && taps(h) == Taps(a: true))
    h.model.settings.source = .master
    h.run(0.1)
    #expect(subscribers(h) == Subscribers(master: 1), "A is let go, the master is held")
    #expect(taps(h) == Taps(master: true), "and only the master's tap is on")
    h.model.settings.source = .deck("B")
    h.run(0.1)
    #expect(subscribers(h) == Subscribers(b: 1) && taps(h) == Taps(b: true))
    h.model.settings.source = .deck("A")
    h.run(0.1)
    #expect(subscribers(h) == Subscribers(a: 1) && taps(h) == Taps(a: true))
    // a source that is not changed is not re-acquired
    h.run(0.3)
    #expect(subscribers(h) == Subscribers(a: 1))
  }

  @Test func detachReleasesAndAttachTakesTheCurrentSource() throws {
    let h = try StageHarness(net: ["A", "B"], source: .deck("A"))
    defer { h.stop() }
    h.run(0.1)
    h.model.detach()
    #expect(subscribers(h) == Subscribers() && taps(h) == Taps() && !h.model.isAttached)
    // the picker moves while the window is away: nothing is held, nothing is tapped
    h.model.settings.source = .deck("B")
    h.model.advance(now: h.now + 1, dt: 0.05, width: 1000, height: 800)
    #expect(subscribers(h) == Subscribers() && taps(h) == Taps())
    h.model.attach()
    #expect(subscribers(h) == Subscribers(b: 1) && taps(h) == Taps(b: true), "B, not A")
    h.model.attach()  // twice is once
    #expect(subscribers(h) == Subscribers(b: 1))
    h.model.detach()
    h.model.detach()
    #expect(subscribers(h) == Subscribers() && taps(h) == Taps())
  }

  @Test func aStageOpenedOverAFeedAnotherPanelHoldsReplaysNoOldFires() throws {
    let h = try StageHarness(source: .deck("A"), attach: false)
    defer { h.stop() }
    // The Scopes panel already holds the feed (two subscribers: the fire log is not reset when
    // the stage joins) and two seconds of fires pile up in it.
    let feed = h.rig.hub.feed(.deck("A"))
    feed.acquire()
    h.rig.render(frames: StageHarness.block * 40)
    h.rig.hub.pump()
    let logged = feed.fireLog.total
    #expect(logged > 20, "the log holds the earlier fires (\(logged))")
    h.model.attach()
    #expect(feed.subscribers == 2)
    h.model.advance(now: 500, dt: 0.05, width: 1000, height: 800)
    #expect(h.model.context.fires.isEmpty, "the first frame owes the stage nothing")
    h.run(0.5)
    let after = h.frames.flatMap(\.fires)
    #expect(after.count > 3, "fires from now on arrive (\(after.count))")
    #expect(after.allSatisfy { $0.time >= feed.nowTime - 0.6 }, "and are all recent")
    feed.release()
    #expect(feed.subscribers == 1)
  }
}
