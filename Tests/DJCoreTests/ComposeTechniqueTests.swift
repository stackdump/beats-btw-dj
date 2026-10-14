import Testing

@testable import DJCore

// The opt-in composition techniques (Techniques.swift, ComposeOptions.swift), measured on
// what the composed net actually plays: the graph is stepped through the whole song.

private func spec(_ options: JSONObject, genre: String = "edm", seed: Double = 4242)
  throws -> TrackSpec
{
  try ComposeOptions.apply(options, to: TrackSpec(genre: genre, seed: seed, structure: "standard"))
}

private func opts(_ pairs: (String, JSONValue)...) -> JSONObject { JSONObject(pairs) }

private struct Heard {
  var step: Int
  var role: String
  var note: Int
}

/// Every audible note of the song: (step, role, note), role = riff group or net id.
private func play(_ p: Project) -> [Heard] {
  let total = p.structure.reduce(0) { $0 + $1.steps }
  let g = WaveGraph(project: p)
  var out: [Heard] = []
  for _ in 0..<total {
    g.advance { n, t in
      let role = n.bundle.riffGroup.isEmpty ? n.id : n.bundle.riffGroup
      out.append(Heard(step: g.tick - 1, role: role, note: n.note[t]))
    }
  }
  return out
}

/// Structure changes land late: beats' accumulator nets spend a tick per event, so by the
/// end of a standard song a slot switch is up to a bar behind its boundary. Notes are only
/// attributed to a section past this margin.
private let lag = 24

/// (name, start, steps) of each section.
private func sections(_ p: Project) -> [(name: String, start: Int, steps: Int)] {
  var pos = 0
  return p.structure.map { s in
    defer { pos += s.steps }
    return (s.name, pos, s.steps)
  }
}

private let melodic: Set<String> = ["bass", "melody", "harmony", "arp"]

private func pcs(_ genre: String, _ seed: Double, step: Int) -> Set<Int> {
  let g = BeatsTables.shared.genres[genre]!
  let plan = buildTrackTheme(genre: genre, seed: seed).plan
  let key = g.scale(g.rootNote)
  return Set(chordAt(plan, step).tones.map { degreeToMidi(clampDegree($0), key) % 12 })
}

@Suite struct ComposeTechniqueTests {
  @Test func optionsOffAreTheBeatsTrack() throws {
    let plain = TrackSpec(genre: "edm", seed: 4242, structure: "standard")
    let off = try spec(
      opts(
        ("hook", .bool(false)), ("chordSnap", .string("off")), ("layerBudget", .string("off")),
        ("bassFollow", .bool(false)), ("keyLock", .bool(false))))
    #expect(off == plain)
    #expect(BeatsCID.shareCID(off.payload) == BeatsCID.shareCID(plain.payload))
    // compose ignores the off values too, even unnormalised
    var ov = plain.overrides.object!
    ov["hook"] = .bool(false)
    ov["chordSnap"] = .string("off")
    #expect(compose(genre: "edm", overrides: .object(ov)).modelCID == plain.project().modelCID)
  }

