import Testing

@testable import DJCore

// `DJMusicality.Fixes.energy`: the composer's per-section energy and filter, which beats' wave
// engine drops, played as level and a tonal lowpass (`EnergyCurve`), measured on renders.

private let sr = 22_050.0

private func played(_ genre: String, _ seed: Double = 42, structure: String = "standard")
  -> Project
{
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  return DJMusicality.apply(spec.project(), spec: spec)
}

/// The whole song, mono, synth voices, with or without the energy arc, in the genre's room.
/// `loudnessGain`: the `.loudness` gain the deck played it at (`WaveProject.gain`).
private func render(_ p: Project, energy: Bool, genre: String, loudnessGain: inout Double)
  -> [Float]
{
  var o = WaveOptions.extended
  o.space = SpaceSpec.forGenre(genre)
  if !energy { o.musicality.remove(.energy) }
  let r = WaveRunner(sampleRate: sr, opts: o)
  let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: o)
  loudnessGain = prepared.gain
  r.load(prepared: prepared)
  r.play()
  let steps = p.structure.reduce(0) { $0 + $1.steps }
  var out = [Float](repeating: 0, count: Int(Double(steps) * sr * 15 / p.tempo) + 512)
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off + 512 <= b.count && !r.stopped {
      r.process(b.baseAddress! + off, nil, frames: 512)
      off += 512
    }
  }
  return out
}

/// RMS (dB) of each section.
private func sectionDB(_ x: [Float], _ p: Project) -> [(name: String, db: Double)] {
  let perStep = sr * 15 / p.tempo
  var at = 0
  return p.structure.map { s in
    let a = Int(Double(at) * perStep)
    let b = min(x.count, Int(Double(at + s.steps) * perStep))
    at += s.steps
    var sum = 0.0
    for i in a..<b { sum += Double(x[i]) * Double(x[i]) }
    return (s.name, ampDB(max(sum / Double(max(1, b - a)), 1e-20).squareRoot()))
  }
}

struct EnergyTests {
  /// The curve follows the composer's arc: the most energetic section at unity, an intro and
  /// a breakdown under it and darker, a buildup sweeping up into the drop.
  @Test func curveFollowsTheComposedArc() throws {
    let p = played("trance")
    let c = try #require(EnergyCurve(project: p))
    let names = p.structure.map(\.name)
    let drop = try #require(names.firstIndex(of: "drop"))
    let intro = try #require(names.firstIndex(of: "intro"))
    let breakdown = try #require(names.firstIndex(of: "breakdown"))
    let buildup = try #require(names.firstIndex(of: "buildup"))
    #expect(c.gain[drop] == 1)
    #expect(ampDB(c.gain[intro]) < -3, "intro \(ampDB(c.gain[intro])) dB")
    #expect(c.cutoff[intro] < 3000 && c.cutoff[breakdown] < 3000 && c.cutoff[drop] > 15000)
    #expect(c.ramp[buildup] && !c.ramp[drop])
    // the buildup starts at its own values and arrives at the drop's
    let s0 = c.start[buildup]
    let s1 = c.start[buildup + 1]
    #expect(c.at(step: s0).cutoff == c.cutoff[buildup])
    #expect(c.at(step: s1 - 1).cutoff > 0.8 * c.cutoff[buildup + 1])
    #expect(c.at(step: (s0 + s1) / 2).cutoff < c.at(step: s1 - 8).cutoff)
    // every occurrence of a section name plays alike (the composer marks only the first)
    for (i, n) in names.enumerated() {
      let first = names.firstIndex(of: n)!
      #expect(c.gain[i] == c.gain[first] && c.cutoff[i] == c.cutoff[first], "\(n) #\(i)")
    }
  }

