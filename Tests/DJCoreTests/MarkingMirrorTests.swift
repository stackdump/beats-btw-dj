import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double, _ structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

private let sr = 22_050.0

@discardableResult
private func run(_ src: WaveDeckSource, from: Int, blocks: Int, size: Int = 128) -> Int {
  var l = [Float](repeating: 0, count: size)
  var r = [Float](repeating: 0, count: size)
  var frame = from
  for _ in 0..<blocks {
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        src.render(frames: size, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: frame)
      }
    }
    frame += size
  }
  return frame
}

/// Does the snapshot hold exactly the graph's tokens and mutes, in the layout's order?
private func matches(_ snap: MarkingSnapshot, _ g: WaveGraph) -> Bool {
  guard let layout = snap.layout, layout.netCount == g.nets.count else { return false }
  for (i, n) in g.nets.enumerated() {
    if layout.netIds[i] != n.id || layout.placeIds[i] != n.placeIds { return false }
    for p in 0..<n.nPlaces where snap.tokens[layout.placeOffsets[i] + p] != n.state[p] {
      return false
    }
    if snap.muted[i] != g.muted[i] { return false }
  }
  return snap.tick == g.tick
}

private func source(_ p: Project, tempo: Double = 300, startTick: Int = 0) -> (
  WaveDeckSource, WaveProject
) {
  let src = WaveDeckSource(sampleRate: sr)
  let prepared = WaveRunner.prepare(p, sampleRate: sr, startTick: startTick)
  src.load(prepared)
  src.setTempo(tempo)
  return (src, prepared)
}

struct MarkingLayoutTests {
  @Test func theLayoutNamesEveryNetAndPlaceInOrder() {
    let prepared = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    let layout = prepared.marking.layout
    let g = prepared.graph
    #expect(layout.generation == prepared.generation)
    #expect(layout.netIds == g.nets.map(\.id))
    #expect(layout.netCount == g.nets.count && layout.netCount > 5)
    #expect(layout.placeOffsets.count == layout.netCount + 1 && layout.placeOffsets[0] == 0)
    var total = 0
    for (i, n) in g.nets.enumerated() {
      #expect(layout.placeIds[i] == n.placeIds)
      #expect(layout.places(ofNet: i) == total..<(total + n.nPlaces))
      total += n.nPlaces
    }
    #expect(layout.placeCount == total && total > 50)
  }

  @Test func everyPreparedProjectGetsItsOwnIncreasingGeneration() {
    let a = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    let b = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    #expect(a.generation > 0 && b.generation > a.generation)
    #expect(a.marking !== b.marking)
  }
}

struct MarkingLayoutIdentityTests {
  @Test func everyNewProjectIsANewTrackUnlessToldItIsTheSameSong() {
    let p = project("techno", 42, "standard")
    let a = WaveRunner.prepare(p, sampleRate: sr)
    let b = WaveRunner.prepare(p, sampleRate: sr)
    #expect(a.trackSerial > 0 && b.trackSerial > a.trackSerial, "a new prepare is a new track")
    let again = WaveRunner.prepare(p, sampleRate: sr, startTick: 200, trackSerial: a.trackSerial)
    #expect(again.trackSerial == a.trackSerial, "a relaunch of the same song keeps its serial")
    #expect(again.generation > b.generation, "but is a new project: tick numbers start over")
    #expect(a.startTick == 0 && again.startTick == 200)
    #expect(WaveRunner.prepare(p, sampleRate: sr, startTick: -5).startTick == 0)
    // the layout carries both, so a consumer holding only an event's generation can tell
    let layout = again.marking.layout
    #expect(layout.generation == again.generation && layout.trackSerial == a.trackSerial)
    #expect(layout.startTick == 200)
    #expect(a.marking.layout.trackSerial != b.marking.layout.trackSerial)
  }