  @Test func validationRejectsBadValues() {
    let base = TrackSpec(genre: "edm", seed: 1)
    for (k, v): (String, JSONValue) in [
      ("hook", .string("yes")), ("hookBars", .int(3)), ("chordSnap", .string("some")),
      ("layerBudget", .int(9)), ("layerBudget", .number(1.5)), ("melodyDensity", .int(0)),
      ("ghostNotes", .number(2)), ("humanize", .number(-1)), ("nope", .bool(true)),
    ] {
      #expect(throws: ComposeOptions.Invalid.self) {
        _ = try ComposeOptions.apply(JSONObject([(k, v)]), to: base)
      }
    }
    // ghostNotes is stored under beats' own key, and reads back under its option name
    let s = try! ComposeOptions.apply(JSONObject([("ghostNotes", .number(0.1))]), to: base)
    #expect(s.extra["ghost-notes"] == .number(0.1))
    #expect(ComposeOptions.describe(s)["ghostNotes"] == .number(0.1))
    // and survives the share payload round trip
    #expect(TrackSpec(payload: s.payload) == s)
  }

  @Test func hookPlaysInEveryMelodySection() throws {
    for bars in [1, 2] {
      let s = try spec(opts(("hook", .bool(true)), ("hookBars", .int(bars))))
      let p = s.project()
      let hook = buildHook(
        genre: "edm", seed: 4242, bars: bars,
        density: BeatsTables.shared.genres["edm"]!.melodyDensity)
      let heard = play(p).filter { $0.role == "melody" }
      var melodySections = 0
      for sec in sections(p) {
        let mode = hookModes[sec.name] ?? MotifMode.play
        let notes = heard.filter { $0.step >= sec.start + lag && $0.step < sec.start + sec.steps }
        guard !notes.isEmpty else { continue }
        melodySections += 1
        let stretch = mode == MotifMode.augmented ? 2 : 1
        for n in notes {
          // on the hook's rhythm (fragment: its first half only)
          #expect(n.step % stretch == 0)
          let h = (n.step / stretch) % hook.length
          #expect(hook.mask[h], "\(sec.name) step \(n.step) is off the hook")
          if mode == MotifMode.fragment { #expect(h < hook.length / 2) }
          // and on the sounding chord
          #expect(pcs("edm", 4242, step: n.step).contains(n.note % 12))
        }
        // same contour: within a bar, each move goes the hook's way (or holds — a chord
        // with no tone between two targets)
        guard mode == MotifMode.play || mode == MotifMode.transposed else { continue }
        for bar in Set(notes.map { $0.step / 16 }) {
          let inBar = notes.filter { $0.step / 16 == bar }.sorted { $0.step < $1.step }
          for (a, b) in zip(inBar, inBar.dropFirst()) {
            let want = hook.target[b.step % hook.length] - hook.target[a.step % hook.length]
            let got = b.note - a.note
            #expect(got == 0 || (got > 0) == (want > 0), "\(sec.name) bar \(bar)")
          }
        }
      }
      // edm standard: every section with melody in it carries the hook
      let active = sections(p).filter { sec in
        heard.contains { $0.step >= sec.start + lag && $0.step < sec.start + sec.steps }
      }
      #expect(melodySections >= 3)
      #expect(melodySections == active.count)
    }
  }

  @Test(arguments: ["strong", "all"])
  func chordSnapLeavesNoNonChordTonesOnItsBeats(_ mode: String) throws {
    let every = mode == "strong" ? 8 : 4
    for (genre, cohesion) in [("edm", "v2"), ("techno", "v1"), ("jazz", "v1")] {
      var s = try spec(
        opts(("chordSnap", .string(mode)), ("chordSnapArp", .bool(true))), genre: genre)
      s.cohesion = cohesion
      let heard = play(s.project()).filter {
        ($0.role == "melody" || $0.role == "arp") && $0.step % every == 0
      }
      #expect(!heard.isEmpty, "\(genre)")
      for n in heard {
        #expect(
          pcs(genre, 4242, step: n.step).contains(n.note % 12),
          "\(genre) \(n.role) step \(n.step) note \(n.note)")
      }
    }
  }

  @Test func layerBudgetCapsMelodicRolesPerSection() throws {
    func maxRoles(_ s: TrackSpec, _ cap: (String) -> Int) -> Bool {
      let p = s.project()
      let heard = play(p)
      var ok = true
      for sec in sections(p) {
        let roles = Set(
          heard.filter {
            melodic.contains($0.role) && $0.step >= sec.start + lag
              && $0.step < sec.start + sec.steps
          }.map(\.role))
        if roles.count > cap(sec.name) {
          ok = false
          Issue.record("\(sec.name): \(roles.sorted()) over \(cap(sec.name))")
        }
      }
      return ok
    }
    // without a budget the drop stacks four
    let plain = TrackSpec(genre: "edm", seed: 4242, structure: "standard")
    let p0 = play(plain.project())
    let drop = sections(plain.project()).first { $0.name == "drop" }!
    #expect(
      Set(
        p0.filter {
          melodic.contains($0.role) && $0.step >= drop.start + lag
            && $0.step < drop.start + drop.steps
        }.map(\.role)
      ).count == 4)

    #expect(maxRoles(try spec(opts(("layerBudget", .string("auto"))))) { autoLayerBudget[$0] ?? 2 })
    #expect(maxRoles(try spec(opts(("layerBudget", .int(1))))) { _ in 1 })
    // the budget keeps bass first, then melody
    let one = play(try spec(opts(("layerBudget", .int(1)))).project())
    #expect(!one.contains { $0.role == "arp" || $0.role == "harmony" })
    // and leaves the nets in place
    #expect(
      try spec(opts(("layerBudget", .int(1)))).project().nets.keys.count
        == plain.project().nets.keys.count)
  }

  @Test func bassFollowRepeatsOnePatternPerCycle() throws {
    for (genre, cohesion) in [("edm", "v2"), ("techno", "v1")] {
      var s = try spec(opts(("bassFollow", .bool(true))), genre: genre)
      s.cohesion = cohesion
      let p = s.project()
      let cycle = cycleSteps(buildTrackTheme(genre: genre, seed: 4242).plan)
      let bass = play(p).filter { $0.role == "bass" }
      #expect(!bass.isEmpty)
      // wherever it plays, the bass at step s is the bass at s + one cycle
      var byStep: [Int: Int] = [:]
      for b in bass { byStep[b.step] = b.note }
      var compared = 0
      for (step, note) in byStep {
        if let later = byStep[step + cycle] {
          #expect(later == note, "\(genre) step \(step)")
          compared += 1
        }
      }
      #expect(compared > 16)
    }
  }

  @Test func keyLockKeepsTensionPhrasesInKey() throws {
    let g = BeatsTables.shared.genres["edm"]!
    let key = Set(g.scale(g.rootNote).map { $0 % 12 })
    func outOfKey(_ s: TrackSpec) -> Int {
      play(s.project()).filter { ($0.role == "melody" || $0.role == "arp") && !key.contains($0.note % 12) }
        .count
    }
    // beats' tension curve moves B / C phrases out of the key…
    #expect(outOfKey(TrackSpec(genre: "edm", seed: 4242, structure: "standard")) > 0)
    // …keyLock keeps them in it
    #expect(outOfKey(try spec(opts(("keyLock", .bool(true))))) == 0)
  }

  @Test func determinism() throws {
    let all = opts(
      ("hook", .bool(true)), ("chordSnap", .string("strong")), ("layerBudget", .string("auto")),
      ("melodyDensity", .number(0.35)), ("ghostNotes", .number(0.1)), ("bassFollow", .bool(true)))
    let a = try spec(all)
    let b = try spec(all)
    #expect(BeatsCID.shareCID(a.payload) == BeatsCID.shareCID(b.payload))
    #expect(a.project().modelCID == b.project().modelCID)
    var seen: Set<String> = []
    var models: Set<String> = []
    for o in [
      opts(), opts(("hook", .bool(true))),
      opts(("chordSnap", .string("strong"))),
      opts(("hook", .bool(true)), ("chordSnap", .string("strong")), ("layerBudget", .string("auto"))),
      all,
    ] {
      let s = try spec(o)
      seen.insert(BeatsCID.shareCID(s.payload))
      models.insert(s.project().modelCID)
    }
    #expect(seen.count == 5)
    #expect(models.count == 5)
    // (hook + chordSnap is the hook's own model: every hook note is already a chord tone)
    #expect(
      try spec(opts(("hook", .bool(true)), ("chordSnap", .string("strong")))).project().modelCID
        == spec(opts(("hook", .bool(true)))).project().modelCID)
  }

  @Test func roleFilterDropsOnlyTheNotes() {
    let p = TrackSpec(genre: "edm", seed: 4242, structure: "standard").project()
    let solo = RoleFilter(solo: ["drums", "bass"]).apply(p)
    #expect(solo.nets.keys == p.nets.keys)
    for id in p.nets.keys {
      let nb = p.nets[id]!
      let kept = !solo.nets[id]!.bindings.keys.isEmpty
      let drumsOrBass = nb.track.group == "drums" || nb.track.group == "bass" || id.hasPrefix("fill-")
      if !nb.bindings.keys.isEmpty { #expect(kept == drumsOrBass, "\(id)") }
      #expect(solo.nets[id]!.controlBindings.keys.count == nb.controlBindings.keys.count)
    }
    let muted = RoleFilter(mute: ["melody"]).apply(p)
    #expect(!play(muted).contains { $0.role == "melody" })
    #expect(play(muted).filter { $0.role != "melody" }.count == play(p).filter { $0.role != "melody" }.count)
  }
}
