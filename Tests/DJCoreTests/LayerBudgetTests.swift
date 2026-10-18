import Testing

@testable import DJCore

// `.layerBudget`: at most `autoLayerBudget[section]` melodic parts a section, the rest resting
// in the runner (`RestSchedule`), in `layerPriority` order. Renders of a small project through
// a linear master, 120 BPM: a step is 0.125 s.

private let sr = 24_000.0
private let step = Int(0.125 * sr)

private func ring(_ group: String, channel: Int, note: Int) -> NetBundle {
  var n = NetBundle.ring(16)
  for s in [0, 4, 8, 12] {
    n.bind(s, note: note, channel: channel, velocity: 100, duration: 200)
  }
  n.track.channel = channel
  n.track.group = group
  n.riffGroup = group
  return n
}

/// Four parts playing all through an intro (budget 1) and a drop (budget 3), 8 bars each.
private func layered() -> Project {
  var p = Project()
  p.tempo = 120
  p.nets["bass"] = ring("bass", channel: 6, note: 33)
  p.nets["melody"] = ring("melody", channel: 1, note: 72)
  p.nets["harmony"] = ring("harmony", channel: 2, note: 60)
  p.nets["arp"] = ring("arp", channel: 3, note: 67)
  p.structure = [Section(name: "intro", steps: 128), Section(name: "drop", steps: 128)]
  return p
}

private func options(_ fixes: DJMusicality.Fixes) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  return o
}

private func render(_ p: Project, _ o: WaveOptions, seconds: Double) -> [Float] {
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var out = [Float](repeating: 0, count: Int(seconds * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      let n = min(256, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n)
      off += n
    }
  }
  return out
}

private func rmsDB(_ x: [Float], _ a: Int, _ b: Int) -> Double { rmsDB(x[a..<b]) }

struct LayerBudgetTests {
  typealias Entry = RestSchedule.Entry

  /// The parts in the order a budget keeps them: `layerPriority` by rest class, each once.
  @Test func priorityIsBassMelodyHarmonyArp() {
    #expect(DJMusicality.layerClassPriority == [.bass, .melody, .harmony, .arp])
    #expect(DJMusicality.layerGroup("lead") == "melody")
    #expect(DJMusicality.layerGroup("chords") == "harmony")
  }

  /// The flag is in `Fixes.all` and `named`, and off in `WaveOptions()` (parity: no rests).
  @Test func flagIsRegisteredAndOffForParity() {
    #expect(DJMusicality.Fixes.all.contains(.layerBudget))
    #expect(DJMusicality.Fixes.named["layerBudget"] == .layerBudget)
    #expect(!WaveOptions().musicality.contains(.layerBudget))
    #expect(RestSchedule.build(layered(), fixes: WaveOptions().musicality).isEmpty)
  }

  /// Each section keeps its first `cap` parts in priority order and rests the rest over the
  /// whole section.
  @Test func budgetsKeepThePriorityParts() {
    let p = layered()
    let b = DJMusicality.layerBudgets(p)
    #expect(b.map(\.cap) == [1, 3])
    #expect(b.allSatisfy { $0.playing == [.bass, .melody, .harmony, .arp] })
    #expect(b[0].kept == [.bass] && b[0].rested == [.melody, .harmony, .arp])
    #expect(b[1].kept == [.bass, .melody, .harmony] && b[1].rested == [.arp])
    #expect(
      DJMusicality.layerBudgetRests(p) == [
        Entry(from: 0, to: 128, mask: [.melody, .harmony, .arp]),
        Entry(from: 128, to: 256, mask: .arp),
      ])
    #expect(RestSchedule.build(p, fixes: .layerBudget).entries.count == 2)
    #expect(RestSchedule.build(p, fixes: []).isEmpty)
    // within budget: nothing rests
    var small = p
    small.nets["harmony"] = nil
    small.nets["arp"] = nil
    small.structure = [Section(name: "drop", steps: 128)]
    #expect(DJMusicality.layerBudgetRests(small).isEmpty)
  }

  /// Without the flag beats' drop stacks four melodic parts (edm 4242, as
  /// `layerBudgetCapsMelodicRolesPerSection`); with it every section over its budget rests
  /// its lowest-priority parts there, and none within it does.
  @Test func composedTrackIsCapped() throws {
    let p = TrackSpec(genre: "edm", seed: 4242, structure: "standard").project()
    let budgets = DJMusicality.layerBudgets(p)
    #expect(budgets.contains { $0.playing.count > $0.cap })
    let drop = try #require(p.structure.firstIndex { $0.name == "drop" })
    #expect(budgets[drop].playing.count == 4 && budgets[drop].rested == [.arp])
    let s = RestSchedule.build(p, fixes: .layerBudget)
    var start = 0
    for (i, sec) in p.structure.enumerated() {
      defer { start += sec.steps }
      let mask = s.mask(at: start + sec.steps / 2)
      var want: RestSchedule.Class = []
      for c in budgets[i].rested { want.formUnion(c) }
      #expect(mask == want, "\(sec.name)")
      #expect(budgets[i].playing.count - budgets[i].rested.count <= budgets[i].cap)
    }
  }

  /// A rested part is silent (< −80 dB) where it rests and plays where it doesn't; the rests
  /// come from the solo's own schedule (`MixBalance.solo` keeps every net).
  @Test func restedSoloIsSilent() {
    let p = layered()
    let o = options(.layerBudget)
    let melody = render(MixBalance.solo(p, "lead"), o, seconds: 32)
    let arp = render(MixBalance.solo(p, "arp"), o, seconds: 32)
    let bass = render(MixBalance.solo(p, "bass"), o, seconds: 32)
    let intro = (step * 4, step * 128)
    let drop = (step * 132, step * 256)
    #expect(rmsDB(melody, intro.0, intro.1) < -80)
    #expect(rmsDB(melody, drop.0, drop.1) > -60)
    #expect(rmsDB(arp, intro.0, intro.1) < -80 && rmsDB(arp, drop.0, drop.1) < -80)
    #expect(rmsDB(bass, intro.0, intro.1) > -60 && rmsDB(bass, drop.0, drop.1) > -60)
    // without the flag the arp plays the drop
    let free = render(MixBalance.solo(p, "arp"), options([]), seconds: 32)
    #expect(rmsDB(free, drop.0, drop.1) > -60)
  }

  /// `djctl render --layers`'s count: four parts a section without the flag, the budget with it.
  @Test func layersPerSectionCountsTheCap() {
    let p = layered()
    let without = OfflineRender.layersPerSection(p, opts: options([]), sampleRate: sr)
    #expect(without.map(\.name) == ["intro", "drop"])
    #expect(without.map(\.layers) == [4, 4])
    let with = OfflineRender.layersPerSection(p, opts: options(.layerBudget), sampleRate: sr)
    #expect(with.map(\.layers) == [1, 3])
    #expect(with[0].parts == ["bass"] && with[1].parts == ["bass", "pad", "lead"])
    #expect((with[1].levelsDB["arp"] ?? 0) <= -150)
    let short = OfflineRender.layersPerSection(
      p, opts: options(.layerBudget), sampleRate: sr, seconds: 20)
    #expect(short.map(\.name) == ["intro"])
  }
}
