import Testing

@testable import DJCore

struct ScopeFramePacerTests {
  @Test func theFpsTableIsScopeJsVizMinFrameMs() {
    #expect(ScopeFramePacer.fps == [30, 15, 8, 4])
    #expect(ScopeFramePacer.minInterval(level: 0) == 1.0 / 30)
    #expect(ScopeFramePacer.minInterval(level: 1) == 1.0 / 15)
    #expect(ScopeFramePacer.minInterval(level: 2) == 1.0 / 8)
    #expect(ScopeFramePacer.minInterval(level: 3) == 0.25)
    #expect(ScopeFramePacer.minInterval(level: 9) == 0.25, "Math.min(3, level)")
    #expect(ScopeFramePacer.minInterval(level: -2) == 1.0 / 30)
  }

  @Test func theFirstCallDrawsThenTheIntervalGates() {
    var p = ScopeFramePacer()
    let first = p.shouldDraw(now: 1000)
    let soon = p.shouldDraw(now: 1000.01)
    let almost = p.shouldDraw(now: 1000.0333)
    let due = p.shouldDraw(now: 1000.0334)  // 1/30 s after the first
    let after = p.shouldDraw(now: 1000.05)
    #expect(first && !soon && !almost && due && !after)
    #expect(p.lastDraw == 1000.0334)
  }

  @Test func aSlowerLevelWaitsLonger() {
    var p = ScopeFramePacer(level: 3)
    let first = p.shouldDraw(now: 0)
    let early = p.shouldDraw(now: 0.24)
    let due = p.shouldDraw(now: 0.25)
    #expect(first && !early && due)
    p.level = 1
    let tooSoon = p.shouldDraw(now: 0.30)
    let next = p.shouldDraw(now: 0.25 + 1.0 / 15 + 1e-9)
    #expect(!tooSoon && next)
  }

  @Test func theLevelIsClampedAndResetForgetsTheLastDraw() {
    var p = ScopeFramePacer(level: 9)
    #expect(p.level == 3)
    p.level = -4
    #expect(p.level == 0)
    p.level = 17
    #expect(p.level == 3 && p.minInterval == 0.25)
    let first = p.shouldDraw(now: 5)
    let again = p.shouldDraw(now: 5.0001)
    p.reset()
    let afterReset = p.shouldDraw(now: 5.0002)
    #expect(first && !again && afterReset)
  }
}