  /// Rendered: the section the curve marks loudest plays as before, the others come down, the
  /// intro by several dB, and sections that played at one level (0.2 dB apart in techno) now
  /// have a contour.
  @Test(arguments: ["techno", "lofi"])
  func sectionsHaveALevelContour(genre: String) throws {
    let p = played(genre)
    let curve = try #require(EnergyCurve(project: p))
    var flatGain = 1.0
    var arcGain = 1.0
    let flat = sectionDB(render(p, energy: false, genre: genre, loudnessGain: &flatGain), p)
    // `.loudness` now hears the probed section's energy gain (Loudness.gain(sectionGain:)): where
    // the busiest section is not the curve's peak (lofi's verse, 0.69) the whole arc render is
    // lifted back to the reference (+3.2 dB in lofi; techno 0). The contour is what `.energy`
    // does to the sections relative to each other, so that track-wide gain is taken out here.
    let arc = sectionDB(render(p, energy: true, genre: genre, loudnessGain: &arcGain), p).map {
      (name: $0.name, db: $0.db - ampDB(arcGain / flatGain))
    }
    print("energy \(genre): loudness gain \(arcGain) with the arc, \(flatGain) flat")
    // mean depth of the sections under the loudest one
    let depth = { (s: [(name: String, db: Double)]) in
      let top = s.map(\.db).max()!
      return s.map { top - $0.db }.reduce(0, +) / Double(s.count)
    }
    // Only techno still renders flat without `.energy`. Lofi no longer does: with every fix
    // that has joined `Fixes.all` since, its flat render is 3.4 dB deep already (intro −19.4,
    // verses −13.2, bridge −17.5, outro −23.3; still 2.6 dB without the 6.2 rests
    // `.layerBudget` / `.bandStop` / `.kickOut`), and its curve puts the peak on the thinner
    // bridge (gain 1, verses 0.69), so the arc brings the verses down toward it rather than
    // deepening the mean. What `.energy` does is held per section, below, for both.
    if genre == "techno" {
      #expect(depth(flat) < 1.5, "\(genre) was flat: \(flat)")
      #expect(depth(arc) > depth(flat) + 1.5, "\(genre): \(flat) → \(arc)")
    }
    for (i, g) in curve.gain.enumerated() {
      if g >= 0.999 {
        #expect(abs(arc[i].db - flat[i].db) < 0.75, "\(genre) \(arc[i].name) keeps its level")
      } else if g <= 0.8 {
        // (−1.9 dB or more of gain: it comes down by at least a dB, its lowpass aside)
        #expect(arc[i].db < flat[i].db - 1, "\(genre) \(arc[i].name) at \(g): \(flat) → \(arc)")
      }
    }
    let intro = try #require(arc.firstIndex { $0.name == "intro" })
    let loudest = try #require(flat.indices.max { arc[$0].db < arc[$1].db })
    // the intro comes down, and sits several dB under the peak (how far it comes down from
    // the flat render depends on how much quieter the composer already made it: held melody
    // notes, `.legato`, lift lofi's melodic sections and so leave its flat intro lower)
    #expect(arc[intro].db < flat[intro].db - 2)
    #expect(arc[intro].db < arc[loudest].db - 3)
  }

  /// A loop has no arc; a project without the flag renders exactly as before.
  @Test func loopsAndParityAreUntouched() {
    #expect(EnergyCurve(project: played("techno", structure: "standard")) != nil)
    let spec = TrackSpec(genre: "techno", seed: 42, structure: nil)
    #expect(EnergyCurve(project: DJMusicality.apply(spec.project(), spec: spec)) == nil)
    let p = played("techno", structure: "minimal")
    var o = WaveOptions.extended
    o.musicality.remove(.energy)
    // (`.sweep` reads the curve's ramps, so it builds the curve too)
    o.musicality.remove(.sweep)
    #expect(WaveRunner.prepare(p, sampleRate: sr, opts: o).energy == nil)
    #expect(WaveRunner.prepare(p, sampleRate: sr, opts: .extended).energy != nil)
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct EnergyRealTimeTests {
  /// Section changes, buildup sweeps and the tonal lowpass render without allocating.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func energyArcDoesNotAllocate() {
    let p = played("trance", structure: "minimal")
    let r = WaveRunner(sampleRate: 48_000, opts: .extended)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: 48_000, opts: .extended))
    r.setTempo(600)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    var rr = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      rr.withUnsafeMutableBufferPointer { c in
        for _ in 0..<50 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        rr.withUnsafeMutableBufferPointer { c in
          for _ in 0..<4000 { r.process(b.baseAddress!, c.baseAddress!, frames: 128) }
        }
      }
    }
    // played through every section (to the song's end, which resets the clock)
    #expect(r.stopped || r.graph!.tick > 300, "crossed sections: tick \(r.graph!.tick)")
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
