import Testing

@testable import DJCore

// RasterController follows a feed: one compute per song of the lead deck, on a background task,
// a stale result dropped. Driven against a real offline engine (ScopeRig), no audio device.

/// "raster · computing the arrangement…", with " N %" once the compute has got somewhere.
private func computingStatus(_ text: String?) -> Bool {
  guard let text, text.hasPrefix("raster · computing the arrangement…") else { return false }
  let rest = text.dropFirst("raster · computing the arrangement…".count)
  if rest.isEmpty { return true }
  guard rest.hasPrefix(" "), rest.hasSuffix(" %") else { return false }
  let number = rest.dropFirst().dropLast(2)
  return Int(number).map { (1...100).contains($0) } ?? false
}

/// A ring of `n` places with one token whose transitions play on channel 1 with a legacy
/// millisecond length (`durationSteps` 0).
private func legacyRing(_ n: Int, milliseconds: Int) -> NetBundle {
  var nb = NetBundle.ring(n)
  nb.track = Track(channel: 1)
  for i in 0..<n {
    nb.bindings["t\(i)"] = MidiBinding(
      note: 48 + i, channel: 1, velocity: 100, duration: milliseconds, durationSteps: 0)
  }
  return nb
}

@MainActor
struct RasterControllerTests {
  /// The raster the model would compute for what the feed shows.
  func expected(_ feed: ScopeFeed, project: Project) -> RasterResult {
    RasterModel.compute(
      project: project, structure: project.structure, tempo: feed.clock.tempo,
      laneOf: feed.laneSet.laneOf)
  }

  @Test func aDeckFeedGetsTheRasterOfItsLoopWithItsOwnLanes() async throws {
    let rig = try ScopeRig(net: ["A"], play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    #expect(raster.phase == .computing && raster.scene == nil, "no raster while it is computed")
    #expect(raster.canvasMessage == "computing the arrangement…")
    #expect(computingStatus(raster.statusText), "\(raster.statusText ?? "nil")")
    await raster.settled()
    #expect(raster.phase == .ready)
    let scene = try #require(raster.scene)
    let project = try #require(feed.leadProject)
    #expect(scene.result.sameContent(as: expected(feed, project: project)))
    #expect(scene.result.loop && scene.result.cycle > 0 && scene.result.count > 20)
    #expect(scene.lanes == feed.lanes && scene.sections.isEmpty)
    #expect(scene.result.lane.allSatisfy { Int($0) < scene.lanes.count })
    #expect(raster.statusText == RasterLayout.statusText(scene.result))
    #expect(raster.canvasMessage == nil && raster.computeCount == 1)
  }

  @Test func anArrangedTrackKeepsItsSectionsAndLength() async throws {
    let rig = try ScopeRig(net: ["A"], structure: "minimal", play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let scene = try #require(raster.scene)
    let project = try #require(feed.leadProject)
    #expect(!scene.result.loop && scene.result.cycle == 0)
    #expect(scene.result.steps == project.structure.reduce(0) { $0 + $1.steps })
    #expect(scene.sections == feed.sections && scene.sections.count == project.structure.count)
    #expect(scene.sections.first == ScopeSection(step: 0, name: project.structure[0].name))
    #expect(
      raster.statusText?.hasPrefix("raster · ") == true
        && raster.statusText?.contains("loop") == false)
  }

  @Test func nothingIsRecomputedUntilTheSongChanges() async throws {
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let raster = RasterController()
    for _ in 0..<6 {
      rig.render(seconds: 0.4)
      rig.hub.pump()
      raster.update(feed: feed)
    }
    await raster.settled()
    #expect(raster.phase == .ready && raster.computeCount == 1)
    let first = raster.scene?.id
    let gen = feed.generation
    // a restart from the top bumps the feed's generation, but it is the same song
    rig.dj["A"]!.wave.stop()
    rig.dj["A"]!.wave.play()
    for _ in 0..<3 {
      rig.render(seconds: 0.4)
      rig.hub.pump()
      raster.update(feed: feed)
    }
    await raster.settled()
    #expect(feed.generation != gen, "the restart did reset the feed's history")
    #expect(raster.computeCount == 1 && raster.scene?.id == first)
    // a new track is a new raster
    rig.load(scopeProject("house", seed: 9))
    for _ in 0..<4 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      raster.update(feed: feed)
    }
    await raster.settled()
    #expect(raster.computeCount == 2 && raster.phase == .ready)
    #expect(raster.scene?.id != first)
    #expect(raster.scene?.lanes == feed.lanes)
  }

