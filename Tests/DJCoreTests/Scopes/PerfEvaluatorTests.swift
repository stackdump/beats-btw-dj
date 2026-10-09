import Testing

@testable import DJCore

/// One window, as the monitor measured it, and the verdict monitor.js `closeWindow` gives it.
/// Every threshold is hit from both sides (the JS comparisons are all strict `>`).
struct PerfWindowCase: Sendable, CustomTestStringConvertible {
  var name: String
  var frames: [Double]
  var spanMs = 2000.0
  var blockingMs = 0.0
  var attributedMs = 0.0
  var viz: [Double] = [0, 0, 0, 0]
  var jank: Bool
  var heavy: Bool
  var cause: PerfCause
  var testDescription: String { name }

  func input() -> PerfWindowInput {
    PerfWindowInput(
      frameIntervalsMs: frames, spanMs: spanMs, blockingMs: blockingMs,
      longCount: blockingMs > 0 ? 1 : 0, vizAttributedMs: attributedMs, vizMs: viz)
  }
}

private func rep(_ ms: Double, _ n: Int) -> [Double] { [Double](repeating: ms, count: n) }

let perfWindowCases: [PerfWindowCase] = [
  PerfWindowCase(
    name: "60 fps, nothing else: smooth", frames: rep(16.7, 120), jank: false, heavy: false,
    cause: .none),
  PerfWindowCase(
    name: "uniformly slow, 25 fps, no viz: jank from elsewhere", frames: rep(40, 50), jank: true,
    heavy: false, cause: .other),
  PerfWindowCase(
    name: "exactly 30 fps is not slow (median > 33.33 is)", frames: rep(1000 / 30, 60),
    jank: false, heavy: false, cause: .none),
  PerfWindowCase(
    name: "just under 30 fps is slow", frames: rep(33.4, 60), jank: true, heavy: false,
    cause: .other),
  PerfWindowCase(
    name: "slow and viz 15 % of the window: the visualization", frames: rep(40, 50),
    viz: [0, 0, 0, 300], jank: true, heavy: true, cause: .visualization),
  PerfWindowCase(
    name: "viz share exactly 12 % is not heavy", frames: rep(40, 50), viz: [100, 60, 40, 40],
    jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "viz share just over 12 % is heavy", frames: rep(40, 50), viz: [100, 60, 40, 40.5],
    jank: true, heavy: true, cause: .visualization),
  PerfWindowCase(
    name: "heavy viz but a smooth window: no verdict", frames: rep(16.7, 120), viz: [0, 500, 0, 0],
    jank: false, heavy: true, cause: .none),
  PerfWindowCase(
    name: "p95 beyond 2x median: 100 x 16 ms and 6 x 40 ms (index floor(106 * .95) = 100)",
    frames: rep(16, 100) + rep(40, 6), jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "5 spikes in 105 frames: p95 index 99 is still 16 ms",
    frames: rep(16, 100) + rep(40, 5), jank: false, heavy: false, cause: .none),
  PerfWindowCase(
    name: "dropped 20 %: 80 x 16 ms and 20 x 30 ms (beyond 1.7 x 16)",
    frames: rep(16, 80) + rep(30, 20),
    jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "dropped exactly 15 % is not jank", frames: rep(16, 85) + rep(30, 15), jank: false,
    heavy: false, cause: .none),
  // The multiple of the median that makes a frame "dropped" is 1.7, and the share of them that
  // is jank is 15 %; the p95 factor is 2. Each is hit from both sides with the other two quiet
  // (checked against monitor.js `closeWindow`).
  PerfWindowCase(
    name: "dropped 16 %: just over 15 % of the frames beyond 1.7 x 16 ms",
    frames: rep(16, 84) + rep(30, 16), jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "dropped 14 %: just under 15 %", frames: rep(16, 86) + rep(30, 14), jank: false,
    heavy: false, cause: .none),
  PerfWindowCase(
    name: "20 frames at 1.75 x the median are dropped (20 x 35 ms against 80 x 20 ms)",
    frames: rep(20, 80) + rep(35, 20), jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "20 frames at 1.65 x the median are not (20 x 33 ms against 80 x 20 ms)",
    frames: rep(20, 80) + rep(33, 20), jank: false, heavy: false, cause: .none),
  PerfWindowCase(
    name: "p95 at 2.1 x the median is jank (6 x 34 ms against 100 x 16 ms)",
    frames: rep(16, 100) + rep(34, 6), jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "p95 at 1.9 x the median is not (6 x 30 ms against 100 x 16 ms)",
    frames: rep(16, 100) + rep(30, 6), jank: false, heavy: false, cause: .none),
  PerfWindowCase(
    name: "five frames are too few to judge, however slow", frames: rep(100, 5), jank: false,
    heavy: false, cause: .none),
  PerfWindowCase(
    name: "six slow frames are judged", frames: rep(100, 6), jank: true, heavy: false, cause: .other
  ),
  PerfWindowCase(
    name: "no frames, nothing to say", frames: [], jank: false, heavy: false, cause: .none),
  PerfWindowCase(
    name: "blocking 101 ms in 2 s = 50.5 ms/s: jank even with smooth frames",
    frames: rep(16.7, 120),
    blockingMs: 101, jank: true, heavy: false, cause: .other),
  PerfWindowCase(
    name: "blocking 100 ms in 2 s = exactly 50 ms/s: not jank", frames: rep(16.7, 120),
    blockingMs: 100, jank: false, heavy: false, cause: .none),
  PerfWindowCase(
    name: "blocking caused mostly by the visuals: heavy with a tiny share", frames: rep(16.7, 120),
    blockingMs: 120, attributedMs: 61, viz: [0, 0, 0, 61], jank: true, heavy: true,
    cause: .visualization),
  PerfWindowCase(
    name: "attributed exactly half of the blocking is not enough", frames: rep(16.7, 120),
    blockingMs: 120, attributedMs: 60, viz: [0, 0, 0, 60], jank: true, heavy: false,
    cause: .other),
  PerfWindowCase(
    name: "attribution counts only where there was blocking", frames: rep(16.7, 120),
    blockingMs: 0, attributedMs: 500, viz: [0, 0, 0, 0], jank: false, heavy: false, cause: .none),
]

