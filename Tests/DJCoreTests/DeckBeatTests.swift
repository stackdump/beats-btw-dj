import Darwin
import Testing

@testable import DJCore

@MainActor
private func eventually(_ cond: @MainActor () -> Bool) async -> Bool {
  for _ in 0..<2000 {
    if cond() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return cond()
}

/// Smallest signed distance between two positions on a circle of `period`.
private func wrapped(_ d: Double, _ period: Double) -> Double {
  d - (d / period).rounded() * period
}

@MainActor
struct DeckBeatTests {
  /// A net deck running at exactly `bpm`, started and rendered `seconds` in.
  func netDeck(
    _ dj: DJEngine, _ name: String, genre: String = "techno", seed: Double = 1, bpm: Double
  )
    async throws -> Deck
  {
    let d = try #require(dj[name])
    await d.generate(
      TrackSpec(genre: genre, seed: seed, extra: JSONObject([("bpm", .number(bpm))])))
    return d
  }

  @Test func netBeatPositionTracksTheClock() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 120)
    #expect(a.beatState?.beat == 0)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 48_000)  // 1 s = 2 beats at 120 bpm
    let s = try #require(a.beatState)
    #expect(abs(s.bpm - 120) < 1e-9)
    #expect(abs(s.beat - 2) < 0.05, "beat \(s.beat)")
    #expect(s.beatInBar == Int(s.beat) && s.bar == 0)
  }

  @Test func sampleBeatPositionUsesTheGrid() throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let a = try #require(dj["A"])
    #expect(a.beatState == nil)
    a.loadDemo()
    #expect(a.beatGrid?.bpm == 120)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 48_000)
    let s = try #require(a.beatState)
    #expect(abs(s.beat - 2) < 0.15, "beat \(s.beat)")  // minus the motor's spin-up
  }

  @Test func syncMatchesTempoWithinTheFaderRange() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 128)
    let b = try #require(dj["B"])
    b.loadDemo()  // 120
    let r = try #require(b.sync(to: a, align: .tempoOnly))
    #expect(!r.tempoClamped && r.multiplier == 1)
    #expect(abs(b.effectiveBPM! - 128) < 1e-9)
    #expect(abs(r.pitch - (128.0 / 120 - 1) / Deck.pitchRange) < 1e-9)
  }

  @Test func syncClampsWhenTheTempiAreTooFarApart() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 150)
    let b = try #require(dj["B"])
    b.loadDemo()
    let r = try #require(b.sync(to: a, align: .tempoOnly))
    #expect(r.tempoClamped && abs(r.pitch - 1) < 1e-9)
    #expect(abs(b.effectiveBPM! - 120 * 1.08) < 1e-9)
  }

  @Test func syncPicksHalfOrDoubleTimeWhenThatFits() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 140)
    let b = try #require(dj["B"])
    b.loadDemo()
    b.setBPM(70)
    let r = try #require(b.sync(to: a, align: .tempoOnly))
    #expect(r.multiplier == 0.5 && !r.tempoClamped && r.pitch == 0, "\(r)")
    #expect(abs(b.effectiveBPM! - 70) < 1e-9)
  }

  @Test func syncWithoutAGridDoesNothing() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 128)
    let b = try #require(dj["B"])
    #expect(b.sync(to: a) == nil)  // nothing loaded
    b.load(
      SampleBuffer(left: [Float](repeating: 0, count: 48_000), sampleRate: dj.sampleRate),
      title: "x")
    #expect(b.sync(to: a) == nil, "no tempo known yet")
  }

  @Test func netDecksLockToTheSameBarGrid() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", seed: 1, bpm: 128)
    let b = try await netDeck(dj, "B", genre: "house", seed: 2, bpm: 124)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 17_000)  // A runs ~0.35 s alone
    b.setPlaying(true)
    _ = try renderOffline(dj, frames: 30_000)
    let before = wrapped(b.beatState!.beat - a.beatState!.beat, 4)
    #expect(abs(before) > 0.3, "the decks start out of phase (\(before))")

    let r = try #require(b.sync(to: a, align: .bar))
    #expect(!r.tempoClamped)
    _ = try renderOffline(dj, frames: 4096)
    #expect(abs(b.effectiveBPM! - 128) < 1e-9)
    let after = wrapped(b.beatState!.beat - a.beatState!.beat, 4)
    #expect(abs(after) < 0.08, "bar-aligned: off by \(after) beats")
    // and it holds: same tempo, so the offset stays put
    _ = try renderOffline(dj, frames: 96_000)
    let later = wrapped(b.beatState!.beat - a.beatState!.beat, 4)
    #expect(abs(later) < 0.1, "still locked 2 s later (\(later))")
  }

  @Test func aSampleDeckSnapsOntoANetDecksBeat() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 126)
    let b = try #require(dj["B"])
    b.loadDemo()
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 10_000)
    b.setPlaying(true)
    _ = try renderOffline(dj, frames: 21_345)  // arbitrary offset
    b.sync(to: a, align: .beat)
    _ = try renderOffline(dj, frames: 8192)  // the seek lands
    let off = wrapped(b.beatState!.beat - a.beatState!.beat, 1)
    #expect(abs(off) < 0.06, "beat-aligned: off by \(off)")
  }

  @Test func followKeepsTheTempoLocked() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj, "A", bpm: 124)
    let b = try #require(dj["B"])
    b.loadDemo()
    b.follow(a)
    #expect(abs(b.effectiveBPM! - 124) < 1e-9)
    a.pitch = 0.5  // +4 %
    b.service()
    #expect(abs(b.effectiveBPM! - 124 * 1.04) < 1e-6)
    b.follow(nil)
    a.pitch = 0
    b.service()
    #expect(abs(b.effectiveBPM! - 124 * 1.04) < 1e-6, "let go: it stays where it was")
  }

  @Test func theAnalyzerFillsInTheGridOfALoadedBuffer() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let a = try #require(dj["A"])
    let sr = dj.sampleRate
    let spb = sr * 60 / 132
    var l = [Float](repeating: 0, count: Int(spb * 40))
    for b in 0..<40 {
      let s = Int(Double(b) * spb)
      for i in 0..<Int(0.08 * sr) where s + i < l.count {
        let t = Double(i) / sr
        l[s + i] = Float(sin(2 * .pi * 60 * t) * exp(-t * 25))
      }
    }
    let buffer = SampleBuffer(left: l, sampleRate: sr)
    a.load(buffer, title: "click")
    #expect(a.beatGrid == nil)
    a.analyze(buffer)
    let ok = await eventually { a.beatGrid != nil }
    #expect(ok)
    #expect(abs((a.beatGrid?.bpm ?? 0) - 132) < 0.5)
  }
}