  @Test func aSampleDeckHasNoRaster() async throws {
    let rig = try ScopeRig(net: ["A"], samples: ["B"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("B"))
    feed.acquire()
    rig.render(seconds: 0.3)
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    #expect(raster.phase == .noNet && raster.scene == nil)
    #expect(raster.canvasMessage == "no net on this deck")
    #expect(raster.statusText == nil, "the host's own status stays")
    #expect(raster.computeCount == 0)
  }

  @Test func theMasterRastersTheLeadDecksSongOnItsLanesOnly() async throws {
    let rig = try ScopeRig(net: ["A", "B"], samples: [])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    for _ in 0..<3 {
      rig.render(seconds: 0.3)
      rig.hub.pump()
    }
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let lead = try #require(feed.leadDeck)
    let scene = try #require(raster.scene)
    #expect(raster.phase == .ready)
    #expect(feed.lanes.count > scene.lanes.count, "the master has both decks' lanes")
    #expect(scene.lanes.allSatisfy { $0.deck == lead })
    #expect(scene.lanes == feed.laneSet.lanes)
    let project = try #require(feed.leadProject)
    #expect(scene.result.sameContent(as: expected(feed, project: project)))
    #expect(feed.project(deck: lead) != nil)
  }

  @Test func aMasterWithNoNetDeckSaysSo() async throws {
    let rig = try ScopeRig(net: [], samples: ["A", "B"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    rig.render(seconds: 0.2)
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    #expect(raster.phase == .noNet && raster.canvasMessage == "no net deck")
  }

  @Test func aFeedThatHasNotSeenItsSongYetWaits() async throws {
    let rig = try ScopeRig(net: ["A"], play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()  // not pumped: the deck's song is not known to the feed yet
    let raster = RasterController()
    raster.update(feed: feed)
    #expect(raster.phase == .waiting && feed.trackSerial == 0)
    #expect(raster.canvasMessage == "computing the arrangement…" && raster.statusText == nil)
    #expect(raster.computeCount == 0)
    rig.hub.pump()
    raster.update(feed: feed)
    #expect(raster.phase == .computing && raster.computeCount == 1)
    await raster.settled()
    #expect(raster.phase == .ready)
  }

  @Test func aSongWhoseProjectIsGoneIsAFailedRasterNotAHang() async throws {
    // a project queued behind a playing one: a feed acquired now sees the sounding song through
    // the engine's layout only, and has no Project to tick
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    rig.render(seconds: 0.1)
    rig.load(scopeProject("house", seed: 3))
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 0.1)
    rig.hub.pump()
    guard feed.hasNet, feed.trackSerial != 0, feed.leadProject == nil else {
      Issue.record("setup: expected a feed with a song but no project")
      return
    }
    let raster = RasterController()
    raster.update(feed: feed)
    #expect(raster.phase == .failed)
    let scene = try #require(raster.scene)
    #expect(scene.result.failed && scene.result.steps == 16 && scene.result.count == 0)
    #expect(raster.statusText?.hasPrefix("raster unavailable — ") == true)
    #expect(scene.lanes == feed.laneSet.lanes, "the lanes are still drawn")
    #expect(raster.computeCount == 0)
  }

  // MARK: jobs

  @Test func aNewJobSupersedesARunningOne() async throws {
    let big = scopeProject("techno", seed: 42, structure: "standard")
    let small = scopeProject("hiphop", seed: 1)
    func input(_ p: Project) -> RasterInput {
      RasterInput(
        project: p, structure: p.structure, tempo: p.tempo,
        laneOf: ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A").laneOf)
    }
    let raster = RasterController()
    raster.start(input(big), lanes: [], sections: [])
    raster.start(input(small), lanes: [], sections: [])
    #expect(raster.phase == .computing && raster.computeCount == 2)
    await raster.settled()
    #expect(raster.phase == .ready)
    let want = RasterModel.compute(input(small))
    #expect(raster.scene?.result.sameContent(as: want) == true, "the later job wins")
    // whatever the superseded job did afterwards does not change the picture
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(raster.scene?.result.sameContent(as: want) == true)
  }

  @Test func cancelDropsTheResultAndTheNextUpdateStartsAfresh() async throws {
    let rig = try ScopeRig(net: ["A"], play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    raster.cancel()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(raster.phase == .computing && raster.scene == nil, "the dropped result is not shown")
    raster.update(feed: feed)
    #expect(raster.computeCount == 2)
    await raster.settled()
    #expect(raster.phase == .ready)
  }

  @Test func theSourceGoingAwayClearsTheRaster() async throws {
    let rig = try ScopeRig(net: ["A"], samples: ["B"], play: false)
    defer { rig.stop() }
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    a.acquire()
    b.acquire()
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: a)
    await raster.settled()
    #expect(raster.phase == .ready)
    raster.update(feed: b)
    #expect(raster.phase == .noNet && raster.scene == nil)
    raster.update(feed: a)
    #expect(raster.phase == .ready, "deck A's raster was kept, no tick")
    #expect(raster.computeCount == 1 && raster.cacheHits == 1)
  }

  // MARK: finished rasters are kept by song

  @Test func aMasterWhoseLeadFlipsBackAndForthComputesEachSongOnce() async throws {
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    let master = rig.hub.feed(.master)
    master.acquire()
    let raster = RasterController()
    func lead(at x: Double) {
      rig.dj.crossfader = x
      rig.render(frames: 1024)
      rig.hub.pump()
      raster.update(feed: master)
    }
    lead(at: 0.5)
    #expect(master.leadDeck == "A")
    await raster.settled()
    let a = try #require(raster.scene)
    #expect(raster.phase == .ready && raster.computeCount == 1)

    lead(at: 0.55)
    #expect(master.leadDeck == "B")
    #expect(raster.phase == .computing && raster.scene == nil, "B's song is new")
    await raster.settled()
    let b = try #require(raster.scene)
    #expect(b.id != a.id && raster.computeCount == 2)
    #expect(b.lanes.allSatisfy { $0.deck == "B" })

    // back to A: its raster is on screen at once, nothing is ticked, the same scene as before
    lead(at: 0.44)
    #expect(master.leadDeck == "A")
    #expect(raster.phase == .ready && raster.scene == a, "no blank 'computing' in between")
    #expect(raster.statusText == RasterLayout.statusText(a.result))
    lead(at: 0.55)
    #expect(raster.phase == .ready && raster.scene == b)
    lead(at: 0.44)
    #expect(raster.scene == a)
    #expect(raster.computeCount == 2 && raster.cacheHits == 3)
    #expect(raster.staleCount == 0)
  }

  @Test func aNewTrackOnTheSameDeckIsNotServedFromTheCache() async throws {
    let rig = try ScopeRig(net: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.render(seconds: 0.3)
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let first = try #require(raster.scene)
    rig.load(scopeProject("house", seed: 9))
    for _ in 0..<4 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      raster.update(feed: feed)
    }
    await raster.settled()
    let second = try #require(raster.scene)
    #expect(second.id != first.id && raster.computeCount == 2 && raster.cacheHits == 0)
    #expect(!second.result.sameContent(as: first.result))
  }

  @Test func cancelForgetsTheKeptRasters() async throws {
    let rig = try ScopeRig(net: ["A"], play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    raster.cancel()
    raster.update(feed: feed)
    #expect(raster.phase == .computing && raster.computeCount == 2 && raster.cacheHits == 0)
    await raster.settled()
  }

  // MARK: what the controller hands to the compute

  @Test func theFeedsTempoTurnsLegacyMillisecondsIntoSteps() async throws {
    // 500 ms is 8 steps at 240 bpm (62.5 ms a step) and 4 at 120: the compute must be given the
    // tempo the deck runs at, not a constant and not the project's own
    var p = Project()
    p.tempo = 90
    p.nets["ring"] = legacyRing(4, milliseconds: 500)
    func durations(atTempo tempo: Double) async throws -> [Float] {
      let rig = try ScopeRig(net: ["A"], play: false)
      defer { rig.stop() }
      rig.load(p, on: "A", tempo: tempo, play: false)
      let feed = rig.hub.feed(.deck("A"))
      feed.acquire()
      rig.render(frames: 1024)
      rig.hub.pump()
      #expect(feed.clock.tempo == tempo)
      let raster = RasterController()
      raster.update(feed: feed)
      await raster.settled()
      let scene = try #require(raster.scene)
      #expect(scene.result.count >= 4)
      return Array(scene.result.dur.prefix(4))
    }
    #expect(try await durations(atTempo: 240) == [8, 8, 8, 8])
    #expect(try await durations(atTempo: 120) == [4, 4, 4, 4])
  }

  // MARK: progress

  @Test func aRunningComputeShowsHowFarItHasGot() async throws {
    // 2000 transitions looked at on every one of 16384 ticks: long enough to be seen
    var p = Project()
    p.nets["big"] = legacyRing(2000, milliseconds: 100)
    let input = RasterInput(
      project: p, structure: [Section(name: "long", steps: 16_384)], tempo: 120,
      laneOf: ["big": 0])
    let raster = RasterController()
    raster.start(input, lanes: [], sections: [])
    #expect(raster.phase == .computing)
    #expect(computingStatus(raster.statusText), "\(raster.statusText ?? "nil")")
    #expect(raster.canvasMessage == "computing the arrangement…", "the canvas keeps the JS text")
    // Watch the line while it computes. Whether a percentage is ever SEEN depends on the main
    // actor getting scheduled while the compute runs, which a loaded machine (this suite runs
    // beside many main-actor tests) does not guarantee, so the text is checked wherever it is
    // seen and the percentage itself is pinned deterministically by `computingStatusText`.
    for _ in 0..<1500 where raster.phase == .computing {
      let text = raster.statusText
      #expect(computingStatus(text), "\(text ?? "nil")")
      if text?.hasSuffix(" %") == true { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    raster.cancel()
  }

  @Test func theComputingLineCarriesThePercentageOnlyOnceTicksAreCounted() {
    #expect(
      RasterController.computingStatusText(percent: 0) == "raster · computing the arrangement…")
    #expect(
      RasterController.computingStatusText(percent: 1) == "raster · computing the arrangement… 1 %")
    #expect(
      RasterController.computingStatusText(percent: 100)
        == "raster · computing the arrangement… 100 %")
    for percent in [0, 1, 37, 99, 100] {
      #expect(computingStatus(RasterController.computingStatusText(percent: percent)))
    }
  }

  @Test func theFinishedStatusLineIsTheSameStringEveryFrame() async throws {
    let rig = try ScopeRig(net: ["A"], play: false)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    rig.hub.pump()
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let scene = try #require(raster.scene)
    #expect(raster.statusText == RasterLayout.statusText(scene.result))
    for _ in 0..<5 { #expect(raster.statusText == RasterLayout.statusText(scene.result)) }
  }
}
