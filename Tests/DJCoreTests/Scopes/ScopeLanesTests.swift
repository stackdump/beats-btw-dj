import Testing

@testable import DJCore

// ScopeLaneSet is scope.js `buildLanes`. The hand-made projects pin each rule of the JS; the
// composed ones check the whole thing on what the composer really makes.

private func bundle(
  channel: Int = 1, group: String? = nil, instrument: String = "", role: String = "music",
  riff: String = "", notes: [(note: Int, ms: Int, steps: Int)] = []
) -> NetBundle {
  var b = NetBundle()
  b.role = role
  b.riffGroup = riff
  b.track = Track(channel: channel, instrument: instrument, group: group)
  for (i, n) in notes.enumerated() {
    b.bindings["t\(i)"] = MidiBinding(
      note: n.note, channel: channel, velocity: 100, duration: n.ms, durationSteps: n.steps)
  }
  return b
}

private func composed(_ genre: String, seed: Double = 42, structure: String = "standard") -> Project
{
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["structure"] = .string(structure)
  return compose(genre: genre, overrides: .object(ov))
}

private let genres = ["techno", "house", "ambient", "dnb", "trap", "hiphop", "jazz", "dubstep"]

struct ScopeLanesTests {
  @Test func nameKeysStripOneTrailingDashDigits() {
    var p = Project()
    p.nets["kick-0"] = bundle(channel: 10, group: "drums")
    p.nets["kick-1"] = bundle(channel: 10, group: "drums")
    p.nets["pad-2-7"] = bundle(group: "pad")
    p.nets["solo"] = bundle(group: "lead")
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    #expect(set.lanes.map(\.key) == ["kick", "solo", "pad-2"])
    #expect(set.lanes[0].ids == ["kick-0", "kick-1"], "variants merge into one lane")
    #expect(set.laneOf["kick-0"] == 0 && set.laneOf["kick-1"] == 0)
    #expect(set.laneOf["solo"] == 1 && set.laneOf["pad-2-7"] == 2)
  }

