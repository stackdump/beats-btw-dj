import Accelerate
import Foundation

/// Long-term average spectrum of a stereo render, in third-octave bands from 25 Hz to 16 kHz:
/// the tonal balance a reference track is compared by (ROADMAP 6.1), and the mastering and
/// translation checks built on it (6.6: slope, no 16 kHz bump, fold to mono).
///
/// One Welch pass (Hann, `fftSize` points, 50 % overlap, vDSP) over both channels; the mono
/// spectrum is (X_L + X_R) / 2 from the same FFTs. A long render is decimated, not cut: past
/// `maxSegments` the segments are spread evenly over the whole render, so the cost stays at
/// `2 × maxSegments` FFTs however long it is.
public struct Spectrum: Sendable {
  public static let fftSize = 8192
  public static let maxSegments = 256
  /// Nominal third-octave centres (IEC 61260), 25 Hz … 16 kHz; the exact centres are
  /// 1000 · 2^(k/3).
  public static let bandsHz: [Double] = [
    25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
    1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000,
  ]
  /// The slope fit's range (exit M7): 63 Hz … 8 kHz.
  public static let slopeRange: ClosedRange<Double> = 63...8000
  /// The bands the 16 kHz bump is read in.
  public static let bumpBands: [Double] = [12500, 16000]

  /// Mono power spectral density per band, dB re full scale² per Hz (the mean of the band's
  /// bins): white noise is flat, pink noise falls 3 dB an octave. −200 for a silent band or
  /// one past Nyquist.
  public var ltasDB: [Double]
  /// Least-squares slope of `ltasDB` against octaves over `slopeRange`, dB per octave.
  public var slopeDBPerOct = 0.0
  /// The fit's level at 1 kHz, dB (its intercept).
  public var fitAt1kDB = -200.0
  /// How far the 12.5 and 16 kHz bands sit over the fit extrapolated to them, dB (mean):
  /// a bright top end that does not follow the rest of the mix.
  public var hfBumpDB = 0.0
  /// Per band: energy of (L + R) / 2 against the mean of L² and R², dB. 0 for a mono band,
  /// −3 for uncorrelated channels, down to −100 when L = −R cancels.
  public var monoFoldLossDB: [Double]
  /// The same over every band together (25 Hz … 16 kHz).
  public var monoFoldDB = 0.0

