import DJRustUI
import Testing

// djandroid's PlayCounterTest (charts/), the same numbers: when a play counts — 30 s heard, once
// per track per UTC day, nothing while not heard.

private let day0: Int64 = 20_403 * PlayCounter.dayMs  // 2025-11-11 00:00 UTC

/// Looks at `deck` every 100 ms from `from` for `ms`; returns the plays that counted.
private func listen(
  _ c: PlayCounter, _ key: String?, _ from: Int64, _ ms: Int64, heard: Bool = true, deck: String = "A"
) -> [String] {
  var out: [String] = []
  var t = from
  while t <= from + ms {
    if let k = c.observe(deck, key, heard: heard, nowMs: t) { out.append(k) }
    t += 100
  }
  return out
}

@Test func countsAfterThirtySecondsHeard() {
  let c = PlayCounter()
  #expect(listen(c, "t", day0, 29_800) == [])
  #expect(listen(c, "t", day0 + 29_900, 200) == ["t"])
}

@Test func onceADayPerTrack() {
  let c = PlayCounter()
  #expect(listen(c, "t", day0, 120_000) == ["t"])
  // another track and back again: the same track does not count twice that day
  #expect(listen(c, "u", day0 + 200_000, 31_000) == ["u"])
  #expect(listen(c, "t", day0 + 300_000, 60_000) == [])
  // the next UTC day it counts again
  #expect(listen(c, "t", day0 + PlayCounter.dayMs, 31_000) == ["t"])
}

@Test func pausedOrFadedOutAddsNothing() {
  let c = PlayCounter()
  _ = listen(c, "t", day0, 20_000)
  // ten minutes paused, then the poll resumes: the gap is not listening
  #expect(listen(c, "t", day0 + 20_100, 600_000, heard: false) == [])
  #expect(listen(c, "t", day0 + 700_000, 9_000) == [])
  #expect(listen(c, "t", day0 + 709_100, 1_500) == ["t"])
}

@Test func aStalledPollCountsAtMostOneSecond() {
  let c = PlayCounter()
  _ = c.observe("A", "t", heard: true, nowMs: day0)
  #expect(c.observe("A", "t", heard: true, nowMs: day0 + 60_000) == nil)
  #expect(c.observe("A", "t", heard: true, nowMs: day0 + 120_000) == nil)
}

@Test func aNewTrackStartsFromZero() {
  let c = PlayCounter()
  _ = listen(c, "t", day0, 25_000)
  #expect(listen(c, "u", day0 + 25_100, 25_000) == [])
}

@Test func decksAreCountedApart() {
  let c = PlayCounter()
  #expect(listen(c, "t", day0, 31_000, deck: "A") == ["t"])
  #expect(listen(c, "u", day0, 31_000, deck: "B") == ["u"])
}

@Test func clearForgetsEverything() {
  let c = PlayCounter()
  _ = listen(c, "t", day0, 31_000)
  c.clear()
  #expect(listen(c, "t", day0 + 40_000, 31_000) == ["t"])
}

@Test func heardNeedsPlayingVolumeAndTheCrossfader() {
  #expect(ChartReporting.heard("A", playing: true, volume: 0.8, crossfader: 0))
  #expect(ChartReporting.heard("A", playing: true, volume: 0.8, crossfader: 0.9))
  #expect(!ChartReporting.heard("A", playing: true, volume: 0.8, crossfader: 1))
  #expect(!ChartReporting.heard("B", playing: true, volume: 0.8, crossfader: 0))
  #expect(ChartReporting.heard("B", playing: true, volume: 0.8, crossfader: 0.1))
  #expect(!ChartReporting.heard("A", playing: false, volume: 0.8, crossfader: 0))
  #expect(!ChartReporting.heard("A", playing: true, volume: 0, crossfader: 0))
}

/// The switch off: nothing runs, so a play heard while it was off never counts later.
@Test func theSwitchOffCountsNothing() {
  final class Sink: PlaySink, @unchecked Sendable {
    var plays: [Play] = []
    func play(_ p: Play) { plays.append(p) }
  }
  let sink = Sink()
  let r = ChartReporting(sink: sink)
  func run(_ from: Int64) {
    var t = from
    while t <= from + 31_000 {
      r.observe("A", genre: "house", seed: 7, structure: nil, title: "x", heard: true, nowMs: t)
      t += 100
    }
  }
  run(day0)
  #expect(sink.plays.isEmpty)
  r.on = true
  run(day0 + 100_000)
  #expect(sink.plays == [Play(deck: "A", genre: "house", seed: 7, structure: nil, title: "x", day: 20_403)])
}
