import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// A stage of N invisible panels (no net is drawn in them) over the real layer stack, so the only
/// things on the black are the overlay layers under test: pulse, flame, bolts, seeds and halo.
/// The layer models are advanced by hand, frame by frame, with the context the test builds, so a
/// particle's age and a beam's energy are exactly what the test says.
///
/// The 1000 x 800 stage with 4 panels: side 240, ring radius 256, centre (500, 400), panel
/// centres (500,144) (756,400) (500,656) (244,400), dark planet radius 56.8. The meta-net is off
/// unless asked for (its arcs would run under a probe).
@MainActor
struct OverlayStage {
  static let width = 1000
  static let height = 800

  let model: StageModel
  private(set) var context: StageContext
  var now: Double { context.now }

  init(
    panels count: Int = 4, overlays: Set<StageOverlay> = StageOverlay.defaults,
    metaRotation: Double = 0, meta: Bool = false, models: StageLayerModels = StageLayerModels()
  ) throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    model = StageModel(hub: ScopeHub(engine: dj), layers: models)
    var layout = StagePanelLayout.layoutRing(
      width: Double(Self.width), height: Double(Self.height), count: count)
    layout.showsMeta = meta && layout.showsMeta
    let shape = StageNetShape(
      netId: "n", placeIds: ["p"], placeX: [0], placeY: [0], transitionIds: ["t"],
      transitionX: [60], transitionY: [0])
    let panels = (0..<count).map { i in
      let center = i < layout.panelCenters.count ? layout.panelCenters[i] : layout.center
      return StagePanel(
        id: "A/n\(i)", deck: "A", netId: "n\(i)", label: "n\(i)", channel: 1, riffGroup: "",
        center: center, ring: layout.hasRing ? center : nil, side: layout.side, angle: 0,
        view: nil, muted: false, opacity: 1, shape: shape, tokens: [0], firedAt: [-.infinity])
    }
    context = StageContext(
      width: Double(Self.width), height: Double(Self.height), layout: layout, panels: panels,
      now: 10, dt: 0, audioNow: 10, metaRotation: metaRotation, overlays: overlays)
  }

  var layers: StageLayerModels { model.layers }

  /// One frame: the layer models see `context` (advanced by `dt`, with `fires`), in registry order.
  mutating func step(
    dt: Double = 0.05, fires: [StageFire] = [], overlays: Set<StageOverlay>? = nil,
    metaRotation: Double? = nil
  ) {
    context.now += dt
    context.audioNow = context.now
    context.dt = dt
    context.fires = fires
    if let overlays { context.overlays = overlays }
    if let metaRotation { context.metaRotation = metaRotation }
    for layer in layers.all { layer.advance(context) }
  }

  /// A fire at the stage point `origin` of panel `panel`, read `age` seconds ago.
  func fire(
    panel: Int = 0, origin: StagePoint?, age: Double = 0, macro: Bool = false
  ) -> StageFire {
    StageFire(
      time: context.audioNow - age, wallTime: context.now - age, panel: panel, deck: "A",
      netId: "n\(panel)", transitionId: "t", transition: 0, origin: origin, note: 60,
      velocity: 100, channel: 1, durSec: 0.1, macroRunning: macro)
  }

  var scene: some View { StageScene(model: model, context: context) }

  func pixels() throws -> Pixels {
    try #require(renderPixels(scene, width: Self.width, height: Self.height))
  }
}

/// Pixel probes shared by the overlay render tests.
enum OverlaySwatch {
  /// `fg` at `alpha` over `bg`, 8-bit.
  static func over(_ fg: (Int, Int, Int), _ alpha: Double, _ bg: (Int, Int, Int)) -> (Int, Int, Int)
  {
    StageSwatch.blend(fg, alpha, over: bg)
  }

  /// The pixels of `after` that differ from `before` by more than `tol` in any channel.
  static func changed(
    _ before: Pixels, _ after: Pixels, tol: Int = 3, in xs: Range<Int>? = nil,
    _ ys: Range<Int>? = nil
  ) -> [(x: Int, y: Int, color: (r: Int, g: Int, b: Int, a: Int))] {
    var out: [(x: Int, y: Int, color: (r: Int, g: Int, b: Int, a: Int))] = []
    for y in ys ?? 0..<after.height {
      for x in xs ?? 0..<after.width {
        let a = before.color(x, y)
        let b = after.color(x, y)
        if abs(a.r - b.r) > tol || abs(a.g - b.g) > tol || abs(a.b - b.b) > tol {
          out.append((x, y, b))
        }
      }
    }
    return out
  }
}
