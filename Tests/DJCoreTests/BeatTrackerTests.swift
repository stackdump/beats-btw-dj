import Darwin
import Testing

@testable import DJCore

/// A click track: a 2 kHz blip on every beat, and (with `accent`) a 60 Hz thump on every
/// fourth one from beat `accentPhase`; the first beat at `lead` seconds.
private func clicks(
  bpm: Double, seconds: Double, sampleRate sr: Double, accent: Bool = false, accentPhase: Int = 0,
  lead: Double = 0
) -> [Float] {
  var x = [Float](repeating: 0, count: Int(seconds * sr))
  let period = 60 / bpm * sr
  var k = 0
  while true {
    let start = Int((lead * sr + Double(k) * period).rounded())
    guard start < x.count else { break }
    let len = Int(0.03 * sr)
    for i in 0..<min(len, x.count - start) {
      let t = Double(i) / sr
      var v = 0.4 * sin(2 * Double.pi * 2000 * t) * exp(-t / 0.005)
      if accent, k % 4 == accentPhase { v += 0.6 * sin(2 * Double.pi * 60 * t) * exp(-t / 0.02) }
      x[start + i] = Float(v)
    }
    k += 1
  }
  return x
}

/// The share of the true beats in `range` (seconds) that have a tracked beat within `tol`.
private func hitRate(
  _ tracked: [Double], bpm: Double, range: ClosedRange<Double>, tol: Double = 0.030
) -> Double {
  let period = 60 / bpm
  var hits = 0
  var total = 0
  var k = 0
  while Double(k) * period <= range.upperBound {
    let t = Double(k) * period
    k += 1
    guard t >= range.lowerBound else { continue }
    total += 1
    if tracked.contains(where: { abs($0 - t) <= tol }) { hits += 1 }
  }
  return total > 0 ? Double(hits) / Double(total) : 0
}

/// Deterministic white noise.
private func noise(seconds: Double, sampleRate sr: Double) -> [Float] {
  var s: UInt64 = 0x9E37_79B9_7F4A_7C15
  return (0..<Int(seconds * sr)).map { _ in
    s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Float(Int64(bitPattern: s >> 11) % 2_000_000) / 2_000_000 * 0.3
  }
}

@Suite struct BeatTrackerTests {
  let sr = 22_050.0

  @Test func aClickTrackReads124() {
    let x = clicks(bpm: 124, seconds: 30, sampleRate: sr)
    let b = BeatTracker(mono: x, sampleRate: sr)
    #expect(abs(b.bpm - 124) <= 0.5, "\(b.bpm) BPM")
    let rate = hitRate(b.beats, bpm: 124, range: 1...29)
    #expect(rate >= 0.99, "\(rate) of beats within 30 ms")
    #expect(b.confidence > 0.5, "confidence \(b.confidence)")
  }

  /// The prior keeps 70–180 BPM clicks at their own tempo, not half or double.
  @Test(arguments: [72.0, 95.0, 140.0, 174.0])
  func clicksReadTheirOwnTempo(bpm: Double) {
    let b = BeatTracker(mono: clicks(bpm: bpm, seconds: 30, sampleRate: sr), sampleRate: sr)
    #expect(abs(b.bpm - bpm) <= 0.5, "\(bpm): \(b.bpm) BPM")
  }

  @Test(arguments: [0, 1, 2, 3])
  func downbeatsFollowTheLowBand(phase: Int) {
    let x = clicks(
      bpm: 124, seconds: 30, sampleRate: sr, accent: true, accentPhase: phase, lead: 0.25)
    let b = BeatTracker(mono: x, sampleRate: sr)
    let period = 60.0 / 124
    let truth = 0.25 + Double(phase) * period
    #expect(b.downbeatPhase == (b.beats.firstIndex { abs($0 - truth) < 0.03 } ?? -1) % 4)
    // every downbeat sits on an accented beat
    #expect(!b.downbeats.isEmpty)
    for d in b.downbeats {
      let bars = (d - truth) / (4 * period)
      #expect(abs(bars - bars.rounded()) * 4 * period < 0.03, "phase \(phase): downbeat at \(d)")
    }
  }

  @Test func noiseHasLowConfidence() {
    let b = BeatTracker(mono: noise(seconds: 20, sampleRate: sr), sampleRate: sr)
    #expect(b.confidence < 0.3, "confidence \(b.confidence)")
  }

  @Test func silenceAndShortInputReadNothing() {
    let b = BeatTracker(mono: [Float](repeating: 0, count: 1000), sampleRate: sr)
    #expect(b.bpm == 0 && b.beats.isEmpty)
  }

  /// Our own synth renders are the ground truth: the project's tempo, a beat every quarter from
  /// the first sample. Within ±1 BPM, ≥ 90 % of beats within 30 ms (the intro's first bars
  /// may be silent or beatless, so the count starts at 4 s).
  @Test(arguments: ["techno", "house", "trance", "dnb"])
  func rendersReadTheirTempoAndBeats(genre: String) {
    let rate = 22_050.0
    let spec = TrackSpec(genre: genre, seed: 4242, structure: "standard")
    let source = WaveDeckSource(sampleRate: rate, opts: .extended)
    let track = PreparedTrack(spec: spec, sampleRate: rate, opts: .extended)
    let tempo = track.project.tempo
    let r = OfflineRender(track: track, source: source, seconds: 60)
    let b = BeatTracker(left: r.left, right: r.right, sampleRate: rate)
    let seconds = Double(r.left.count) / rate
    let rate30 = hitRate(b.beats, bpm: tempo, range: 4...(seconds - 1))
    print(
      "BeatTracker \(genre): truth \(tempo) BPM, read \(b.bpm), beats within 30 ms \(rate30),"
        + " confidence \(b.confidence), downbeat phase \(b.downbeatPhase)")
    #expect(abs(b.bpm - tempo) <= 1, "\(genre): \(b.bpm) vs \(tempo) BPM")
    #expect(rate30 >= 0.9, "\(genre): \(rate30) of beats within 30 ms")
  }
}
