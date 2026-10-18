import Testing

@testable import DJCore

// `.backbeat` (Backbeat.swift, ROADMAP 6.5's dj half): the chill family's verses and choruses get
// the kick and snare beats' theme table leaves out, on existing transitions only.

private let chill = ["lofi", "jazz", "bossa"]
private let seeds: [Double] = [42, 7, 1234]

private func composed(_ genre: String, _ seed: Double) -> (spec: TrackSpec, project: Project) {
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  return (spec, spec.project())
}

private func report(_ p: Project, genre: String) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls, genre: genre)
}

/// Bound transition indices of a net, in order.
private func hits(_ nb: NetBundle) -> [Int] {
  nb.bindings.keys.compactMap { $0.hasPrefix("t") ? Int($0.dropFirst()) : nil }.sorted()
}

/// A one-bar drum ring on channel 10 with `note` on `steps`.
private func drumRing(_ note: Int, _ steps: [Int], size: Int = 16) -> NetBundle {
  var nb = NetBundle.ring(size)
  for s in steps { nb.bind(s, note: note, channel: 10, velocity: 100, duration: 50) }
  nb.track = Track(channel: 10, defaultVelocity: 100, group: "drums")
  return nb
}

/// Notes of net `id` in each section of `p`.
private func perSection(_ p: Project, _ id: String) -> [Int] {
  let (log, _) = NoteLog.captureAll(p)
  var start = 0
  return p.structure.map { s in
    defer { start += s.steps }
    return log.filter { $0.net == id && $0.tick > start && $0.tick <= start + s.steps }.count
  }
}

struct BackbeatTests {
  /// The exit: lofi, jazz and bossa have a kick and snare in every section their style expects
  /// one, at three seeds, with the pass alone and with every fix.
  @Test func chillFamilyHasABeat() {
    for genre in chill {
      for seed in seeds {
        let (spec, p) = composed(genre, seed)
        let alone = DJMusicality.apply(p, spec: spec, fixes: [.timing, .backbeat])
        let r = report(alone, genre: genre)
        #expect(r.hasBeat == 1, "\(genre) \(seed) backbeat: \(r.beatBySection)")
        let all = report(DJMusicality.apply(p, spec: spec, fixes: .all), genre: genre)
        #expect(all.hasBeat == 1, "\(genre) \(seed) all: \(all.beatBySection)")
      }
    }
  }

  /// Sections outside the style keep what the composer gave them: no snare in an intro, bridge
  /// or outro that had none, the kick only where it was.
  @Test func otherSectionsKeepTheComposersParts() {
    for genre in chill {
      let style = DJMusicality.beatStyle(genre: genre)!
      for seed in seeds {
        let (spec, p) = composed(genre, seed)
        let played = DJMusicality.apply(p, spec: spec, fixes: [.timing, .backbeat])
        for role in DJMusicality.backbeatRoles {
          let before = perSection(DJMusicality.apply(p, spec: spec, fixes: [.timing]), role)
          let after = perSection(played, role)
          for (k, s) in p.structure.enumerated() where !style.contains(s.name) {
            #expect((before[k] > 0) == (after[k] > 0), "\(genre) \(seed) \(role) in \(s.name)")
          }
          for (k, s) in p.structure.enumerated() where style.contains(s.name) {
            #expect(after[k] > 0, "\(genre) \(seed) \(role) in \(s.name)")
          }
        }
      }
    }
  }

  /// The part comes in on the section's downbeat bar and is gone by the next section's.
  @Test func edgesLandOnSectionStarts() {
    let (spec, p) = composed("lofi", 42)
    let played = DJMusicality.apply(p, spec: spec, fixes: [.timing, .backbeat])
    let style = DJMusicality.beatStyle(genre: "lofi")!
    let (log, _) = NoteLog.captureAll(played)
    var start = 0
    for s in played.structure {
      defer { start += s.steps }
      let snares = log.filter {
        $0.net == "snare" && $0.tick > start && $0.tick <= start + s.steps
      }
      if style.contains(s.name) {
        #expect(snares.first.map { $0.tick <= start + 16 } == true, "\(s.name) at \(start)")
      } else {
        #expect(snares.isEmpty, "\(s.name) at \(start)")
      }
    }
  }

