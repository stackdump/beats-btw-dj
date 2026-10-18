import Testing

@testable import DJCore

// `DJMusicality.Fixes.kickOut`: the kick sits out the last bar of a dance buildup, the snare
// roll and the rest playing on. Renders of small projects through a linear master, 120 BPM:
// a step is 0.125 s.

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

/// Four bars of buildup into four of drop: kick on the beats, a snare roll on the eighths, an
/// offbeat bass, any of them left out.
private func buildupProject(
  kick: Bool = true, snare: Bool = true, bass: Bool = true,
  structure: [Section] = [Section(name: "buildup", steps: 64), Section(name: "drop", steps: 64)]
) -> Project {
  var p = Project()
  p.tempo = 120
  if kick { p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50) }
  if snare {
    p.nets["snare"] = ring(
      "drums", channel: 10, stride(from: 0, to: 16, by: 2).map { ($0, 38) }, ms: 40)
  }
  if bass { p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100) }
  p.structure = structure
  return p
}

private func render(_ p: Project, _ fixes: DJMusicality.Fixes, duck: Double = 0) -> [Float] {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.duckDepth = duck
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var out = [Float](repeating: 0, count: Int(10 * sr))
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

struct KickOutTests {
  typealias Entry = RestSchedule.Entry

  /// Each buildup of two bars or more into a drop: the kick, for its last bar. Not a buildup
  /// into a chorus, not a one-bar buildup, not a buildup that ends the song.
  @Test func restsTheLastBarOfEachBuildupIntoADrop() {
    func rests(_ s: [(String, Int)]) -> [Entry] {
      var p = Project()
      p.structure = s.map { Section(name: $0.0, steps: $0.1) }
      return DJMusicality.kickOutRests(p)
    }
    #expect(
      rests([("intro", 64), ("buildup", 64), ("drop", 128), ("buildup", 32), ("drop", 64)])
        == [Entry(from: 112, to: 128, mask: .kick), Entry(from: 272, to: 288, mask: .kick)])
    #expect(rests([("buildup", 64), ("chorus", 64)]).isEmpty)
    #expect(rests([("buildup", 16), ("drop", 64)]).isEmpty)
    #expect(rests([("intro", 64), ("buildup", 64)]).isEmpty)
    #expect(rests([("pre-chorus", 64), ("drop", 64)]).isEmpty)

    let edm = TrackSpec(genre: "edm", seed: 42, structure: "extended").project()
    let built = DJMusicality.kickOutRests(edm)
    #expect(!built.isEmpty)
    #expect(built.allSatisfy { $0.to - $0.from == DJMusicality.kickOutSteps && $0.mask == .kick })
    #expect(RestSchedule.build(edm, fixes: .kickOut) == RestSchedule(merging: built))
  }

  /// Genres outside the dance family get no kick out, whatever their structure.
  @Test func nonDanceGenresAreUnchanged() {
    let genres = BeatsTables.shared.genres.keys.sorted().filter {
      BeatsTables.shared.family(of: $0) != 0
    }
    #expect(!genres.isEmpty)
    for g in genres {
      for structure in ["minimal", "standard", "extended", "build", "drop", "ab", "jam"] {
        let p = TrackSpec(genre: g, seed: 42, structure: structure).project()
        #expect(DJMusicality.kickOutRests(p).isEmpty, "\(g) \(structure)")
        #expect(
          RestSchedule.build(p, fixes: .all)
            == RestSchedule.build(p, fixes: .all.subtracting(.kickOut)),
          "\(g) \(structure)")
      }
    }
  }

  /// Solo, the kick is silent for the last bar of the buildup and back on the drop; the bars
  /// before render exactly as without the fix.
  @Test func kickIsOutForTheLastBuildupBar() {
    let kickOnly = buildupProject(snare: false, bass: false)
    let out = render(kickOnly, .kickOut)
    let plain = render(kickOnly, [])
    #expect(sameSamples(Array(out[0..<(48 * step)]), Array(plain[0..<(48 * step)])) == .identical)
    let last = rmsDB(out, 48 * step + step / 2, 64 * step)
    #expect(last < -60, "kick in the last buildup bar: \(last) dB")
    #expect(rmsDB(plain, 48 * step + step / 2, 64 * step) > -40)
    let drop = rmsDB(out, 64 * step, 68 * step)
    #expect(abs(drop - rmsDB(plain, 64 * step, 68 * step)) < 0.5, "drop: \(drop) dB")
  }

  /// The snare roll plays through: alone it renders byte for byte, and in the mix the last bar
  /// is the snare and bass without the kick.
  @Test func snareRollPlaysOn() {
    let snare = buildupProject(kick: false, bass: false)
    let same = render(snare, .kickOut) == render(snare, [])
    #expect(same)
    let mix = render(buildupProject(), .kickOut)
    let noKick = render(buildupProject(kick: false), [])
    let a = 48 * step + step / 2
    let b = 64 * step
    #expect(abs(rmsDB(mix, a, b) - rmsDB(noKick, a, b)) < 0.5)
    #expect(rmsDB(noKick, a, b) > -40)
  }

  /// `.duck` follows the hits that play: with the kick out the bass stops dipping, so in the
  /// last buildup bar the ducked mix is the unducked one.
  @Test func duckFollowsTheKickOut() {
    let p = buildupProject(snare: false)
    let ducked = render(p, .kickOut, duck: 0.5)
    let flat = render(p, .kickOut, duck: 0)
    // a bar earlier the kick still pumps the bass
    let pumped = Array(ducked[(32 * step)..<(48 * step)]) != Array(flat[(32 * step)..<(48 * step)])
    #expect(pumped)
    // past the last kick's release (step 44: e^-9 of the dip left by step 50)
    let a = 50 * step
    let b = 64 * step
    #expect(abs(rmsDB(ducked, a, b) - rmsDB(flat, a, b)) < 0.05)
    #expect(rmsDB(flat, a, b) > -40)
  }
}