  @Test func theLayoutDescribesEveryNetForDisplay() {
    let p = project("techno", 42, "standard")
    let prepared = WaveRunner.prepare(p, sampleRate: sr)
    let layout = prepared.marking.layout
    let g = prepared.graph
    #expect(layout.nets.count == g.nets.count && layout.nets.count == layout.netCount)
    var drums = 0
    var tonal = 0
    var stingers = 0
    var controls = 0
    for (i, n) in g.nets.enumerated() {
      let info = layout.nets[i]
      #expect(info.id == n.id && info.id == layout.netIds[i])
      #expect(info.role == n.bundle.role && info.riffGroup == n.bundle.riffGroup)
      #expect(info.instrument == n.bundle.track.instrument && info.group == n.bundle.track.group)
      #expect(info.channel == n.bundle.track.channel)
      #expect(info.isDrum == isDrumChannel(n.bundle.track.channel))
      #expect(info.isStinger == g.isStingerNet[i])
      #expect(info.transitionIds == n.transIds)
      #expect(info.placeX.count == n.nPlaces && info.placeY.count == n.nPlaces)
      #expect(info.transitionX.count == n.nTrans && info.transitionY.count == n.nTrans)
      let voiced = (0..<n.nTrans).filter { n.lane[$0] >= 0 }.map { n.note[$0] }
      if voiced.isEmpty {
        #expect(info.noteLow == -1 && info.noteHigh == -1, "\(n.id) never sounds")
        if info.role == "control" { controls += 1 }
      } else {
        #expect(info.noteLow == voiced.min() && info.noteHigh == voiced.max())
        #expect(info.noteLow <= info.noteHigh)
        if info.isDrum { drums += 1 } else { tonal += 1 }
      }
      if info.isStinger { stingers += 1 }
      // positions are the composed ring layout, in place / transition order
      let composed = p.nets[n.id]!
      for (k, id) in n.placeIds.enumerated() {
        #expect(
          info.placeX[k] == composed.places[id]!.x && info.placeY[k] == composed.places[id]!.y)
      }
      for (k, id) in n.transIds.enumerated() {
        #expect(
          info.transitionX[k] == composed.transitions[id]!.x
            && info.transitionY[k] == composed.transitions[id]!.y)
      }
    }
    #expect(drums > 2 && tonal > 2 && stingers > 0 && controls > 0, "a real song: all kinds")
    #expect(
      layout.nets.contains {
        $0.placeX.contains { $0 != 0 } && $0.transitionY.contains { $0 != 0 }
      },
      "the ring layout positions are in there")
  }

  @Test func theLayoutKnowsTheSectionsOfItsOwnProject() {
    let song = WaveRunner.prepare(project("techno", 42, "standard"), sampleRate: sr)
    let sections = song.marking.layout.sections
    #expect(sections.count >= 5 && sections[0].startTick == 0)
    #expect(sections.map(\.steps).reduce(0, +) > 600)
    #expect(
      zip(sections, sections.dropFirst()).allSatisfy { $1.startTick == $0.startTick + $0.steps })
    #expect(sections == Deck.SectionInfo.sections(of: project("techno", 42, "standard")))
    #expect(
      WaveRunner.prepare(project("techno", 42), sampleRate: sr).marking.layout.sections.isEmpty)
  }

  @Test func aDecksSectionsFlipAtLoadButTheSoundingLayoutKeepsItsOwnUntilTheBar() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sr)
    let deck = try #require(dj["A"])
    deck.loadSynthNet(project("techno", 42, "standard"))
    deck.wave.setTempo(600)
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 8192)
    let first = try #require(deck.wave.latest)
    deck.loadSynthNet(project("ambient", 5, "short"))  // queued behind the playing song
    #expect(deck.sections != first.marking.layout.sections, "the deck already shows the new song")
    let sounding = try #require(deck.wave.markingLayout(generation: deck.wave.activeGeneration))
    #expect(sounding.generation == first.generation)
    #expect(
      sounding.sections == first.marking.layout.sections, "the sounding one is still the first")
    _ = try renderOffline(dj, frames: 8192 * 4)  // past the bar
    #expect(deck.wave.activeGeneration == deck.wave.latest?.generation)
    let now = try #require(deck.wave.markingLayout(generation: deck.wave.activeGeneration))
    #expect(now.sections == deck.sections)
  }

  @Test func everyFireResolvesToItsNetThroughTheLayoutOfItsGeneration() {
    let src = WaveDeckSource(sampleRate: sr)
    let first = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    src.load(first)
    src.setTempo(600)
    src.play()
    var frame = run(src, from: 0, blocks: 200)
    let second = WaveRunner.prepare(project("house", 4), sampleRate: sr)
    let third = WaveRunner.prepare(project("dnb", 3), sampleRate: sr)
    src.load(second)
    src.load(third)  // replaces `second` while it waits for the bar: its events never come
    frame = run(src, from: frame, blocks: 600)
    var fires: [FireEvent] = []
    var cursor = 0
    src.fires.drain(from: &cursor, into: &fires)
    #expect(fires.count > 100)
    #expect(Set(fires.map(\.generation)) == [first.generation, third.generation])
    for f in fires {
      let layout = src.markingLayout(generation: f.generation)
      #expect(layout != nil, "generation \(f.generation) resolves")
      guard let net = layout?.nets[Int(f.net)] else { continue }
      #expect(Int(f.transition) < net.transitionIds.count)
      #expect(Int(f.note) >= net.noteLow && Int(f.note) <= net.noteHigh)
      #expect(f.flags.contains(.drum) == net.isDrum)
      #expect(f.flags.contains(.stinger) == net.isStinger)
      #expect(net.role != "control", "control nets never fire")
    }
  }
}

