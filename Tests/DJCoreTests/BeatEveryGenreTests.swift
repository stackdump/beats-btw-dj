import Testing

@testable import DJCore

// ROADMAP 6.5's exit, across the catalogue: every genre whose style has a beat plays one
// (`MusicalityReport.hasBeat` = 1, `.backbeat` filling lofi / jazz / bossa), and M6 — the
// groove as the runner plays it (`HitLog`, `GrooveReport`) — reads as a drummer under every fix:
// more than one hat velocity a bar position (`.drift`), timing mostly the pattern but not a
// grid (`.feel` + `.drift`: consistency 0.9…0.99), and the family's swing at the track's tempo.
//
// Runtime cap: one seed, and each render is at most `maxBars` bars (≤ `maxSeconds` of audio) of
// synth voices at 22.05 kHz, started at the first section the style expects a beat in.

private let sr = 22_050.0
private let maxBars = 8
private let maxSeconds = 16.0

/// The catalogue's genres whose style has a beat (all but ambient).
private let drumGenres = BeatsTables.shared.genreIDs.sorted().filter {
  DJMusicality.beatStyle(genre: $0) != nil
}

private func spec(_ genre: String, seed: Double = 42) -> TrackSpec {
  TrackSpec(genre: genre, seed: seed, structure: "standard")
}

/// The first tick of the first section the genre's style expects a beat in, and that
/// section's length in steps.
private func firstBeatSection(_ p: Project, genre: String) -> (tick: Int, steps: Int)? {
  guard let style = DJMusicality.beatStyle(genre: genre) else { return nil }
  var at = 0
  for s in p.structure {
    if style.contains(s.name) { return (at, s.steps) }
    at += s.steps
  }
  return nil
}

/// `genre` with every fix, synth voices, from its first beat section for at most `maxBars`
/// bars (and `maxSeconds`): the track's tempo and the hits its runner played.
private func hits(_ genre: String) throws -> (bpm: Double, hits: [HitRecord]) {
  let s = spec(genre)
  let composed = DJMusicality.apply(s.project(), spec: s)
  let from = try #require(firstBeatSection(composed, genre: genre), "\(genre) has a beat section")
  let track = PreparedTrack(spec: s, sampleRate: sr, opts: .extended, startTick: from.tick)
  let bpm = track.played.tempo > 0 ? track.played.tempo : 120
  let log = HitLog()
  var o = track.opts
  log.attach(&o)
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: track.prepared)
  r.play()
  let barSeconds = 4 * 60 / bpm
  let bars = max(1, min(maxBars, from.steps / 16, Int(maxSeconds / barSeconds)))
  var out = [Float](repeating: 0, count: Int(Double(bars) * barSeconds * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count && !r.stopped {
      let n = min(512, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n, startFrame: off)
      off += n
    }
  }
  return (bpm, log.records)
}

/// Linn's ratio measured on the tonal lanes (they get the swing alone, no template offset),
/// on the template's swing grid: the off-beat member's mean lateness against the on-beat's,
/// as a share of the pair. nil without hits on both.
private func tonalSwing(_ hits: [HitRecord], grid: GrooveTemplate.Swing, bpm: Double) -> Double? {
  let pair = grid.pairSteps
  var on: [Double] = []
  var off: [Double] = []
  for h in hits where !h.isDrum {
    let ms = Double(h.delayFrames) / sr * 1000
    switch h.step % pair {
    case 0: on.append(ms)
    case pair / 2: off.append(ms)
    default: break
    }
  }
  guard !on.isEmpty, !off.isEmpty else { return nil }
  let mean = { (x: [Double]) in x.reduce(0, +) / Double(x.count) }
  return 0.5 + (mean(off) - mean(on)) / (Double(pair) * 15_000 / bpm)
}

struct BeatEveryGenreTests {
  /// Every fix on, each genre with a beat style plays a kick and a snare through every
  /// section the style expects one in: `hasBeat` = 1 (before 6.5 lofi, jazz and bossa read 0;
  /// `BeatTests.surveyEveryGenreBeforeThePass`). Ambient still has none to expect.
  @Test func everyGenreHasItsBeat() {
    #expect(drumGenres.count == 18, "\(drumGenres)")
    for g in BeatsTables.shared.genreIDs.sorted() {
      let s = spec(g)
      let p = DJMusicality.apply(s.project(), spec: s)
      let (notes, controls) = NoteLog.captureAll(p)
      let r = MusicalityReport(project: p, log: notes, controls: controls, genre: g)
      if g == "ambient" {
        #expect(r.hasBeat == nil, "ambient")
      } else {
        #expect(r.hasBeat == 1, "\(g): \(r.beatBySection)")
      }
    }
  }

  /// M6 on every drum genre, measured on what the runner played with every fix: the hats
  /// play more than one velocity a bar position, the drums' timing is the template's pattern
  /// with the drift on it (consistency 0.9…0.99), and the tonal lanes swing at the family's
  /// ratio for the track's tempo, within 2 %.
  @Test(arguments: drumGenres)
  func grooveReadsAsPlayed(genre: String) throws {
    let (bpm, played) = try hits(genre)
    try #require(played.count >= 64, "\(genre): \(played.count) hits")
    #expect(played.allSatisfy { $0.delayFrames >= 0 }, "\(genre): a hit played early")
    let report = GrooveReport(played, sampleRate: sr, bpm: bpm)
    let hat = try #require(report.voices["hat"], "\(genre) plays hats: \(report.voices.keys)")
    #expect(hat.distinctVelocitiesPerPosition > 1, "\(genre): hats \(hat)")
    #expect(
      report.consistency >= 0.9 && report.consistency <= 0.99,
      "\(genre): consistency \(report.consistency)")

    let template = try #require(GrooveTemplate.forGenre(genre))
    let want = template.swing.ratio(bpm: bpm)
    let got = try #require(
      tonalSwing(played, grid: template.swing, bpm: bpm), "\(genre): tonal hits on both members")
    #expect(abs(got - want) / want < 0.02, "\(genre) @\(bpm): swing \(got) against \(want)")
  }
}
