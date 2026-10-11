import Darwin
import Testing

@testable import DJCore

// AnalyserFFT is the Web Audio AnalyserNode's analysis (Blackman, FFT, |X|/N, smoothing, dB).
// Literals below come from scripts/analyser-reference.mjs (the spec's algorithm as a naive
// O(N^2) double-precision DFT, nothing shared with the vDSP code) or from closed forms worked
// out by hand next to them.
//
// Tolerance policy for FFT output (float32 against a double reference): a bin must match to
// 1e-5 relative, where "relative" is to max(|bin|, 1% of the frame's largest bin). Bins above
// 1% of the peak are therefore held to a strict 1e-5; smaller ones to 1e-7 of the peak in
// absolute terms (float32's noise floor is about -140 dB).

private func sine(_ n: Int, bin k: Double, amp: Double = 1, phase: Double = 0) -> [Float] {
  (0..<n).map { Float(amp * sin(2 * Double.pi * k * Double($0) / Double(n) + phase)) }
}

/// Fresh analyser, one analysis, linear magnitudes.
private func spectrum(_ x: [Float], size: Int, tau: Float = 0) -> [Float] {
  let a = AnalyserFFT(fftSize: size, smoothingTimeConstant: tau)
  a.analyse(x)
  return a.linearMagnitudes()
}

private func matches(_ got: [Float], _ want: [Double], peak: Double? = nil) -> Bool {
  guard got.count == want.count else { return false }
  let top = peak ?? want.max() ?? 0
  return zip(got, want).allSatisfy { g, w in
    abs(Double(g) - w) <= 1e-5 * max(abs(w), 0.01 * top)
  }
}

private func firstMismatch(_ got: [Float], _ want: [Double]) -> String {
  let top = want.max() ?? 0
  for (i, (g, w)) in zip(got, want).enumerated()
  where abs(Double(g) - w) > 1e-5 * max(abs(w), 0.01 * top) {
    return "bin \(i): got \(g) want \(w)"
  }
  return "count \(got.count) vs \(want.count)"
}

/// A tone plus a deterministic ramp-noise pattern, different per `f`.
private func mixedFrame(_ n: Int, _ f: Int) -> [Float] {
  var out = [Float](repeating: 0, count: n)
  for i in 0..<n {
    let tone: Double = sin(Double(i * (f + 3)) * 0.37 + Double(f)) * 0.5
    let steps: Int = ((i * (37 + f) + 11) % 17) - 8
    out[i] = Float(tone) + Float(steps) / 32
  }
  return out
}

private func isNegativeInfinity(_ v: Float) -> Bool { v == -Float.infinity }

/// scripts/analyser-reference.mjs: x[n] = ((n*a + b) % m - c) / d, exact binary fractions.
private func frame32(_ a: Int, _ b: Int, _ m: Int, _ c: Int, _ d: Int) -> [Float] {
  (0..<32).map { Float((($0 * a + b) % m) - c) / Float(d) }
}
private let frames32: [[Float]] = [
  frame32(37, 11, 17, 8, 16), frame32(29, 5, 13, 6, 8), frame32(13, 3, 11, 5, 32),
]

struct AnalyserFFTTests {
  // MARK: Window

