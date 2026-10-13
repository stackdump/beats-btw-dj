import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct SectionTimelineRenderTests {
  let timeline = SectionTimeline(
    segments: [
      .init(name: "intro", start: 0, width: 0.25, isCurrent: false),
      .init(name: "drop", start: 0.25, width: 0.5, isCurrent: true),
      .init(name: "outro", start: 0.75, width: 0.25, isCurrent: false),
    ], playhead: 0.5, totalTicks: 200)

  @Test func theCurrentSectionIsBrighterAndThePlayheadIsDrawn() throws {
    let px = try #require(
      renderPixels(SectionTimelineView(timeline: timeline), width: 400, height: 30))
    let current = px.color(150, 4)
    let other = px.color(30, 4)
    func lum(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Int { c.r + c.g + c.b }
    #expect(lum(current) > lum(other) + 100, "current \(current) other \(other)")
    #expect(
      px.near(200, 4, (255, 255, 255), tol: 40) || px.near(199, 4, (255, 255, 255), tol: 40),
      "playhead at 0.5")
    // segments are separated by a thin gap and coloured by name (drop ≠ outro)
    #expect(
      px.color(150, 20).r != px.color(350, 20).r || px.color(150, 20).g != px.color(350, 20).g)
  }

  @Test func nothingToDrawWithoutASong() throws {
    let px = try #require(renderPixels(SectionTimelineView(timeline: nil), width: 100, height: 20))
    #expect(px.count(inX: 0..<100, y: 0..<20) { r, g, b in r > 40 || g > 40 || b > 40 } == 0)
  }

  /// A section too narrow for its name shows its initial; the playhead's caps mark it at the
  /// top and bottom edges.
  @Test func narrowSectionsShowTheirInitialAndThePlayheadHasCaps() throws {
    let t = SectionTimeline(
      segments: [
        .init(name: "intro", start: 0, width: 0.06, isCurrent: false),
        .init(name: "drop", start: 0.06, width: 0.94, isCurrent: true),
      ], playhead: 0.5, totalTicks: 200)
    let px = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    // the "I" in the 24 px intro block: bright pixels in its middle
    let letter = px.count(inX: 8..<16, y: 10..<20) { r, g, b in r > 180 && g > 180 && b > 180 }
    #expect(letter > 3, "initial \(letter)")
    // caps: white 3 px either side of the line at the top edge
    #expect(px.near(197, 0, (255, 255, 255), tol: 60) && px.near(202, 0, (255, 255, 255), tol: 60))
  }
}