  public init(left: [Float], right: [Float], sampleRate sr: Double) {
    let bands = Self.bandsHz.count
    ltasDB = [Double](repeating: -200, count: bands)
    monoFoldLossDB = [Double](repeating: 0, count: bands)
    let n = min(left.count, right.count)
    let size = Self.fftSize
    let half = size / 2
    guard n >= size, sr > 0 else { return }
    let log2n = vDSP_Length(log2(Double(size)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
    defer { vDSP_destroy_fftsetup(setup) }

    // segment starts: every half window, or `maxSegments` spread evenly over the render
    let hop = size / 2
    let available = (n - size) / hop + 1
    let count = min(available, Self.maxSegments)
    let starts: [Int] =
      count == available
      ? (0..<count).map { $0 * hop }
      : (0..<count).map { (n - size) * $0 / max(1, count - 1) }

    var window = [Float](repeating: 0, count: size)
    vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    var w2: Float = 0
    vDSP_svesq(window, 1, &w2, vDSP_Length(size))

    var psdL = [Float](repeating: 0, count: half + 1)
    var psdR = psdL
    var psdM = psdL
    var bufL = [Float](repeating: 0, count: size)
    var bufR = bufL
    var reL = [Float](repeating: 0, count: half)
    var imL = reL
    var reR = reL
    var imR = reL
    var reM = reL
    var imM = reL
    var mag = reL
    left.withUnsafeBufferPointer { lp in
      right.withUnsafeBufferPointer { rp in
        for s in starts {
          vDSP_vmul(lp.baseAddress! + s, 1, window, 1, &bufL, 1, vDSP_Length(size))
          vDSP_vmul(rp.baseAddress! + s, 1, window, 1, &bufR, 1, vDSP_Length(size))
          Self.fft(setup, log2n, &bufL, &reL, &imL)
          Self.fft(setup, log2n, &bufR, &reR, &imR)
          var h: Float = 0.5
          vDSP_vasm(reL, 1, reR, 1, &h, &reM, 1, vDSP_Length(half))
          vDSP_vasm(imL, 1, imR, 1, &h, &imM, 1, vDSP_Length(half))
          // packed: imag[0] is the Nyquist bin's real part
          psdL[half] += imL[0] * imL[0]
          psdR[half] += imR[0] * imR[0]
          psdM[half] += imM[0] * imM[0]
          imL[0] = 0
          imR[0] = 0
          imM[0] = 0
          Self.accumulate(&reL, &imL, &mag, &psdL)
          Self.accumulate(&reR, &imR, &mag, &psdR)
          Self.accumulate(&reM, &imM, &mag, &psdM)
        }
      }
    }
    // zrip returns 2 × the DFT; one-sided PSD = 2 |X|² / (fs Σw²), averaged over segments
    let scale = 2 / (4 * sr * Double(w2) * Double(starts.count))
    let binHz = sr / Double(size)

    var totalMono = 0.0
    var totalMean = 0.0
    for b in Self.bandsHz.indices {
      let fc = 1000 * pow(2, Double(b - 16) / 3)
      let lo = fc / pow(2, 1.0 / 6)
      let hi = fc * pow(2, 1.0 / 6)
      guard hi < sr / 2 else { continue }
      var first = Int((lo / binHz).rounded(.up))
      var last = Int((hi / binHz).rounded(.up)) - 1
      if last < first {  // a band narrower than a bin: its nearest one
        first = Int((fc / binHz).rounded())
        last = first
      }
      var m = 0.0
      var mean = 0.0
      for k in first...min(last, half) {
        m += Double(psdM[k])
        mean += (Double(psdL[k]) + Double(psdR[k])) / 2
      }
      totalMono += m
      totalMean += mean
      let bins = Double(min(last, half) - first + 1)
      if m > 0 { ltasDB[b] = 10 * log10(m * scale / bins) }
      if mean > 0 { monoFoldLossDB[b] = max(-100, 10 * log10(max(m, 1e-30) / mean)) }
    }
    if totalMean > 0 { monoFoldDB = max(-100, 10 * log10(max(totalMono, 1e-30) / totalMean)) }

    // the slope: least squares of level against octaves from 1 kHz
    var xs: [Double] = []
    var ys: [Double] = []
    for (b, f) in Self.bandsHz.enumerated() where Self.slopeRange.contains(f) && ltasDB[b] > -190 {
      xs.append(Double(b - 16) / 3)
      ys.append(ltasDB[b])
    }
    guard xs.count >= 2 else { return }
    let mx = xs.reduce(0, +) / Double(xs.count)
    let my = ys.reduce(0, +) / Double(ys.count)
    var sxy = 0.0
    var sxx = 0.0
    for i in xs.indices {
      sxy += (xs[i] - mx) * (ys[i] - my)
      sxx += (xs[i] - mx) * (xs[i] - mx)
    }
    slopeDBPerOct = sxx > 0 ? sxy / sxx : 0
    fitAt1kDB = my - slopeDBPerOct * mx
    var bump: [Double] = []
    for (b, f) in Self.bandsHz.enumerated() where Self.bumpBands.contains(f) && ltasDB[b] > -190 {
      bump.append(ltasDB[b] - (fitAt1kDB + slopeDBPerOct * Double(b - 16) / 3))
    }
    if !bump.isEmpty { hfBumpDB = bump.reduce(0, +) / Double(bump.count) }
  }

  /// In-place real FFT of `buf` (zrip, packed) into `re` / `im`.
  private static func fft(
    _ setup: FFTSetup, _ log2n: vDSP_Length, _ buf: inout [Float], _ re: inout [Float],
    _ im: inout [Float]
  ) {
    let half = buf.count / 2
    re.withUnsafeMutableBufferPointer { r in
      im.withUnsafeMutableBufferPointer { i in
        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
        buf.withUnsafeBytes {
          vDSP_ctoz(
            $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
      }
    }
  }

  /// `psd[0..<half] += |re + i·im|²`.
  private static func accumulate(
    _ re: inout [Float], _ im: inout [Float], _ mag: inout [Float], _ psd: inout [Float]
  ) {
    let half = re.count
    re.withUnsafeMutableBufferPointer { r in
      im.withUnsafeMutableBufferPointer { i in
        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
        vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(half))
      }
    }
    psd.withUnsafeMutableBufferPointer { p in
      vDSP_vadd(p.baseAddress!, 1, mag, 1, p.baseAddress!, 1, vDSP_Length(half))
    }
  }
}
