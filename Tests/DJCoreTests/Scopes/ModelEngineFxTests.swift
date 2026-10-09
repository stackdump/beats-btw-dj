import Darwin
import Testing

@testable import DJCore

// The FX response: scope-model.js `biquadMag2` and `fxResponse` against node, and the deck chain
// (DJ filter, EQ bands, faders) against the real AVAudioUnitEQ and the real engine.

private func close(_ a: Double, _ b: Double, rel: Double = 1e-9, abs floor: Double = 0) -> Bool {
  Swift.abs(a - b) <= rel * Swift.abs(b) + floor
}

private func db(_ power: Double) -> Double { 10 * log10(power) }

/// |H(f)|² of everything in `fx` at one frequency (no gain), through the same coefficients.
private func response(_ fx: DeckFx, at f: Double, sampleRate: Double) -> Double {
  var m = 1.0
  func pass(_ kind: ModelPassKind, _ p: DeckFx.Pass?) {
    guard let p,
      let c = BiquadCoefficients.pass(kind, fc: p.fc, qDb: p.qDb, sampleRate: sampleRate)
    else { return }
    m *= pow(c.magnitude2(at: f, sampleRate: sampleRate), Double(p.stages))
  }
  pass(.highpass, fx.highPass)
  pass(.lowpass, fx.lowPass)
  if let s = fx.lowShelf {
    m *= BiquadCoefficients.shelf(low: true, fc: s.fc, gainDb: s.gainDb, sampleRate: sampleRate)!
      .magnitude2(at: f, sampleRate: sampleRate)
  }
  if let p = fx.mid {
    m *= BiquadCoefficients.peak(
      fc: p.fc, gainDb: p.gainDb, bandwidth: p.bandwidth, sampleRate: sampleRate)!
      .magnitude2(at: f, sampleRate: sampleRate)
  }
  if let s = fx.highShelf {
    m *= BiquadCoefficients.shelf(low: false, fc: s.fc, gainDb: s.gainDb, sampleRate: sampleRate)!
      .magnitude2(at: f, sampleRate: sampleRate)
  }
  return m
}

struct ModelBiquadTests {
  @Test func theWebAudioLowAndHighPassAgainstNode() {
    for (type, fc, qDb, f, rate, want) in ModelOracle.biquad {
      let kind: ModelPassKind = type == "lowpass" ? .lowpass : .highpass
      let got = ModelFx.biquadMag2(kind, fc: fc, qDb: qDb, f: f, sampleRate: rate)
      #expect(
        close(got, want, rel: 1e-12),
        "\(type) fc \(fc) q \(qDb) f \(f) sr \(rate): \(got) vs \(want)")
    }
  }

  @Test func theClosedFormsAtTheCorner() {
    let qb = DeckFx.butterworthQDb
    #expect(close(qb, -3.0102999566398120, rel: 1e-12), "20·log10(1/√2)")
    let at = { (kind: ModelPassKind, fc: Double, f: Double) in
      ModelFx.biquadMag2(kind, fc: fc, qDb: qb, f: f, sampleRate: 44100)
    }
    // Butterworth: half power at the corner, wherever the corner is
    for fc in [100.0, 1000, 5000, 15000] {
      #expect(
        close(at(.lowpass, fc, fc), 0.5, rel: 1e-9) && close(at(.highpass, fc, fc), 0.5, rel: 1e-9))
    }
    // a resonant peak of Q dB at the corner: |H|² = Q² (Q = 6 dB -> 3.98)
    #expect(
      close(
        ModelFx.biquadMag2(.lowpass, fc: 1000, qDb: 6, f: 1000, sampleRate: 44100), pow(10, 0.6),
        rel: 1e-9))
    // the two are complementary at every frequency for a Butterworth pair
    for f in [50.0, 300, 1000, 3000, 9000] {
      #expect(close(at(.lowpass, 1000, f) + at(.highpass, 1000, f), 1, rel: 1e-9), "\(f) Hz")
    }
    // low-pass falls ~12 dB/oct above the corner, high-pass rises ~12 dB/oct below it
    let drop = db(at(.lowpass, 100, 400)) - db(at(.lowpass, 100, 800))
    #expect(abs(drop - 12) < 0.4, "\(drop) dB per octave")
    let rise = db(at(.highpass, 2000, 500)) - db(at(.highpass, 2000, 250))
    #expect(abs(rise - 12) < 0.4, "\(rise) dB per octave")
  }

  @Test func aCornerOutsideTheSpectrumIsNoFilter() {
    // JS: !(fc > 0) || !(fc < sr / 2) -> 1
    for fc in [0.0, -5, 22_050, 30_000, .nan, .infinity] {
      #expect(
        ModelFx.biquadMag2(.lowpass, fc: fc, qDb: 0, f: 1000, sampleRate: 44100) == 1, "\(fc)")
    }
    // a non-finite Q reads as 0 dB
    let a = ModelFx.biquadMag2(.highpass, fc: 1000, qDb: .nan, f: 700, sampleRate: 44100)
    let b = ModelFx.biquadMag2(.highpass, fc: 1000, qDb: 0, f: 700, sampleRate: 44100)
    #expect(a == b)
    #expect(ModelFx.isParked(.lowpass, fc: 19_000) && ModelFx.isParked(.lowpass, fc: 20_000))
    #expect(!ModelFx.isParked(.lowpass, fc: 18_999))
    #expect(ModelFx.isParked(.highpass, fc: 25) && ModelFx.isParked(.highpass, fc: 20))
    #expect(!ModelFx.isParked(.highpass, fc: 25.5))
  }
}

