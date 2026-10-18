import Testing

@testable import DJCore

// RasterModel.compute is scope.js `computeRaster`: the whole arrangement ticked offline by the
// engine's own WaveGraph. The hand-made nets pin each rule of the JS (loop cycle on a bar line,
// the mute table counting as state, the value clamps, the caps); the composed projects check the
// whole thing on what the composer really makes, against a second, independent tick of the graph.

// MARK: - builders

private func place(_ initial: Double) -> Place { Place(initial: [initial], x: 0, y: 0, label: nil) }

/// A ring of `n` places with one token; transition `i` plays note `36 + i`.
private func ringNet(
  _ n: Int, channel: Int = 1, velocity: Int = 100, durSteps: Int = 1, durMs: Int = 0,
  noteBase: Int = 36
) -> NetBundle {
  var nb = NetBundle.ring(n)
  nb.track = Track(channel: channel)
  for i in 0..<n {
    nb.bindings["t\(i)"] = MidiBinding(
      note: noteBase + i, channel: channel, velocity: velocity, duration: durMs,
      durationSteps: durSteps)
  }
  return nb
}

/// One transition that fires every tick and piles a token into `p1` each time: the marking never
/// comes back, so a loop made of it has no cycle.
private func counterNet(note: Int = 60) -> NetBundle {
  var nb = NetBundle()
  nb.track = Track(channel: 1)
  nb.places["p0"] = place(1)
  nb.places["p1"] = place(0)
  nb.transitions["t0"] = Transition(x: 0, y: 0, label: nil)
  nb.arcs = [
    Arc(source: "p0", target: "t0", weight: [1], inhibit: false),
    Arc(source: "t0", target: "p0", weight: [1], inhibit: false),
    Arc(source: "t0", target: "p1", weight: [1], inhibit: false),
  ]
  nb.bindings["t0"] = MidiBinding(
    note: note, channel: 1, velocity: 100, duration: 0, durationSteps: 1)
  return nb
}

private func project(_ nets: [(String, NetBundle)], tempo: Double = 120) -> Project {
  var p = Project()
  p.tempo = tempo
  for (id, nb) in nets { p.nets[id] = nb }
  return p
}

private func lanes(_ p: Project) -> [String: Int] {
  ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A").laneOf
}

