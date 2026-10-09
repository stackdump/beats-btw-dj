import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct StageHostLifecycleTests {
  @Test func theHostAcquiresTheFeedOnAppearAndReleasesItOnDisappear() throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    rig.model.detach()
    #expect(feed.subscribers == 0 && !rig.dj["A"]!.tap.isEnabled && !rig.model.isAttached)

    let mount = StageHostHarness(model: rig.model)
    mount.settle()
    #expect(rig.model.isAttached, "onAppear attaches the model")
    #expect(feed.subscribers == 1 && rig.dj["A"]!.tap.isEnabled, "and the tap goes on")

    mount.unmount()
    mount.settle()
    #expect(!rig.model.isAttached, "onDisappear detaches it")
    #expect(feed.subscribers == 0 && !rig.dj["A"]!.tap.isEnabled, "and the tap goes off")
  }

  @Test func reopeningTheWindowBringsTheSameModelBackToLife() throws {
    let rig = try StageViewRig(play: false)
    defer { rig.stop() }
    rig.model.detach()
    let feed = rig.hub.feed(.deck("A"))
    let first = StageHostHarness(model: rig.model)
    first.settle()
    #expect(feed.subscribers == 1)
    first.unmount()
    first.settle()
    #expect(feed.subscribers == 0)
    // reopened: the same model comes back to life
    let again = StageHostHarness(model: rig.model)
    again.settle()
    #expect(rig.model.isAttached && feed.subscribers == 1)
    again.unmount()
    again.settle()
    #expect(feed.subscribers == 0)
  }
}
