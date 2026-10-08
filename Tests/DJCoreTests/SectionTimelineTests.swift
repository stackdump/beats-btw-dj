import Testing

@testable import DJCore

@MainActor
struct SectionTimelineTests {
  @Test func segmentsCoverTheSongAndFollowTheClock() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    #expect(a.sectionTimeline == nil)
    await a.generate(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    let t0 = try #require(a.sectionTimeline)
    #expect(t0.segments.count == a.sections.count && t0.segments[0].start == 0)
    #expect(abs(t0.segments.map(\.width).reduce(0, +) - 1) < 1e-9)
    for (s, n) in zip(t0.segments.dropFirst(), t0.segments) {
      #expect(abs(s.start - (n.start + n.width)) < 1e-9, "contiguous")
    }
    #expect(t0.segments[0].isCurrent && t0.playhead == 0)
    a.wave.setTempo(900)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 22_050 * 4)
    let t1 = try #require(a.sectionTimeline)
    #expect(t1.playhead > 0 && t1.playhead < 1)
    let cur = try #require(t1.segments.firstIndex { $0.isCurrent })
    #expect(
      t1.segments[cur].start <= t1.playhead
        && t1.playhead < t1.segments[cur].start + t1.segments[cur].width + 1e-9)
    #expect(t1.segments.filter(\.isCurrent).count == 1)
  }

  @Test func clicksLandOnTheRightSection() {
    let t = SectionTimeline(
      segments: [
        .init(name: "intro", start: 0, width: 0.2, isCurrent: false),
        .init(name: "drop", start: 0.2, width: 0.5, isCurrent: true),
        .init(name: "outro", start: 0.7, width: 0.3, isCurrent: false),
      ], playhead: 0.3, totalTicks: 100)
    #expect(t.index(atFraction: 0) == 0)
    #expect(t.index(atFraction: 0.1999) == 0 && t.index(atFraction: 0.2) == 1)
    #expect(t.index(atFraction: 0.69) == 1 && t.index(atFraction: 0.7) == 2)
    #expect(t.index(atFraction: 1.5) == 2 && t.index(atFraction: -3) == 0)
    #expect(SectionTimeline(segments: [], playhead: 0, totalTicks: 0).index(atFraction: 0.5) == nil)
  }

  @Test func hueIsStablePerName() {
    #expect(SectionTimeline.hue("drop") == SectionTimeline.hue("drop"))
    #expect(SectionTimeline.hue("drop") != SectionTimeline.hue("breakdown"))
    #expect((0..<1).contains(SectionTimeline.hue("verse")))
  }
}
