import Testing

@testable import DJCore

// `DJMusicality.Fixes.feel` (ROADMAP 6.5): the runner plays the family's groove template
// (`GrooveTemplate`, `WaveProject.feelTable`) and its tempo-scaled swing, measured from the
// hits it plays (`HitLog`, `GrooveReport`).

private let sr = 48_000.0
/// The chill family's: the steepest swing line and the widest velocity spread.
private let lofi = GrooveTemplate.forGenre("lofi")!

/// One note on every sixteenth of a 16-step bar: a closed hat (drum channel 12) or a tonal C.
private func sixteenths(
  drum: Bool, tempo: Double, velocity: Int = 80, swing: Double = 0, humanize: Double = 0
) -> Project {
  var nb = NetBundle.ring(16)
  let channel = drum ? 12 : 2
  for step in 0..<16 {
    nb.bind(step, note: drum ? 42 : 60, channel: channel, velocity: velocity, duration: 50)
  }
  nb.track.channel = channel
  var p = Project()
  p.tempo = tempo
  p.swing = swing
  p.humanize = humanize
  p.nets[drum ? "hat" : "keys"] = nb
  return p
}

/// `bars` bars of `p` in 256-frame blocks, and the hits it played.
private func render(
  _ p: Project, fixes: DJMusicality.Fixes, feel: GrooveTemplate?, bars: Int = 4
) -> (audio: [Float], hits: [HitRecord]) {
  var o = WaveOptions()
  o.musicality = fixes
  o.feel = feel
  let log = HitLog()
  log.attach(&o)
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(p)
  r.play()
  var out = [Float](repeating: 0, count: Int(Double(bars) * 4 * 60 / p.tempo * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      let n = min(256, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n, startFrame: off)
      off += n
    }
  }
  return (out, log.records)
}

private func lateMs(_ h: HitRecord) -> Double { Double(h.delayFrames) / sr * 1000 }

private func pearson(_ x: [Double], _ y: [Double]) -> Double {
  let n = Double(x.count)
  let mx = x.reduce(0, +) / n
  let my = y.reduce(0, +) / n
  var sxy = 0.0
  var sxx = 0.0
  var syy = 0.0
  for (a, b) in zip(x, y) {
    sxy += (a - mx) * (b - my)
    sxx += (a - mx) * (a - mx)
    syy += (b - my) * (b - my)
  }
  return sxy / (sxx * syy).squareRoot()
}

struct FeelTests {
  /// A tonal lane gets the swing only: the measured ratio is the table's at three tempi
  /// (within 2 %), the off-beat sixteenths (2r − 1) sixteenths late, the rest on the grid.
  /// The tempi are where the chill line swings: fitted from the Groove MIDI Dataset's hip-hop
  /// files (grooves.json: 0.363 + 0.00175 × bpm), it is all but straight at 80 bpm (0.503), so
  /// 80 could not tell the swing from none; 95 is the slowest tempo here it clearly swings.
  @Test(arguments: [95.0, 105.0, 130.0])
  func swingFollowsTheTable(bpm: Double) throws {
    let hits = render(sixteenths(drum: false, tempo: bpm), fixes: [.feel], feel: lofi).hits
    try #require(hits.count >= 60, "\(hits.count) hits")
    let want = lofi.swing.ratio(bpm: bpm)
    #expect(want > 0.52, "the chill line swings at \(bpm): \(want)")
    let report = GrooveReport(hits, sampleRate: sr, bpm: bpm)
    let got = try #require(report.swingRatio)
    #expect(abs(got - want) / want < 0.02, "\(bpm) bpm: \(got) against \(want)")
    let sixteenthMs = 15_000 / bpm
    for h in hits {
      let expected = h.step % 2 == 1 ? (2 * want - 1) * sixteenthMs : 0
      #expect(abs(lateMs(h) - expected) < 0.05, "tick \(h.tick): \(lateMs(h)) ms")
      #expect(h.velocity == 80, "tonal velocities stay as bound")
    }
  }

