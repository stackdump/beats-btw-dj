import Testing

@testable import DJCore

struct VizPacingTests {
  @Test func theRingGapsAreOnStateSyncsMinGap() {
    // backend/index.js: lvl >= 3 ? 2000 : lvl >= 2 ? 500 : 0
    #expect(RingRenderGate.minGap(level: 0) == 0)
    #expect(RingRenderGate.minGap(level: 1) == 0)
    #expect(RingRenderGate.minGap(level: 2) == 0.5)
    #expect(RingRenderGate.minGap(level: 3) == 2.0)
    #expect(RingRenderGate.minGap(level: 9) == 2.0)
    #expect(RingRenderGate.minGap(level: -1) == 0)
  }

  @Test func atFullAndReducedEveryPollRenders() {
    for level in [0, 1] {
      var g = RingRenderGate()
      let all = (0..<30).map { g.due(now: Double($0) / 30, level: level) }
      #expect(all.allSatisfy { $0 }, "level \(level)")
    }
  }

  @Test func atMinimalTheRingsRenderEveryHalfSecond() {
    var g = RingRenderGate()
    // 30 polls a second for 2 s
    let due = (0..<60).filter { g.due(now: Double($0) / 30, level: 2) }
    #expect(due == [0, 15, 30, 45], "t = 0, 0.5, 1.0, 1.5")
  }

  @Test func atPausedTheRingsRenderEveryTwoSeconds() {
    var g = RingRenderGate()
    let due = (0..<150).filter { g.due(now: Double($0) / 30, level: 3) }
    #expect(due == [0, 60, 120])
  }

  @Test func theGateMeasuresFromTheLastRenderNotFromTheLastPoll() {
    var g = RingRenderGate()
    let first = g.due(now: 10, level: 2)
    let soon = g.due(now: 10.4, level: 2)
    let almost = g.due(now: 10.499, level: 2)
    let on = g.due(now: 10.5, level: 2)
    let after = g.due(now: 10.6, level: 2)
    #expect(first && !soon && !almost && on && !after)
    // dropping to full lets the next poll through at once, and records it
    let full = g.due(now: 10.61, level: 0)
    #expect(full && g.lastRender == 10.61)
  }

  @Test func aSlowAnimationNeverGoesFasterThanTheLevelAllows() {
    // a running macro's glow breathes at 30 fps, an LED blinks at 15
    #expect(VizPacing.interval(level: 0, cappedAt: 1.0 / 30) == 1.0 / 30)
    #expect(VizPacing.interval(level: 1, cappedAt: 1.0 / 30) == 1.0 / 15)
    #expect(VizPacing.interval(level: 3, cappedAt: 1.0 / 30) == 0.25)
    #expect(VizPacing.interval(level: 0, cappedAt: 1.0 / 15) == 1.0 / 15)
    #expect(VizPacing.interval(level: 1, cappedAt: 1.0 / 15) == 1.0 / 15)
    #expect(VizPacing.interval(level: 2, cappedAt: 1.0 / 15) == 1.0 / 8)
    #expect(VizPacing.interval(level: 3, cappedAt: 1.0 / 15) == 0.25)
  }

  @Test func everyDriverFamilyHasItsOwnTableFromBeats() {
    // scopes and timeline: 30 / 15 / 8 / 4 fps
    #expect(
      (0...3).map { ScopeFramePacer.minInterval(level: $0) } == [1.0 / 30, 1.0 / 15, 1.0 / 8, 0.25])
    // the Stage: every frame, then 30 / 15 / 4
    #expect(
      (0...3).map { StageFramePacer.minInterval(level: $0) } == [0, 1.0 / 30, 1.0 / 15, 0.25])
    #expect(
      StageFramePacer.showsFireEffects(level: 1) && !StageFramePacer.showsFireEffects(level: 2))
  }
}