struct MarkingMirrorTests {
  @Test func aFreshProjectIsReadableBeforeAnythingRenders() {
    let (src, prepared) = source(project("techno", 42))
    var snap = MarkingSnapshot()
    #expect(src.activeGeneration == 0, "the audio thread has not run it")
    #expect(src.readMarking(into: &snap))
    #expect(snap.generation == prepared.generation && snap.header.sequence == 1)
    #expect(snap.tick == 0 && snap.header.frame == 0)
    #expect(matches(snap, prepared.graph))
    #expect(snap.tokens.contains { $0 > 0 }, "the initial marking has tokens in it")
  }

  @Test func aSeekedProjectIsSeededWithItsRebuiltMarking() {
    let (src, prepared) = source(project("techno", 42, "standard"), startTick: 200)
    var snap = MarkingSnapshot()
    #expect(src.readMarking(into: &snap))
    #expect(snap.tick == 200 && matches(snap, prepared.graph))
    let fresh = WaveRunner.prepare(project("techno", 42, "standard"), sampleRate: sr)
    var other = MarkingSnapshot()
    #expect(fresh.marking.read(into: &other))
    #expect(other.tokens != snap.tokens, "tick 200 is not the starting marking")
  }

  @Test func nothingLoadedMeansNoSnapshot() {
    let src = WaveDeckSource(sampleRate: sr)
    var snap = MarkingSnapshot()
    #expect(!src.readMarking(into: &snap))
    #expect(!src.readMarking(generation: 99, into: &snap))
    #expect(src.markingLayout == nil && src.markingLayout(generation: 1) == nil)
  }

  @Test func theSnapshotFollowsTheGraphBlockByBlock() {
    let (src, prepared) = source(project("house", 7), tempo: 900)
    src.play()
    var snap = MarkingSnapshot()
    var frame = 0
    var changes = 0
    var lastSeq = 0
    for _ in 0..<500 {
      frame = run(src, from: frame, blocks: 1)
      #expect(src.readMarking(into: &snap))
      #expect(matches(snap, prepared.graph), "tick \(prepared.graph.tick)")
      #expect(snap.header.frame <= frame && snap.generation == prepared.generation)
      if snap.header.sequence != lastSeq { changes += 1 }
      lastSeq = snap.header.sequence
    }
    #expect(src.activeGeneration == prepared.generation)
    #expect(prepared.graph.tick > 80 && changes > 80, "ticks went by and were published")
  }

  @Test func afterNTicksTheSnapshotEqualsMarkingOnTheStoppedRunner() {
    let (src, prepared) = source(project("dnb", 3), tempo: 600)
    src.play()
    run(src, from: 0, blocks: 800)
    src.pause()
    run(src, from: 800 * 128, blocks: 4)  // the pause lands; nothing moves
    var snap = MarkingSnapshot()
    #expect(src.readMarking(into: &snap))
    #expect(snap.tick > 100 && snap.tick == src.tick)
    let truth = prepared.graph.marking()  // allocating: fine here, the audio thread is idle
    #expect(truth.count == snap.layout!.netCount)
    for (netId, places) in truth {
      for (placeId, tokens) in places {
        #expect(snap.tokens(net: netId, place: placeId) == tokens, "\(netId).\(placeId)")
      }
    }
    #expect(snap.tokens(net: "no-such-net", place: "x") == nil)
  }

  @Test func theSequenceMovesOnlyWhenSomethingChanges() {
    let (src, prepared) = source(project("techno", 42))
    var snap = MarkingSnapshot()
    src.play()
    var frame = run(src, from: 0, blocks: 60)
    src.pause()
    frame = run(src, from: frame, blocks: 3)
    src.readMarking(into: &snap)
    let seq = snap.header.sequence
    frame = run(src, from: frame, blocks: 200)  // paused: nothing changes
    src.readMarking(into: &snap)
    #expect(snap.header.sequence == seq, "no tick, no mute change, no publish")
    // a mute changes the snapshot without any tick
    let kick = prepared.graph.byId["kick"]!
    #expect(snap.muted[kick] == 0)
    src.setMute("kick", true)
    frame = run(src, from: frame, blocks: 2)
    src.readMarking(into: &snap)
    #expect(snap.header.sequence == seq + 1 && snap.muted[kick] == 1 && snap.isMuted(net: kick))
    #expect(matches(snap, prepared.graph))
    src.setRoleMuted("kick", false)
    frame = run(src, from: frame, blocks: 2)
    src.readMarking(into: &snap)
    #expect(snap.header.sequence == seq + 2 && snap.muted[kick] == 0)
  }

