import Testing

@testable import DJCore

// `DJMusicality.slotWindows`: which slot net of a role plays which bars of which section.

private func played(_ genre: String, _ seed: Double = 42, _ structure: String = "standard")
  -> Project
{
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  return DJMusicality.apply(spec.project(), spec: spec)
}

private func sectionStarts(_ p: Project) -> [Int] {
  var t = 0
  return p.structure.map { s in
    defer { t += s.steps }
    return t
  }
}

/// Every window of `role`, in song order.
private func timeline(_ w: [String: [SlotWindow]]) -> [(net: String, w: SlotWindow)] {
  w.flatMap { net, ws in ws.map { (net, $0) } }.sorted { $0.w.start < $1.w.start }
}

private let genres = ["techno", "house", "edm", "trance", "dnb", "lofi", "jazz", "synthwave"]

struct SlotWindowsTests {
  /// In what a deck plays, a role's windows tile every section it plays in, start on bars and
  /// never overlap; the sections it sits out have none.
  @Test(arguments: genres)
  func windowsTileEachSectionOnBars(genre: String) {
    let p = played(genre)
    let starts = sectionStarts(p)
    var checked = 0
    for role in ["melody", "bass"] {
      let all = timeline(DJMusicality.slotWindows(p, role: role))
      for (si, s) in p.structure.enumerated() {
        let ws = all.filter { $0.w.section == si }
        guard s.phrases[role] != nil else {
          #expect(ws.isEmpty, "\(genre) \(role): windows in \(s.name), which it sits out")
          continue
        }
        checked += 1
        #expect(ws.first?.w.start == starts[si], "\(genre) \(role) \(s.name) starts late")
        #expect(ws.last?.w.end == starts[si] + s.steps, "\(genre) \(role) \(s.name) ends early")
        for (a, b) in zip(ws, ws.dropFirst()) {
          #expect(a.w.end == b.w.start, "\(genre) \(role) \(s.name): gap or overlap at \(a.w.end)")
        }
        for x in ws {
          #expect(x.w.start % 16 == 0, "\(genre) \(role): \(x.net) starts at step \(x.w.start)")
          #expect(x.w.end > x.w.start)
          #expect(x.w.sectionName == s.name)
          #expect(x.w.phrase >= 0 && x.w.phrase < s.phrases[role]!.count)
        }
      }
    }
    #expect(checked > 0, "\(genre): no role played anywhere")
  }