@MainActor
struct QuantizeTests {
  func ready() throws -> (DJEngine, Deck, Double) {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let a = try #require(dj["A"])
    a.loadDemo()  // 120 bpm, beat at sample 0 → 0.5 s per beat
    try dj.start()
    return (dj, a, dj.sampleRate * 0.5)
  }

  func seek(_ dj: DJEngine, _ a: Deck, to p: Double) throws {
    a.turntable.send(.seek(sample: p))
    _ = try renderOffline(dj, frames: 128)
  }

  @Test func hotCuesSnapToTheGrid() throws {
    let (dj, a, spb) = try ready()
    defer { dj.stop() }
    try seek(dj, a, to: spb * 3 + 4000)
    a.hotCue(0)
    #expect(abs(a.hotCues[0]! - (spb * 3 + 4000)) < 1, "off: set where we are")
    a.clearCue(0)
    a.quantize = .beat
    a.hotCue(0)
    #expect(a.hotCues[0] == spb * 3, "beat: snapped to the nearest beat")
    a.clearCue(1)
    a.quantize = .bar
    try seek(dj, a, to: spb * 5.2)
    a.hotCue(1)
    #expect(a.hotCues[1] == spb * 4, "bar: nearest bar line (4 beats)")
  }

  @Test func loopsSnapAndLoopBeatsIsExact() throws {
    let (dj, a, spb) = try ready()
    defer { dj.stop() }
    a.quantize = .beat
    try seek(dj, a, to: spb * 2 + 3000)
    a.loopIn()
    #expect(a.loopStart == spb * 2)
    try seek(dj, a, to: spb * 4 + 9000)
    a.loopOut()
    #expect(a.looping && a.loopEnd == spb * 4)
    a.loopHalve()
    #expect(a.loopEnd == spb * 3, "halving keeps the grid")
    a.loopDouble()
    #expect(a.loopEnd == spb * 4)
    try seek(dj, a, to: spb * 1.2 + 500)
    a.loopBeats(4)
    #expect(a.loopStart == spb && a.loopEnd == spb * 5)
  }

  @Test func quantizedJumpsKeepThePhase() throws {
    let (dj, a, spb) = try ready()
    defer { dj.stop() }
    a.quantize = .beat
    try seek(dj, a, to: spb * 6)
    a.hotCue(0)  // cue at beat 6
    a.setPlaying(true)
    try seek(dj, a, to: spb * 2 + 0.2 * spb)  // 0.2 beat past a line
    a.turntable.send(.transport(playing: false))  // freeze the position for a clean read
    _ = try renderOffline(dj, frames: 128)
    let here = a.turntable.position
    a.hotCue(0)
    _ = try renderOffline(dj, frames: 128)
    let there = a.turntable.position
    #expect(
      abs((there - spb * 6) - (here - spb * 2)) < spb * 0.02, "same offset past the grid line")
  }
}
