import Darwin
import Testing

@testable import DJCore

// `DJMusicality.Fixes.drift` (ROADMAP 6.5): humanize as seeded 1/f noise (`Drift`, Voss–McCartney)
// keyed by (seed, net, tick), on top of `.feel` or `.groove`'s swing, measured from the hits the
// runner plays (`HitLog`, `GrooveReport`).

private let sr = 48_000.0

/// One note on every sixteenth of a 16-step bar: a closed hat (drum channel 12).
private func hats(tempo: Double, humanize: Double, swing: Double = 0, velocity: Int = 80)
  -> Project
{
  var nb = NetBundle.ring(16)
  for step in 0..<16 {
    nb.bind(step, note: 42, channel: 12, velocity: velocity, duration: 50)
  }
  nb.track.channel = 12
  var p = Project()
  p.tempo = tempo
  p.swing = swing
  p.humanize = humanize
  p.nets["hat"] = nb
  return p
}

/// `bars` bars of `p` in 256-frame blocks, and the hits it played.
private func render(
  _ p: Project, fixes: DJMusicality.Fixes, feel: GrooveTemplate? = nil, seed: Double = 42,
  bars: Int = 16
) -> (audio: [Float], hits: [HitRecord]) {
  var o = WaveOptions()
  o.musicality = fixes
  o.feel = feel
  o.voicingSeed = seed
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

/// Welch's estimate of the noise's power spectrum: the mean periodogram of `segments`
/// Hann-windowed segments of `n` ticks; bin k is k / n cycles a tick.
private func spectrum(_ key: UInt64, n: Int, segments: Int) -> [Double] {
  var power = [Double](repeating: 0, count: n / 2)
  let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
  for s in 0..<segments {
    var x = (0..<n).map { Drift.pink(key, net: 3, stream: 0, tick: s * n + $0) }
    let m = x.reduce(0, +) / Double(n)
    for i in 0..<n { x[i] = (x[i] - m) * window[i] }
    for k in 1..<n / 2 {
      var re = 0.0
      var im = 0.0
      for i in 0..<n {
        let a = 2 * Double.pi * Double(k * i) / Double(n)
        re += x[i] * cos(a)
        im -= x[i] * sin(a)
      }
      power[k] += (re * re + im * im) / Double(segments)
    }
  }
  return power
}

struct DriftTests {
  /// The noise is bounded, a pure function of (key, net, stream, tick) — read in any order it
  /// gives the same values — and the key, the net and the stream each change it.
  @Test func noiseIsBoundedDeterministicAndSeekable() {
    let key = Drift.key(seed: 42)
    #expect(key == Drift.key(seed: 42))
    let forward = (0..<2048).map { Drift.pink(key, net: 1, stream: 0, tick: $0) }
    #expect(forward.allSatisfy { $0 >= -1 && $0 <= 1 })
    #expect(Set(forward).count > 1000, "it moves")
    for t in stride(from: 2047, through: 0, by: -37) {
      #expect(Drift.pink(key, net: 1, stream: 0, tick: t) == forward[t], "tick \(t)")
    }
    let other = (0..<2048).map { Drift.pink(Drift.key(seed: 43), net: 1, stream: 0, tick: $0) }
    let net2 = (0..<2048).map { Drift.pink(key, net: 2, stream: 0, tick: $0) }
    let timing = (0..<2048).map { Drift.pink(key, net: 1, stream: 1, tick: $0) }
    #expect(other != forward)
    #expect(net2 != forward)
    #expect(timing != forward)
    let sd = (forward.map { $0 * $0 }.reduce(0, +) / Double(forward.count)).squareRoot()
    #expect(sd > 0.2 && sd < 0.5, "SD \(sd)")
  }

  /// 1/f: the power falls about 10 dB a decade over the octaves the sum covers (a least-squares
  /// line through log power against log frequency, 1/256 … 1/4 cycles a tick).
  @Test func noiseIsPink() {
    let n = 512
    let power = spectrum(Drift.key(seed: 7), n: n, segments: 24)
    var xs: [Double] = []
    var ys: [Double] = []
    for k in 2...(n / 4) {
      xs.append(log10(Double(k) / Double(n)))
      ys.append(10 * log10(power[k]))
    }
    let mx = xs.reduce(0, +) / Double(xs.count)
    let my = ys.reduce(0, +) / Double(ys.count)
    var sxy = 0.0
    var sxx = 0.0
    for (x, y) in zip(xs, ys) {
      sxy += (x - mx) * (y - my)
      sxx += (x - mx) * (x - mx)
    }
    let slope = sxy / sxx
    #expect(slope < -7 && slope > -13, "slope \(slope) dB/decade")
  }

  /// On top of `.feel`: each hat is its template offset plus swing plus 0…3 ms × h late (never
  /// early), velocities vary at each bar position, and the timing stays mostly the pattern.
  @Test(arguments: ["house", "lofi", "funk"])
  func driftOnTopOfFeel(genre: String) throws {
    let g = try #require(BeatsTables.shared.genres[genre])
    let template = try #require(GrooveTemplate.forGenre(genre))
    let p = hats(tempo: g.bpm, humanize: g.humanize)
    let h = g.humanize / 100
    let hits = render(p, fixes: [.feel, .drift], feel: template).hits
    try #require(hits.count >= 200, "\(hits.count) hits")
    let base = render(p, fixes: [.feel], feel: template).hits
    try #require(base.count == hits.count)
    for (a, b) in zip(hits, base) {
      #expect(a.delayFrames >= 0, "tick \(a.tick) early")
      let extra = lateMs(a) - lateMs(b)
      #expect(extra > -0.05 && extra < Drift.lateSpanMs * h + 0.05, "tick \(a.tick): +\(extra) ms")
      #expect(abs(a.velocity - b.velocity) <= Int((Drift.velocitySpan * h).rounded()) + 1)
    }
    let report = GrooveReport(hits, sampleRate: sr, bpm: g.bpm)
    #expect(report.distinctVelocitiesPerPosition >= 2, "\(genre): \(report)")
    #expect(report.consistency > 0.9 && report.consistency < 1, "\(genre): \(report.consistency)")
    // without drift the template plays one velocity a position
    let flat = GrooveReport(base, sampleRate: sr, bpm: g.bpm)
    #expect(flat.distinctVelocitiesPerPosition == 1)
  }

  /// With `.groove` alone it replaces the white jitter: the swing as beats has it, then the
  /// drift's few late ms — the off-beats no longer jitter ±30 ms × h.
  @Test func replacesTheWhiteJitter() throws {
    let p = hats(tempo: 100, humanize: 40, swing: 30)
    let hits = render(p, fixes: [.groove, .drift]).hits
    try #require(hits.count >= 200)
    let tickMs = 15_000 / 100.0
    for hit in hits {
      let swing = hit.step % 2 == 1 ? 0.3 * tickMs * 0.5 : 0
      let extra = lateMs(hit) - swing
      #expect(extra > -0.05 && extra < Drift.lateSpanMs * 0.4 + 0.05, "tick \(hit.tick): \(extra)")
    }
    let report = GrooveReport(hits, sampleRate: sr, bpm: 100)
    #expect(report.distinctVelocitiesPerPosition > 1)
    // `.drift` on its own humanizes too (no swing without `.groove`)
    let alone = render(p, fixes: [.drift]).hits
    #expect(alone.allSatisfy { lateMs($0) < Drift.lateSpanMs * 0.4 + 0.05 })
    #expect(Set(alone.map(\.velocity)).count > 1)
  }

  /// The same seed plays the same hits twice; another seed other ones.
  @Test func deterministicBySeed() {
    let p = hats(tempo: 120, humanize: 30)
    let lofi = GrooveTemplate.forGenre("lofi")!
    let a = render(p, fixes: [.feel, .drift], feel: lofi, seed: 42)
    let b = render(p, fixes: [.feel, .drift], feel: lofi, seed: 42)
    let c = render(p, fixes: [.feel, .drift], feel: lofi, seed: 43)
    #expect(a.hits == b.hits)
    #expect(a.audio == b.audio)
    #expect(a.hits.map(\.velocity) != c.hits.map(\.velocity))
  }

  /// Seekable: a project prepared from tick 64 (a section launch) plays the hits the whole song
  /// plays there — the noise is a function of the song's tick, not of how long it has played.
  @Test func seekPlaysTheSameDrift() throws {
    let p = hats(tempo: 120, humanize: 40)
    var o = WaveOptions()
    o.musicality = [.drift]
    o.voicingSeed = 42
    let whole = render(p, fixes: [.drift]).hits
    let log = HitLog()
    log.attach(&o)
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: 64))
    r.play()
    var buf = [Float](repeating: 0, count: 256)
    // `startFrame` counts on, as in `render`: a hit the drift holds past a block's end is
    // logged in the next block, and its frame is only comparable with the grid's when the
    // blocks are numbered (with every block at 0 it reads a block — 256 frames — early).
    buf.withUnsafeMutableBufferPointer { b in
      for i in 0..<2400 { r.process(b.baseAddress!, nil, frames: 256, startFrame: i * 256) }
    }
    let seeked = log.records
    try #require(seeked.count >= 64)
    let byTick = Dictionary(whole.map { ($0.tick, $0) }, uniquingKeysWith: { a, _ in a })
    var compared = 0
    for hit in seeked {
      guard let w = byTick[hit.tick] else { continue }
      #expect(hit.velocity == w.velocity, "tick \(hit.tick)")
      #expect(abs(hit.delayFrames - w.delayFrames) <= 1, "tick \(hit.tick)")
      compared += 1
    }
    #expect(compared >= 64, "\(compared) ticks in common")
  }

  /// Off, nothing reads the seed: `.feel` and `.groove` renders are bit-identical across seeds
  /// (beats' white jitter stays as it was), and the flag is in `Fixes.all` and `named`.
  @Test func offIsUntouched() {
    let p = hats(tempo: 110, humanize: 30, swing: 20)
    let lofi = GrooveTemplate.forGenre("lofi")!
    let cases: [(DJMusicality.Fixes, GrooveTemplate?)] = [
      ([.groove], nil), ([.feel], lofi), ([], nil),
    ]
    for (fixes, feel) in cases {
      #expect(
        render(p, fixes: fixes, feel: feel, seed: 1, bars: 4).audio
          == render(p, fixes: fixes, feel: feel, seed: 2, bars: 4).audio, "\(fixes)")
    }
    #expect(DJMusicality.Fixes.all.contains(.drift))
    #expect(DJMusicality.Fixes.named["drift"] == .drift)
    // with no humanize there is nothing to drift
    let still = hats(tempo: 110, humanize: 0)
    #expect(
      render(still, fixes: [.drift], bars: 4).audio == render(still, fixes: [], bars: 4).audio)
  }
}