  /// The composed track still tiles each section, from the slot's first change: beats lands
  /// each structure event a tick or more late (`.timing` says why), so a section the role
  /// enters starts a few ticks in.
  @Test(arguments: ["techno", "lofi"])
  func composedWindowsTile(genre: String) {
    let p = TrackSpec(genre: genre, seed: 42, structure: "standard").project()
    let starts = sectionStarts(p)
    let all = timeline(DJMusicality.slotWindows(p, role: "melody"))
    #expect(!all.isEmpty)
    for (si, s) in p.structure.enumerated() where s.phrases["melody"] != nil {
      let ws = all.filter { $0.w.section == si }
      let first = ws.first?.w.start ?? -1
      #expect(
        first >= starts[si] && first <= starts[si] + boundaryStagger + 1, "\(genre) \(s.name)")
      #expect(ws.last?.w.end == starts[si] + s.steps)
      for (a, b) in zip(ws, ws.dropFirst()) {
        #expect(a.w.end == b.w.start)
        #expect(a.w.phrase <= b.w.phrase)
      }
      #expect(ws.last?.w.phrase == s.phrases["melody"]!.count - 1, "\(genre) \(s.name)")
    }
  }

  /// `ringStart` is where the net's token really sits at `start`, by simulating the nets, and
  /// equals the phase `NoteLog` reports for the switch that opens a window.
  @Test(arguments: ["techno", "trance", "lofi"])
  func ringStartIsWhereTheTokenSits(genre: String) throws {
    let p = played(genre)
    let windows = DJMusicality.slotWindows(p, role: "melody")
    let g = WaveGraph(project: p)
    var wanted: [Int: [(String, Int)]] = [:]
    for (net, ws) in windows {
      for w in ws { wanted[w.start, default: []].append((net, try #require(w.ringStart))) }
    }
    var seen = 0
    func check(_ step: Int) {
      for (net, ring) in wanted[step] ?? [] {
        let n = g.nets[g.byId[net]!]
        #expect(NoteLog.ringPosition(n) == ring, "\(genre) \(net) at step \(step)")
        seen += 1
      }
    }
    check(0)
    for step in 1..<NoteLog.length(p) {
      g.advance()
      check(step)
    }
    #expect(seen == windows.values.map(\.count).reduce(0, +))
    #expect(seen > 0)

    for c in NoteLog.captureAll(p).controls where c.action == .slot && windows[c.target] != nil {
      let w = try #require(windows[c.target]!.first { $0.start == c.tick }, "\(c.target)")
      #expect(w.ringStart == c.phase)
    }
  }

  /// The spike for 6.4: bars 5–8 of an 8-bar `A B` (or `C C`) section are always a different
  /// net from bars 1–4. Both start from the top of their ring where the ring is 4 bars; an
  /// 8-bar ring (edm's breakdown) keeps song time, so the half that starts on an odd 4-bar
  /// boundary of the song plays the second half of its ring (ringStart 64).
  @Test func eightBarSectionHalvesAreTwoNets() throws {
    let p = played("edm", 42, "extended")
    let starts = sectionStarts(p)
    let all = timeline(DJMusicality.slotWindows(p, role: "melody"))
    var rings: [String] = []
    for (si, s) in p.structure.enumerated()
    where s.steps == 128 && s.phrases["melody"]?.count == 2 {
      let ws = all.filter { $0.w.section == si }
      try #require(ws.count == 2, "\(s.name): \(ws.map(\.net))")
      #expect(ws[0].net != ws[1].net)
      #expect(ws[0].w.start == starts[si] && ws[0].w.end == starts[si] + 64)
      #expect(ws[1].w.start == starts[si] + 64 && ws[1].w.end == starts[si] + 128)
      #expect(ws.map(\.w.phrase) == [0, 1])
      for x in ws {
        let length = try #require(x.w.ringLength)
        #expect(x.w.ringStart == x.w.start % length)
      }
      rings.append(
        "\(s.name) " + ws.map { "\($0.w.ringStart!)/\($0.w.ringLength!)" }.joined(separator: " "))
    }
    #expect(
      rings == [
        "buildup 0/64 0/64", "breakdown 64/128 0/128", "buildup 0/64 0/64", "bridge 0/64 0/64",
        "outro 0/64 0/64",
      ])
  }

  /// A 2-bar phrase plays the second half of its 4-bar ring: the 12-bar `A A B B` drop is cut
  /// 4 + 4 + 2 + 2 (`.phrases`), and its last phrase starts at ringStart 32.
  @Test func twoBarPhrasesStartMidRing() throws {
    let p = played("techno")
    let starts = sectionStarts(p)
    let si = try #require(p.structure.firstIndex { $0.name == "drop" })
    let ws = timeline(DJMusicality.slotWindows(p, role: "melody")).filter { $0.w.section == si }
    #expect(ws.map { $0.w.start - starts[si] } == [0, 64, 128, 160])
    #expect(ws.map(\.w.phrase) == [0, 1, 2, 3])
    #expect(ws.map(\.w.ringStart) == [0, 0, 0, 32])
  }

  /// Simulating only the control nets acting on the role sees the same part changes as
  /// the whole song.
  @Test(arguments: ["techno", "trance", "lofi", "jazz"])
  func partOnlySeesTheSongsChanges(genre: String) {
    let p = played(genre)
    for role in ["melody", "bass"] {
      let ids = Set(p.nets.pairs.filter { $0.value.riffGroup == role }.map(\.key))
      let full = NoteLog.captureAll(p).controls.filter { ids.contains($0.target) }
      let part = NoteLog.captureAll(DJMusicality.partOnly(p, ids), ticks: NoteLog.length(p))
        .controls.filter { ids.contains($0.target) }
      #expect(!full.isEmpty || ids.count <= 1, "\(genre) \(role)")
      #expect(sameSamples(part.map(\.tick), full.map(\.tick)) == .identical, "\(genre) \(role)")
      #expect(part.map(\.target) == full.map(\.target), "\(genre) \(role)")
      #expect(part.map(\.action) == full.map(\.action), "\(genre) \(role)")
      #expect(part.map(\.net) == full.map(\.net), "\(genre) \(role)")
    }
  }

  @Test func noWindowsForAnUnknownRoleOrALoop() {
    #expect(DJMusicality.slotWindows(played("techno"), role: "nope").isEmpty)
    let loop = TrackSpec(genre: "techno", seed: 42, structure: nil).project()
    #expect(DJMusicality.slotWindows(loop, role: "melody").isEmpty)
  }

  /// The cost on a 300 s song: one simulation of it.
  @Test func costOnALongSong() throws {
    let p = played("reggae", 42, "extended")
    let seconds = Double(NoteLog.length(p)) * 15 / p.tempo
    #expect(seconds >= 300, "\(seconds) s")
    let clock = ContinuousClock()
    var w: [String: [SlotWindow]] = [:]
    let took = clock.measure { w = DJMusicality.slotWindows(p, role: "melody") }
    print("slotWindows: \(Int(seconds)) s song, \(NoteLog.length(p)) steps, took \(took)")
    #expect(!w.isEmpty)
  }
}

// MARK: - Part changes on a section boundary (raw nets)

/// A 16-step ring of `group` with a note on every beat.
private func beatRing(_ group: String, channel: Int, note: Int) -> NetBundle {
  var n = NetBundle.ring(16)
  for s in [0, 4, 8, 12] {
    n.bind(s, note: note, channel: channel, velocity: 100, duration: 200)
  }
  n.track.channel = channel
  n.track.group = group
  n.riffGroup = group
  return n
}

/// A control net firing `action` on `target` at song step `step` (its transition `t<step>`
/// fires on the graph's tick `step + 1`).
private func controlAt(_ step: Int, _ action: String, _ target: String, steps: Int) -> NetBundle {
  buildControlBundle(
    steps: steps, ctrlAt: [step: controlBinding(action, target: target)], sink: true)
}

/// A drop then a breakdown, 2 bars each, bass + melody + harmony; on the breakdown's first
/// step the bass and melody are muted and the harmony unmuted (muted through the drop). With
/// `controlsFirst` the control nets come before the parts in the graph, so each change acts on
/// the tick it fires (its own step); after them, on the next step.
private func boundaryProject(controlsFirst: Bool) -> Project {
  var p = Project()
  p.tempo = 120
  p.structure = [Section(name: "drop", steps: 32), Section(name: "breakdown", steps: 32)]
  let controls = [
    ("ctl-bass", controlAt(32, "mute-track", "bass", steps: 64)),
    ("ctl-melody", controlAt(32, "mute-track", "melody", steps: 64)),
    ("ctl-harmony", controlAt(32, "unmute-track", "harmony", steps: 64)),
  ]
  if controlsFirst { for (id, nb) in controls { p.nets[id] = nb } }
  p.nets["bass"] = beatRing("bass", channel: 6, note: 33)
  p.nets["melody"] = beatRing("melody", channel: 1, note: 72)
  p.nets["harmony"] = beatRing("harmony", channel: 2, note: 60)
  if !controlsFirst { for (id, nb) in controls { p.nets[id] = nb } }
  p.initialMutes = ["harmony"]
  return p
}

/// The steps (from 0) each part's notes actually play on.
private func playedSteps(_ p: Project) -> [String: Set<Int>] {
  var out: [String: Set<Int>] = [:]
  for n in NoteLog.capture(p) { out[n.net, default: []].insert(n.tick - 1) }
  return out
}

struct SlotWindowsBoundaryTests {
  /// A part muted / unmuted on a section's first step is attributed to the sections it really
  /// plays in, step for step, whichever side of the parts its control net sits.
  @Test(arguments: [true, false])
  func boundaryChangesLandInTheRightSection(controlsFirst: Bool) {
    let p = boundaryProject(controlsFirst: controlsFirst)
    let truth = playedSteps(p)
    for role in ["bass", "melody", "harmony"] {
      let ws = DJMusicality.slotWindows(p, role: role)[role] ?? []
      let covered = Set(ws.flatMap { $0.start..<$0.end })
      for s in truth[role] ?? [] {
        #expect(
          covered.contains(s),
          "\(role) (controls first: \(controlsFirst)): plays step \(s) outside its windows \(ws.map { ($0.start, $0.end) })"
        )
      }
      // Every window holds a note of the part (it plays one on every beat).
      for w in ws {
        #expect(
          (w.start..<w.end).contains { truth[role]?.contains($0) ?? false },
          "\(role) (controls first: \(controlsFirst)): window \(w.start)..<\(w.end) plays no note")
      }
    }
    if controlsFirst {
      // The change acts on step 32 itself: nothing of the bass / melody reaches the
      // breakdown, and the harmony plays only there.
      #expect(!(truth["bass"] ?? []).contains(32))
      #expect((truth["harmony"] ?? []).min() == 32)
      #expect(DJMusicality.slotWindows(p, role: "bass")["bass"]?.map(\.section) == [0])
      #expect(DJMusicality.slotWindows(p, role: "melody")["melody"]?.map(\.section) == [0])
      #expect(DJMusicality.slotWindows(p, role: "harmony")["harmony"]?.map(\.section) == [1])
    }
  }

  /// beats puts every control net after the parts, so in a composed (and a played) track every
  /// change acts from the step its tick names: the fix moves nothing there.
  @Test(arguments: ["techno", "lofi", "edm"])
  func composedChangesActOnTheirTick(genre: String) {
    let p = played(genre)
    let controls = NoteLog.captureAll(p).controls
    #expect(!controls.isEmpty)
    #expect(controls.allSatisfy { $0.step == $0.tick }, "\(genre)")
  }

  /// `.layerBudget` on that breakdown (budget 1) keeps the one part that actually plays there.
  @Test func layerBudgetKeepsThePartThatPlays() {
    let p = boundaryProject(controlsFirst: true)
    let b = DJMusicality.layerBudgets(p)
    #expect(b.count == 2)
    #expect(
      b[1].playing == [RestSchedule.Class.of(kind: "tonal", group: "harmony", net: "harmony")])
    #expect(b[1].rested.isEmpty)
  }
}
