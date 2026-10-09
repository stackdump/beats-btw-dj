// ModelEngine, part 3: the FX response |H_fx|² per spectrogram/band row.
//
// scope-model.js `fxResponse` reads the live Tone engine (master HP/LP, per-channel strip HP/LP,
// channel volume) and fills `out[ch·NR + j]` with the power response of the effects chain in
// row j: the mean over PROBES = 4 log-spaced probe frequencies of |H(f)|² for every filter, times
// the gain². Here the chain is a DECK's: the one-knob DJ filter (an LP and an HP biquad of
// `Deck.filterNode`), the three EQ bands (low shelf, mid peak, high shelf), and the gain of the
// strip. The numbers come from the live state of the deck's `AVAudioUnitEQ` bands, not from the
// knob positions, so whatever moves a band shows up in the model.
//
// What the equalizer really is (verified, not assumed: `ModelEngineFxTests` renders an
// `AVAudioUnitEQ` offline and measures it; the fits below agree to better than 1e-4 dB):
//   * `.lowPass` / `.highPass` are 2nd-order Butterworth (RBJ biquads, Q = 1/√2) and IGNORE
//     `bandwidth`. In the Web Audio vocabulary of `biquadMag2` (Q in dB) that is
//     Q = 20·log10(1/√2) = -3.0103 dB, one stage (12 dB/oct). So the JS function is used as is.
//   * `.parametric` is the RBJ peaking filter with
//     α = sin w0 · sinh(ln 2 / 2 · BW · w0 / sin w0), BW = `bandwidth` in octaves.
//   * `.lowShelf` / `.highShelf` are the RBJ shelves with slope S = 1 (α = sin w0 / √2) and also
//     ignore `bandwidth`; the gain at the corner is half the dB gain.
// The shelves and the peak are an intentional addition to the JS (the beats chain has no EQ).

@preconcurrency import AVFoundation
import Foundation

/// Which edge of the band a pass filter keeps.
public enum ModelPassKind: Sendable {
  case lowpass
  case highpass
}

/// One biquad, normalised as the Web Audio spec writes it (a0 kept, not divided out).
struct BiquadCoefficients: Equatable, Sendable {
  var b0: Double
  var b1: Double
  var b2: Double
  var a0: Double
  var a1: Double
  var a2: Double

  /// |H(f)|² at `f` for a filter running at `sr`. A degenerate denominator reads as 1.
  func magnitude2(at f: Double, sampleRate sr: Double) -> Double {
    let w = 2 * Double.pi * f / sr
    let c1 = cos(w)
    let s1 = sin(w)
    let c2 = cos(2 * w)
    let s2 = sin(2 * w)
    let nr = b0 + b1 * c1 + b2 * c2
    let ni = -(b1 * s1 + b2 * s2)
    let dr = a0 + a1 * c1 + a2 * c2
    let di = -(a1 * s1 + a2 * s2)
    let d = dr * dr + di * di
    return d > 0 ? (nr * nr + ni * ni) / d : 1
  }

