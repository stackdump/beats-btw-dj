import Testing

@testable import DJCore

/// `PitchMeasure`: a held note against its MIDI note, and its period.
struct PitchMeasureTests {
  let sr = 48_000.0

  @Test func a3SineReadsOnNote57() {
    let x = sineWave(220, rmsDB: -12, seconds: 1, sampleRate: sr)
    let r = PitchMeasure.error(x, note: 57, sampleRate: sr)
    #expect(abs(r.cents) < 1, "\(r.cents)")
    #expect(r.octave == 0)
    #expect(abs(r.hz - 220) < 0.2, "\(r.hz)")
    // −12 dB RMS: amplitude 0.355
    #expect(abs(r.level - 0.355) < 0.02, "\(r.level)")
    let f = PitchMeasure.fundamental(x, sampleRate: sr)
    #expect(f != nil && abs(f! - 220) < 0.5, "\(String(describing: f))")
  }

  @Test func twentyCentsSharpReadsTwenty() {
    let x = sineWave(hzAbove(220, cents: 20), rmsDB: -12, seconds: 1, sampleRate: sr)
    let r = PitchMeasure.error(x, note: 57, sampleRate: sr)
    #expect(abs(r.cents - 20) <= 2, "\(r.cents)")
  }

  @Test func silenceReadsLevelZero() {
    let x = [Float](repeating: 0, count: Int(sr))
    #expect(PitchMeasure.error(x, note: 57, sampleRate: sr).level == 0)
    #expect(PitchMeasure.fundamental(x, sampleRate: sr) == nil)
  }
}
