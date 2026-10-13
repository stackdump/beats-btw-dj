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

  /// Where the playhead crosses a section's name its line breaks, so the name stays legible;
  /// above and below the name the line (and the caps) still mark the position.
  @Test func thePlayheadBreaksOverAName() throws {
    let t = SectionTimeline(
      segments: [.init(name: "buildup", start: 0, width: 1, isCurrent: true)], playhead: 0.5,
      totalTicks: 200)
    let px = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    let x = 200  // inside "buildup", centred in its block
    var white = 0
    for y in 11...19 where px.near(x, y, (255, 255, 255), tol: 40) { white += 1 }
    #expect(white < 7, "\(white) of 9 white pixels through the name: the line runs over it")
    #expect(px.near(x, 5, (255, 255, 255), tol: 60), "the line above the name")
    #expect(px.near(x, 25, (255, 255, 255), tol: 60), "the line below the name")
  }

  /// The playhead's caps mark it at the top and bottom edges, so it reads over a pale block.
  @Test func thePlayheadHasCaps() throws {
    let px = try #require(
      renderPixels(SectionTimelineView(timeline: timeline), width: 400, height: 30))
    #expect(px.near(197, 0, (255, 255, 255), tol: 60) && px.near(202, 0, (255, 255, 255), tol: 60))
    #expect(
      px.near(197, 29, (255, 255, 255), tol: 60) && px.near(202, 29, (255, 255, 255), tol: 60))
  }
}
