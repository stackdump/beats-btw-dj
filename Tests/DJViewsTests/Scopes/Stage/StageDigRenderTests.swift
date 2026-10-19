import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The "Dig" visualizer, rendered: the layer on a synthetic context at points of a real composed
// song's control timeline (techno 42, standard: buildup 64, drop 256). Set DJ_SHOT_DIR to also
// write the frames as PNGs.

@MainActor
@Suite struct StageDigRenderTests {
  static let w = 1000
  static let h = 600

  static let timeline: StageControlTimeline = {
    let spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    return StageControlTimeline.build(DJMusicality.apply(spec.project(), spec: spec))
  }()

  static func frame(_ step: Double, name: String) throws -> (Pixels, StageDigScene) {
    let m = StageDigModel()
    let ctx = StageContext(
      width: Double(w), height: Double(h),
      layout: StagePanelLayout.layoutRing(width: Double(w), height: Double(h), count: 0),
      now: 100, dt: 1.0 / 30, selection: .dig, visualizer: .dig)
    m.advance(ctx, timeline: timeline, step: step, tickSec: 0.05)
    let view = ZStack {
      StagePalette.background.color
      StageDigLayer(context: ctx, model: m)
    }
    savePNG(view, width: w, height: h, name: "dig-\(name)")
    return (try #require(renderPixels(view, width: w, height: h)), m.scene)
  }

  static func count(_ px: Pixels, _ match: (Int, Int, Int) -> Bool) -> Int {
    var n = 0
    for y in stride(from: 0, to: px.height, by: 2) {
      for x in stride(from: 0, to: px.width, by: 2) {
        let c = px.color(x, y)
        if match(c.r, c.g, c.b) { n += 1 }
      }
    }
    return n
  }

  @Test func theMinerDigsByTorchlight() throws {
    let (px, s) = try Self.frame(150, name: "buildup")
    #expect(s.mined == 4 && s.crack > 0)
    // the helmet and the torches: yellow on a dark tunnel
    #expect(Self.count(px) { r, g, b in r > 200 && g > 160 && b < 80 } > 10)
    // the tunnel is dark away from the light, lit around the miner
    let far = px.color(10, 10)
    #expect(far.r < 60 && far.g < 60 && far.b < 60, "\(far)")
  }

  @Test func theDiamondIsSeenComingAndFlashesAtTheDrop() throws {
    let (before, s) = try Self.frame(250, name: "diamond-face")
    #expect(s.faceOre == .diamond)
    let cyan = { (r: Int, g: Int, b: Int) in r < 140 && g > 190 && b > 180 }
    #expect(Self.count(before, cyan) > 4, "the diamond's specks on the face")
    let (flash, f) = try Self.frame(257, name: "diamond-break")
    #expect(f.flash > 0.2)
    let mean = { (px: Pixels) -> Double in
      Double(Self.count(px) { r, g, b in r + g + b > 450 }) }
    #expect(mean(flash) > mean(before) * 2, "the break washes the tunnel white")
  }

  @Test func aStrideOnIntoTheDrop() throws {
    _ = try Self.frame(320, name: "drop-deepslate")
    _ = try Self.frame(470, name: "verse")
  }
}
