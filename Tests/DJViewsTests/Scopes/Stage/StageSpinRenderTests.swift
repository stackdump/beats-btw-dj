import DJCore
import SwiftUI
import Testing

@testable import DJViews

private typealias Sw = StageSwatch

@MainActor
struct StageSpinRenderTests {
  func render(_ rig: StageViewRig, _ ctx: StageContext? = nil) throws -> Pixels {
    let view = StageScene(model: rig.model, context: ctx ?? rig.model.context)
    return try #require(renderPixels(view, width: Int(rig.width), height: Int(rig.height)))
  }

  @Test func theWholeDiagramTurnsWithTheTrackSpin() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    var ctx = rig.model.context
    ctx.metaRotation = 0
    let flat = try render(rig, ctx)
    ctx.metaRotation = 90
    let turned = try render(rig, ctx)
    func lit(_ px: Pixels, _ x: Int, _ y: Int, _ r: Int) -> Int {
      px.count(inX: (x - r)..<(x + r), y: (y - r)..<(y + r)) { red, g, b in
        abs(red - 10) + abs(g - 10) + abs(b - 26) > 24
      }
    }
    // the top panel (500, 120) swings a quarter turn clockwise about the centre to (780, 400),
    // where the ring has a gap between its two right-hand panels
    #expect(lit(flat, 500, 120, 70) > 300 && lit(flat, 780, 400, 30) == 0)
    #expect(lit(turned, 780, 400, 70) > 300 && lit(turned, 500, 120, 30) == 0)
    // a rotation keeps the ink: the same amount of the window is drawn on
    let whole = { (p: Pixels) in
      p.count(inX: 0..<1000, y: 0..<800) { r, g, b in abs(r - 10) + abs(g - 10) + abs(b - 26) > 24 }
    }
    #expect(
      abs(whole(turned) - whole(flat)) < whole(flat) / 20, "\(whole(flat)) vs \(whole(turned))")
    savePNG(
      StageScene(model: rig.model, context: ctx), width: 1000, height: 800, name: "stage-spin-90")
  }
}
