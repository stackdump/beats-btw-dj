import Testing

@testable import DJCore

private func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

/// Poll (yielding) until `cond` holds or ~10 s pass.
@MainActor
private func eventually(_ cond: @MainActor () -> Bool) async -> Bool {
  for _ in 0..<2000 {
    if cond() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return cond()
}

@MainActor
struct DeckNetTests {
  @Test func generatedTrackPlaysThroughTheDeck() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    #expect(deck.mode == .sample)
    let ok = await deck.generate(TrackSpec(genre: "techno", seed: 42))
    #expect(ok)
    #expect(deck.mode == .net)
    #expect(deck.title.hasPrefix("techno"))
    #expect(deck.currentSpec?.seed == 42)
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let audio = try renderOffline(dj, frames: 48_000)
    #expect(peak(audio) > 0.05)
    #expect(deck.wave.isPlaying && deck.wave.tick > 4)
    #expect(deck.turntable.position == 0, "the turntable stays parked")
  }

  @Test func theLatestGenerateWins() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    async let first = deck.generate(TrackSpec(genre: "jazz", seed: 1, structure: "standard"))
    async let second = deck.generate(TrackSpec(genre: "dnb", seed: 2))
    let (a, b) = await (first, second)
    #expect(b)
    #expect(!a, "the first compose finished after the second was requested")
    #expect(deck.currentSpec?.genre == "dnb")
  }

  @Test func nextTrackIsComposedInTheBackgroundThenAdvanced() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 1))
    #expect(deck.nextReady == nil && !deck.advanceToNext())
    let spec = TrackSpec(genre: "house", seed: 9, structure: "minimal")
    deck.queueNext(spec)
    let ok = await eventually { deck.nextReady == spec }
    #expect(ok)
    #expect(deck.advanceToNext())
    #expect(deck.currentSpec == spec)
    #expect(deck.title.hasPrefix("house"))
    #expect(deck.nextReady == nil, "taken")
  }

  @Test func aSongThatEndsHandsOverToThePrecomposedNext() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    deck.autoAdvance = true
    await deck.generate(TrackSpec(genre: "ambient", seed: 3, structure: "minimal"))
    deck.queueNext(TrackSpec(genre: "techno", seed: 5, structure: "minimal"))
    let ok = await eventually { deck.nextReady != nil }
    #expect(ok)
    deck.wave.setTempo(3000)  // ~5 ms per tick: the 320-tick song ends in ~1.6 s
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    var handedOver = false
    for _ in 0..<40 {
      _ = try renderOffline(dj, frames: 12_000)
      deck.service()
      if deck.currentSpec?.genre == "techno" {
        handedOver = true
        break
      }
    }
    #expect(handedOver, "service() must start the next track when the song ends")
    #expect(deck.playing)
  }

  @Test func nextProviderKeepsOneComing() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    var n = 0.0
    deck.nextProvider = {
      n += 1
      return TrackSpec(genre: "lofi", seed: n)
    }
    await deck.generate(TrackSpec(genre: "techno", seed: 1))
    deck.service()
    #expect(deck.nextComposing != nil || deck.nextReady != nil)
    let ok = await eventually { deck.nextReady != nil }
    #expect(ok)
    let before = n
    deck.service()
    #expect(n == before, "no new request while one is ready")
    #expect(deck.advanceToNext())
    deck.service()
    #expect(n == before + 1)
  }

  @Test func loadingAudioLeavesNetMode() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 1))
    deck.setPlaying(true)
    deck.loadDemo()
    #expect(deck.mode == .sample && deck.netProject == nil && !deck.wave.isActive)
    #expect(!deck.playing)
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    #expect(peak(try renderOffline(dj, frames: 24_000)) > 0.1)
    #expect(!deck.wave.isPlaying)
  }

  @Test func tempoFaderScalesTheNetClock() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 1))
    let base = deck.netBaseBPM
    deck.pitch = 0.5
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 4096)
    #expect(abs(deck.wave.tempo - base * (1 + 0.5 * Deck.pitchRange)) < 1e-9)
  }

  @Test func shareEnvelopesBecomeSpecs() throws {
    let rows = try JSONValue.parse(try beatsFixtureText("envelopes"))["envelopes"]!.array!
    var n = 0
    for row in rows {
      let share = Share(payload: row["payload"]!, cid: row["cid"]!.string!)
      guard let spec = TrackSpec(share: share) else { continue }
      guard let want = row["project"] else { continue }
      let project = compose(genre: spec.genre, overrides: spec.overrides)
      #expect(project.modelCID == want["modelCID"]!.string!, "\(row["payload"]!.jsStringified)")
      n += 1
    }
    #expect(n >= 14)
  }
}