  /// Web Audio lowpass/highpass; Q is in dB. Nil if the corner is not strictly inside (0, sr/2).
  static func pass(_ kind: ModelPassKind, fc: Double, qDb: Double, sampleRate sr: Double)
    -> BiquadCoefficients?
  {
    guard fc > 0, fc < sr / 2 else { return nil }
    let w0 = 2 * Double.pi * fc / sr
    let cw = cos(w0)
    let alpha = sin(w0) / (2 * pow(10, (qDb.isFinite ? qDb : 0) / 20))
    let b0: Double
    let b1: Double
    switch kind {
    case .lowpass:
      b0 = (1 - cw) / 2
      b1 = 1 - cw
    case .highpass:
      b0 = (1 + cw) / 2
      b1 = -(1 + cw)
    }
    return BiquadCoefficients(b0: b0, b1: b1, b2: b0, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
  }

  /// RBJ peaking EQ with the bandwidth in octaves. Nil for an invalid corner.
  static func peak(fc: Double, gainDb: Double, bandwidth: Double, sampleRate sr: Double)
    -> BiquadCoefficients?
  {
    guard fc > 0, fc < sr / 2, bandwidth > 0 else { return nil }
    let a = pow(10, gainDb / 40)
    let w0 = 2 * Double.pi * fc / sr
    let cw = cos(w0)
    let sw = sin(w0)
    let alpha = sw * sinh(log(2.0) / 2 * bandwidth * w0 / sw)
    return BiquadCoefficients(
      b0: 1 + alpha * a, b1: -2 * cw, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * cw,
      a2: 1 - alpha / a)
  }

  /// RBJ shelf, slope S = 1. Nil for an invalid corner.
  static func shelf(low: Bool, fc: Double, gainDb: Double, sampleRate sr: Double)
    -> BiquadCoefficients?
  {
    guard fc > 0, fc < sr / 2 else { return nil }
    let a = pow(10, gainDb / 40)
    let w0 = 2 * Double.pi * fc / sr
    let cw = cos(w0)
    // α = sin w0 / (2Q) with Q = 1/√2 (slope S = 1)
    let alpha = sin(w0) * 0.5.squareRoot()
    let t = 2 * a.squareRoot() * alpha
    if low {
      return BiquadCoefficients(
        b0: a * ((a + 1) - (a - 1) * cw + t), b1: 2 * a * ((a - 1) - (a + 1) * cw),
        b2: a * ((a + 1) - (a - 1) * cw - t), a0: (a + 1) + (a - 1) * cw + t,
        a1: -2 * ((a - 1) + (a + 1) * cw), a2: (a + 1) + (a - 1) * cw - t)
    }
    return BiquadCoefficients(
      b0: a * ((a + 1) + (a - 1) * cw + t), b1: -2 * a * ((a - 1) + (a + 1) * cw),
      b2: a * ((a + 1) + (a - 1) * cw - t), a0: (a + 1) - (a - 1) * cw + t,
      a1: 2 * ((a - 1) - (a + 1) * cw), a2: (a + 1) - (a - 1) * cw - t)
  }
}

/// The state of one deck's effects chain, as the model needs it: which filters are in the
/// path and where, plus the linear gain of everything after them. A plain value, so tests can
/// build one by hand; `init(deck:gain:)` reads a live deck.
public struct DeckFx: Equatable, Sendable {
  /// A pass filter in the path (`nil`: bypassed). `stages` > 1 stacks identical biquads (Web
  /// Audio's `rolloff` -24 / -48 ...); the DJ filter is a single stage.
  public struct Pass: Equatable, Sendable {
    public var fc: Double
    public var qDb: Double
    public var stages: Int
    public init(fc: Double, qDb: Double = DeckFx.butterworthQDb, stages: Int = 1) {
      self.fc = fc
      self.qDb = qDb
      self.stages = stages
    }
  }
  public struct Shelf: Equatable, Sendable {
    public var fc: Double
    public var gainDb: Double
    public init(fc: Double, gainDb: Double) {
      self.fc = fc
      self.gainDb = gainDb
    }
  }
  public struct Peak: Equatable, Sendable {
    public var fc: Double
    public var gainDb: Double
    public var bandwidth: Double
    public init(fc: Double, gainDb: Double, bandwidth: Double) {
      self.fc = fc
      self.gainDb = gainDb
      self.bandwidth = bandwidth
    }
  }

  /// Q of Apple's low/high-pass in the Web Audio convention (dB): 20·log10(1/√2).
  public static let butterworthQDb = 20 * log10(0.5.squareRoot())

  public var highPass: Pass?
  public var lowPass: Pass?
  public var lowShelf: Shelf?
  public var mid: Peak?
  public var highShelf: Shelf?
  /// Linear amplitude of the rest of the chain (squared in the response).
  public var gain: Double

  public init(
    highPass: Pass? = nil, lowPass: Pass? = nil, lowShelf: Shelf? = nil, mid: Peak? = nil,
    highShelf: Shelf? = nil, gain: Double = 1
  ) {
    self.highPass = highPass
    self.lowPass = lowPass
    self.lowShelf = lowShelf
    self.mid = mid
    self.highShelf = highShelf
    self.gain = gain
  }