private func composed(_ genre: String, seed: Double, structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

/// The independent tick: a fresh graph, advanced with the plain `advance()`, counting the audible
/// fires of nets that have a lane from `g.fired` (not through the `onNote` closure the compute
/// uses). Stops where the compute stops: at `steps`, a stop request, or `until`.
private func independentFireCount(_ p: Project, laneOf: [String: Int], ticks: Int) -> Int {
  let g = WaveGraph(project: p)
  var n = 0
  for _ in 0..<ticks {
    g.advance()
    var i = 0
    while i < g.firedCount {
      if laneOf[g.nets[Int(g.fired[i])].id] != nil { n += 1 }
      i += 2
    }
    if g.stopRequested { break }
  }
  return n
}

private let genres = ["techno", "house", "ambient", "dnb", "trap", "hiphop", "jazz", "dubstep"]

struct RasterModelTests {
  // MARK: the constants

  @Test func theCapsAreTheJs() {
    #expect(RasterModel.maxBars == 1024 && RasterModel.loopMaxBars == 64)
    #expect(RasterModel.eventCapacity == 262_144 && RasterModel.stepsPerBar == 16)
  }

  // MARK: loop cycles

  @Test(arguments: [(4, 16), (3, 48), (5, 80), (7, 112), (16, 16), (32, 32)])
  func aRingRepeatsOnTheFirstBarLineWhereItIsHome(ring: Int, cycle: Int) {
    let p = project([("ring", ringNet(ring))])
    let r = RasterModel.compute(
      project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(r.loop && r.cycle == cycle && r.steps == cycle && !r.failed && !r.cancelled)
    #expect(r.count == cycle, "one fire per tick")
    #expect(r.step == (0..<cycle).map { Int32($0) })
    #expect(r.note == (0..<cycle).map { UInt8(36 + $0 % ring) }, "transition i plays 36 + i")
    #expect(r.lane.allSatisfy { $0 == 0 } && r.vel.allSatisfy { $0 == 100 })
    #expect(r.dur.allSatisfy { $0 == 1 })
    #expect(r.cycle % 16 == 0 && r.cycle <= RasterModel.loopMaxBars * 16)
  }

  @Test func aLoopThatNeverComesHomeRunsTheFullSixtyFourBars() {
    let p = project([("pile", counterNet())])
    let r = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(r.loop && r.cycle == 0, "no repeat")
    #expect(r.steps == 1024 && r.count == 1024)
    #expect(
      RasterLayout.statusText(r).hasPrefix("raster · loop (no repeat) · 1024 events · 64 bars"))
  }

  @Test func aRingOfSixtyFiveBarsIsOutOfReach() {
    // 65 bars = 1040 ticks: home only after the 64-bar horizon
    let p = project([("ring", ringNet(1040))])
    let r = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(r.cycle == 0 && r.steps == 1024)
  }

  @Test func theMuteTableIsPartOfTheState() {
    // `ctl` toggles A's mute once per 16 ticks (on the first tick of each round). A is a ring of
    // 4, home at every bar line; ctl is a ring of 16, home at every bar line too. The marking
    // alone repeats at step 16, but A is muted then, so the repeat is the second bar line.
    var ctl = ringNet(16)
    ctl.role = "control"
    ctl.bindings = OrderedMap<MidiBinding>()
    ctl.controlBindings["t0"] = ControlBinding(
      action: "toggle-track", targetNet: "A", targetNote: 0)
    let p = project([("A", ringNet(4)), ("ctl", ctl)])
    let r = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(r.cycle == 32 && r.steps == 32)
    // A sounds on tick 1 (before ctl, later in project order, mutes it), is muted for ticks 2...17
    // and sounds again from tick 18 (step 17) on: step 0, then steps 17...31
    #expect(r.step == [0] + (17..<32).map { Int32($0) })
    #expect(r.lane.allSatisfy { $0 == 0 })
  }

  @Test func aNetThatStartsMutedStaysSilentAndStillLoops() {
    var p = project([("A", ringNet(4)), ("B", ringNet(8, noteBase: 60))])
    p.initialMutes = ["A"]
    let r = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(r.cycle == 16 && r.count == 16, "only B is heard")
    #expect(r.lane.allSatisfy { $0 == 1 } || r.lane.allSatisfy { $0 == 0 })
    #expect(r.note.allSatisfy { $0 >= 60 })
  }

  @Test func atStartLooksAtMarkingAndMutesAndAllocatesNothing() {
    let p = project([("ring", ringNet(4)), ("pile", counterNet())])
    let g = WaveGraph(project: p)
    let muted0 = g.muted
    #expect(RasterModel.isAtStart(g, muted0: muted0))
    g.advance()
    #expect(!RasterModel.isAtStart(g, muted0: muted0), "tokens moved")
    let h = WaveGraph(project: project([("ring", ringNet(4))]))
    let m0 = h.muted
    for _ in 0..<16 { h.advance() }
    #expect(RasterModel.isAtStart(h, muted0: m0), "a full round is home")
    h.muted[0] = 1
    #expect(!RasterModel.isAtStart(h, muted0: m0), "a mute differs")
  }

  // MARK: arrangements

  @Test func anArrangedTrackIsTheSumOfItsSections() {
    var p = project([("ring", ringNet(5))])
    p.structure = [
      Section(name: "intro", steps: 32), Section(name: "verse", steps: 64),
      Section(name: "outro", steps: 16),
    ]
    let r = RasterModel.compute(
      project: p, structure: p.structure, tempo: 120, laneOf: lanes(p))
    #expect(!r.loop && r.cycle == 0, "an arrangement never looks for a cycle")
    #expect(r.steps == 112 && r.count == 112)
  }

  @Test func sectionsThatAddUpToNothingFallToSixteenBars() {
    // the JS: `sum || el._totalSteps`, where _totalSteps is that same sum; then `|| 16 * 16`
    let p = project([("ring", ringNet(5))])
    for sections in [
      [Section(name: "a", steps: 0)],
      [Section(name: "a", steps: 16), Section(name: "b", steps: -16)],
    ] {
      let r = RasterModel.compute(project: p, structure: sections, tempo: 120, laneOf: lanes(p))
      #expect(r.steps == 256 && r.count == 256 && !r.loop)
    }
    let sections = RasterModel.compute(
      project: p, structure: [Section(name: "a", steps: 16)], tempo: 120, laneOf: lanes(p))
    #expect(sections.steps == 16)
  }

  @Test func aHostileSumOfSectionsSaturatesInsteadOfTrapping() {
    // two sections of 9e18 steps overflow an Int; the old unchecked sum killed the process
    let p = project([("ring", ringNet(5))])
    let huge = Int.max / 2 + 1
    let r = RasterModel.compute(
      project: p, structure: [Section(name: "a", steps: huge), Section(name: "b", steps: huge)],
      tempo: 120, laneOf: lanes(p), capacity: 100)
    #expect(r.steps == 16_384 && r.count == 100 && r.dropped == 16_284)
    let all = RasterModel.compute(
      project: p,
      structure: [Section(name: "a", steps: Int.max), Section(name: "b", steps: Int.max)],
      tempo: 120, laneOf: lanes(p), capacity: 1)
    #expect(all.steps == 16_384)
    // the other way: a negative sum is nothing, which is sixteen bars
    let low = RasterModel.compute(
      project: p,
      structure: [Section(name: "a", steps: Int.min), Section(name: "b", steps: Int.min)],
      tempo: 120, laneOf: lanes(p), capacity: 1)
    #expect(low.steps == 256)
    #expect(RasterModel.saturatingSum([3, 4, 5]) == 12)
    #expect(RasterModel.saturatingSum([Int.max, Int.max]) == Int.max)
    #expect(RasterModel.saturatingSum([Int.min, Int.min]) == Int.min)
    #expect(RasterModel.saturatingSum([]) == 0)
  }

  @Test func anArrangementIsCappedAtAThousandAndTwentyFourBars() {
    let p = project([("pile", counterNet())])
    let r = RasterModel.compute(
      project: p, structure: [Section(name: "long", steps: 20_000)], tempo: 120,
      laneOf: lanes(p))
    #expect(r.steps == 16_384 && r.count == 16_384)
    #expect(RasterLayout.statusText(r).contains("1024 bars"))
  }

  @Test func aStopTransportEndsTheTickButNotTheLength() {
    var nb = ringNet(10)
    nb.controlBindings["t3"] = ControlBinding(
      action: "stop-transport", targetNet: "", targetNote: 0)
    let p = project([("ring", nb)])
    let arranged = RasterModel.compute(
      project: p, structure: [Section(name: "s", steps: 64)], tempo: 120, laneOf: lanes(p))
    // t3 fires on tick 4 (step 3) and its note is still recorded; then the tick stops
    #expect(arranged.count == 4 && arranged.step.last == 3)
    #expect(arranged.steps == 64, "the raster keeps the length of the arrangement")
    let loop = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(loop.count == 4 && loop.cycle == 0 && loop.steps == 1024)
  }

  // MARK: what is recorded

  @Test func valuesAreClampedAndConvertedLikeTheJs() {
    var nb = ringNet(8)
    // (velocity, note, durationSteps, legacy ms) per transition
    let rows: [(Int, Int, Int, Int)] = [
      (0, 60, 2, 0), (200, 60, 0, 500), (-3, 60, 0, 10), (64, 200, 0, 0), (127, -1, 0, 125),
      (1, 128, 3, 999), (100, 61, 0, 250), (100, 62, 0, 62),
    ]
    for (i, row) in rows.enumerated() {
      nb.bindings["t\(i)"] = MidiBinding(
        note: row.1, channel: 1, velocity: row.0, duration: row.3, durationSteps: row.2)
    }
    let p = project([("ring", nb)])
    let r = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: lanes(p))
    #expect(r.cycle == 16 && r.count == 16)
    let first = 0..<8
    // velocity: 0 -> 100, 200 -> 127, -3 -> 1
    #expect(Array(r.vel[first]) == [100, 127, 1, 64, 127, 1, 100, 100])
    // note & 127
    #expect(Array(r.note[first]) == [60, 60, 60, 72, 127, 0, 61, 62])
    // length: steps when positive; else ms / tickMs (125 ms at 120 bpm), at least 0.5; 0 ms = 100
    #expect(Array(r.dur[first]) == [2, 4, 0.5, 0.8, 1, 3, 2, 0.5])
    // the second round of the ring repeats the first
    #expect(sameSamples(Array(r.vel[8..<16]), Array(r.vel[first])) == .identical)
    #expect(sameSamples(Array(r.dur[8..<16]), Array(r.dur[first])) == .identical)
  }

  @Test func legacyMillisecondsFollowTheTempoAndABadTempoIsOneTwenty() {
    var nb = ringNet(2)
    nb.bindings["t0"] = MidiBinding(
      note: 60, channel: 1, velocity: 100, duration: 500, durationSteps: 0)
    nb.bindings["t1"] = MidiBinding(
      note: 61, channel: 1, velocity: 100, duration: 0, durationSteps: 0)
    let p = project([("ring", nb)])
    func durs(_ tempo: Double) -> [Float] {
      Array(
        RasterModel.compute(project: p, structure: [], tempo: tempo, laneOf: lanes(p)).dur.prefix(2)
      )
    }
    #expect(durs(120) == [4, 0.8])  // 500 / 125, 100 / 125
    #expect(durs(240) == [8, 1.6])  // a step is 62.5 ms
    #expect(sameSamples(durs(0), durs(120)) == .identical)
    #expect(sameSamples(durs(.nan), durs(120)) == .identical)
    #expect(sameSamples(durs(-5), durs(120)) == .identical)
  }

  @Test func netsWithoutALaneAreSkippedAndLanesAreCopiedVerbatim() {
    let p = project([
      ("drums", ringNet(4, channel: 10)), ("bass", ringNet(4)), ("lead", ringNet(8, noteBase: 72)),
    ])
    // lane indices as the feed gives them: any map, here with a gap-free subset
    let map = ["bass": 3, "lead": 7]
    let r = RasterModel.compute(project: p, structure: [], tempo: 120, laneOf: map)
    #expect(r.cycle == 16 && r.count == 32, "16 bass + 16 lead, no drums")
    #expect(Set(r.lane) == [3, 7])
    for i in 0..<r.count {
      #expect(r.lane[i] == (r.note[i] >= 72 ? 7 : 3))
    }
    // a lane index that does not fit a byte, or a negative one, is skipped, not a trap
    let odd = RasterModel.compute(
      project: p, structure: [], tempo: 120, laneOf: ["drums": 256, "bass": -1, "lead": 0])
    #expect(odd.count == 16 && odd.lane.allSatisfy { $0 == 0 })
  }

  @Test func eventsBeyondTheCapacityAreCountedNotStored() {
    let p = project([("ring", ringNet(4))])
    let r = RasterModel.compute(
      project: p, structure: [], tempo: 120, laneOf: lanes(p), capacity: 10)
    #expect(r.count == 10 && r.dropped == 6, "16 events, room for 10")
    #expect(r.cycle == 16, "the tick goes on to the end of the loop")
    #expect(RasterLayout.statusText(r).hasSuffix(" · 6 dropped"))
    let none = RasterModel.compute(
      project: p, structure: [], tempo: 120, laneOf: lanes(p), capacity: 0)
    #expect(none.count == 0 && none.dropped == 16)
  }

  @Test func nothingToShowIsNotAnError() {
    let r = RasterModel.compute(project: Project(), structure: [], tempo: 120, laneOf: [:])
    #expect(!r.failed && r.count == 0 && r.loop)
    // no net moves, so the empty marking is home at the first bar line
    #expect(r.cycle == 16 && r.steps == 16)
  }

  // MARK: cancellation

  @Test func aCancelledComputeStopsAndSaysSo() {
    let p = project([("pile", counterNet())])
    var polls = 0
    let r = RasterModel.compute(
      project: p, structure: [Section(name: "s", steps: 16_384)], tempo: 120, laneOf: lanes(p),
      isCancelled: {
        polls += 1
        return polls > 3
      })
    #expect(r.cancelled)
    #expect(r.count == 3 * 64, "polled every 64 ticks")
    #expect(polls == 4)
  }

  @Test func progressIsToldTheTicksDoneEverySixtyFourTicks() {
    let p = project([("pile", counterNet())])
    let progress = RasterProgress()
    #expect(progress.percent == 0 && progress.fraction == 0, "before a compute")
    var seen: [Int] = []
    let r = RasterModel.compute(
      project: p, structure: [Section(name: "s", steps: 640)], tempo: 120, laneOf: lanes(p),
      progress: progress,
      isCancelled: {
        seen.append(progress.percent)
        return false
      })
    // polled on ticks 0, 64 ... 576: the progress was told the tick before each poll
    #expect(seen == [0, 10, 20, 30, 40, 50, 60, 70, 80, 90])
    #expect(r.count == 640 && progress.percent == 100 && progress.fraction == 1)
    // a cancelled run does not claim to be through
    let q = RasterProgress()
    var polls = 0
    let c = RasterModel.compute(
      project: p, structure: [Section(name: "s", steps: 640)], tempo: 120, laneOf: lanes(p),
      progress: q,
      isCancelled: {
        polls += 1
        return polls == 3
      })
    #expect(c.cancelled && q.percent == 20 && q.fraction < 1)
  }

  @Test func aLoopReportsAgainstTheSixtyFourBarHorizon() {
    let p = project([("ring", ringNet(4))])
    let progress = RasterProgress()
    let r = RasterModel.compute(
      project: p, structure: [], tempo: 120, laneOf: lanes(p), progress: progress)
    #expect(r.cycle == 16)
    #expect(progress.percent == 100, "a loop that is found early is simply done")
  }

  @Test func aLongHeavyArrangementStopsAtTheNextPollOfACancel() {
    // 2000 transitions looked at on each of 16384 ticks: the cost the progress and the cancel are
    // for. The test pins the latency in polls (64 ticks), not the time of a whole compute.
    let p = project([("big", ringNet(2000))])
    var polls = 0
    let r = RasterModel.compute(
      project: p, structure: [Section(name: "long", steps: 16_384)], tempo: 120, laneOf: lanes(p),
      isCancelled: {
        polls += 1
        return polls == 3
      })
    #expect(r.cancelled && polls == 3 && r.count == 2 * 64, "stopped within one poll")
    #expect(r.ms < 5000, "\(r.ms) ms for 128 ticks")
  }

  // MARK: determinism

  @Test func twoComputesAreByteForByteEqual() {
    let p = composed("techno", seed: 42, structure: "minimal")
    let map = lanes(p)
    let a = RasterModel.compute(
      project: p, structure: p.structure, tempo: 128, laneOf: map)
    let b = RasterModel.compute(
      project: p, structure: p.structure, tempo: 128, laneOf: map)
    #expect(a.count > 100)
    #expect(a.sameContent(as: b))
    #expect(sameSamples(a.step, b.step) == .identical)
    #expect(sameSamples(a.lane, b.lane) == .identical)
    #expect(sameSamples(a.note, b.note) == .identical)
    #expect(sameSamples(a.vel, b.vel) == .identical)
    #expect(sameSamples(a.dur.map(\.bitPattern), b.dur.map(\.bitPattern)) == .identical)
    // and it does not depend on the projects' history: a project round-tripped through JSON is
    // the same score
    let c = RasterModel.compute(
      project: Project(json: p.toJSON()), structure: p.structure, tempo: 128, laneOf: map)
    #expect(a.sameContent(as: c))
  }

  @Test func theTimeIsMeasuredAndNotPartOfTheContent() {
    let p = composed("house", seed: 7, structure: "minimal")
    var r = RasterModel.compute(project: p, structure: p.structure, tempo: 120, laneOf: lanes(p))
    #expect(r.ms >= 0)
    let before = r
    r.ms += 1000
    #expect(r != before, "ms is part of the value")
    #expect(r.sameContent(as: before), "but not of its content")
    r.steps += 1
    #expect(!r.sameContent(as: before))
  }

  // MARK: composed projects against an independent tick

  @Test(arguments: genres) func aComposedLoopRepeatsExactlyWhereItSays(genre: String) {
    for seed in [1.0, 42.0] {
      let p = composed(genre, seed: seed)
      #expect(p.structure.isEmpty, "a loop project has no structure")
      let map = lanes(p)
      let r = RasterModel.compute(project: p, structure: p.structure, tempo: p.tempo, laneOf: map)
      #expect(r.loop && !r.failed)
      #expect(r.count == independentFireCount(p, laneOf: map, ticks: r.steps), "\(genre) \(seed)")
      let g = WaveGraph(project: p)
      let initial = g.marking()
      let muted0 = g.muted
      var home: [Int] = []
      for tick in 1...(RasterModel.loopMaxBars * 16) {
        g.advance()
        if tick % 16 == 0, g.marking() == initial, g.muted == muted0 { home.append(tick) }
      }
      if r.cycle > 0 {
        #expect(r.cycle % 16 == 0 && r.cycle <= 1024 && r.steps == r.cycle)
        #expect(
          home.first == r.cycle, "\(genre) \(seed): first home bar line \(home) vs \(r.cycle)")
        // the marking at `cycle` equals the initial marking
        let h = WaveGraph(project: p)
        for _ in 0..<r.cycle { h.advance() }
        #expect(h.marking() == initial && h.muted == muted0)
      } else {
        #expect(r.steps == 1024 && home.isEmpty, "\(genre) \(seed): no repeat, home at \(home)")
      }
    }
  }

  @Test func someComposedLoopHasACycle() {
    // a vacuous pass of the test above (every project "no repeat") would prove nothing
    var found: [(String, Int)] = []
    for genre in genres {
      let p = composed(genre, seed: 42)
      let r = RasterModel.compute(
        project: p, structure: p.structure, tempo: p.tempo, laneOf: lanes(p))
      if r.cycle > 0 { found.append((genre, r.cycle)) }
    }
    #expect(!found.isEmpty, "no composed loop had a cycle")
  }

  @Test(arguments: ["minimal", "standard"])
  func aComposedArrangementIsTickedForTheSumOfItsSections(structure: String) {
    let p = composed("techno", seed: 42, structure: structure)
    #expect(!p.structure.isEmpty)
    let want = min(p.structure.reduce(0) { $0 + $1.steps }, 16_384)
    let map = lanes(p)
    let r = RasterModel.compute(project: p, structure: p.structure, tempo: p.tempo, laneOf: map)
    #expect(!r.loop && r.cycle == 0 && r.steps == want)
    // every event lies inside the arrangement, in step order
    #expect(r.step.allSatisfy { $0 >= 0 && Int($0) < want })
    #expect(zip(r.step, r.step.dropFirst()).allSatisfy { $0 <= $1 })
    // the compute ticks until the structure's own stop-transport, which fires on the last step
    #expect(r.count == independentFireCount(p, laneOf: map, ticks: want))
    #expect(r.count > 200)
    // lane indices are the feed's: every one maps back to a lane
    let laneCount = ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A").lanes.count
    #expect(r.lane.allSatisfy { Int($0) < laneCount })
  }

  @Test func eachEventIsTheOneTheIndependentTickFires() {
    let p = composed("techno", seed: 5, structure: "minimal")
    let map = lanes(p)
    let r = RasterModel.compute(project: p, structure: p.structure, tempo: p.tempo, laneOf: map)
    let g = WaveGraph(project: p)
    var i = 0
    for cur in 0..<r.steps {
      g.advance()
      var k = 0
      while k < g.firedCount {
        let n = g.nets[Int(g.fired[k])]
        let t = Int(g.fired[k + 1])
        k += 2
        guard let lane = map[n.id] else { continue }
        #expect(i < r.count)
        guard i < r.count else { return }
        #expect(
          Int(r.step[i]) == cur && Int(r.lane[i]) == lane && Int(r.note[i]) == n.note[t] & 127)
        i += 1
      }
      if g.stopRequested { break }
    }
    #expect(i == r.count)
  }

  @Test func theEventsOfAMutedSectionAreNotThere() {
    // an arrangement starts with only some parts audible: the mutes are the score
    let p = composed("techno", seed: 42, structure: "minimal")
    let map = lanes(p)
    let r = RasterModel.compute(project: p, structure: p.structure, tempo: p.tempo, laneOf: map)
    let all = RasterModel.compute(
      project: rewritingAllUnmuted(p), structure: p.structure, tempo: p.tempo, laneOf: map)
    #expect(r.count < all.count, "\(r.count) heard of \(all.count)")
  }
}

/// `p` with nothing muted at the start and no control nets, so every net plays all the time.
private func rewritingAllUnmuted(_ p: Project) -> Project {
  var q = p
  q.initialMutes = []
  for (id, net) in q.nets.pairs where net.role == "control" || id.hasPrefix("struct-") {
    q.nets[id] = nil
  }
  return q
}