struct ModelFxResponseTests {
  private func rows(_ fx: DeckFx, rate: Double) -> [Double] {
    ModelFx.response(fx, sampleRate: rate).map(Double.init)
  }

  private func same(_ got: [Double], _ want: [Double], rel: Double = 1e-5) -> Bool {
    got.count == want.count && zip(got, want).allSatisfy { close($0, $1, rel: rel, abs: 1e-12) }
  }

  @Test func filtersAndGainAgainstTheJavaScript() {
    let q = DeckFx.butterworthQDb
    #expect(same(rows(DeckFx(lowPass: .init(fc: 800), gain: 1), rate: 44100), ModelOracle.fxLp800))
    // gain 0.5 is a gain² of 0.25 in the JS call (`resp(0.5, ...)` fills .5 there: g2)
    let hp = rows(DeckFx(highPass: .init(fc: 400, qDb: q), gain: 0.5.squareRoot()), rate: 48000)
    #expect(same(hp, ModelOracle.fxHp400Gain05))
    let both = rows(
      DeckFx(highPass: .init(fc: 120), lowPass: .init(fc: 6000), gain: 0.5), rate: 48000)
    #expect(same(both, ModelOracle.fxBoth))
    #expect(same(rows(DeckFx(lowPass: .init(fc: 19_000)), rate: 44100), ModelOracle.fxParkedLp))
    #expect(same(rows(DeckFx(highPass: .init(fc: 25)), rate: 44100), ModelOracle.fxParkedHp))
    #expect(
      same(
        rows(DeckFx(lowPass: .init(fc: 1000, qDb: 0, stages: 2)), rate: 44100),
        ModelOracle.fxTwoStages))
  }

  @Test func noFilterMeansGainSquaredInEveryRow() {
    for g in [1.0, 0.8, 0.25, 0] {
      #expect(rows(DeckFx(gain: g), rate: 44100).allSatisfy { close($0, g * g, rel: 1e-6) })
    }
    // a parked filter changes nothing; so does a flat EQ band
    let parked = DeckFx(
      highPass: .init(fc: 20), lowPass: .init(fc: 20_000), lowShelf: nil, gain: 0.5)
    #expect(rows(parked, rate: 48000).allSatisfy { close($0, 0.25, rel: 1e-6) })
  }

  @Test func theRowIsTheMeanOverItsFourProbes() {
    // Hand-built: a low-pass at 1 kHz, row 'lomid' (250-2000), the four probes by hand.
    let fx = DeckFx(lowPass: .init(fc: 1000))
    var want = 0.0
    for p in 0..<4 {
      want += ModelFx.biquadMag2(
        .lowpass, fc: 1000, qDb: DeckFx.butterworthQDb,
        f: ModelGrid.probeFrequencies[2 * 4 + p], sampleRate: 44100)
    }
    want /= 4
    #expect(close(rows(fx, rate: 44100)[2], want, rel: 1e-6))
    // pass bands stay near 1, stop bands fall
    let r = rows(fx, rate: 44100)
    #expect(r[0] > 0.99 && r[4] < 0.01)
    #expect(zip(r.dropFirst(5), r.dropFirst(6)).allSatisfy { $0 >= $1 }, "monotone down the bins")
  }

  @Test func theResponseGoesWhereItIsAsked() {
    var out = [Float](repeating: -1, count: 66)
    ModelFx.response(DeckFx(gain: 2), sampleRate: 44100, into: &out, at: 33)
    #expect(out[0..<33].allSatisfy { $0 == -1 }, "the first deck's rows are untouched")
    #expect(out[33...].allSatisfy { $0 == 4 })
  }
}

