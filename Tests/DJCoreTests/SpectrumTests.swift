import Darwin
import Testing

@testable import DJCore

/// `Spectrum`: the long-term spectrum and what is read from it, against signals whose
/// spectrum is known.
struct SpectrumTests {
  let sr = 44100.0

  /// Deterministic white noise, uniform in ±0.5.
  func white(_ count: Int, seed: UInt64 = 1) -> [Float] {
    var x = seed
    return (0..<count).map { _ in
      x &+= 0x9E37_79B9_7F4A_7C15
      var z = x
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z ^= z >> 31
      return Float(Double(z >> 11) / Double(1 << 53) - 0.5)
    }
  }

  /// Paul Kellett's refined pink filter over white noise (±0.05 dB from 9 Hz at 44.1 kHz).
  func pink(_ count: Int, seed: UInt64 = 2) -> [Float] {
    var b = [Double](repeating: 0, count: 7)
    return white(count, seed: seed).map { f in
      let w = Double(f)
      b[0] = 0.99886 * b[0] + w * 0.0555179
      b[1] = 0.99332 * b[1] + w * 0.0750759
      b[2] = 0.96900 * b[2] + w * 0.1538520
      b[3] = 0.86650 * b[3] + w * 0.3104856
      b[4] = 0.55000 * b[4] + w * 0.5329522
      b[5] = -0.7616 * b[5] - w * 0.0168980
      let y = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
      b[6] = w * 0.115926
      return Float(y * 0.11)
    }
  }

  var seconds: Int { Int(10 * sr) }

  @Test func whiteNoiseIsFlat() {
    let x = white(seconds)
    let s = Spectrum(left: x, right: x, sampleRate: sr)
    #expect(abs(s.slopeDBPerOct) < 0.3, "slope \(s.slopeDBPerOct)")
    #expect(abs(s.hfBumpDB) < 1, "bump \(s.hfBumpDB)")
  }

  @Test func pinkNoiseFallsThreeDBAnOctave() {
    let x = pink(seconds)
    let s = Spectrum(left: x, right: x, sampleRate: sr)
    #expect(abs(s.slopeDBPerOct + 3) < 0.4, "slope \(s.slopeDBPerOct)")
    #expect(abs(s.hfBumpDB) < 1.5, "bump \(s.hfBumpDB)")
  }

  @Test func sineIsLoudestInItsThirdOctave() {
    let x = (0..<seconds).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / sr)) }
    let s = Spectrum(left: x, right: x, sampleRate: sr)
    let loudest = s.ltasDB.indices.max { s.ltasDB[$0] < s.ltasDB[$1] }!
    #expect(Spectrum.bandsHz[loudest] == 1000)
  }

  @Test func boostAt14kHzIsABump() {
    var x = pink(seconds)
    // band-passed white noise at 14 kHz, well over the pink there
    var hiss = white(seconds, seed: 9).map(Double.init)
    let bp = biquad(type: "bandpass", fc: 14000, q: 2, sr: sr)
    for _ in 0..<2 {
      var z1 = 0.0
      var z2 = 0.0
      for i in hiss.indices {
        let v = hiss[i]
        let y = bp[0] * v + z1
        z1 = bp[1] * v - bp[3] * y + z2
        z2 = bp[2] * v - bp[4] * y
        hiss[i] = y
      }
    }
    for i in x.indices { x[i] += Float(hiss[i]) }
    let s = Spectrum(left: x, right: x, sampleRate: sr)
    #expect(s.hfBumpDB > 6, "bump \(s.hfBumpDB)")
    #expect(abs(s.slopeDBPerOct + 3) < 1, "slope \(s.slopeDBPerOct)")
  }

  @Test func monoFoldsWithoutLossAndInvertedLosesEverything() {
    let x = pink(seconds)
    let mono = Spectrum(left: x, right: x, sampleRate: sr)
    #expect(mono.monoFoldLossDB.allSatisfy { abs($0) < 0.01 }, "\(mono.monoFoldLossDB)")
    #expect(abs(mono.monoFoldDB) < 0.01)
    let inverted = Spectrum(left: x, right: x.map { -$0 }, sampleRate: sr)
    #expect(inverted.monoFoldLossDB.allSatisfy { $0 < -60 }, "\(inverted.monoFoldLossDB)")
    #expect(inverted.monoFoldDB < -60)
    // uncorrelated channels fold 3 dB down
    let wide = Spectrum(left: x, right: pink(seconds, seed: 5), sampleRate: sr)
    #expect(abs(wide.monoFoldDB + 3) < 0.5, "\(wide.monoFoldDB)")
  }

  /// AudioMetrics carries it, and its dictionary (what `djctl render` prints) has the keys.
  @Test func audioMetricsReportsTheSpectrum() {
    let x = pink(Int(3 * sr))
    let m = AudioMetrics(left: x, right: x, sampleRate: sr)
    let d = m.dictionary
    for key in ["ltasDB", "slopeDBPerOct", "hfBumpDB", "monoFoldLossDB", "spectrumHz"] {
      #expect(d[key] != nil, "\(key)")
    }
    #expect((d["ltasDB"] as? [Double])?.count == Spectrum.bandsHz.count)
    #expect(abs(m.spectrum.slopeDBPerOct + 3) < 0.6)
  }

  /// A long render costs at most `maxSegments` segments, spread over the whole of it.
  @Test func longRenderIsDecimated() {
    let x = pink(Int(60 * sr))
    let s = Spectrum(left: x, right: x, sampleRate: sr)
    #expect(abs(s.slopeDBPerOct + 3) < 0.4, "slope \(s.slopeDBPerOct)")
  }
}
