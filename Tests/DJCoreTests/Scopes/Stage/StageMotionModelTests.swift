import Testing

@testable import DJCore

// Flow and spin in the model (SPEC modes 13 and 20).

@MainActor
struct StageMotionModelTests {
  @Test func expandingAndSwitchingTheViewDoNotTurnTheDiagram() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    #expect(
      h.model.spin.target == 0 && !h.ctx.trackChanged, "the first build is not a track change")
    h.model.settings.expandVariants = true
    h.run(0.1)
    #expect(
      h.model.spin.target == 0 && !h.ctx.trackChanged, "toggling the view is not a track change")
    h.model.settings.expandVariants = false
    h.run(0.1)
    #expect(h.model.spin.target == 0)
  }

  @Test func switchingTheSourceDoesNotTurnTheDiagram() throws {
    let h = try StageHarness(net: ["A", "B"], source: .deck("A"))
    defer { h.stop() }
    h.run(0.3)
    h.model.settings.source = .master
    h.run(0.2)
    h.model.settings.source = .deck("B")
    h.run(0.2)
    #expect(h.model.spin.target == 0)
  }

  @Test func aNewTrackTurnsTheWholeDiagramAQuarter() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    let epoch = h.ctx.epoch
    let serial = try #require(h.rig.hub.feed(.deck("A")).marking()?.layout?.trackSerial)
    // another song, queued at the next bar while the deck plays
    h.deck.loadNet(scopeProject("techno", seed: 7, structure: "standard"))
    var turnedAt: Int?
    for i in 0..<120 {
      h.step()
      if h.ctx.trackChanged {
        turnedAt = i
        break
      }
    }
    _ = try #require(turnedAt, "the swap lands within a bar or two")
    let c = h.ctx
    #expect(c.epoch == epoch + 1 && h.model.spin.target == 90)
    let now = try #require(h.rig.hub.feed(.deck("A")).marking()?.layout?.trackSerial)
    #expect(now != serial)
    #expect(c.metaRotation > 0 && c.metaRotation < 90, "easing toward the target")
    // trackChanged is true for exactly the frame it landed on
    h.step()
    #expect(!h.ctx.trackChanged)
    // it settles on exactly 90
    h.run(3)
    #expect(h.ctx.metaRotation == 90 && h.model.spin.rotation == 90)
    #expect(h.ctx.epoch == epoch + 1, "one rebuild for one track change")
  }

  @Test func aStoppedDeckThatLoadsATrackTurnsToo() throws {
    let h = try StageHarness(play: false)
    defer { h.stop() }
    h.run(0.1)
    let first = h.ctx
    #expect(first.panels.count > 0 && h.model.spin.target == 0)
    h.deck.loadNet(scopeProject("techno", seed: 9, structure: "standard"))
    h.run(0.2)
    #expect(h.model.spin.target == 90 && h.ctx.epoch == first.epoch + 1)
  }

  @Test func aDeckThatLosesItsNetIsNotATrackChange() throws {
    let h = try StageHarness(play: false)
    defer { h.stop() }
    h.run(0.2)
    let first = h.ctx
    #expect(first.panels.count == 6 && h.model.spin.target == 0)
    // a sample is loaded where the net was: nothing new started, so nothing turns (and the card
    // flash, which keys on `trackChanged`, stays down)
    h.deck.loadDemo()
    h.run(0.3)
    #expect(h.ctx.panels.isEmpty && !h.ctx.hasNet, "no net, no panels")
    #expect(h.ctx.epoch == first.epoch + 1, "the panels are rebuilt (to none)")
    #expect(h.model.spin.target == 0 && !h.frames.contains { $0.trackChanged })
    // a net comes back: the first track of an empty stage is not a turn either
    h.deck.loadNet(scopeProject("techno", seed: 7, structure: "standard"))
    h.run(0.3)
    #expect(h.ctx.panels.count == 6)
    #expect(h.model.spin.target == 0 && !h.frames.contains { $0.trackChanged })
    // but a net swapped for another one is the real thing
    h.deck.loadNet(scopeProject("techno", seed: 9, structure: "standard"))
    h.run(0.3)
    #expect(h.model.spin.target == 90 && h.frames.contains { $0.trackChanged })
  }

  @Test func inTheMasterOnlyADeckSwappingItsSongTurnsTheDiagram() throws {
    let h = try StageHarness(net: ["A", "B"], source: .master, play: false)
    defer { h.stop() }
    h.run(0.2)
    #expect(Set(h.ctx.panels.map(\.deck)) == ["A", "B"] && h.model.spin.target == 0)
    // B drops to a sample: A's panels stay, no turn
    h.rig.dj["B"]!.loadDemo()
    h.run(0.3)
    #expect(Set(h.ctx.panels.map(\.deck)) == ["A"] && h.model.spin.target == 0)
    #expect(!h.frames.contains { $0.trackChanged })
    // B gets a net again: still not a turn
    h.rig.dj["B"]!.loadNet(scopeProject("house", seed: 5, structure: "standard"))
    h.run(0.3)
    #expect(Set(h.ctx.panels.map(\.deck)) == ["A", "B"] && h.model.spin.target == 0)
    // A swaps its song: a quarter turn
    h.deck.loadNet(scopeProject("techno", seed: 9, structure: "standard"))
    h.run(0.3)
    #expect(h.model.spin.target == 90)
  }

  @Test func aTrackLoadedWhileTheWindowWasAwayDoesNotTurnItOnReturn() throws {
    let h = try StageHarness(play: false)
    defer { h.stop() }
    h.run(0.2)
    h.model.detach()
    h.deck.loadNet(scopeProject("techno", seed: 9, structure: "standard"))
    h.rig.render(frames: StageHarness.block * 4)
    h.model.attach()  // the feed is acquired afresh: a new feed, so a rebuild without the turn
    h.run(0.3)
    #expect(h.ctx.panels.count == 6)
    #expect(h.model.spin.target == 0 && !h.frames.contains { $0.trackChanged })
  }

  @Test func relaunchingASectionOfTheSameSongKeepsThePanels() throws {
    let h = try StageHarness(play: false)
    defer { h.stop() }
    h.run(0.1)
    let epoch = h.ctx.epoch
    let project = try #require(h.deck.netProject)
    let serial = try #require(h.deck.wave.latest?.trackSerial)
    let gen = h.deck.wave.latest?.generation
    h.deck.wave.load(
      WaveRunner.prepare(project, sampleRate: ScopeRig.rate, startTick: 32, trackSerial: serial))
    #expect(h.deck.wave.latest?.generation != gen, "a new generation, the same song")
    h.run(0.2)
    #expect(h.ctx.epoch == epoch, "no rebuild")
    #expect(h.model.spin.target == 0 && !h.frames.contains { $0.trackChanged })
    #expect(h.ctx.panels.map(\.id) == h.frames[0].panels.map(\.id))
  }

  @Test func theFlowDriftsEveryPanelAndCanBeSwitchedOff() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.1)
    let a0 = h.ctx.panels.map(\.angle)
    h.run(1)
    let a1 = h.ctx.panels.map(\.angle)
    let drift = zip(a0, a1).map { $1 - $0 }
    #expect(drift.allSatisfy { abs($0) > 2.5 && abs($0) < 9.5 }, "3...9 degrees a second: \(drift)")
    #expect(drift.contains { $0 > 0 } && drift.contains { $0 < 0 }, "both directions")
    h.model.settings.toggle(.flow)
    h.run(0.1)
    let b0 = h.ctx.panels.map(\.angle)
    h.run(1)
    #expect(h.ctx.panels.map(\.angle) == b0, "flow off: no drift")
  }

  @Test func theseededDriftIsReproducible() throws {
    let a = try StageHarness()
    let b = try StageHarness()
    defer {
      a.stop()
      b.stop()
    }
    a.run(1)
    b.run(1)
    #expect(a.ctx.panels.map(\.angle) == b.ctx.panels.map(\.angle))
  }

  @Test func aReacquireOfTheFeedIsNotATrackChange() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    // the feed generation bumps on a re-acquire; the stage must not read it as a new track
    let feed = h.rig.hub.feed(.deck("A"))
    let gen = feed.generation
    feed.acquire()
    feed.release()
    h.model.detach()
    h.model.attach()
    h.run(0.2)
    #expect(feed.generation != gen, "the feed did reset")
    #expect(h.model.spin.target == 0, "but it is the same song")
  }
}
