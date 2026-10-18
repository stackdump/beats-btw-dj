import Testing

@testable import DJCore

// `WaveOptions.onHit` and `GrooveReport` (ROADMAP 6.5, exit M6): the hits the runner plays,
// sample-exact, and what the groove did to them, measured.

private let sr = 48_000.0

/// A closed hat on every sixteenth of a 16-step bar, velocity 100.
private func sixteenths(swing: Double, humanize: Double, tempo: Double = 120) -> Project {
  var nb = NetBundle.ring(16)
  for step in 0..<16 { nb.bind(step, note: 42, channel: 12, velocity: 100, duration: 50) }
  nb.track.channel = 12
  var p = Project()
  p.tempo = tempo
  p.swing = swing
  p.humanize = humanize
  p.nets["hat"] = nb
  return p
}

/// Render `bars` 4/4 bars of `p` in 256-frame blocks; the hits through `onHit` when `log`.
private func render(
  _ p: Project, opts: WaveOptions = WaveOptions(), groove: Bool = true, bars: Int = 4,
  log: HitLog? = nil
) -> [Float] {
  var o = opts
  if groove { o.musicality.insert(.groove) }
  log?.attach(&o)
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(p)
  r.play()
  let tempo = p.tempo > 0 ? p.tempo : 120
  var out = [Float](repeating: 0, count: Int(Double(bars) * 4 * 60 / tempo * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      let n = min(256, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n, startFrame: off)
      off += n
    }
  }
  return out
}

private func record(step: Int, bar: Int, delayMs: Double, velocity: Int, kind: String = "hat")
  -> HitRecord
{
  let tick = bar * 16 + step + 1
  let grid = Int64(Double(tick - 1) * 0.125 * sr)
  return HitRecord(
    frame: grid + Int64(delayMs / 1000 * sr), gridFrame: grid, tick: tick, net: "hat", note: 42,
    channel: 12, kind: kind, velocity: velocity)
}

struct GrooveReportTests {
  /// The record says what played where: the hat's net, note, channel and kind, every tick in
  /// order, the off-beat sixteenths late by swing% × half a sixteenth, the beats on the grid.
  @Test func recordsAreSampleExact() throws {
    let log = HitLog()
    _ = render(sixteenths(swing: 50, humanize: 0), log: log)
    let hits = log.records
    try #require(hits.count >= 60, "\(hits.count) hits")
    let tickFrames = 0.125 * sr
    for h in hits {
      #expect(h.net == "hat" && h.note == 42 && h.channel == 12 && h.kind == "hat")
      #expect(h.velocity == 100)
      #expect(h.isDrum)
      let lateMs = Double(h.delayFrames) / sr * 1000
      #expect(abs(lateMs - (h.step % 2 == 1 ? 31.25 : 0)) < 0.05, "tick \(h.tick): \(lateMs) ms")
    }
    #expect(hits.map(\.tick) == hits.map(\.tick).sorted())
    // the grid steps a sixteenth per tick
    let first = try #require(hits.first)
    for h in hits {
      let want = Double(first.gridFrame) + Double(h.tick - first.tick) * tickFrames
      #expect(abs(Double(h.gridFrame) - want) <= 1, "tick \(h.tick) at \(h.gridFrame)")
    }
  }

  /// Measured swing matches the theory (beats' `swingDelay`: the off-beat late by
  /// swing% × half a tick, so the ratio is ½ + swing / 400) within 0.5 %, at two tempi.
  @Test(arguments: [10.0, 30.0, 50.0, 66.0, 90.0])
  func measuredSwingMatchesTheory(swing: Double) throws {
    for tempo in [92.0, 128.0] {
      let log = HitLog()
      _ = render(sixteenths(swing: swing, humanize: 0, tempo: tempo), log: log)
      let report = GrooveReport(log.records, sampleRate: sr, bpm: tempo)
      let theory = 0.5 + swing / 400
      let measured = try #require(report.swingRatio)
      #expect(abs(measured - theory) / theory < 0.005, "swing \(swing) @\(tempo): \(measured)")
      // the pattern repeats bar for bar, and only the off-beats move
      #expect(report.consistency > 0.999)
      #expect(report.distinctVelocitiesPerPosition == 1)
    }
  }

  /// Without the groove every hit sits on its tick: straight, nothing late.
  @Test func straightIsOnTheGrid() throws {
    let log = HitLog()
    _ = render(sixteenths(swing: 50, humanize: 40), groove: false, log: log)
    let report = GrooveReport(log.records, sampleRate: sr, bpm: 120)
    #expect(report.hits > 0)
    #expect(log.records.allSatisfy { $0.delayFrames == 0 })
    #expect(try #require(report.swingRatio) == 0.5)
    #expect(report.microtimingMs == 0)
    #expect(report.consistency == 1)
  }

  /// Humanize moves the velocities and the timing from bar to bar: more than one velocity per
  /// position, timing that isn't a fixed pattern.
  @Test func humanizeShowsInTheReport() {
    let log = HitLog()
    _ = render(sixteenths(swing: 0, humanize: 60), bars: 8, log: log)
    let report = GrooveReport(log.records, sampleRate: sr, bpm: 120)
    #expect(report.distinctVelocitiesPerPosition > 2, "\(report)")
    #expect(report.consistency < 0.9, "\(report)")
    #expect(report.microtimingMs > 1 && report.microtimingSDMs > 1, "\(report)")
    #expect(report.voices["hat"]?.hits == report.hits)
  }

  /// The hook observes: a render with it is bit-identical to one without, on a full extended
  /// track with swing and humanize.
  @Test func theHookDoesNotChangeTheRender() {
    var spec = TrackSpec(genre: "jazz", seed: 42, structure: "minimal").project()
    spec.swing = 60
    spec.humanize = 40
    let log = HitLog()
    let hooked = render(spec, opts: .extended, bars: 8, log: log)
    let plain = render(spec, opts: .extended, bars: 8)
    #expect(log.records.count > 100)
    #expect(hooked == plain)
    #expect(Set(log.records.map(\.kind)).contains("tonal"))
  }

  /// The report's arithmetic on hand-made hits.
  @Test func reportArithmetic() throws {
    // two bars: even steps on time, odd steps 20 ms late; step 0 at velocity 90 then 110
    var hits: [HitRecord] = []
    for bar in 0..<2 {
      for step in 0..<16 {
        hits.append(
          record(
            step: step, bar: bar, delayMs: step % 2 == 1 ? 20 : 0,
            velocity: step == 0 ? 90 + 20 * bar : 100))
      }
    }
    hits.append(record(step: 3, bar: 0, delayMs: 5, velocity: 64, kind: "tonal"))
    let r = GrooveReport(hits, sampleRate: sr, bpm: 120)
    #expect(r.hits == 33 && r.drumHits == 32)
    // 16 positions hit twice: one has two velocities
    #expect(abs(r.distinctVelocitiesPerPosition - 17.0 / 16) < 1e-9)
    #expect(abs(r.consistency - 1) < 1e-9)
    // pair = 250 ms; off-beats (16 hats at 20 ms + one tonal at 5) against on-beats at 0
    let offMean = (16 * 20.0 + 5) / 17
    #expect(abs(try #require(r.swingRatio) - (0.5 + offMean / 250)) < 1e-4)
    #expect(r.voices["tonal"]?.hits == 1)
    #expect(abs((r.voices["hat"]?.meanDelayMs ?? 0) - 10) < 0.01)
    #expect(GrooveReport([], sampleRate: sr, bpm: 120).swingRatio == nil)
  }
}
