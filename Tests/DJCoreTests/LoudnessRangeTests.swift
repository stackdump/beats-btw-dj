import Darwin
import Testing

@testable import DJCore

// EBU Tech 3342 loudness range (`IntegratedLoudness.range`) and BS.1770-4 true peak
// (`TruePeak`), on signals whose answers are known.

private let sr = 48_000.0

/// `seconds` of a sine at `hz`, peak `amplitude`, starting at `phase`.
private func sine(
  _ hz: Double, amplitude: Double, seconds: Double, phase: Double = 0
) -> [Float] {
  (0..<Int(seconds * sr)).map {
    Float(amplitude * sin(2 * Double.pi * hz * Double($0) / sr + phase))
  }
}

private func db(_ x: Double) -> Double { pow(10, x / 20) }

@Suite struct LoudnessRangeTests {
  @Test func steadySineHasNoRange() {
    let x = sine(1000, amplitude: db(-20), seconds: 20)
    let lra = IntegratedLoudness.range(left: x, right: x, sampleRate: sr)
    #expect(lra >= 0 && lra < 0.2, "lra \(lra)")
  }

  @Test func twoLevelsTenDBApartReadTenLU() {
    let x =
      sine(1000, amplitude: db(-20), seconds: 20) + sine(1000, amplitude: db(-30), seconds: 20)
    let lra = IntegratedLoudness.range(left: x, right: x, sampleRate: sr)
    #expect(abs(lra - 10) <= 1, "lra \(lra)")
  }

  @Test func silenceAndShortRenderHaveNoRange() {
    let quiet = [Float](repeating: 0, count: Int(5 * sr))
    #expect(IntegratedLoudness.range(left: quiet, right: nil, sampleRate: sr) == 0)
    let short = sine(1000, amplitude: 0.5, seconds: 2)
    #expect(IntegratedLoudness.range(left: short, right: nil, sampleRate: sr) == 0)
  }

  @Test func quarterRateSineAt45DegreesPeaksBetweenSamples() {
    let x = sine(sr / 4, amplitude: 1, seconds: 1, phase: Double.pi / 4)
    let samplePeak = 20 * log10(Double(x.map { abs($0) }.max()!))
    let tp = TruePeak.dbtp(left: x, right: nil)
    #expect(abs(tp - samplePeak - 3.0) <= 0.3, "tp \(tp) sample peak \(samplePeak)")
  }

  @Test func fullScale997HzReadsZeroDBTP() {
    let x = sine(997, amplitude: 1, seconds: 1)
    let tp = TruePeak.dbtp(left: x, right: x)
    #expect(abs(tp) <= 0.2, "tp \(tp)")
  }

  @Test func truePeakTakesTheLouderChannel() {
    let l = sine(997, amplitude: db(-12), seconds: 0.5)
    let r = sine(997, amplitude: db(-6), seconds: 0.5)
    #expect(abs(TruePeak.dbtp(left: l, right: r) + 6) <= 0.2)
    #expect(TruePeak.dbtp(left: [0, 0, 0], right: nil) == -200)
  }

  @Test func detectorStreamsWithoutGrowingAndResets() {
    var d = TruePeak.Detector()
    for v in sine(997, amplitude: 0.5, seconds: 0.1) { _ = d.process(Double(v)) }
    #expect(abs(20 * log10(d.peak) - 20 * log10(0.5)) <= 0.2)
    d.reset()
    #expect(d.peak == 0)
    #expect(d.process(0) == 0)
  }
}
