import Testing

@testable import DJCore

// `DJMusicality.Fixes.bandStop`: in the song family, everything but the lead rests for the
// beat before a chorus. Renders of small projects through a linear master, 120 BPM: a step is
// 0.125 s.

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

/// A lead playing `melody` steps of every bar (the last beat by default).
private func lead(_ steps: [Int] = [12, 13, 14, 15]) -> NetBundle {
  ring("melody", channel: 1, steps.map { ($0, 72) }, ms: 100)
}

/// Four bars of verse into four of chorus: kick on the beats, an offbeat bass, a pad stab on
/// each beat, a fill chain's snare on the last beat of the bar, and (optionally) the lead.
private func verseAndChorus(band: Bool = true, melody: NetBundle? = lead()) -> Project {
  var p = Project()
  p.tempo = 120
  if band {
    p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50)
    p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100)
    p.nets["harmony"] = ring("harmony", channel: 7, [0, 4, 8, 12].map { ($0, 48) }, ms: 150)
    p.nets["fill-1"] = ring("drums", channel: 10, [13, 15].map { ($0, 38) }, ms: 50)
  }
  if let melody { p.nets["melody"] = melody }
  p.structure = [Section(name: "verse", steps: 64), Section(name: "chorus", steps: 64)]
  return p
}

private func options(_ fixes: DJMusicality.Fixes, genre: String?) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.genre = genre
  return o
}

private func render(_ p: Project, _ o: WaveOptions, seconds: Double = 10) -> [Float] {
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

struct BandStopTests {
  /// A stop is the last beat before each chorus, except the song's first section and a chorus
  /// after a buildup / pre-chorus (the drop gap's).
  @Test func stopsSitBeforeChoruses() {
    var p = Project()
    p.nets["melody"] = lead()
    p.structure = [
      Section(name: "chorus", steps: 64), Section(name: "verse", steps: 64),
      Section(name: "chorus", steps: 64), Section(name: "pre-chorus", steps: 64),
      Section(name: "chorus", steps: 64), Section(name: "bridge", steps: 32),
      Section(name: "chorus", steps: 64),
    ]
    #expect(DJMusicality.bandStops(p) == [124, 348])
    #expect(DJMusicality.dropGaps(p) == [252])
  }

  /// No lead note in the beat, no stop: the band plays through rather than leave dead air.
  @Test func silentLeadSkipsTheStop() {
    #expect(DJMusicality.bandStops(verseAndChorus(melody: lead([0, 4]))).isEmpty)
    #expect(DJMusicality.bandStops(verseAndChorus(melody: nil)).isEmpty)
    var muted = verseAndChorus()
    muted.initialMutes = ["melody"]
    #expect(DJMusicality.bandStops(muted).isEmpty, "a muted lead plays nothing")
    #expect(DJMusicality.bandStops(verseAndChorus()) == [60])
    let p = verseAndChorus(melody: lead([0, 4]))
    #expect(render(p, options([], genre: "funk")) == render(p, options(.bandStop, genre: "funk")))
  }

  /// Only the song family stops; an unknown genre (raw nets, parity) does not.
  @Test func songFamilyOnly() {
    let p = verseAndChorus()
    for g in ["country", "blues", "funk", "reggae", "synthwave", "metal"] {
      #expect(DJMusicality.bandStopGenre(g), "\(g)")
      #expect(
        RestSchedule.build(p, fixes: .bandStop, genre: g).entries
          == [.init(from: 60, to: 64, mask: DJMusicality.bandStopMask)])
    }
    for g in ["edm", "techno", "house", "trance", "dnb", "jazz", "bossa", "lofi", "ambient"] {
      #expect(!DJMusicality.bandStopGenre(g), "\(g)")
      #expect(RestSchedule.build(p, fixes: .bandStop, genre: g).isEmpty)
    }
    #expect(RestSchedule.build(p, fixes: .bandStop).isEmpty)
    #expect(!DJMusicality.bandStopMask.contains(.melody))
    #expect(WaveOptions().forGenre("funk").genre == "funk")
  }

  /// The dance genres are byte-identical with `.bandStop` on: composed tracks' schedules, and a
  /// render of a project that would stop in the song family.
  @Test func edmUnchanged() {
    for structure in ["standard", "extended", "ab"] {
      let edm = TrackSpec(genre: "edm", seed: 42, structure: structure).project()
      #expect(
        RestSchedule.build(edm, fixes: .all, genre: "edm")
          == RestSchedule.build(edm, fixes: .all.subtracting(.bandStop), genre: "edm"))
    }
    let p = verseAndChorus()
    #expect(render(p, options([], genre: "edm")) == render(p, options(.bandStop, genre: "edm")))
  }

  /// In the stop the band (kick, bass, pad, the fill's snare) is ≥ 15 dB under the beat before,
  /// the lead plays on as it would alone, and the chorus's downbeat comes back; the bars before
  /// are untouched.
  @Test func bandRestsLeadPlays() {
    let p = verseAndChorus()
    let o = options(.bandStop, genre: "funk")
    let plain = render(p, options([], genre: "funk"))
    let stopped = render(p, o)
    let alone = render(verseAndChorus(band: false), o)
    let stop = 60 * step
    let window = (stop + step / 4)..<(stop + 4 * step)
    let before = rmsDB(stopped, stop - 4 * step, stop)
    let band = zip(stopped[window], alone[window]).map { $0 - $1 }
    let rest = rmsDB(band[...])
    #expect(
      rest < before - 15, "band in the stop \(rest) dB against the beat before at \(before) dB")
    let leadDB = rmsDB(alone, window.lowerBound, window.upperBound)
    #expect(leadDB > -60, "the lead plays in the stop (\(leadDB) dB)")
    #expect(abs(rmsDB(stopped, window.lowerBound, window.upperBound) - leadDB) < 1)
    #expect(rmsDB(plain, window.lowerBound, window.upperBound) > before - 3)
    let chorus = 64 * step
    let downbeat = rmsDB(stopped, chorus, chorus + step)
    let earlier = rmsDB(stopped, 56 * step, 57 * step)
    #expect(abs(downbeat - earlier) < 1, "chorus downbeat \(downbeat) dB, bar 4's \(earlier) dB")
    #expect(Array(plain[0..<stop]) == Array(stopped[0..<stop]))
  }
}