  /// A deck's live filter and EQ bands (the bypassed ones, and shelves/peaks at 0 dB, are left
  /// out), with `gain` as given.
  public init(deck: Deck, gain: Double) {
    let b = deck.filterNode.bands
    func pass(_ band: AVAudioUnitEQFilterParameters) -> Pass? {
      band.bypass ? nil : Pass(fc: Double(band.frequency))
    }
    self.init(gain: gain)
    lowPass = pass(b[0])
    highPass = pass(b[1])
    if !b[2].bypass, b[2].gain != 0 {
      lowShelf = Shelf(fc: Double(b[2].frequency), gainDb: Double(b[2].gain))
    }
    if !b[3].bypass, b[3].gain != 0 {
      mid = Peak(
        fc: Double(b[3].frequency), gainDb: Double(b[3].gain), bandwidth: Double(b[3].bandwidth))
    }
    if !b[4].bypass, b[4].gain != 0 {
      highShelf = Shelf(fc: Double(b[4].frequency), gainDb: Double(b[4].gain))
    }
  }
}

/// scope-model.js `fxResponse`, for a deck.
public enum ModelFx {
  /// Probe frequencies per row.
  public static let probes = ModelGrid.probes

  /// scope-model.js `biquadMag2`: |H(f)|² of one Web Audio low/high-pass (Q in dB). A corner that
  /// is not strictly between 0 and Nyquist reads as 1; a non-finite Q as 0 dB.
  public static func biquadMag2(
    _ kind: ModelPassKind, fc: Double, qDb: Double, f: Double, sampleRate sr: Double
  ) -> Double {
    guard let c = BiquadCoefficients.pass(kind, fc: fc, qDb: qDb, sampleRate: sr) else {
      return 1
    }
    return c.magnitude2(at: f, sampleRate: sr)
  }

  /// A pass filter parked at the edge of the spectrum (the default "open" state) is skipped, as
  /// the JS does: a low-pass at or above 19 kHz, a high-pass at or below 25 Hz.
  public static func isParked(_ kind: ModelPassKind, fc: Double) -> Bool {
    switch kind {
    case .lowpass: fc >= 19000
    case .highpass: fc <= 25
    }
  }

  /// Row-mean power response of one biquad: the mean over the row's probes of |H|².
  private static func rowMean(_ c: BiquadCoefficients, row j: Int, sampleRate sr: Double) -> Double
  {
    var m = 0.0
    for p in 0..<probes {
      m += c.magnitude2(at: ModelGrid.probeFrequencies[j * probes + p], sampleRate: sr)
    }
    return m / Double(probes)
  }

  /// Fill `out[offset ..< offset + NR]` with `gain² · Π |H_filter|²` (mean over each row's
  /// probes; a pass filter with `stages` biquads contributes the mean to the power `stages`).
  public static func response(
    _ fx: DeckFx, sampleRate sr: Double, into out: inout [Float], at offset: Int = 0
  ) {
    var factors = [Double](repeating: fx.gain * fx.gain, count: ModelGrid.nr)
    func apply(_ c: BiquadCoefficients?, stages: Int = 1) {
      guard let c else { return }
      for j in 0..<ModelGrid.nr {
        factors[j] *= pow(rowMean(c, row: j, sampleRate: sr), Double(max(1, stages)))
      }
    }
    func pass(_ kind: ModelPassKind, _ p: DeckFx.Pass?) {
      guard let p, !isParked(kind, fc: p.fc) else { return }
      apply(BiquadCoefficients.pass(kind, fc: p.fc, qDb: p.qDb, sampleRate: sr), stages: p.stages)
    }
    pass(.highpass, fx.highPass)
    pass(.lowpass, fx.lowPass)
    if let s = fx.lowShelf {
      apply(BiquadCoefficients.shelf(low: true, fc: s.fc, gainDb: s.gainDb, sampleRate: sr))
    }
    if let m = fx.mid {
      apply(
        BiquadCoefficients.peak(fc: m.fc, gainDb: m.gainDb, bandwidth: m.bandwidth, sampleRate: sr)
      )
    }
    if let s = fx.highShelf {
      apply(BiquadCoefficients.shelf(low: false, fc: s.fc, gainDb: s.gainDb, sampleRate: sr))
    }
    for j in 0..<ModelGrid.nr { out[offset + j] = Float(factors[j]) }
  }

  /// `response` as a fresh array of NR values.
  public static func response(_ fx: DeckFx, sampleRate sr: Double) -> [Float] {
    var out = [Float](repeating: 1, count: ModelGrid.nr)
    response(fx, sampleRate: sr, into: &out)
    return out
  }
}
