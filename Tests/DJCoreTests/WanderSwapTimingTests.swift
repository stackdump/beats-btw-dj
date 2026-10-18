import Testing

@testable import DJCore

private let rate = 22_050.0

/// A Wander swap (`SwapStart.tick`) composed after the deck reached its phrase boundary starts
/// at the next bar, not back at the boundary (`Deck.generate`, `PreparedTrack.restarted`).
@MainActor
struct WanderSwapTimingTests {
  let song = TrackSpec(genre: "techno", seed: 42, structure: "standard")
  let next = TrackSpec(genre: "techno", seed: 43, structure: "standard")

  /// Deck A playing `song` in the offline engine, run to `tick`. The engine only renders when
  /// stepped, so the deck stays put while a `generate` composes.
  func playing(toTick tick: Int) throws -> (DJEngine, Deck, OfflineConductor) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    let d = dj["A"]!
    d.loadNet(PreparedTrack(spec: song, sampleRate: rate, opts: d.waveOptions))
    dj["B"]!.loadDemo()
    try dj.start()
    d.setPlaying(true)
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    var blocks = 0
    while d.wave.tick < tick, blocks < 20_000 {
      _ = try conductor.step()
      blocks += 1
    }
    return (dj, d, conductor)
  }

  /// Render until the deck plays what was loaded last (generous: it takes a bar at most).
  func untilInstalled(_ d: Deck, _ conductor: OfflineConductor) throws -> Bool {
    var blocks = 0
    while d.wave.activeGeneration != d.wave.latest?.generation, blocks < 20_000 {
      _ = try conductor.step()
      blocks += 1
    }
    return d.wave.activeGeneration == d.wave.latest?.generation
  }

  @Test func aSwapComposedPastItsBoundaryStartsAtTheNextBar() async throws {
    let (dj, d, conductor) = try playing(toTick: 40)  // in bar 3: bar 3's boundary (32) passed
    defer { dj.stop() }
    let now = d.wave.tick
    #expect(now >= 40 && now < 48, "tick \(now)")
    #expect(await d.generate(next, startTick: .tick(32)))
    #expect(d.wave.latest?.startTick == 48, "starts at the bar the install lands on")
    #expect(d.currentSpec == next)
    #expect(try untilInstalled(d, conductor))
    #expect(d.playing && d.wave.isPlaying)
    #expect(d.wave.tick >= 48, "not a bar back: tick \(d.wave.tick)")
  }

  @Test func anOnTimeSwapStillStartsAtItsBoundary() async throws {
    let (dj, d, conductor) = try playing(toTick: 40)
    defer { dj.stop() }
    #expect(d.wave.tick < 48)
    #expect(await d.generate(next, startTick: .tick(48)))
    #expect(d.wave.latest?.startTick == 48)
    #expect(try untilInstalled(d, conductor))
    #expect(d.wave.tick >= 48 && d.wave.tick < 64, "tick \(d.wave.tick)")
  }

  @Test func aRestartKeepsTheTrackAndItsMeasurements() {
    let track = PreparedTrack(spec: next, sampleRate: rate, opts: .extended, startTick: 32)
    let again = track.restarted(atTick: 48)
    #expect(again.prepared.startTick == 48)
    #expect(again.source == track.source && again.played.toJSON() == track.played.toJSON())
    #expect(again.prepared.trackSerial == track.prepared.trackSerial, "the same song")
    #expect(again.prepared.gain == track.prepared.gain)
    #expect(again.prepared.energy == track.prepared.energy)
    #expect(again.prepared.balance == track.prepared.balance)
    #expect(again.prepared.rests == track.prepared.rests)
    #expect(again.prepared.space == track.prepared.space)
    #expect(again.prepared.echo == track.prepared.echo)
    #expect(again.prepared.duckDepth == track.prepared.duckDepth)
    // past the song's end it starts at the top, as `init(spec:startTick:)` does
    #expect(track.restarted(atTick: 10_000_000).prepared.startTick == 0)
  }

  // MARK: the look-ahead (`Deck.lookAheadWander`)

  /// Wander on at pace 4 with its step on the first one (from `from`) whose plan is a swap; the
  /// clock not yet read, so `advanceWander` takes every bar it is given.
  func wanderingToASwap(_ d: Deck, _ dj: DJEngine, from: Int = 0) throws -> TrackSpec {
    d.setWander(true)
    d.setWanderPace(4)
    d.wander.lastBar = nil
    let c = try #require(d.wanderContext(lockedActions: dj.lockedActions))
    for step in from..<(from + 200) {
      if case .swap(let spec)? = Wander.plan(c, step: step)?.action {
        d.wander.step = step
        return spec
      }
    }
    Issue.record("no swap in 200 steps")
    return d.currentSpec!
  }

  @Test func aPlannedSwapIsComposedBeforeItsPhraseEnds() async throws {
    let (dj, d, conductor) = try playing(toTick: 40)  // bar 2: the bar before bar 3, the last
    defer { dj.stop() }
    let planned = try wanderingToASwap(d, dj)
    let step = d.wander.step
    d.advanceWander(toBar: 2, lockedActions: dj.lockedActions)
    let key = try #require(d.lookAhead.key, "a swap is planned: it is composed ahead")
    #expect(key.spec == planned && key.step == step && key.start == .tick(64))
    #expect(d.wander.step == step && d.wander.log.isEmpty, "the look-ahead moves nothing")
    let ahead = try #require(await d.lookAhead.task?.value)
    #expect(d.lookAhead.isReady)
    #expect(d.wave.tick < 48, "composed before the phrase's last bar: tick \(d.wave.tick)")
    #expect(ahead.prepared.startTick == 64)

    d.advanceWander(toBar: 3, lockedActions: dj.lockedActions)  // the move
    #expect(d.wander.step == step + 1)
    #expect(d.wander.log.last?.spec == planned)
    #expect(d.lookAhead.key == nil)
    #expect(d.wave.latest === ahead.prepared, "the look-ahead is what loads: nothing composed")
    #expect(d.currentSpec == planned)
    #expect(try untilInstalled(d, conductor))
    #expect(d.wave.tick >= 64 && d.wave.tick < 80, "on time: tick \(d.wave.tick)")
  }

  @Test func aPokeBetweenDropsTheLookAhead() async throws {
    let (dj, d, _) = try playing(toTick: 40)
    defer { dj.stop() }
    _ = try wanderingToASwap(d, dj)
    d.advanceWander(toBar: 2, lockedActions: dj.lockedActions)
    let ahead = try #require(await d.lookAhead.task?.value)
    // the poke: another song loaded on the deck, so the move plans from it
    let other = TrackSpec(genre: "house", seed: 7, structure: "standard")
    d.loadNet(PreparedTrack(spec: other, sampleRate: rate, opts: d.waveOptions))
    let replanned = d.wanderSwapKey(bar: 3, lockedActions: dj.lockedActions)
    #expect(replanned?.spec != ahead.spec)
    let before = d.wave.latest
    d.advanceWander(toBar: 3, lockedActions: dj.lockedActions)
    #expect(d.lookAhead.key == nil, "dropped")
    #expect(d.wave.latest !== ahead.prepared)
    if let replanned {
      #expect(d.seedTarget == replanned.spec, "composed afresh")
      #expect(d.wave.latest === before, "not loaded until that compose is done")
    }
  }

  @Test func aLockBetweenDropsTheLookAhead() async throws {
    let (dj, d, _) = try playing(toTick: 40)
    defer { dj.stop() }
    _ = try wanderingToASwap(d, dj)
    d.advanceWander(toBar: 2, lockedActions: dj.lockedActions)
    #expect(d.lookAhead.key != nil)
    d.setWanderLock("genre", true)
    #expect(d.lookAhead.key == nil)
  }

  @Test func deterministicReplayDoesNotLookAhead() throws {
    let (dj, d, _) = try playing(toTick: 40)
    defer { dj.stop() }
    dj.deterministic = true
    _ = try wanderingToASwap(d, dj)
    d.advanceWander(toBar: 2, lockedActions: dj.lockedActions)
    #expect(d.lookAhead.key == nil)
    #expect(d.wander.log.isEmpty)
  }
}