  /// The jazz family swings eighths: only the off-beat eighth of each beat moves.
  @Test func jazzSwingsEighths() throws {
    let jazz = try #require(GrooveTemplate.forGenre("bossa"))
    #expect(jazz.swing.grid == .eighth)
    let bpm = 200.0
    let hits = render(sixteenths(drum: false, tempo: bpm), fixes: [.feel], feel: jazz).hits
    try #require(hits.count >= 60)
    let want = jazz.swing.delayMs(bpm: bpm)
    #expect(want > 1)
    for h in hits {
      #expect(abs(lateMs(h) - (h.step % 4 == 2 ? want : 0)) < 0.05, "tick \(h.tick)")
    }
  }

  /// A drum plays its template offset plus the swing at each bar step, never early.
  @Test func drumsPlayTheTemplateOffsets() throws {
    let bpm = 105.0
    let hits = render(sixteenths(drum: true, tempo: bpm), fixes: [.feel], feel: lofi).hits
    try #require(hits.count >= 60)
    let swing = lofi.swing.delayMs(bpm: bpm)
    for h in hits {
      #expect(h.delayFrames >= 0, "tick \(h.tick) early")
      let expected = lofi.offsetMs(.hihat, step: h.step) + (h.step % 2 == 1 ? swing : 0)
      #expect(abs(lateMs(h) - expected) < 0.05, "tick \(h.tick): \(lateMs(h)) vs \(expected)")
    }
  }

  /// Velocities follow the template's accents (correlation > 0.9 over the bar's 16 steps).
  @Test func velocitiesFollowTheTemplate() throws {
    let hits = render(sixteenths(drum: true, tempo: 100), fixes: [.feel], feel: lofi).hits
    try #require(hits.count >= 60)
    var played = [Double](repeating: 0, count: 16)
    var count = [Double](repeating: 0, count: 16)
    for h in hits {
      played[h.step] += Double(h.velocity)
      count[h.step] += 1
    }
    try #require(!count.contains(0))
    let mean = zip(played, count).map { $0 / $1 }
    let template = (0..<16).map { lofi.velocity(.hihat, step: $0) }
    #expect(Set(template).count > 4, "the template accents")
    let r = pearson(mean, template)
    #expect(r > 0.9, "correlation \(r): \(mean)")
  }

  /// Without the flag the template is never read: a render with `feel` set but `.feel` off is
  /// bit-identical to one without it (beats' engine, and `.groove` alone, beats' swing).
  @Test func withoutTheFlagIsBitIdentical() {
    for (fixes, swing) in [(DJMusicality.Fixes(), 0.0), ([.groove], 0.0), ([.groove], 40.0)] {
      let p = sixteenths(drum: true, tempo: 110, swing: swing, humanize: swing / 2)
      let a = render(p, fixes: fixes, feel: lofi).audio
      let b = render(p, fixes: fixes, feel: nil).audio
      #expect(sameSamples(a, b) == .identical, "\(fixes) swing \(swing)")
    }
    // with it, the hats move
    let p = sixteenths(drum: true, tempo: 110)
    #expect(
      sameSamples(
        render(p, fixes: [.feel], feel: lofi).audio, render(p, fixes: [], feel: nil).audio)
        != .identical)
    // and the flag on without a template plays as without the flag
    #expect(
      sameSamples(render(p, fixes: [.feel], feel: nil).audio, render(p, fixes: [], feel: nil).audio)
        == .identical)
  }

  /// `forGenre` sets the family's template only when the flag is on; a prepared track keeps
  /// it on its project (`sameSongOptions` hands it to a section jump).
  @Test func forGenreSetsTheTemplate() {
    var o = WaveOptions()
    #expect(o.forGenre("lofi").feel == nil)
    o.musicality = [.feel]
    #expect(o.forGenre("lofi").feel?.family == "chill")
    #expect(o.forGenre("techno").feel?.family == "dance")
    #expect(DJMusicality.Fixes.all.contains(.feel))
    let track = PreparedTrack(
      spec: TrackSpec(genre: "lofi", seed: 42, structure: "minimal"), sampleRate: 22_050)
    #expect(track.prepared.feel?.family == "chill")
    #expect(track.prepared.feelTable != nil)
  }
}