  @Test func riffGroupWinsOverTheName() {
    var p = Project()
    p.nets["a"] = bundle(group: "lead", riff: "melody")
    p.nets["b-3"] = bundle(group: "lead", riff: "melody")
    p.nets["c-1"] = bundle(group: "lead")
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "B")
    #expect(set.lanes.map(\.key) == ["c", "melody"])
    #expect(set.lane(of: "a")?.ids == ["a", "b-3"])
    #expect(set.lanes.allSatisfy { $0.deck == "B" })
  }

  @Test func controlNetsAndMacroNetsAreSkipped() {
    var p = Project()
    p.nets["fill-0"] = bundle(role: "control")
    p.nets["macro:drop"] = bundle(group: "lead")
    p.nets["bass"] = bundle(group: "bass")
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    #expect(set.lanes.map(\.key) == ["bass"])
    #expect(set.laneOf == ["bass": 0])
  }

  @Test func sortIsDrumsThenGroupRankThenKey() {
    var p = Project()
    // creation order is deliberately scrambled
    p.nets["x"] = bundle()
    p.nets["weird"] = bundle(group: "weird")
    p.nets["hit1"] = bundle(channel: 20)
    p.nets["pad"] = bundle(group: "pad")
    p.nets["lead"] = bundle(group: "lead")
    p.nets["kick"] = bundle(channel: 10, group: "drums")
    p.nets["bass-0"] = bundle(group: "bass")
    p.nets["hihat"] = bundle(channel: 12, group: "drums")
    p.nets["aaa"] = bundle()
    p.nets["perc"] = bundle(channel: 15, group: "percussion")
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    // drums first (drums group, then percussion); then bass 2, lead 5, pad 8, stinger 10
    // (hit1: no group, id hit<N>), then everything unranked (main, weird) by key
    #expect(
      set.lanes.map(\.key) == [
        "hihat", "kick", "perc", "bass", "lead", "pad", "hit1", "aaa", "weird", "x",
      ])
    #expect(set.lanes.prefix(3).allSatisfy(\.drum) && !set.lanes[3].drum)
    #expect(set.lane(of: "hit1")?.group == "stinger")
    #expect(set.lane(of: "x")?.group == "main")
  }

  @Test func sectionGroupFollowsTheMixerRule() {
    #expect(ScopeLaneSet.sectionGroup(id: "kick", trackGroup: "drums") == "drums")
    #expect(ScopeLaneSet.sectionGroup(id: "hit7", trackGroup: nil) == "stinger")
    #expect(ScopeLaneSet.sectionGroup(id: "hit7", trackGroup: "") == "stinger")
    #expect(ScopeLaneSet.sectionGroup(id: "hit", trackGroup: nil) == "main")
    #expect(ScopeLaneSet.sectionGroup(id: "hit1a", trackGroup: nil) == "main")
    #expect(
      ScopeLaneSet.sectionGroup(id: "hit1", trackGroup: "lead") == "lead", "explicit group wins")
    #expect(ScopeLaneSet.sectionGroup(id: "bass", trackGroup: nil) == "main")
  }

  @Test func fallbackColoursCycleInCreationOrderAndKnownColoursDoNotConsumeThem() {
    var p = Project()
    p.nets["p1"] = bundle()
    p.nets["kick"] = bundle(channel: 10, group: "drums")
    p.nets["p2"] = bundle()
    p.nets["bass-0"] = bundle(group: "bass")
    for i in 3...10 { p.nets["p\(i)"] = bundle() }
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    func color(_ id: String) -> ScopeColor { set.lane(of: id)!.color }
    let fb = ScopeColors.fallbackLaneColors
    #expect(color("kick") == ScopeColors.laneColors["kick"])
    #expect(color("bass-0") == ScopeColors.laneColors["bass"])
    #expect(color("p1") == fb[0] && color("p2") == fb[1] && color("p3") == fb[2])
    #expect(color("p8") == fb[7] && color("p9") == fb[0] && color("p10") == fb[1], "wraps after 8")
  }

  @Test func durationsAreDurMsOfAtTheGivenTempo() {
    var p = Project()
    p.nets["lead"] = bundle(
      group: "lead", notes: [(60, 200, 0), (62, 0, 4), (64, 0, 0), (60, 150, 2), (70, -5, 0)])
    // 128 BPM: a sixteenth is 60000 / 128 / 4 = 117.1875 ms
    let at128 = ScopeLaneSet.build(project: p, tempo: 128, deck: "A").lanes[0]
    #expect(at128.durationsMs == [200, 468.75, 100, 234.375, 100])
    #expect(at128.notes == [60, 62, 64, 70], "distinct, first-seen order")
    #expect(at128.lo == 60 && at128.hi == 70)
    // a bad tempo falls back to 120: 4 steps = 500 ms
    for bad in [0.0, -3.0, .nan, .infinity] {
      let d = ScopeLaneSet.build(project: p, tempo: bad, deck: "A").lanes[0].durationsMs
      #expect(d[1] == 500 && d[3] == 250, "tempo \(bad)")
    }
  }

  @Test func durationsAreCappedAt256AcrossMergedNets() {
    var p = Project()
    let many = (0..<200).map { (note: 40 + $0 % 5, ms: 100, steps: 0) }
    p.nets["m-0"] = bundle(group: "lead", riff: "m", notes: many)
    p.nets["m-1"] = bundle(group: "lead", riff: "m", notes: many)
    let l = ScopeLaneSet.build(project: p, tempo: 120, deck: "A").lanes[0]
    #expect(l.durationsMs.count == 256)
    #expect(l.notes == [40, 41, 42, 43, 44])
  }

  @Test func aLaneWithNoNotesGetsTheDefaultRange() {
    var p = Project()
    p.nets["silent"] = bundle(group: "lead")
    p.nets["one"] = bundle(group: "lead", notes: [(50, 100, 0)])
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    #expect(set.lane(of: "silent")?.lo == 48 && set.lane(of: "silent")?.hi == 72)
    #expect(set.lane(of: "one")?.lo == 50 && set.lane(of: "one")?.hi == 50)
  }

  @Test func atMost32LanesAreKeptAndTheRestDropOutOfLaneOf() {
    var p = Project()
    for i in 0..<40 { p.nets["n\(i < 10 ? "0" : "")\(i)"] = bundle() }
    p.nets["kick"] = bundle(channel: 10, group: "drums")  // sorts first despite being last
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    #expect(set.lanes.count == 32)
    #expect(set.lanes[0].key == "kick")
    #expect(set.lanes[31].key == "n30")
    #expect(set.laneOf.count == 32)
    #expect(set.laneOf["n30"] == 31 && set.laneOf["n31"] == nil && set.laneOf["n39"] == nil)
  }

  @Test func channelsAreTheDistinctKeptChannelsInLaneOrder() {
    var p = Project()
    p.nets["kick"] = bundle(channel: 10, group: "drums")
    p.nets["snare"] = bundle(channel: 11, group: "drums")
    p.nets["bassA"] = bundle(channel: 6, group: "bass")
    p.nets["bassB"] = bundle(channel: 6, group: "bass")
    p.nets["lead"] = bundle(channel: 4, group: "lead")
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    #expect(set.channels == [10, 11, 6, 4])
  }

  @Test func sectionsAreCumulativeStarts() {
    var p = Project()
    p.nets["a"] = bundle()
    p.structure = [
      Section(name: "intro", steps: 64), Section(name: "verse", steps: 128),
      Section(name: "", steps: 32),
    ]
    let set = ScopeLaneSet.build(project: p, tempo: 120, deck: "A")
    #expect(
      set.sections == [
        ScopeSection(step: 0, name: "intro"), ScopeSection(step: 64, name: "verse"),
        ScopeSection(step: 192, name: ""),
      ])
    #expect(ScopeLaneSet.build(project: Project(), tempo: 120, deck: "A").sections.isEmpty)
    #expect(ScopeLaneSet.build(project: Project(), tempo: 120, deck: "A").isEmpty)
  }

  // MARK: composed projects

  @Test(arguments: genres) func composedProjectsGiveWellFormedLanes(_ genre: String) {
    let p = composed(genre)
    let set = ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A")
    let n = set.lanes.count
    #expect(n > 0 && n <= ScopeLaneSet.maxLanes, "\(genre): \(n) lanes")
    // drums come first, as one block
    let drumFlags = set.lanes.map(\.drum)
    #expect(drumFlags == drumFlags.sorted { $0 && !$1 }, "\(genre): drums first")
    #expect(drumFlags.contains(true), "\(genre) has percussion")
    // within drums and within tonal parts: group rank never goes down, and keys go up in a rank
    func rank(_ l: ScopeLane) -> Int {
      ScopeLaneSet.groupOrder.firstIndex(of: l.group) ?? ScopeLaneSet.groupOrder.count
    }
    for (a, b) in zip(set.lanes, set.lanes.dropFirst()) where a.drum == b.drum {
      #expect(rank(a) <= rank(b), "\(genre): \(a.key) before \(b.key)")
      if rank(a) == rank(b) { #expect(a.key < b.key, "\(genre): \(a.key) < \(b.key)") }
    }
    // laneOf is exactly the ids of the lanes, and never a control or macro net
    var seen = 0
    for (i, l) in set.lanes.enumerated() {
      for id in l.ids {
        seen += 1
        #expect(set.laneOf[id] == i)
        let net = p.nets[id]!
        #expect(net.role != "control" && !id.hasPrefix("macro:"))
        #expect(
          l.key == (net.riffGroup.isEmpty ? ScopeColors.stripTrailingDashDigits(id) : net.riffGroup)
        )
        if id == l.ids[0] { #expect(l.channel == net.track.channel) }
      }
      #expect(l.drum == isDrumChannel(l.channel))
      #expect(l.lo <= l.hi && !l.durationsMs.isEmpty == !l.notes.isEmpty)
      #expect(l.durationsMs.count <= 256)
    }
    #expect(set.laneOf.count == seen)
    for (id, net) in p.nets.pairs where net.role == "control" { #expect(set.laneOf[id] == nil) }
    #expect(Set(set.channels) == Set(set.lanes.map(\.channel)))
    #expect(set.sections.count == p.structure.count && set.sections.first?.step == 0)
  }

  @Test func composedPartsGetTheirTableColoursAndMergeVariants() throws {
    let p = composed("techno")
    let set = ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A")
    func lane(_ key: String) throws -> ScopeLane {
      try #require(set.lanes.first { $0.key == key }, "lane \(key)")
    }
    #expect(try lane("kick").color == ScopeColors.laneColors["kick"])
    #expect(try lane("snare").color == ScopeColors.laneColors["snare"])
    #expect(try lane("hihat").color == ScopeColors.laneColors["hihat"])
    #expect(try lane("bass").color == ScopeColors.laneColors["bass"])
    #expect(try lane("melody").color == ScopeColors.laneColors["melody"])
    #expect(try lane("harmony").color == ScopeColors.laneColors["harmony"])
    #expect(try lane("bass").ids.count > 1, "bass variants are one lane")
    #expect(try lane("kick").drum && !lane("bass").drum)
    #expect(try lane("kick").group == "drums" && lane("bass").group == "bass")
    // the stingers are lanes of their own, in the fallback colours
    let hits = set.lanes.filter { $0.group == "stinger" }
    #expect(hits.map(\.key) == ["hit1", "hit2", "hit3", "hit4"])
    #expect(hits.map(\.color) == Array(ScopeColors.fallbackLaneColors.prefix(4)))
  }

  @Test(arguments: ["techno", "ambient", "dnb"]) func theLayoutPathGivesTheSameLanes(
    _ genre: String
  ) {
    let p = composed(genre)
    let a = ScopeLaneSet.build(project: p, tempo: p.tempo, deck: "A")
    let layout = WaveRunner.prepare(p, sampleRate: 22_050).marking.layout
    let b = ScopeLaneSet.build(layout: layout, deck: "A")
    #expect(a.lanes.count == b.lanes.count)
    for (x, y) in zip(a.lanes, b.lanes) {
      #expect(x.key == y.key && x.ids == y.ids && x.channel == y.channel && x.group == y.group)
      #expect(x.drum == y.drum && x.instrument == y.instrument && x.color == y.color)
      #expect(x.lo == y.lo && x.hi == y.hi, "\(x.key): note range")
      #expect(y.notes.isEmpty && y.durationsMs.isEmpty, "the layout carries no per-note facts")
    }
    #expect(a.laneOf == b.laneOf && a.channels == b.channels && a.sections == b.sections)
  }
}
