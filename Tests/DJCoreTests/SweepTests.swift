import Darwin
import Testing

@testable import DJCore

// `DJMusicality.Fixes.sweep`: subtractive voices struck in a buildup open (filter base 0.6× →
// 2×) and resonate (Q towards 2.5) as it goes, and play stock everywhere else.

private let sr = 22_050.0

private func played(_ genre: String, _ seed: Double = 42, structure: String = "standard")
  -> Project
{
  let spec = TrackSpec(genre: genre, seed: seed, structure: structure)
  return DJMusicality.apply(spec.project(), spec: spec)
}

/// The song from its start, mono, synth voices, for `steps` steps (default: all of it).
private func render(_ p: Project, opts o: WaveOptions, steps: Int? = nil) -> [Float] {
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  let n = steps ?? p.structure.reduce(0) { $0 + $1.steps }
  var out = [Float](repeating: 0, count: Int(Double(n) * sr * 15 / p.tempo) + 512)
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off + 512 <= b.count && !r.stopped {
      r.process(b.baseAddress! + off, nil, frames: 512)
      off += 512
    }
  }
  return out
}

/// Spectral centroid (Hz) of `x[a..<b]`: Hann-windowed 1024-sample frames, a naive DFT up to
/// 5.5 kHz (the bins a filter base moves), power-weighted.
private func centroid(_ x: [Float], _ a: Int, _ b: Int) -> Double {
  let size = 1024
  let bins = Int(5_500 / (sr / Double(size)))
  var window = [Double](repeating: 0, count: size)
  for i in 0..<size { window[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(size)) }
  var cosT = [Double](repeating: 0, count: size)
  var sinT = [Double](repeating: 0, count: size)
  for i in 0..<size {
    cosT[i] = cos(2 * Double.pi * Double(i) / Double(size))
    sinT[i] = sin(2 * Double.pi * Double(i) / Double(size))
  }
  var num = 0.0
  var den = 0.0
  var f = a
  var frame = [Double](repeating: 0, count: size)
  while f + size <= b {
    for i in 0..<size { frame[i] = Double(x[f + i]) * window[i] }
    for k in 1..<bins {
      var re = 0.0
      var im = 0.0
      var j = 0
      for i in 0..<size {
        re += frame[i] * cosT[j]
        im += frame[i] * sinT[j]
        j += k
        if j >= size { j -= size }
      }
      let p = re * re + im * im
      num += p * Double(k) * sr / Double(size)
      den += p
    }
    f += size * 2
  }
  return den > 0 ? num / den : 0
}

/// `.extended` with `.sweep` on or off, everything measured at prepare pinned so the two differ
/// by the sweep alone.
private func options(_ p: Project, sweep: Bool) -> WaveOptions {
  var o = WaveOptions.extended
  o.trackBalance = MixBalance.trims(for: p, fixes: o.musicality.subtracting(.sweep))
  o.trackEnergy = EnergyCurve(project: p)
  var off = o
  off.musicality.remove(.sweep)
  o.trackGain = WaveRunner.prepare(p, sampleRate: sr, opts: off).gain
  if !sweep { o.musicality.remove(.sweep) }
  return o
}

struct SweepTests {
  @Test func sweepIsRegistered() {
    #expect(DJMusicality.Fixes.all.contains(.sweep))
    #expect(DJMusicality.Fixes.named["sweep"] == .sweep)
    #expect(!WaveOptions().musicality.contains(.sweep), "parity stays beats-exact")
  }

  /// The ramp's progress: 0 on a buildup's first step, rising to just under 1 on its last, nil
  /// in every other section.
  @Test func rampProgressRunsThroughTheBuildupOnly() throws {
    let p = played("trance")
    let c = try #require(EnergyCurve(project: p))
    let b = try #require(c.ramp.firstIndex(of: true))
    let s0 = c.start[b]
    let s1 = c.start[b + 1]
    #expect(c.rampProgress(step: s0) == 0)
    let last = try #require(c.rampProgress(step: s1 - 1))
    #expect(last > 0.9 && last < 1)
    #expect(c.rampProgress(step: (s0 + s1) / 2)! < last)
    #expect(c.rampProgress(step: s1) == nil)
    #expect(c.rampProgress(step: max(0, s0 - 1)) == nil || b == 0)
    for (k, r) in c.ramp.enumerated() where !r {
      #expect(c.rampProgress(step: c.start[k]) == nil, "section \(k)")
    }
  }