  @Test func macrosShowUpAsMutes() {
    let (src, prepared) = source(project("techno", 42))
    src.play()
    var frame = run(src, from: 0, blocks: 40)
    src.fire(.drop, ticks: 8)
    frame = run(src, from: frame, blocks: 2)
    var snap = MarkingSnapshot()
    src.readMarking(into: &snap)
    #expect(matches(snap, prepared.graph))
    #expect(snap.muted.contains(1), "the drop muted the non-drums")
    frame = run(src, from: frame, blocks: 400)
    src.readMarking(into: &snap)
    #expect(matches(snap, prepared.graph))
  }

  @Test func scrubbingMovesTheMirrorToo() {
    let (src, prepared) = source(project("techno", 42))
    src.play()
    var frame = run(src, from: 0, blocks: 80)
    var snap = MarkingSnapshot()
    src.freeze()
    src.scrub(ticks: 10)
    frame = run(src, from: frame, blocks: 120)
    src.readMarking(into: &snap)
    #expect(matches(snap, prepared.graph) && snap.tick > 10, "scratching forward is published")
    let forward = snap.tick
    src.scrub(ticks: -6)
    frame = run(src, from: frame, blocks: 120)
    src.readMarking(into: &snap)
    #expect(matches(snap, prepared.graph) && snap.tick < forward, "and backwards")
  }

  @Test func aSwapSwitchesGenerationAndLayoutTogether() {
    let a = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    let b = WaveRunner.prepare(project("ambient", 5), sampleRate: sr)
    #expect(a.marking.layout.placeCount != b.marking.layout.placeCount, "different shapes")
    let src = WaveDeckSource(sampleRate: sr)
    src.load(a)
    src.setTempo(600)
    src.play()
    var frame = run(src, from: 0, blocks: 100)
    src.load(b)  // while playing: takes over at the next bar
    #expect(src.markingLayout?.generation == b.generation, "the latest layout is already B's")
    var snap = MarkingSnapshot()
    var sawA = 0
    var sawB = 0
    var swapped = false
    for _ in 0..<400 {
      frame = run(src, from: frame, blocks: 1)
      #expect(src.readMarking(into: &snap))
      let layout = snap.layout!
      #expect(snap.generation == layout.generation)
      #expect(snap.tokens.count == layout.placeCount && snap.muted.count == layout.netCount)
      if snap.generation == a.generation {
        sawA += 1
        #expect(!swapped, "once B has taken over A does not come back")
        #expect(matches(snap, a.graph))
        #expect(src.activeGeneration == a.generation)
        #expect(
          src.markingLayout(generation: a.generation) === layout,
          "A's layout is still available while A runs")
      } else {
        swapped = true
        sawB += 1
        #expect(snap.generation == b.generation && matches(snap, b.graph))
        #expect(src.activeGeneration == b.generation)
      }
    }
    #expect(sawA > 0 && sawB > 0, "saw both (A \(sawA) times, B \(sawB))")
    #expect(src.markingLayout(generation: a.generation) != nil, "old layouts stay readable")
    var old = MarkingSnapshot()
    #expect(src.readMarking(generation: a.generation, into: &old))
    #expect(old.generation == a.generation && matches(old, a.graph), "A's last published state")
  }

  @Test func theActiveProjectsMirrorSurvivesAFloodOfLoads() {
    let a = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    let src = WaveDeckSource(sampleRate: sr)
    src.load(a)
    src.setTempo(300)
    src.play()
    let frame = run(src, from: 0, blocks: 40)
    #expect(src.activeGeneration == a.generation)
    for seed in 1...20 {  // queued behind A; each replaces the one waiting for the bar
      src.load(WaveRunner.prepare(project("house", Double(seed)), sampleRate: sr))
    }
    #expect(src.markingLayout(generation: a.generation) != nil, "A is running: never pruned")
    var snap = MarkingSnapshot()
    run(src, from: frame, blocks: 1)
    #expect(src.readMarking(into: &snap) && snap.generation == a.generation)
    #expect(src.markingLayout(generation: 9999) == nil)
  }

  @Test func tooSmallABufferIsRefused() {
    let prepared = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    var tokens = [Double](repeating: 0, count: prepared.marking.layout.placeCount - 1)
    var muted = [UInt8](repeating: 0, count: prepared.marking.layout.netCount)
    let h = tokens.withUnsafeMutableBufferPointer { t in
      muted.withUnsafeMutableBufferPointer { m in prepared.marking.read(tokens: t, muted: m) }
    }
    #expect(h == nil)
  }

  @Test func theSnapshotBufferIsReusedAcrossReads() {
    let (src, _) = source(project("techno", 42))
    src.play()
    var snap = MarkingSnapshot()
    run(src, from: 0, blocks: 5)
    src.readMarking(into: &snap)
    let first = snap.tokens.withUnsafeBufferPointer { $0.baseAddress }
    run(src, from: 5 * 128, blocks: 500)
    src.readMarking(into: &snap)
    let second = snap.tokens.withUnsafeBufferPointer { $0.baseAddress }
    #expect(first == second, "no reallocation for the same layout")
  }
}

