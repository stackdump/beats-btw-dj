import Foundation

@testable import DJCore

// Synthetic stage contexts for the overlay layers' unit tests (pulse, flame, tilt, bolts): a ring
// of N panels laid out by the real `layoutRing`, each holding a one-transition net, and fires
// whose origins the test states outright, so the expected numbers are plain arithmetic on the
// layout (a 1000 x 800 stage with 4 panels: side 240, ring radius 256, centre (500, 400), panel
// centres (500,144) (756,400) (500,656) (244,400), dark planet radius 56.8).
//
// (No Testing import here: Foundation lives in a file like this one, see AllocationCounter.swift.)

func stageAtan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) }

enum OverlayFixture {
  static let width = 1000.0
  static let height = 800.0

  /// A ring of `count` panels, panel `i` holding the net `n<i>` with one transition `t`.
  static func panels(_ count: Int, layout: StageRingLayout) -> [StagePanel] {
    (0..<count).map { i in
      let shape = StageNetShape(
        netId: "n\(i)", placeIds: ["p"], placeX: [0], placeY: [0], transitionIds: ["t"],
        transitionX: [60], transitionY: [0])
      let content = StagePanelView.contentSize(side: layout.side)
      let center = i < layout.panelCenters.count ? layout.panelCenters[i] : layout.center
      return StagePanel(
        id: "A/n\(i)", deck: "A", netId: "n\(i)", label: "n\(i)", channel: 1, riffGroup: "",
        center: center, ring: layout.hasRing ? center : nil, side: layout.side, angle: 0,
        view: StagePanelView.fit(bounds: shape.bounds!, width: content, height: content),
        muted: false, opacity: 1, shape: shape, tokens: [0], firedAt: [-.infinity])
    }
  }

  /// A frame of the stage: `count` panels, `now` seconds, a `dt` step, the given fires and toggles.
  static func context(
    panels count: Int = 4, now: Double = 10, dt: Double = 0.05, fires: [StageFire] = [],
    overlays: Set<StageOverlay> = StageOverlay.defaults, width: Double = OverlayFixture.width,
    height: Double = OverlayFixture.height, metaRotation: Double = 0, epoch: Int = 0
  ) -> StageContext {
    let layout = StagePanelLayout.layoutRing(width: width, height: height, count: count)
    return StageContext(
      width: width, height: height, layout: layout, panels: panels(count, layout: layout),
      now: now, dt: dt, audioNow: now, fires: fires, metaRotation: metaRotation,
      overlays: overlays, epoch: epoch)
  }

  /// A fire on panel `panel` (nil: a net without a panel) at `origin`, read at wall time `wall`
  /// seconds.
  static func fire(
    panel: Int? = 0, origin: StagePoint?, wall: Double, macro: Bool = false
  ) -> StageFire {
    StageFire(
      time: wall, wallTime: wall, panel: panel, deck: "A", netId: panel.map { "n\($0)" } ?? "x",
      transitionId: "t", transition: panel == nil ? nil : 0, origin: origin, note: 60,
      velocity: 100, channel: 1, durSec: 0.1, macroRunning: macro)
  }
}