struct PerfEvaluatorTests {
  @Test(arguments: perfWindowCases) func theVerdictFollowsMonitorJs(_ c: PerfWindowCase) {
    let w = PerfEvaluator.evaluate(c.input(), level: 1)
    #expect(w.jank == c.jank, "jank")
    #expect(w.vizHeavy == c.heavy, "heavy")
    #expect(w.cause == c.cause, "cause")
    #expect(w.level == 1 && w.spanMs == c.spanMs)
  }

  @Test func theStatsAreTheOnesTheJsReports() {
    // 100 x 16 ms + 6 x 40 ms in 2000 ms with 100 ms of viz and 60 ms of blocking
    let input = PerfWindowInput(
      frameIntervalsMs: Array(repeating: 40, count: 6) + Array(repeating: 16, count: 100),
      spanMs: 2000, blockingMs: 60, longCount: 2, vizAttributedMs: 0, vizMs: [10, 20, 30, 40])
    let w = PerfEvaluator.evaluate(input, level: 0)
    #expect(w.medianFrameMs == 16 && w.p95FrameMs == 40)
    #expect(w.fps == 62.5)
    #expect(abs(w.dropped - 6.0 / 106) < 1e-12)
    #expect(w.longFrames == 2)
    #expect(w.blockingMsPerS == 30)
    #expect(abs(w.vizSharePct - 5) < 1e-9 && w.vizMs == [10, 20, 30, 40])
  }

  @Test func theMedianIsTheElementAtHalfTheCount() {
    // monitor.js `sorted[floor(n / 2)]`: the upper middle of an even count
    #expect(PerfEvaluator.median([1, 2, 3, 4]) == 3)
    #expect(PerfEvaluator.median([1, 2, 3]) == 2)
    #expect(PerfEvaluator.median([]) == 0)
    let w = PerfEvaluator.evaluate(
      PerfWindowInput(frameIntervalsMs: [10, 10, 10, 30, 30, 30, 30, 30], spanMs: 2000), level: 0)
    #expect(w.medianFrameMs == 30, "n = 8: sorted[4]")
  }

  @Test func aZeroLengthWindowDividesByNothing() {
    let w = PerfEvaluator.evaluate(
      PerfWindowInput(frameIntervalsMs: [16, 16], spanMs: 0, blockingMs: 99, vizMs: [1, 1, 1, 1]),
      level: 0)
    #expect(w.blockingMsPerS == 0 && w.vizSharePct == 0 && w.cause == .none)
  }

  @Test func theThresholdsAreTheDefaultsOfMonitorJs() {
    let c = PerfConfig.standard
    #expect(c.windowMs == 2000 && c.downAfter == 2 && c.upAfter == 8)
    #expect(c.vizShare == 0.12 && c.jankP95Factor == 2.0 && c.jankDropped == 0.15)
    #expect(c.droppedFactor == 1.7)
    #expect(c.jankBlockingMsPerS == 50 && c.minFps == 30)
    #expect(c.longTaskMs == 50 && c.floorWithinSeconds == 30)
  }

  @Test func aTighterConfigMovesTheLines() {
    var cfg = PerfConfig()
    cfg.minFps = 60
    let w = PerfEvaluator.evaluate(
      PerfWindowInput(frameIntervalsMs: Array(repeating: 20, count: 100), spanMs: 2000), level: 0,
      config: cfg)
    #expect(w.jank, "20 ms is slower than 1000 / 60")
  }
}