struct ModelEQMatchesAppleTests {
  // The filter shapes are not guessed: AVAudioUnitEQ is rendered offline (an impulse through
  // one band, DFT of 32768 samples) and compared with the RBJ forms in ModelEngineFx.swift.
  // The fit is tight (< 1e-4 dB when this was written); the tolerance leaves room for float
  // rounding in the AU. Only responses above -60 dB are compared (the AU's float noise floor).
  private func compare(
    _ name: String, type: EQShape, fc: Float, bw: Float, gain: Float,
    rate: Double, coefficients: (Double) -> BiquadCoefficients?
  ) throws {
    let freqs: [Double] = [100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 9000]
      .filter { $0 < rate / 2 * 0.95 }
    let measured = measureEQBand(
      type: type, frequency: fc, bandwidth: bw, gainDb: gain, sampleRate: rate, at: freqs)
    let c = try #require(coefficients(rate))
    for (f, m) in zip(freqs, measured) where m > 1e-6 {
      let model = c.magnitude2(at: f, sampleRate: rate)
      #expect(
        abs(db(m) - db(model)) < 0.02, "\(name) @ \(f) Hz: AU \(db(m)) dB, model \(db(model)) dB")
    }
  }

  @Test(arguments: [44_100.0, 22_050.0])
  func theDJFilterIsAButterworthThatIgnoresBandwidth(rate: Double) throws {
    for (type, kind) in [(EQShape.lowPass, ModelPassKind.lowpass), (.highPass, .highpass)] {
      for (fc, bw) in [(1000, 1.5), (300, 0.5), (3000, 3.0)] as [(Float, Float)] {
        try compare("\(kind) fc \(fc) bw \(bw)", type: type, fc: fc, bw: bw, gain: 0, rate: rate) {
          BiquadCoefficients.pass(kind, fc: Double(fc), qDb: DeckFx.butterworthQDb, sampleRate: $0)
        }
      }
    }
  }

  @Test(arguments: [44_100.0, 22_050.0])
  func theShelvesAreSlopeOneAndIgnoreBandwidth(rate: Double) throws {
    for (g, bw) in [(6, 1.5), (-24, 1.5), (3.6, 0.5), (-12, 3.0)] as [(Float, Float)] {
      try compare(
        "low shelf \(g) dB bw \(bw)", type: .lowShelf, fc: 250, bw: bw, gain: g, rate: rate
      ) {
        BiquadCoefficients.shelf(low: true, fc: 250, gainDb: Double(g), sampleRate: $0)
      }
      try compare(
        "high shelf \(g) dB bw \(bw)", type: .highShelf, fc: 4000, bw: bw, gain: g, rate: rate
      ) {
        BiquadCoefficients.shelf(low: false, fc: 4000, gainDb: Double(g), sampleRate: $0)
      }
    }
  }

  @Test(arguments: [44_100.0, 22_050.0])
  func theMidBandIsAPeakWithItsBandwidthInOctaves(rate: Double) throws {
    for (g, bw) in [(6, 1.5), (-24, 1.5), (-14.4, 0.5), (4, 3.0)] as [(Float, Float)] {
      try compare("peak \(g) dB bw \(bw)", type: .parametric, fc: 1000, bw: bw, gain: g, rate: rate)
      {
        BiquadCoefficients.peak(fc: 1000, gainDb: Double(g), bandwidth: Double(bw), sampleRate: $0)
      }
    }
  }
}

