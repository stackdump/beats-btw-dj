import Testing

@testable import DJCore

// `DJMusicality.Fixes.duck`: bass and pad dip on each kick and swell back, measured on renders
// (linear master, so a mix minus its kick-alone render is exactly the pad as it played).

private let sr = 48_000.0

/// A four-on-the-floor kick and a pad chord held for the bar, at 120 BPM (a beat is 0.5 s).
private func kickAndPad(pad: Bool = true, kick: Bool = true) -> Project {
  var k = NetBundle.ring(16)
  for step in [0, 4, 8, 12] { k.bind(step, note: 36, channel: 10, velocity: 100, duration: 50) }
  k.track.channel = 10
  k.track.group = "drums"
  var h = NetBundle.ring(16)
  for (v, note) in [60, 64, 67].enumerated() {
    h.bind(v, note: note, channel: 7, velocity: 90, duration: 1950)
  }
  h.track.channel = 7
  h.track.group = "harmony"
  var p = Project()
  p.tempo = 120
  if kick { p.nets["kick"] = k }
  if pad { p.nets["harmony"] = h }
  return p
}

private func render(_ p: Project, depth: Double) -> [Float] {
  var o = WaveOptions()
  o.master = "linear"
  o.duckDepth = depth
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var out = [Float](repeating: 0, count: Int(4 * sr))
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

/// RMS of `x[a..<b]`.
private func rms(_ x: [Float], _ a: Int, _ b: Int) -> Double {
  var s = 0.0
  for i in a..<b { s += Double(x[i]) * Double(x[i]) }
  return (s / Double(b - a)).squareRoot()
}

struct DuckTests {
  /// Just after each kick the pad is about `depth` down; just before the next it is back.
  @Test func padDipsOnTheKickAndRecovers() {
    let kickAlone = render(kickAndPad(pad: false), depth: 0.5)
    let ducked = render(kickAndPad(), depth: 0.5)
    let plain = render(kickAndPad(), depth: 0)
    let pad = zip(ducked, kickAlone).map { $0 - $1 }
    let padPlain = zip(plain, kickAlone).map { $0 - $1 }
    let beat = Int(0.5 * sr)
    for b in 1..<7 {
      let k = b * beat + 1  // the kick lands on the beat
      let early = ampDB(rms(pad, k + 480, k + 1440) / rms(padPlain, k + 480, k + 1440))
      let late = ampDB(
        rms(pad, k + beat - 2400, k + beat - 480) / rms(padPlain, k + beat - 2400, k + beat - 480))
      #expect(early < -4, "beat \(b): \(early) dB 10–30 ms after the kick")
      #expect(late > -0.5, "beat \(b): \(late) dB just before the next kick")
    }
  }

  /// Depth 0 (beats' engine, and genres that don't pump) renders exactly as before; the kick
  /// itself is never ducked.
  @Test func noDepthIsBitIdenticalAndTheKickIsUntouched() {
    let a = render(kickAndPad(), depth: 0)
    var o = WaveOptions()
    o.master = "linear"
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(kickAndPad())
    r.play()
    var b = [Float](repeating: 0, count: a.count)
    b.withUnsafeMutableBufferPointer { buf in
      var off = 0
      while off < buf.count {
        let n = min(256, buf.count - off)
        r.process(buf.baseAddress! + off, nil, frames: n)
        off += n
      }
    }
    #expect(a == b)
    #expect(render(kickAndPad(pad: false), depth: 0.5) == render(kickAndPad(pad: false), depth: 0))
  }

  /// Which genres pump: four-on-the-floor dance genres by half, broken dance beats less, the
  /// rest not at all; a deck's track gets its genre's depth.
  @Test func depthByGenre() {
    #expect(DJMusicality.duckDepth(genre: "techno") == 0.5)
    #expect(DJMusicality.duckDepth(genre: "trance") == 0.5)
    #expect(DJMusicality.duckDepth(genre: "dnb") > 0 && DJMusicality.duckDepth(genre: "dnb") < 0.5)
    for g in ["jazz", "bossa", "lofi", "ambient", "country", "funk"] {
      #expect(DJMusicality.duckDepth(genre: g) == 0, "\(g)")
    }
    let track = PreparedTrack(
      spec: TrackSpec(genre: "house", seed: 42, structure: "minimal"), sampleRate: 22_050)
    #expect(track.prepared.duckDepth == 0.5)
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct DuckRealTimeTests {
  /// Ducking is a few multiplies a sample: a pumping song renders without allocating.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func duckingDoesNotAllocate() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "techno", seed: 42, structure: "minimal"), sampleRate: sr)
    let r = WaveRunner(sampleRate: sr, opts: .extended)
    r.load(prepared: track.prepared)
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
    #expect(track.prepared.duckDepth > 0)
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