  @Test(arguments: [256, 4096])
  func blackmanWindowValues(n: Int) {
    let w = AnalyserFFT.blackmanWindow(count: n)
    #expect(w.count == n)
    // Hand: w(0) = 0.42 - 0.5 + 0.08 = 0; w(N/4) = 0.42 - 0 - 0.08 = 0.34;
    // w(N/2) = 0.42 + 0.5 + 0.08 = 1; w(N/8) = 0.42 - 0.5*sqrt(2)/2 = 0.0664466094067.
    #expect(abs(w[0]) < 1e-7)
    #expect(abs(Double(w[n / 8]) - 0.0664466094067) < 1e-7)
    #expect(abs(w[n / 4] - 0.34) < 1e-6)
    #expect(abs(w[n / 2] - 1) < 1e-6)
    #expect(abs(w[3 * n / 4] - 0.34) < 1e-6)
    // First sample after the zero, from the script: it depends on N (periodic form).
    let w1 = n == 256 ? 5.42271483117e-5 : 2.11778915141e-7
    #expect(abs(Double(w[1]) - w1) < 1e-9, "w[1] = \(w[1])")
    // Periodic (denominator N, not N-1): w[N-i] == w[i], and the mean is the coherent gain 0.42.
    for i in 1..<n { #expect(abs(w[n - i] - w[i]) < 1e-6) }
    let mean = w.reduce(0, +) / Float(n)
    #expect(abs(mean - 0.42) < 1e-5)
  }

  // MARK: Sizes

  @Test func validSizesAndBinCount() {
    for p in 5...15 {
      let n = 1 << p
      #expect(AnalyserFFT.isValidFFTSize(n))
      let a = AnalyserFFT(fftSize: n)
      #expect(a.fftSize == n)
      #expect(a.frequencyBinCount == n / 2)
      #expect(a.decibels().count == n / 2)
      #expect(a.linearMagnitudes().count == n / 2)
      #expect(a.bytes().count == n / 2)
    }
    for bad in [-32, 0, 1, 16, 31, 33, 48, 100, 2047, 32769, 65536] {
      #expect(!AnalyserFFT.isValidFFTSize(bad), "\(bad)")
    }
    #expect(AnalyserFFT().fftSize == 2048, "AnalyserNode default")
    #expect(AnalyserFFT().smoothingTimeConstant == 0.8, "AnalyserNode default")
  }

  @Test func invalidSizeIsRefusedAndChangesNothing() {
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    a.analyse(sine(256, bin: 16))
    let before = a.linearMagnitudes()
    for bad in [0, 16, 100, 65536, -256] { #expect(!a.setFFTSize(bad)) }
    #expect(a.fftSize == 256)
    #expect(a.linearMagnitudes() == before, "a refused size must not reset the smoothed state")
  }

  /// Scaling and bin addressing at every legal size: a sine on bin N/8 has |X|/N = 0.21 there
  /// and 0.125 / 0.02 on its neighbours. Measured float32 error is about 1e-7 at every size.
  @Test func sineOnBinAtEveryLegalSize() {
    for p in 5...15 {
      let n = 1 << p
      let k = n / 8
      let m = spectrum(sine(n, bin: Double(k)), size: n)
      let want = [0.02, 0.125, 0.21, 0.125, 0.02]
      for (i, w) in want.enumerated() {
        #expect(
          abs(Double(m[k - 2 + i]) - w) <= 1e-6 * w, "N=\(n) bin \(k - 2 + i): \(m[k - 2 + i])")
      }
      for i in m.indices where abs(i - k) > 2 { #expect(m[i] < 1e-7, "N=\(n) bin \(i) = \(m[i])") }
    }
  }

  // MARK: Spectra with closed forms

  /// A sine of amplitude A exactly on bin k: |X_k|/N = A * 0.42 / 2 (coherent gain 0.42), and
  /// since the periodic Blackman window's DFT is non-zero only at bins 0, +-1, +-2
  /// (0.42, -0.25, 0.04) the spectrum is exactly five bins wide: 0.04/2, 0.25/2, 0.42/2 times A.
  @Test func sineOnBinHasTheBlackmanMainLobe() {
    let m = spectrum(sine(256, bin: 16), size: 256)
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    a.analyse(sine(256, bin: 16))
    let db = a.decibels()
    let peak = m.indices.max { m[$0] < m[$1] }!
    #expect(peak == 16)
    #expect(matches(Array(m[14...18]), [0.02, 0.125, 0.21, 0.125, 0.02]))
    // 20 log10 of those: -33.9794000867, -18.0617997398, -13.5556141053.
    let wantDB: [Float] = [
      -33.9794000867, -18.0617997398, -13.5556141053, -18.0617997398, -33.9794000867,
    ]
    for (got, want) in zip(db[14...18], wantDB) { #expect(abs(got - want) < 2e-4) }
    // Everything else is exactly 0 in theory: only float32 noise (< -126 dB) is left.
    for k in m.indices where k < 14 || k > 18 { #expect(m[k] < 1e-7, "bin \(k) = \(m[k])") }
    // Amplitude scales linearly; -6.0206 dB per halving.
    let half = spectrum(sine(256, bin: 16, amp: 0.5), size: 256)
    #expect(abs(Double(half[16]) - 0.105) < 1e-5 * 0.105)
  }

  @Test func sineMagnitudeDoesNotDependOnPhaseOrBin() {
    for (k, phase) in [(16.0, 0.7), (100.0, 2.1), (3.0, -1.0), (61.0, 4.0)] {
      let m = spectrum(sine(256, bin: k, phase: phase), size: 256)
      #expect(abs(Double(m[Int(k)]) - 0.21) < 2e-5 * 0.21, "k=\(k) phase=\(phase): \(m[Int(k)])")
    }
    // Bin 4096/N scaling too: k = 512 of N = 4096 (the measured scope's size).
    let m = spectrum(sine(4096, bin: 512, amp: 0.8), size: 4096)
    #expect(abs(Double(m[512]) - 0.168) < 5e-5 * 0.168, "\(m[512])")
  }

  /// DC: |X_0|/N = c * 0.42 (the window's mean); bin 1 gets 0.25 c and bin 2 0.04 c of leakage.
  @Test func dcInput() {
    let m = spectrum([Float](repeating: 1, count: 256), size: 256)
    #expect(matches(Array(m[0...2]), [0.42, 0.25, 0.04]))
    for k in 3..<m.count { #expect(m[k] < 1e-7, "bin \(k) = \(m[k])") }
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    a.analyse([Float](repeating: 1, count: 256))
    let db = a.decibels()
    // -7.53501419204, -12.0411998266, -27.9588001734
    #expect(abs(db[0] + 7.53501419204) < 2e-4)
    #expect(abs(db[1] + 12.0411998266) < 2e-4)
    #expect(abs(db[2] + 27.9588001734) < 2e-4)
    // A negative DC is the same magnitude.
    #expect(
      matches(
        Array(spectrum([Float](repeating: -0.5, count: 256), size: 256)[0...2]),
        [0.21, 0.125, 0.02]))
  }

  /// A Nyquist-rate input must not leak into the DC bin through the packed real transform
  /// (real[0] = DC, imag[0] = Nyquist).
  @Test func nyquistToneStaysOutOfDC() {
    let x = (0..<256).map { Float($0 % 2 == 0 ? 1 : -1) }
    let m = spectrum(x, size: 256)
    // Bins 126, 127 get the window's +-1 and +-2 leakage of the Nyquist line (bin 128 is not
    // reported): 0.25, 0.04; the packed Nyquist value must not appear in bin 0.
    #expect(matches(Array(m[126...127]), [0.04, 0.25]))
    #expect(m[0] < 1e-7)
  }

  @Test func silenceIsMinusInfinity() {
    let a = AnalyserFFT(fftSize: 256)
    #expect(a.decibels().allSatisfy(isNegativeInfinity), "before any analysis")
    a.analyse([Float](repeating: 0, count: 256))
    #expect(a.decibels().allSatisfy(isNegativeInfinity))
    #expect(a.linearMagnitudes().allSatisfy { $0 == 0 })
    #expect(a.bytes().allSatisfy { $0 == 0 })
    a.analyse([])  // nothing at all is silence too
    #expect(a.decibels().allSatisfy(isNegativeInfinity))
  }

  @Test func nonFiniteInputCountsAsSilenceInsteadOfPoisoningTheState() {
    let a = AnalyserFFT(fftSize: 64, smoothingTimeConstant: 0.5)
    a.analyse(sine(64, bin: 8))
    let s1 = a.linearMagnitudes()[8]  // 0.5 * 0.21
    var bad = sine(64, bin: 8)
    bad[10] = .nan
    a.analyse(bad)
    #expect(a.linearMagnitudes().allSatisfy { $0.isFinite })
    #expect(abs(a.linearMagnitudes()[8] - 0.5 * s1) < 1e-7, "decayed as a silent frame")
    bad[20] = .infinity
    a.analyse(bad)
    a.analyse(sine(64, bin: 8))  // and recovers
    #expect(a.linearMagnitudes().allSatisfy { $0.isFinite })
    #expect(a.linearMagnitudes()[8] > 0.04)
  }

  // MARK: Reference (naive DFT of the spec, double precision)

  @Test func n32AgainstTheSpecReference() {
    // tau 0: the raw normalised magnitudes of frame 1.
    let raw1: [Double] = [
      2.0057740191e-18, 0.00990061982172, 0.0173189519354, 0.0194063131702, 0.00105746346289,
      0.0505455386809, 0.0701567169002, 0.0391419639204, 0.0208676536235, 0.0208823360033,
      0.00157321675928, 0.0305685951819, 0.0344237720849, 0.0220680322785, 0.0233921368922,
      0.0240828329843,
    ]
    let m1 = spectrum(frames32[0], size: 32)
    // Bin 0 is a near-cancelling DC (reference 2.0e-18, below float32's reach): it can only be
    // bounded, so it is held to < 1e-8 and bins 1... are matched to 1e-5.
    #expect(m1[0] < 1e-8, "bin 0 = \(m1[0])")
    #expect(
      matches(Array(m1[1...]), Array(raw1[1...])),
      "\(firstMismatch(Array(m1[1...]), Array(raw1[1...])))")

    // tau 0.4 after three frames, then dB and bytes.
    let s04: [Double] = [
      0.0000875108526758, 0.0038215894866, 0.0111620953369, 0.0116502204215, 0.00631141373567,
      0.0209614704967, 0.026396895956, 0.0338897833923, 0.0279222366775, 0.0189266120596,
      0.0126938948579, 0.0113317182678, 0.0155751049496, 0.00693620014889, 0.0153677436376,
      0.0208480829661,
    ]
    let db04: [Double] = [
      -81.1587616904, -48.3551193298, -39.0450854488, -38.6733171546, -43.9974669868,
      -33.5715650767, -31.5689427872, -29.3986241392, -31.0809959203, -34.4585423911,
      -37.9281020644, -38.9140846312, -36.1513803651, -43.1775676696, -36.2677978584,
      -33.6186774666,
    ]
    let by04: [UInt8] = [
      68, 188, 222, 223, 204, 241, 249, 255, 251, 238, 226, 222, 232, 206, 232, 241,
    ]
    let a = AnalyserFFT(fftSize: 32, smoothingTimeConstant: 0.4)
    for f in frames32 { a.analyse(f) }
    #expect(matches(a.linearMagnitudes(), s04), "\(firstMismatch(a.linearMagnitudes(), s04))")
    let db = a.decibels()
    for k in 1..<16 {
      #expect(abs(Double(db[k]) - db04[k]) < 1e-3, "bin \(k): \(db[k]) vs \(db04[k])")
    }
    #expect(abs(Double(db[0]) - db04[0]) < 0.05, "bin 0 is a near-cancelling DC: \(db[0])")
    #expect(a.bytes() == by04)

    // tau 0.78 after three frames.
    let s078: [Double] = [
      0.0000584443550575, 0.0032118156046, 0.00820231945796, 0.00821196936329, 0.00322710013518,
      0.0147647209415, 0.0186631357947, 0.0246248773137, 0.020323733551, 0.0134324999713,
      0.00807048890533, 0.00799345361871, 0.0110197741374, 0.00568265638773, 0.0109942541915,
      0.0148226062774,
    ]
    let by078: [UInt8] = [
      55, 182, 212, 212, 182, 230, 238, 247, 241, 227, 211, 211, 221, 200, 221, 231,
    ]
    let b = AnalyserFFT(fftSize: 32, smoothingTimeConstant: 0.78)
    for f in frames32 { b.analyse(f) }
    #expect(matches(b.linearMagnitudes(), s078), "\(firstMismatch(b.linearMagnitudes(), s078))")
    #expect(b.bytes() == by078)
  }

  @Test func n4096TwoToneAgainstTheSpecReference() {
    let n = 4096
    let x = (0..<n).map { i -> Float in
      let t = Double(i)
      return Float(
        0.5 * sin((2 * Double.pi * 300.37 * t) / 4096 + 0.4)
          + 0.25 * sin((2 * Double.pi * 1234.5 * t) / 4096))
    }
    let a = AnalyserFFT(fftSize: n, smoothingTimeConstant: 0)
    a.analyse(x)
    let m = a.linearMagnitudes()
    let peak = 0.0979963407131
    let near: [(Int, Double)] = [
      (298, 0.0027614271216), (299, 0.0384307868168), (300, 0.0979963407131),
      (301, 0.0858118470882), (302, 0.0241958837137), (1233, 0.015460765894),
      (1234, 0.0462610367923), (1235, 0.0462610367674), (1236, 0.0154607659354),
    ]
    for (k, want) in near {
      #expect(
        abs(Double(m[k]) - want) <= 1e-5 * max(want, 0.01 * peak), "bin \(k): \(m[k]) vs \(want)")
    }
    // Far from both tones the reference is itself float-input noise (~1e-9); only bound it.
    for k in [0, 5, 100, 500, 1500, 2047] { #expect(m[k] < 1e-7, "bin \(k) = \(m[k])") }
    let db = a.decibels()
    #expect(abs(db[300] + 20.1758028204) < 1e-3)
    #expect(abs(db[1234] + 26.6956927629) < 1e-3)
    #expect(abs(db[299] + 28.3064144774) < 1e-3)
  }

  // MARK: Smoothing

  /// Bin 16 of a bin-centred sine: raw 0.21, 0.105, 0 over three frames. By hand:
  /// tau 0.4:  0.6*0.21 = 0.126;   0.4*0.126 + 0.6*0.105 = 0.1134;    0.4*0.1134 = 0.04536
  /// tau 0.78: 0.22*0.21 = 0.0462; 0.78*0.0462 + 0.22*0.105 = 0.059136; 0.78*0.059136 = 0.04612608
  @Test func smoothingRecurrenceByHand() {
    let frames = [
      sine(256, bin: 16), sine(256, bin: 16, amp: 0.5), [Float](repeating: 0, count: 256),
    ]
    let cases: [(Float, [Double], [Double])] = [
      (0.4, [0.126, 0.1134, 0.04536], [-17.9925890976, -18.9077389089, -26.8665390823]),
      (0.78, [0.0462, 0.059136, 0.04612608], [-26.7071604889, -24.5629610959, -26.7210690421]),
    ]
    for (tau, want, wantDB) in cases {
      let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: tau)
      for (i, f) in frames.enumerated() {
        a.analyse(f)
        let s = a.linearMagnitudes()[16]
        #expect(abs(Double(s) - want[i]) <= 1e-5 * want[i], "tau \(tau) frame \(i + 1): \(s)")
        #expect(abs(Double(a.decibels()[16]) - wantDB[i]) < 2e-4, "tau \(tau) frame \(i + 1) dB")
      }
    }
  }

  /// s_t = tau*s_{t-1} + (1-tau)*m_t for every bin, m_t the unsmoothed magnitudes, over many
  /// different frames.
  @Test func smoothingRecurrenceOnEveryBin() {
    let n = 128
    let frames: [[Float]] = (0..<8).map { mixedFrame(n, $0) }
    for tau in [Float(0), 0.4, 0.78, 0.95] {
      let a = AnalyserFFT(fftSize: n, smoothingTimeConstant: tau)
      let raw = AnalyserFFT(fftSize: n, smoothingTimeConstant: 0)
      var want = [Float](repeating: 0, count: n / 2)
      for f in frames {
        a.analyse(f)
        raw.analyse(f)
        let m = raw.linearMagnitudes()
        for k in 0..<want.count { want[k] = tau * want[k] + (1 - tau) * m[k] }
        let got = a.linearMagnitudes()
        for k in 0..<want.count {
          #expect(abs(got[k] - want[k]) <= 1e-6 * max(want[k], 0.01), "tau \(tau) bin \(k)")
        }
      }
    }
  }

  @Test func smoothingTimeConstantIsClampedAndNeverResets() {
    let a = AnalyserFFT(fftSize: 64, smoothingTimeConstant: 0.5)
    #expect(a.smoothingTimeConstant == 0.5)
    a.smoothingTimeConstant = 1.5
    #expect(a.smoothingTimeConstant == 1)
    a.smoothingTimeConstant = -0.2
    #expect(a.smoothingTimeConstant == 0)
    a.smoothingTimeConstant = 0.3
    a.smoothingTimeConstant = .nan
    #expect(a.smoothingTimeConstant == 0.3, "NaN is ignored")
    a.analyse(sine(64, bin: 8))
    let before = a.linearMagnitudes()
    a.smoothingTimeConstant = 0.9
    #expect(a.linearMagnitudes() == before, "changing tau keeps the state")
    // tau 1 freezes the state at 0 forever.
    let frozen = AnalyserFFT(fftSize: 64, smoothingTimeConstant: 1)
    frozen.analyse(sine(64, bin: 8))
    #expect(frozen.decibels().allSatisfy(isNegativeInfinity))
  }

  @Test func sizeChangeAndResetClearTheSmoothingState() {
    let x256 = sine(256, bin: 16)
    let x512 = sine(512, bin: 40)
    let tau: Float = 0.9
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: tau)
    for _ in 0..<3 { a.analyse(x256) }
    // 1 - 0.9^3 of the raw 0.21 has built up.
    #expect(abs(Double(a.linearMagnitudes()[16]) - 0.21 * (1 - 0.729)) < 1e-5)

    // Same size: no reset.
    let held = a.linearMagnitudes()
    #expect(a.setFFTSize(256))
    #expect(a.linearMagnitudes() == held)

    // Different size: state starts again from zero, like a fresh analyser.
    #expect(a.setFFTSize(512))
    #expect(a.fftSize == 512 && a.frequencyBinCount == 256)
    #expect(a.decibels().allSatisfy(isNegativeInfinity))
    a.analyse(x512)
    let fresh = AnalyserFFT(fftSize: 512, smoothingTimeConstant: tau)
    fresh.analyse(x512)
    #expect(a.linearMagnitudes() == fresh.linearMagnitudes(), "first frame after a size change")
    #expect(abs(Double(a.linearMagnitudes()[40]) - 0.21 * (1 - 0.9)) < 1e-5)

    // And back: it does not remember the earlier 256-point state either.
    #expect(a.setFFTSize(256))
    a.analyse(x256)
    #expect(abs(Double(a.linearMagnitudes()[16]) - 0.21 * (1 - 0.9)) < 1e-5)

    // reset() clears without a size change.
    a.reset()
    #expect(a.decibels().allSatisfy(isNegativeInfinity))
    a.analyse(x256)
    #expect(abs(Double(a.linearMagnitudes()[16]) - 0.21 * (1 - 0.9)) < 1e-5)
  }

  // MARK: Input window handling

  @Test func shortInputIsZeroPaddedAtTheFront() {
    let x = (0..<100).map { Float(sin(Double($0) * 0.3) * 0.5) }
    let padded = [Float](repeating: 0, count: 156) + x
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    a.analyse(x)
    let b = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    b.analyse(padded)
    #expect(a.linearMagnitudes() == b.linearMagnitudes(), "identical to padding by hand")
    // The spec reference for the same signal (front padded): bins 0...7.
    let want: [Double] = [
      0.00533301576711, 0.00536678176637, 0.00548737201824, 0.0056803748886, 0.00599650598004,
      0.00645545243251, 0.00708264767009, 0.00812612162255,
    ]
    let m = a.linearMagnitudes()
    #expect(matches(Array(m[0..<8]), want))
    // Padding at the back would give another answer (the phase differs), so this is not vacuous.
    let back = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    back.analyse(x + [Float](repeating: 0, count: 156))
    #expect(back.linearMagnitudes() != m)
  }

  /// The analyser reuses its scratch frame, which after a loud full-size analysis holds that
  /// frame's samples and magnitudes. Short input must be padded with real zeros over all of it,
  /// not over whatever the last frame left behind: on a reused analyser the answer is
  /// bit-identical to a fresh one's. (A fresh analyser's scratch is all zeros, so the test above
  /// cannot see a missing zero-fill.)
  @Test func shortInputOnAReusedAnalyserIgnoresWhatTheLastFrameLeftBehind() {
    let loud = sine(256, bin: 16)
    let x = (0..<100).map { Float(sin(Double($0) * 0.3) * 0.5) }
    let fresh = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    fresh.analyse(x)
    let reused = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    reused.analyse(loud)
    reused.analyse(x)
    #expect(reused.linearMagnitudes() == fresh.linearMagnitudes())
    // Several shapes of short input after loud frames, each against a fresh analyser.
    for count in [1, 7, 128, 200, 255] {
      let short = (0..<count).map { Float(sin(Double($0) * 0.3) * 0.5) }
      let want = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
      want.analyse(short)
      reused.analyse(loud)
      reused.analyse(short)
      #expect(reused.linearMagnitudes() == want.linearMagnitudes(), "count \(count)")
    }
    // No input at all after a loud frame is silence, not the previous frame again.
    reused.analyse(loud)
    reused.analyse([])
    #expect(reused.linearMagnitudes().allSatisfy { $0 == 0 })
    #expect(reused.decibels().allSatisfy(isNegativeInfinity))
  }

  @Test func longInputContributesItsNewestSamples() {
    let n = 128
    let long = (0..<1000).map { Float(sin(Double($0) * 0.21) * 0.4) }
    let a = AnalyserFFT(fftSize: n, smoothingTimeConstant: 0)
    a.analyse(long)
    let b = AnalyserFFT(fftSize: n, smoothingTimeConstant: 0)
    b.analyse(Array(long.suffix(n)))
    #expect(a.linearMagnitudes() == b.linearMagnitudes())
    let c = AnalyserFFT(fftSize: n, smoothingTimeConstant: 0)
    c.analyse(long[600..<1000])  // ArraySlice overload
    #expect(c.linearMagnitudes() == b.linearMagnitudes())
  }

  @Test func timeDomainIsTheNewestFFTSizeSamples() {
    let a = AnalyserFFT(fftSize: 32)
    let ramp = (0..<100).map { Float($0) }
    #expect(a.timeDomain(window: ramp) == (68..<100).map { Float($0) }, "newest 32")
    #expect(
      a.timeDomain(window: Array(ramp[0..<20])) == [Float](repeating: 0, count: 12) + ramp[0..<20])
    #expect(a.timeDomain(window: []) == [Float](repeating: 0, count: 32))
    #expect(a.timeDomain(window: ramp).count == a.fftSize)
    // The ArraySlice overload (startIndex != 0): the newest 32 of ramp[40..<100], and a slice
    // shorter than fftSize padded at the front.
    #expect(a.timeDomain(window: ramp[40..<100]) == (68..<100).map { Float($0) })
    #expect(
      a.timeDomain(window: ramp[40..<60]) == [Float](repeating: 0, count: 12) + ramp[40..<60])
    #expect(a.timeDomain(window: ramp[10..<10]) == [Float](repeating: 0, count: 32))
    // A short destination gets the OLDEST part of that span, as getFloatTimeDomainData does.
    var short = [Float](repeating: -1, count: 5)
    ramp.withUnsafeBufferPointer { w in
      short.withUnsafeMutableBufferPointer { a.floatTimeDomainData(window: w, into: $0) }
    }
    #expect(short == [68, 69, 70, 71, 72])
    // ...and a long destination only fills fftSize values.
    var long = [Float](repeating: -1, count: 40)
    ramp.withUnsafeBufferPointer { w in
      long.withUnsafeMutableBufferPointer { a.floatTimeDomainData(window: w, into: $0) }
    }
    #expect(Array(long[0..<32]) == (68..<100).map { Float($0) })
    #expect(Array(long[32...]) == [Float](repeating: -1, count: 8))
    // Reading the time domain does not touch the analysis state.
    let b = AnalyserFFT(fftSize: 32, smoothingTimeConstant: 0.5)
    b.analyse(ramp)
    let before = b.linearMagnitudes()
    _ = b.timeDomain(window: ramp)
    #expect(b.linearMagnitudes() == before)
  }

  @Test func destinationsShorterOrLongerThanTheBinCountAreSafe() {
    let a = AnalyserFFT(fftSize: 64, smoothingTimeConstant: 0)
    a.analyse(sine(64, bin: 8))
    let all = a.decibels()
    var short = [Float](repeating: 99, count: 10)
    short.withUnsafeMutableBufferPointer { a.floatFrequencyData(into: $0) }
    #expect(short == Array(all[0..<10]))
    var long = [Float](repeating: 99, count: 40)
    long.withUnsafeMutableBufferPointer { a.floatFrequencyData(into: $0) }
    #expect(Array(long[0..<32]) == all)
    #expect(long[32...].allSatisfy { $0 == 99 })
    var none = [Float]()
    none.withUnsafeMutableBufferPointer { a.floatFrequencyData(into: $0) }
    none.withUnsafeMutableBufferPointer { a.magnitudes(into: $0) }
  }

  // MARK: Byte data

  /// getByteFrequencyData: 255 * (dB + 100) / 70, clamped, TRUNCATED (not rounded).
  @Test func byteFrequencyDataTruncates() {
    // Amplitude 0.001 on bin 16: 0.00021, 0.000125, 0.00002 (bins 16, 15/17, 14/18) =
    // -73.5556, -78.0618, -93.9794 dB -> 96.33, 79.92, 21.93 -> 96, 79, 21 (rounding: 80, 22).
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    a.analyse(sine(256, bin: 16, amp: 0.001))
    let b = a.bytes()
    #expect(Array(b[14...18]) == [21, 79, 96, 79, 21])
    #expect(b.enumerated().allSatisfy { (14...18).contains($0.offset) || $0.element == 0 })
    // A loud signal clamps at 255, silence is 0.
    a.analyse(sine(256, bin: 16))
    #expect(a.bytes()[16] == 255)
    // A custom range maps -80...-20: bin 16 at -73.5556 dB -> 255 * 6.4444 / 60 = 27.39.
    let c = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    c.minDecibels = -80
    c.maxDecibels = -20
    c.analyse(sine(256, bin: 16, amp: 0.001))
    #expect(c.bytes()[16] == 27)
  }

  /// Chrome throws unless minDecibels < maxDecibels (and both are finite); here an invalid
  /// assignment is ignored and the pair stays as it was, so the byte scale is always finite and
  /// positive.
  @Test func decibelRangeRefusesAnEmptyOrInvertedOrNonFiniteRange() {
    let a = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0)
    #expect(a.minDecibels == -100 && a.maxDecibels == -30, "AnalyserNode defaults")
    func unchanged(_ what: String) {
      #expect(a.minDecibels == -100 && a.maxDecibels == -30, "\(what)")
    }
    a.minDecibels = -30
    unchanged("min == max")
    a.minDecibels = -20
    unchanged("min > max")
    a.maxDecibels = -100
    unchanged("max == min")
    a.maxDecibels = -120
    unchanged("max < min")
    for bad in [Float.nan, .infinity, -.infinity] {
      a.minDecibels = bad
      a.maxDecibels = bad
      unchanged("\(bad)")
    }
    // The bytes are still the default mapping (255 * (dB + 100) / 70, truncated).
    a.analyse(sine(256, bin: 16, amp: 0.001))
    #expect(Array(a.bytes()[14...18]) == [21, 79, 96, 79, 21])
    // A valid change is applied, whichever bound moves first as long as the order holds.
    a.maxDecibels = 0
    a.minDecibels = -50
    #expect(a.minDecibels == -50 && a.maxDecibels == 0)
    // -73.5556 dB is below -50: 0; the range is 50 wide now, so a -20 dB bin is 255 * 30 / 50.
    #expect(a.bytes()[16] == 0)
    a.analyse(sine(256, bin: 16, amp: 0.4762))  // bin 16: 0.4762 * 0.21 = 0.1 = -20 dB
    #expect(a.bytes()[16] == 153)
  }

  // MARK: Callers' conventions

  @Test func callerConventions() {
    // scope.js: only bins above -200 dB add 10^(dB/10) to a band's power.
    #expect(AnalyserFFT.measuredPower(decibels: -Float.infinity) == 0)
    #expect(AnalyserFFT.measuredPower(decibels: -200) == 0, "the test is `db > -200`")
    #expect(AnalyserFFT.measuredPower(decibels: -250) == 0)
    #expect(abs(AnalyserFFT.measuredPower(decibels: -199.99) - 1.0023e-20) < 1e-23)
    #expect(abs(AnalyserFFT.measuredPower(decibels: -10) - 0.1) < 1e-12)
    #expect(AnalyserFFT.measuredPower(decibels: 0) == 1)
    #expect(AnalyserFFT.measuredFloorDecibels == -200)
    // Corona: Math.max(-100, Math.min(0, db)).
    #expect(AnalyserFFT.clamped(decibels: -Float.infinity, to: -100...0) == -100)
    #expect(AnalyserFFT.clamped(decibels: -140, to: -100...0) == -100)
    #expect(AnalyserFFT.clamped(decibels: -42.5, to: -100...0) == -42.5)
    #expect(AnalyserFFT.clamped(decibels: 6, to: -100...0) == 0)
  }
}