struct DeckFxTests {
  @Test func aCentredDeckHasNoFiltersAndAKnobShowsUp() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let d = try #require(dj["A"])
    #expect(DeckFx(deck: d, gain: 1) == DeckFx(gain: 1), "knobs at centre: nothing in the path")
    d.filter = 0.2  // low-pass from 20 kHz down: t = (0.45 - 0.2)/0.45
    var fx = DeckFx(deck: d, gain: 1)
    let lp = try #require(fx.lowPass)
    #expect(fx.highPass == nil)
    #expect(close(lp.fc, 20_000 * pow(0.01, 0.25 / 0.45), rel: 1e-6) && lp.stages == 1)
    #expect(close(lp.qDb, DeckFx.butterworthQDb, rel: 1e-12))
    d.filter = 0.9  // high-pass up from 20 Hz: t = (0.9 - 0.55)/0.45
    fx = DeckFx(deck: d, gain: 1)
    #expect(fx.lowPass == nil)
    #expect(close(try #require(fx.highPass).fc, 20 * pow(250.0, 0.35 / 0.45), rel: 1e-6))
    d.filter = 0.5
    d.eqLow = 0.8  // +6·0.6 dB shelf at 250
    d.eqMid = 0.2  // -24·0.6 dB peak at 1 kHz, 1.5 octaves
    d.eqHigh = 1.0  // +6 dB shelf at 4 kHz
    fx = DeckFx(deck: d, gain: 0.5)
    let low = try #require(fx.lowShelf)
    #expect(close(low.fc, 250, rel: 1e-6) && close(low.gainDb, 3.6, rel: 1e-6))
    let mid = try #require(fx.mid)
    #expect(
      close(mid.fc, 1000, rel: 1e-6) && close(mid.gainDb, -14.4, rel: 1e-6) && mid.bandwidth == 1.5)
    let high = try #require(fx.highShelf)
    #expect(close(high.fc, 4000, rel: 1e-6) && close(high.gainDb, 6, rel: 1e-6))
    #expect(fx.gain == 0.5)
    // a knob within 0.01 of centre is bypassed by the deck, so it is out of the path here too
    d.eqLow = 0.505
    d.eqMid = 0.5
    d.eqHigh = 0.4951
    fx = DeckFx(deck: d, gain: 1)
    #expect(fx.lowShelf == nil && fx.mid == nil && fx.highShelf == nil)
  }

  @Test func theRealChainHasTheModelledPowerGain() throws {
    // Sines through deck A of an offline engine with the filter, EQ, trim, fader, crossfader and
    // master moved. Two renders per frequency: with the gains only (the reference: the
    // turntable's own interpolation droops the top end by up to a dB, which is not the model's
    // business), and with the filter and EQ as well. The reference must be gain² (checked at
    // 200 Hz, where the droop is 0.003 dB); the ratio must be DeckFx's |H|².
    struct Setup {
      var filter: Double
      var low: Double
      var mid: Double
      var high: Double
      var volume: Double
      var trim: Double
      var cross: Double
      var master: Double
    }
    let setups = [
      Setup(
        filter: 0.2, low: 1.0, mid: 0.2, high: 0.9, volume: 0.6, trim: 0.7, cross: 0.3, master: 0.8),
      Setup(
        filter: 0.9, low: 0.1, mid: 0.8, high: 0.2, volume: 1.0, trim: 0.5, cross: 0.0, master: 1.0),
    ]
    for s in setups {
      func gains(_ dj: DJEngine, _ deck: Deck) -> Double {
        deck.volume = s.volume
        deck.gain = s.trim
        dj.crossfader = s.cross
        dj.master = s.master
        let g = deck.trim * deck.volume * dj.crossfadeGain("A") * dj.master
        return g * g
      }
      var gain2 = 0.0
      let flat = try deckPowerGain(freq: 200) { dj, deck in gain2 = gains(dj, deck) }
      #expect(abs(db(flat) - db(gain2)) < 0.05, "\(s): gain² \(db(flat)) dB vs \(db(gain2)) dB")
      for f in [200.0, 700, 1500, 3500] {
        let reference = try deckPowerGain(freq: f) { dj, deck in _ = gains(dj, deck) }
        var expected = 0.0
        let measured = try deckPowerGain(freq: f) { dj, deck in
          _ = gains(dj, deck)
          deck.filter = s.filter
          deck.eqLow = s.low
          deck.eqMid = s.mid
          deck.eqHigh = s.high
          expected = response(DeckFx(deck: deck, gain: 1), at: f, sampleRate: 22_050)
        }
        #expect(
          abs(db(measured) - db(reference) - db(expected)) < 0.1,
          "\(s) @ \(f) Hz: engine \(db(measured) - db(reference)) dB, model \(db(expected)) dB")
      }
    }
  }
}
