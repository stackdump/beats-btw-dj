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
}
