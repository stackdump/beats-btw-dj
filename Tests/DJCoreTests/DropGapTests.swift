import Testing

@testable import DJCore

// `DJMusicality.Fixes.dropGap` (the rhythm section rests for the beat before a drop) and
// `.choke` (a closed hat cuts the open hat off), measured on renders of small projects through a
// linear master. 120 BPM: a step is 0.125 s.

private let sr = 48_000.0
private let step = Int(0.125 * sr)

private func ring(_ group: String, channel: Int, _ notes: [(step: Int, note: Int)], ms: Int)
  -> NetBundle
{
  var n = NetBundle.ring(16)
  for x in notes { n.bind(x.step, note: x.note, channel: channel, velocity: 100, duration: ms) }
  n.track.channel = channel
  n.track.group = group
  return n
}

/// Four bars of buildup into four of drop: kick on the beats, an offbeat bass, and (optionally)
/// a pad chord held through each bar.
private func buildupAndDrop(rhythm: Bool = true, pad: Bool = false) -> Project {
  var p = Project()
  p.tempo = 120
  if rhythm {
    p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50)
    p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100)
  }
  if pad {
    p.nets["harmony"] = ring("harmony", channel: 7, [(0, 60), (1, 64), (2, 67)], ms: 1950)
  }
  p.structure = [Section(name: "buildup", steps: 64), Section(name: "drop", steps: 64)]
  return p
}

private func render(_ p: Project, _ fixes: DJMusicality.Fixes, seconds: Double = 10) -> [Float] {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
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

struct DropGapTests {
  /// The gap is the last beat of each buildup that lands on a drop (or a pre-chorus on a
  /// chorus), nowhere else.
  @Test func gapsSitBeforeDrops() {
    var p = Project()
    p.structure = [
      Section(name: "intro", steps: 64), Section(name: "buildup", steps: 128),
      Section(name: "drop", steps: 128), Section(name: "breakdown", steps: 64),
      Section(name: "drop", steps: 64), Section(name: "pre-chorus", steps: 64),
      Section(name: "chorus", steps: 64),
    ]
    #expect(DJMusicality.dropGaps(p) == [188, 508])
    let edm = TrackSpec(genre: "edm", seed: 42, structure: "standard").project()
    var start = 0
    var drops: [Int] = []
    for (k, s) in edm.structure.enumerated() {
      if k > 0 && s.name == "drop" && edm.structure[k - 1].name == "buildup" { drops.append(start) }
      start += s.steps
    }
    #expect(!drops.isEmpty)
    #expect(DJMusicality.dropGaps(edm) == drops.map { $0 - DJMusicality.dropGapSteps })
  }

  /// In the gap the kick and bass stop (the tail of the last kick is all that is left); the
  /// drop's downbeat plays as loud as a downbeat before the gap; bars before are untouched.
  @Test func rhythmSectionRestsForTheLastBeat() {
    let plain = render(buildupAndDrop(), [])
    let gapped = render(buildupAndDrop(), .dropGap)
    let gap = 60 * step
    let before = rmsDB(gapped, gap - 4 * step, gap)
    let inGap = rmsDB(gapped, gap + step / 4, gap + 4 * step)
    #expect(inGap < before - 20, "gap \(inGap) dB against the beat before at \(before) dB")
    #expect(rmsDB(plain, gap + step / 4, gap + 4 * step) > before - 3)
    let drop = 64 * step
    let downbeat = rmsDB(gapped, drop, drop + step)
    let earlier = rmsDB(gapped, 56 * step, 57 * step)
    #expect(abs(downbeat - earlier) < 1, "drop downbeat \(downbeat) dB, bar 4's \(earlier) dB")
    #expect(sameSamples(Array(plain[0..<gap]), Array(gapped[0..<gap])) == .identical)
  }

  /// Pads (and everything that is not kick, snare, hats or bass) play through the gap.
  @Test func padsPlayThrough() {
    let p = buildupAndDrop(rhythm: false, pad: true)
    #expect(sameSamples(render(p, []), render(p, .dropGap)) == .identical)
  }

  /// An open hat followed by a closed hat in the same net: choked, the open hat's tail is gone
  /// 20 ms after the closed hat; before it, nothing changes. The closed hat is played softly so
  /// what is measured after it is the open hat.
  @Test func closedHatChokesTheOpenHat() {
    var hats = NetBundle.ring(16)
    hats.bind(2, note: 46, channel: 10, velocity: 110, duration: 50)
    hats.bind(3, note: 42, channel: 10, velocity: 1, duration: 50)
    hats.track.channel = 10
    hats.track.group = "drums"
    var p = Project()
    p.tempo = 120
    p.nets["hihat"] = hats
    let ringing = render(p, .openHats, seconds: 1)
    let choked = render(p, [.openHats, .choke], seconds: 1)
    let closed = 3 * step + 1
    #expect(sameSamples(Array(ringing[0..<closed]), Array(choked[0..<closed])) == .identical)
    let a = closed + Int(0.02 * sr)
    let b = closed + Int(0.1 * sr)
    let tail = rmsDB(ringing, a, b)
    let cut = rmsDB(choked, a, b)
    #expect(cut < tail - 20, "open hat tail \(tail) dB, choked \(cut) dB")
    // a net without an open hat is untouched
    var closedOnly = NetBundle.ring(16)
    for s in [0, 2, 4] { closedOnly.bind(s, note: 42, channel: 10, velocity: 100, duration: 50) }
    closedOnly.track.channel = 10
    var q = Project()
    q.tempo = 120
    q.nets["hihat"] = closedOnly
    #expect(
      sameSamples(render(q, .openHats, seconds: 1), render(q, [.openHats, .choke], seconds: 1))
        == .identical)
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct DropGapRealTimeTests {
  /// Rendering through a drop gap and choked hats allocates nothing.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func gapsAndChokesDoNotAllocate() {
    var p = buildupAndDrop(pad: true)
    var hats = NetBundle.ring(16)
    for s in [0, 4, 8, 12] { hats.bind(s, note: 42, channel: 10, velocity: 90, duration: 50) }
    for s in [2, 6, 10, 14] { hats.bind(s, note: 46, channel: 10, velocity: 100, duration: 50) }
    hats.track.channel = 10
    hats.track.group = "drums"
    p.nets["hihat"] = hats
    var o = WaveOptions()
    o.musicality = [.dropGap, .choke, .openHats]
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
    r.play()
    var l = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      for _ in 0..<200 { r.process(b.baseAddress!, nil, frames: 128) }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        for _ in 0..<4000 { r.process(b.baseAddress!, nil, frames: 128) }
      }
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