  /// Each family's figure on the composed rings: boom-bap, a feathered jazz kick and soft
  /// snare on every beat of beats' 12-step jazz rings, a bossa surdo and the clave on the rim.
  @Test func figuresByGenre() {
    func nets(_ genre: String) -> (kick: NetBundle, snare: NetBundle) {
      let (spec, p) = composed(genre, 42)
      let q = DJMusicality.apply(p, spec: spec, fixes: [.backbeat])
      return (q.nets["kick"]!, q.nets["snare"]!)
    }
    let lofi = nets("lofi")
    #expect(hits(lofi.kick) == [0, 7, 10])
    #expect(hits(lofi.snare) == [4, 12])
    #expect(lofi.snare.bindings["t4"]?.note == 38)

    let jazz = nets("jazz")
    #expect(jazz.kick.transitions.count == 12, "beats' jazz drums are 12-step rings")
    #expect(hits(jazz.kick) == [0, 4, 8])
    #expect(hits(jazz.snare) == [0, 4, 8])
    let kickPeak = jazz.kick.bindings.values.map(\.velocity).max()!
    #expect(kickPeak < 80, "feathered: \(kickPeak)")

    let bossa = nets("bossa")
    #expect(hits(bossa.kick) == [0, 6, 8, 14])
    #expect(bossa.kick.bindings["t8"]!.velocity > bossa.kick.bindings["t6"]!.velocity)
    #expect(hits(bossa.snare) == [0, 3, 6, 10, 13])
    #expect(bossa.snare.bindings.values.allSatisfy { $0.note == 37 }, "rim")
  }