  @Test func sweepShapesBaseAndQ() {
    #expect(abs(BuildupSweep.base(2.5, x: 0) - 1.5) < 1e-12)
    #expect(abs(BuildupSweep.base(2.5, x: 1) - 5) < 1e-12)
    #expect(BuildupSweep.base(2.5, x: 0.5) > 1.5 && BuildupSweep.base(2.5, x: 0.5) < 5)
    #expect(BuildupSweep.q(0.8, x: 0) == 0.8)
    #expect(abs(BuildupSweep.q(0.8, x: 1) - 2.5) < 1e-12)
    #expect(BuildupSweep.q(0.8, x: 0.5) < (0.8 + 2.5) / 2, "accelerating")
    #expect(BuildupSweep.q(3, x: 1) == 3, "never below the voice's own")
  }

  /// Everything before the first buildup renders bit-identical with and without the sweep.
  @Test func rendersOutsideBuildupsAreBitIdentical() throws {
    let p = played("trance")
    let c = try #require(EnergyCurve(project: p))
    let b = try #require(c.ramp.firstIndex(of: true))
    let before = c.start[b]
    try #require(before >= 64)
    let on = render(p, opts: options(p, sweep: true), steps: before + 16)
    let off = render(p, opts: options(p, sweep: false), steps: before + 16)
    let edge = Int(Double(before) * sr * 15 / p.tempo) - 512
    #expect(sameSamples(Array(on[0..<edge]), Array(off[0..<edge])) == .identical)
    // and the buildup itself is not
    #expect(sameSamples(on[edge...], off[edge...]) != .identical)
  }

  /// A soloed subtractive part (no `.energy` lowpass, so the brightening is the sweep's): its
  /// buildup's last bar has a centroid ≥ 1.5× its first; without the sweep it stays put. The
  /// extra resonance adds no more than 1 dB to the full mix's peak.
  @Test(arguments: ["trance", "techno"])
  func buildupBrightensItsSynthVoices(genre: String) throws {
    let p = played(genre)
    let c = try #require(EnergyCurve(project: p))
    let b = try #require(c.ramp.firstIndex(of: true))
    let s0 = c.start[b]
    let s1 = c.start[b + 1]
    try #require(s1 - s0 >= 32)
    var base = WaveOptions.extended
    base.musicality.remove(.energy)
    base.musicality.remove(.space)
    base.musicality.remove(.echo)
    base.musicality.remove(.balance)
    base.trackEnergy = c
    base.trackGain = 1
    // the first part whose lanes the subtractive envelope shapes
    var part: Project?
    for name in ["bass", "lead", "arp"] {
      let solo = MixBalance.solo(p, name)
      let prepared = WaveRunner.prepare(solo, sampleRate: sr, opts: base)
      if prepared.lanes.contains(where: { $0.fAmount > 0 && $0.samplerSlot < 0 }) {
        part = solo
        break
      }
    }
    let solo = try #require(part, "no subtractive part in \(genre)")
    var off = base
    off.musicality.remove(.sweep)
    let on = render(solo, opts: base, steps: s1)
    let flat = render(solo, opts: off, steps: s1)
    let perStep = sr * 15 / p.tempo
    let first = (Int(Double(s0) * perStep), Int(Double(s0 + 16) * perStep))
    let last = (Int(Double(s1 - 16) * perStep), Int(Double(s1) * perStep))
    let ratio = centroid(on, last.0, last.1) / max(1, centroid(on, first.0, first.1))
    let flatRatio = centroid(flat, last.0, last.1) / max(1, centroid(flat, first.0, first.1))
    print("\(genre): centroid last/first \(ratio) with the sweep, \(flatRatio) without")
    #expect(ratio >= 1.5, "\(genre): \(ratio)")
    #expect(ratio > flatRatio)
    // The full mix's peak with the extra resonance, against the same mix without the sweep.
    // Not against 0 dBFS: `.extended` is the app's "limit" master, a linear runner sum at the
    // track's loudness gain (one loudness, -12 LUFS) that `WaveDeckSource`'s `PeakLimiter`
    // holds under -1 dBTP afterwards, so the runner's own peaks pass 0 dBFS with or without
    // the sweep (techno ~+11 dB). What the sweep must not do is add peaks of its own.
    let mix = render(p, opts: options(p, sweep: true), steps: s1 + 16)
    let stock = render(p, opts: options(p, sweep: false), steps: s1 + 16)
    let peak = mix.reduce(Float(0)) { max($0, abs($1)) }
    let stockPeak = stock.reduce(Float(0)) { max($0, abs($1)) }
    print("\(genre): mix peak \(ampDB(Double(peak))) dBFS, \(ampDB(Double(stockPeak))) without")
    #expect(
      ampDB(Double(peak)) <= ampDB(Double(stockPeak)) + 1,
      "\(genre): peak \(ampDB(Double(peak))) dBFS, \(ampDB(Double(stockPeak))) without the sweep")
  }
}