struct MarkingMirrorThreadTests {
  @Test(arguments: [false, true])
  func aReaderNeverSeesAMixOfTwoStates(preempted: Bool) {
    // preempted: the reader is held up halfway through each copy, so the writer laps it
    let report = stressMirror(publishes: 20_000, preemptReader: preempted)
    #expect(report.torn == 0, "\(report.torn) snapshots mixed two states")
    #expect(report.backwards == 0)
    #expect(report.published == 20_000)
    #expect(report.reads > 10 && report.changesSeen > 5, "the reader really saw the writer move")
    if preempted {
      #expect(report.retried > 0, "the writer really did lap the reader copy: \(report)")
    }
  }

  @Test func swapsUnderLoadNeverPairALayoutWithTheWrongTokens() {
    let genres = [("techno", 42.0), ("ambient", 5.0), ("house", 7.0), ("dnb", 3.0)]
    let projects = (0..<12).map { i -> WaveProject in
      let (g, s) = genres[i % genres.count]
      return WaveRunner.prepare(project(g, s + Double(i)), sampleRate: 8000)
    }
    #expect(Set(projects.map { $0.marking.layout.placeCount }).count >= 3, "varied shapes")
    let report = stressEngineMirror(projects: projects, rate: 8000)
    #expect(report.mismatched == 0, "a snapshot's arrays did not fit its own layout")
    #expect(report.unknownLayouts == 0)
    #expect(report.backwards == 0)
    #expect(report.reads > 1000)
    #expect(
      report.swapsSeen == projects.count,
      "the audio thread swapped through every project under the reader (\(report.swapsSeen))")
    #expect(report.framesRendered > 0)
  }
}

struct MarkingBeforeTheFirstRenderTests {
  private func warmSource() -> (WaveDeckSource, WaveProject, Int) {
    let first = WaveRunner.prepare(project("techno", 42), sampleRate: sr)
    let src = WaveDeckSource(sampleRate: sr)
    src.load(first)
    src.setTempo(300)
    src.play()
    let frame = run(src, from: 0, blocks: 60)
    return (src, first, frame)
  }

  @Test func aStoppedDeckReportsTheProjectLoadedSinceItLastRendered() {
    let (src, first, frame) = warmSource()
    src.pause()
    let after = run(src, from: frame, blocks: 3)
    var snap = MarkingSnapshot()
    #expect(src.readMarking(into: &snap) && snap.generation == first.generation)
    // a new song is loaded onto the paused deck; no block has run since
    let next = WaveRunner.prepare(project("house", 4), sampleRate: sr)
    src.load(next)
    #expect(src.activeGeneration == first.generation, "the audio thread has not seen it yet")
    #expect(src.readMarking(into: &snap), "...but it is what will sound")
    #expect(snap.generation == next.generation && snap.header.sequence == 1)
    #expect(matches(snap, next.graph) && snap.tick == 0)
    run(src, from: after, blocks: 1)
    #expect(src.activeGeneration == next.generation)
    #expect(src.readMarking(into: &snap) && snap.generation == next.generation)
  }

  @Test func aPlayingDeckKeepsReportingTheSoundingProjectUntilTheBar() {
    let (src, first, frame) = warmSource()
    let next = WaveRunner.prepare(project("house", 4), sampleRate: sr)
    src.load(next)
    var snap = MarkingSnapshot()
    #expect(src.readMarking(into: &snap) && snap.generation == first.generation)
    let after = run(src, from: frame, blocks: 1)  // queued behind the playing one
    #expect(src.readMarking(into: &snap) && snap.generation == first.generation)
    // pause before the bar: it stays queued, and the sounding one is still the one reported
    src.pause()
    run(src, from: after, blocks: 3)
    #expect(src.readMarking(into: &snap) && snap.generation == first.generation)
    #expect(src.activeGeneration == first.generation)
  }
}
