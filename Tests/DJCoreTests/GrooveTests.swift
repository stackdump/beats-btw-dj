import Testing

@testable import DJCore

// `DJMusicality.Fixes.groove`: the project's swing and humanize, played by the runner the way
// beats' browser plays them (backend/index.js `swingDelay`, `humanizeNote`), measured from the
// rendered audio.

private let sr = 48_000.0

/// A hi-hat on steps 1 (an off-beat sixteenth) and 4 (a beat) of every 16-step bar.
private func hats(swing: Double, humanize: Double) -> Project {
  var nb = NetBundle.ring(16)
  for step in [1, 4] { nb.bind(step, note: 42, channel: 12, velocity: 100, duration: 50) }
  nb.track.channel = 12
  var p = Project()
  p.tempo = 120  // a sixteenth is 125 ms
  p.swing = swing
  p.humanize = humanize
  p.nets["hat"] = nb
  return p
}

/// Sample index of every onset: the first sample over the threshold after 20 ms of quiet.
private func onsets(_ x: [Float]) -> [Int] {
  var out: [Int] = []
  var quiet = Int.max / 2
  for (i, v) in x.enumerated() {
    if abs(v) > 0.01 {
      if quiet > Int(0.02 * sr) { out.append(i) }
      quiet = 0
    } else {
      quiet += 1
    }
  }
  return out
}

private func render(_ p: Project, groove: Bool, bars: Int = 4) -> [Float] {
  var o = WaveOptions()
  if groove { o.musicality = .groove }
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(p)
  r.play()
  var out = [Float](repeating: 0, count: Int(Double(bars) * 2 * sr))
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

struct GrooveTests {
  /// Without the fix (beats' wave engine) both hats sit on the grid; with it the off-beat one
  /// is late by swing% × half a sixteenth and the on-beat one stays put.
  @Test func swingDelaysTheOffBeatSixteenths() throws {
    let tick = 0.125 * sr
    let straight = onsets(render(hats(swing: 50, humanize: 0), groove: false))
    let swung = onsets(render(hats(swing: 50, humanize: 0), groove: true))
    try #require(straight.count == 8 && swung.count == 8, "\(straight) \(swung)")
    for (a, b) in zip(straight, swung) {
      let offBeat = Int((Double(a) / tick).rounded()) % 16 == 1
      let late = Double(b - a) / sr * 1000
      #expect(abs(late - (offBeat ? 31.25 : 0)) < 1, "onset \(a): \(late) ms late")
    }
  }

  /// Humanize moves every hit a little (never early), differently from bar to bar, and the
  /// same way on every render (a replay plays the same groove).
  @Test func humanizeJittersDeterministically() throws {
    let tick = 0.125 * sr
    let a = onsets(render(hats(swing: 0, humanize: 40), groove: true))
    let b = onsets(render(hats(swing: 0, humanize: 40), groove: true))
    #expect(a == b)
    try #require(a.count == 8)
    let offsets = a.map { Double($0) - (Double($0) / tick).rounded(.down) * tick }
    #expect(Set(offsets.map { Int($0 / sr * 1000) }).count > 2, "the hits move: \(offsets)")
    for o in offsets { #expect(o / sr * 1000 < 0.4 * 30 + 1, "within humanize's reach: \(o)") }
  }

  /// A project with neither (most of beats' techno / trance / edm) plays exactly as before.
  @Test func noSwingNoHumanizeIsBitIdentical() {
    #expect(
      render(hats(swing: 0, humanize: 0), groove: true)
        == render(hats(swing: 0, humanize: 0), groove: false))
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct GrooveRealTimeTests {
  /// Held-back notes live in fixed arrays: a swung, humanized song renders without allocating.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func swungNotesDoNotAllocate() {
    var spec = TrackSpec(genre: "jazz", seed: 42, structure: "minimal").project()
    spec.swing = 60
    spec.humanize = 40
    let r = WaveRunner(sampleRate: sr, opts: .extended)
    r.load(spec)
    r.setTempo(480)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    l.withUnsafeMutableBufferPointer { b in
      for _ in 0..<200 { r.process(b.baseAddress!, nil, frames: 128) }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { b in
        for _ in 0..<3000 { r.process(b.baseAddress!, nil, frames: 128) }
      }
    }
    #expect(r.graph!.tick > 100)
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