  /// Bindings and markings only: same nets, places, transitions and arcs; the composed project
  /// (and so its CID) is untouched; only struct nets' delays change among the markings.
  @Test func keepsTopologyAndCID() {
    for genre in chill {
      for seed in seeds {
        let (spec, p) = composed(genre, seed)
        let cid = p.modelCID
        let q = DJMusicality.apply(p, spec: spec, fixes: [.timing, .backbeat])
        #expect(p.modelCID == cid && spec.project().modelCID == cid, "\(genre) \(seed)")
        #expect(q.nets.keys == p.nets.keys)
        for id in p.nets.keys {
          let a = p.nets[id]!
          let b = q.nets[id]!
          #expect(a.places.keys == b.places.keys, "\(genre) \(id)")
          #expect(a.transitions.keys == b.transitions.keys, "\(genre) \(id)")
          #expect(
            a.arcs.map { "\($0.source)>\($0.target)\($0.inhibit)" }
              == b.arcs.map { "\($0.source)>\($0.target)\($0.inhibit)" }, "\(genre) \(id)")
          #expect(Set(b.bindings.keys).isSubset(of: Set(b.transitions.keys)), "\(genre) \(id)")
          #expect(
            Set(b.controlBindings.keys).isSubset(of: Set(b.transitions.keys)), "\(genre) \(id)")
          if !id.hasPrefix("struct-") {
            #expect(
              a.places.values.map(\.initial) == b.places.values.map(\.initial), "\(genre) \(id)")
          }
        }
        #expect(q.structure.map(\.steps) == p.structure.map(\.steps))
      }
    }
  }

  /// Ambient (no beat style) and the genres outside the family are untouched.
  @Test func otherGenresUnchanged() {
    for genre in ["ambient", "techno", "funk"] {
      let (spec, p) = composed(genre, 42)
      #expect(
        DJMusicality.apply(p, spec: spec, fixes: .all).canonicalJSON
          == DJMusicality.apply(p, spec: spec, fixes: .all.subtracting(.backbeat)).canonicalJSON,
        "\(genre)")
      var q = p
      #expect(DJMusicality.backbeat(&q, genre: genre).isEmpty)
      #expect(q.canonicalJSON == p.canonicalJSON, "\(genre)")
    }
  }

  // MARK: synthetic projects

  /// intro, verse, bridge, verse; the snare composed into the bridge only (two stages).
  private func song(snareStages: Bool, fills: Bool) -> Project {
    var p = Project()
    p.structure = [("intro", 64), ("verse", 64), ("bridge", 64), ("verse", 64)].map {
      Section(name: $0.0, steps: $0.1)
    }
    p.nets["kick"] = drumRing(36, [0, 8])
    p.nets["snare"] = drumRing(38, [6])
    p.nets["struct-kick"] = buildAccumulatorNet([])
    p.nets["struct-snare"] = buildAccumulatorNet(
      snareStages
        ? [
          StructureEvent(tick: 128, binding: controlBinding("unmute-track", target: "snare")),
          StructureEvent(tick: 192, binding: controlBinding("mute-track", target: "snare")),
        ] : [])
    if fills {
      for (i, b) in [64, 128, 192, 256].enumerated() {
        p.nets["fill-\(i)"] = drumFillNet(boundaryStep: b, fillLength: 4)
      }
    }
    p.initialMutes = ["kick", "snare"]
    return p
  }

  /// With as many stages as edges, the struct net's own stages are retimed (no fill chain
  /// needed); the composer's bridge snare stays.
  @Test func retimesTheStructNetsOwnStages() {
    var p = song(snareStages: true, fills: false)
    let skipped = DJMusicality.backbeat(&p, genre: "lofi")
    #expect(skipped["snare"] == nil, "\(skipped)")
    #expect(perSection(p, "snare").map { $0 > 0 } == [false, true, true, true])
    #expect(p.nets["struct-snare"]!.places.keys.filter { $0.hasPrefix("p_delay_") }.count == 2)
    // no fill chains to carry the kick's two edges: it is left as composed
    #expect(skipped["kick"]?.hasPrefix("no stage or fill chain") == true)
    #expect(perSection(p, "kick").allSatisfy { $0 == 0 })
  }

  /// With too few stages, the edges ride on the fill chains, and the struct net agrees.
  @Test func carriesEdgesOnFillChains() {
    var p = song(snareStages: false, fills: true)
    let skipped = DJMusicality.backbeat(&p, genre: "lofi")
    #expect(skipped.isEmpty, "\(skipped)")
    #expect(perSection(p, "kick").map { $0 > 0 } == [false, true, false, true])
    #expect(perSection(p, "snare").map { $0 > 0 } == [false, true, false, true])
    #expect(hits(p.nets["snare"]!) == [4, 12])
    let carried = p.nets.pairs.filter { $0.key.hasPrefix("fill-") }
      .flatMap { $0.value.controlBindings.values }
    #expect(carried.count == 6, "kick and snare in at each verse, out at the bridge")
    #expect(p.initialMutes.contains("kick") && p.initialMutes.contains("snare"))
  }

  /// A song that starts with a beat drops the part's initial mute.
  @Test func dropsTheInitialMute() {
    var p = song(snareStages: false, fills: true)
    p.structure[0].name = "verse"
    DJMusicality.backbeat(&p, genre: "bossa")
    #expect(!p.initialMutes.contains("kick") && !p.initialMutes.contains("snare"))
    #expect(perSection(p, "snare").map { $0 > 0 } == [true, true, false, true])
  }

  /// A slotted part is skipped with a reason; the other part still comes in.
  @Test func skipsSlottedParts() {
    var p = song(snareStages: false, fills: true)
    p.nets["kick"] = nil
    for i in 0..<2 {
      var slot = drumRing(36, [0])
      slot.riffGroup = "kick"
      p.nets["kick-\(i)"] = slot
    }
    let before = p.nets["kick-0"]!.bindings.keys
    let skipped = DJMusicality.backbeat(&p, genre: "lofi")
    #expect(skipped["kick"]?.hasPrefix("slotted") == true)
    #expect(p.nets["kick-0"]!.bindings.keys == before)
    #expect(skipped["snare"] == nil)
    #expect(perSection(p, "snare").map { $0 > 0 } == [false, true, false, true])
  }
}
