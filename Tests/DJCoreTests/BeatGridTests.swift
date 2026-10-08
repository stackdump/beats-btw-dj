import Darwin
import Testing

@testable import DJCore

/// A synthetic track: a kick on every beat, quieter hats on the offbeats, a bass note
/// every two beats; `lead` seconds of silence first.
private func track(bpm: Double, beats: Int, lead: Double, sr: Double = 22_050) -> SampleBuffer {
  let spb = sr * 60 / bpm
  let n = Int(lead * sr + Double(beats) * spb)
  var l = [Float](repeating: 0, count: n)
  var seed: UInt32 = 12345
  func noise() -> Float {
    seed ^= seed << 13
    seed ^= seed >> 17
    seed ^= seed << 5
    return Float(seed) / Float(UInt32.max) * 2 - 1
  }
  for b in 0..<beats {
    let start = Int(lead * sr + Double(b) * spb)
    for i in 0..<Int(0.12 * sr) where start + i < n {  // kick
      let t = Double(i) / sr
      l[start + i] += Float(sin(2 * .pi * (50 + 120 * exp(-t * 40)) * t) * exp(-t * 18)) * 0.9
    }
    let hat = start + Int(spb / 2)
    for i in 0..<Int(0.04 * sr) where hat + i < n {
      l[hat + i] += noise() * Float(exp(-Double(i) / sr * 90)) * 0.3
    }
  }
  return SampleBuffer(left: l, sampleRate: sr)
}

private func phaseError(_ got: Double, _ want: Double, spb: Double) -> Double {
  var d = (got - want).truncatingRemainder(dividingBy: spb)
  if d > spb / 2 { d -= spb }
  if d < -spb / 2 { d += spb }
  return abs(d)
}

struct BPMAnalyzerTests {
  @Test(arguments: [90.0, 100, 120, 128, 140, 150, 174])
  func findsTempoAndPhase(bpm: Double) throws {
    let sr = 22_050.0
    let lead = 0.1
    let buf = track(bpm: bpm, beats: 48, lead: lead, sr: sr)
    let grid = try #require(BPMAnalyzer.analyze(buf))
    #expect(abs(grid.bpm - bpm) < 0.5, "\(bpm): got \(grid.bpm)")
    let spb = sr * 60 / bpm
    #expect(
      phaseError(grid.offset, lead * sr, spb: spb) < 0.012 * sr,
      "\(bpm): offset \(grid.offset) vs \(lead * sr)")
  }

  @Test func theDemoLoopIs120() throws {
    let sr = 22_050.0
    // The demo is two bars; repeat it so there is something to measure.
    let one = DemoLoop.make(sampleRate: sr)
    var l: [Float] = []
    for _ in 0..<4 { l += UnsafeBufferPointer(start: one.left, count: one.length) }
    let grid = try #require(BPMAnalyzer.analyze(SampleBuffer(left: l, sampleRate: sr)))
    #expect(abs(grid.bpm - DemoLoop.bpm) < 1, "got \(grid.bpm)")
    #expect(phaseError(grid.offset, 0, spb: sr * 60 / 120) < 0.015 * sr)
  }

  @Test func silenceAndNoiseGiveNothingUseful() {
    #expect(
      BPMAnalyzer.analyze(
        SampleBuffer(left: [Float](repeating: 0, count: 100_000), sampleRate: 22_050)) == nil)
    #expect(
      BPMAnalyzer.analyze(
        SampleBuffer(left: [Float](repeating: 0.1, count: 200), sampleRate: 22_050)) == nil)
  }
}
