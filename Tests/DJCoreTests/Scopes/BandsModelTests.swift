import Darwin
import Testing

@testable import DJCore

// The numbers of the Bands scope (BandsModel): digit mapping, coverage, statistics, residual.
// Expected values come from scope.js itself: scratchpad m5/oracle.js evals the verbatim `modelDb`,
// `measDb`, `rowRefs`, `fullBar` and `scopeStats` (beats-bitwrap-io 095d030, lines 903-956) on the
// arrays that `BandsOracleData` generates, and `drawBands`'s residual rule on top.

private func close(_ a: Double?, _ b: Double, _ tol: Double = 1e-9) -> Bool {
  guard let a else { return false }
  return abs(a - b) < tol
}

struct BandsDigitTests {
  @Test func theConstantsAreTheJsOnes() {
    #expect(BandsModel.rows == 6 && BandsModel.levelDb == 4 && BandsModel.stepsPerBar == 16)
    #expect(BandsModel.labels == ["sub", "low", "lomid", "himid", "high", "E"])
  }

  @Test func theDigitIsNineMinusTheDbBelowTheLoudestBarOverFourRoundedHalfUp() {
    // clamp(round(9 - d/4), 0, 9) for d dB below the row's loudest bar; expected from
    // Math.max(0, Math.min(9, Math.round(9 - d / 4))) in node
    let table: [(Double, Int)] = [
      (0, 9), (1, 9), (1.9, 9), (2, 9), (2.0001, 8), (3.9, 8), (4, 8), (5.9, 8), (6, 8),
      (6.0001, 7), (34, 1), (34.0001, 0), (33.9, 1), (35, 0), (36, 0), (37.9, 0), (38, 0),
      (50, 0), (100, 0),
    ]
    for (d, want) in table {
      #expect(BandsModel.digit(value: -10 - d, ref: -10) == want, "\(d) dB below the loudest")
    }
  }

  @Test func eachStepOfFourDbIsOneDigitDown() {
    let ds = (0...9).map { BandsModel.digit(value: -4 * Double($0), ref: 0) }
    // 0, 4, 8 ... 36 dB below: 9 - d/4 = 9, 8, 7 ... 0
    #expect(ds == [9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
  }

  @Test func halfADigitRoundsUpAsMathRoundDoesAndTheClampMakesSwiftsRoundingAgree() {
    // 2 dB below is 8.5: Math.round -> 9 (and .rounded() -> 9). 34 dB below is 0.5 -> 1.
    #expect(BandsModel.digit(value: -2, ref: 0) == 9)
    #expect(BandsModel.digit(value: -34, ref: 0) == 1)
    // -0.5 (38 dB below): Math.round(-0.5) is -0 and .rounded() is -1; both clamp to 0
    #expect(BandsModel.digit(value: -38, ref: 0) == 0)
    #expect(jsRound(-0.5) == 0 && (-0.5).rounded() == -1)
    // and every level on a fine grid gives the digit a direct Math.round formula gives
    var n = 0
    var d = 0.0
    while d < 50 {
      let want = Int(max(0, min(9, jsRound(9 - d / 4))))
      let swiftRounding = Int(max(0, min(9, (9 - d / 4).rounded())))
      #expect(BandsModel.digit(value: -d, ref: 0) == want && want == swiftRounding)
      d += 0.0625
      n += 1
    }
    #expect(n > 700)
  }

  @Test func aCellWithNoLevelOrNoReferenceIsEmpty() {
    #expect(BandsModel.digit(value: nil, ref: 0) == nil)
    #expect(BandsModel.digit(value: -3, ref: -.infinity) == nil)
    #expect(BandsModel.digit(value: -3, ref: .nan) == nil)
    #expect(BandsModel.digit(value: .nan, ref: 0) == nil)
  }
}

struct BandsLevelTests {
  @Test func modelAndMeasuredLevelsAreTenLogTenOfThePowerAndTheMeanPower() {
    let d = BandsOracleData.make(.main)
    // scope.js modelDb / measDb at a few cells
    let want: [(bar: Int, row: Int, m: Double, x: Double)] = [
      (0, 0, -25.75, -34.6), (3, 2, -12.25, -6.050000000000001),
      (13, 5, -1.2335863659618231, -1.6960781409706203),
    ]
    for w in want {
      #expect(close(d.modelDb(bar: w.bar, row: w.row), w.m), "model \(w.bar),\(w.row)")
      #expect(close(d.measDb(bar: w.bar, row: w.row), w.x), "measured \(w.bar),\(w.row)")
    }
  }

  @Test func theMeasuredLevelIsTheMeanOverTheReadsOfTheBar() {
    // two reads of power 4 and 8: the mean is 6
    let d = BandsModel(
      modelBars: [], modelMaxBar: -1, measBars: [Double](repeating: 12, count: 6),
      measCnt: [2], measMaxBar: 0)
    #expect(close(d.measDb(bar: 0, row: 3), 10 * log10(6)))
    // no reads, or no power: no level
    let none = BandsModel(
      modelBars: [], modelMaxBar: -1, measBars: [Double](repeating: 0, count: 6), measCnt: [3],
      measMaxBar: 0)
    #expect(none.measDb(bar: 0, row: 0) == nil)
    let unread = BandsModel(
      modelBars: [], modelMaxBar: -1, measBars: [Double](repeating: 5, count: 6), measCnt: [0],
      measMaxBar: 0)
    #expect(unread.measDb(bar: 0, row: 0) == nil)
  }

  @Test func outOfRangeAsksAreNilNotATrap() {
    let d = BandsOracleData.make(.main)
    #expect(d.modelDb(bar: -1, row: 0) == nil && d.modelDb(bar: 0, row: 6) == nil)
    #expect(d.modelDb(bar: 5000, row: 0) == nil && d.measDb(bar: 5000, row: 0) == nil)
    #expect(BandsModel.empty.modelDb(bar: 0, row: 0) == nil)
    #expect(BandsModel.empty.measDb(bar: 0, row: 0) == nil)
    #expect(BandsModel.empty.maxBar == -1)
    #expect(BandsModel.empty.rowRefs(.model) == [Double](repeating: -.infinity, count: 6))
  }

  @Test func theRowReferencesAreTheLoudestBarOfEachRow() {
    let d = BandsOracleData.make(.main)
    let m = d.rowRefs(.model)
    let x = d.rowRefs(.measured)
    let wantM = [-2.25, -1.5, -7.75, -11, -4.249999999999999, 0.05863978692794542]
    let wantX = [-15.05, -6.950000000000001, -3.2, 0.9499999999999988, -21.4, 1.260615333099178]
    for r in 0..<6 {
      #expect(close(m[r], wantM[r]), "model row \(r): \(m[r])")
      #expect(close(x[r], wantX[r]), "measured row \(r): \(x[r])")
    }
  }

  @Test func theLoudestBarOfEveryRowIsDigitNine() {
    let d = BandsOracleData.make(.main)
    for side in [BandsSide.model, .measured] {
      let refs = d.rowRefs(side)
      for r in 0..<6 {
        let digits = (0...d.maxBar).map {
          BandsModel.digit(value: d.db(side, bar: $0, row: r), ref: refs[r])
        }
        #expect(digits.contains(9), "\(side) row \(r) has its 9")
        #expect(digits.allSatisfy { $0 != nil && $0! <= 9 })
      }
    }
  }

  @Test func maxBarIsTheLargerOfTheTwoSides() {
    let a = BandsModel(modelBars: [], modelMaxBar: 4, measMaxBar: 9)
    let b = BandsModel(modelBars: [], modelMaxBar: 12, measMaxBar: 3)
    #expect(a.maxBar == 9 && b.maxBar == 12)
  }
}

struct BandsCoverageTests {
  @Test func aBarIsFullWhenBothSidesCoveredAllOfIt() {
    // modelFrom 0, measFrom 5, measAt 215: bar 0 started before the measured side did, bar 13
    // (224 ... 239) is still playing
    let d = BandsOracleData.make(.main)
    let full = (0..<14).filter { d.fullBar($0) }
    #expect(full == Array(1...12))
  }

  @Test func theLaterOfTheTwoStartsDecides() {
    let late = BandsOracleData.make(.main, modelFrom: 20)
    #expect((0..<14).filter { late.fullBar($0) } == Array(2...12), "20 is inside bar 1")
    let exact = BandsOracleData.make(.main, modelFrom: 16, measFrom: 16)
    #expect(exact.fullBar(1) && !exact.fullBar(0), "a side that starts at the first step is full")
  }

  @Test func theBarThatEndsExactlyAtTheLatestStepCounts() {
    let d = BandsOracleData.make(.main, measAt: 208)
    #expect(d.fullBar(12) && !d.fullBar(13))
    let before = BandsOracleData.make(.main, measAt: 207.999)
    #expect(!before.fullBar(12) && before.fullBar(11))
  }

  @Test func nothingIsFullWithoutBothSides() {
    let none = BandsOracleData.make(.main, measFrom: .infinity, measAt: -1)
    #expect((0..<14).allSatisfy { !none.fullBar($0) })
    let noModel = BandsOracleData.make(.main, modelFrom: .max)
    #expect((0..<14).allSatisfy { !noModel.fullBar($0) })
    #expect(!BandsModel.empty.fullBar(0))
  }
}

struct BandsStatsTests {
  /// (bars, corr, rms, offset) per row sub, low, lomid, himid, high, E.
  private func expect(
    _ s: BandsStats, _ rows: [(Int, Double?, Double, Double)], tilt: [Double]?,
    _ comment: Comment? = nil
  ) {
    #expect(s.bands.map(\.band) == ["sub", "low", "lomid", "himid", "high", "E"])
    for (i, w) in rows.enumerated() {
      let b = s.bands[i]
      #expect(b.bars == w.0, "\(b.band) bars")
      #expect(b.corr == w.1, "\(b.band) corr \(String(describing: b.corr))")
      #expect(b.rmsResidualDb == w.2, "\(b.band) rms \(String(describing: b.rmsResidualDb))")
      #expect(b.offsetDb == w.3, "\(b.band) offset \(String(describing: b.offsetDb))")
    }
    #expect(s.bars == rows.map(\.0).max())
    #expect(s.tiltDb?.map(\.db) == tilt)
  }

  @Test func statsMatchScopeJsOnABelievableAgreement() {
    let s = BandsOracleData.make(.main).stats(modelStatus: "model · 12 kernels", fires: 77)
    expect(
      s,
      [
        (12, 0.991, 2.96, -9.1), (12, 0.988, 2.93, -1.1), (12, 0.979, 1.94, 7),
        (12, 0.962, 2.86, 13), (12, 0.99, 1.85, -14.5), (12, -0.182, 6.25, 1.4),
      ], tilt: [-8.2, -0.2, 7.9, 13.9, -13.6])
    #expect(s.model == "model · 12 kernels" && s.fires == 77)
    #expect(s.tiltDb?.map(\.band) == ["sub", "low", "lomid", "himid", "high"])
  }

  @Test func identicalShapesCorrelateAtOneWithNoResidualAndTheOffsetIsTheGain() {
    let s = BandsOracleData.make(.same).stats()
    // offsets are the injected per-band gains: the model and measured sides differ by a constant
    expect(
      s,
      [
        (12, 1, 0, -12), (12, 1, 0, -5), (12, 1, 0, 3), (12, 1, 0, 8), (12, 1, 0, -20),
        (12, 0.166, 5.56, -1.4),
      ], tilt: [-6.8, 0.2, 8.2, 13.2, -14.8])
  }

  @Test func mirroredShapesCorrelateAtMinusOne() {
    let s = BandsOracleData.make(.inverted).stats()
    expect(
      s,
      [
        (12, -1, 24.72, 26.8), (12, -1, 25.47, 39.4), (12, -1, 17.04, 43.5),
        (12, -1, 16.73, 58), (12, -1, 21.24, 31.5), (12, 0.847, 2.79, 44.1),
      ], tilt: [-13, -0.4, 3.7, 18.2, -8.3])
  }

  @Test func theTiltIsEachBandsOffsetMinusTheMeanOfTheFiveRoundedOffsets() {
    // sub -9.1, low -1.1, lomid 7, himid 13, high -14.5: mean -0.94
    let t = BandsOracleData.make(.main).stats().tiltDb!
    let off = [-9.1, -1.1, 7, 13, -14.5]
    let avg = off.reduce(0, +) / 5
    for i in 0..<5 {
      #expect(t[i].db == BandsModel.toFixed(off[i] - avg, 1), "\(t[i].band)")
    }
  }

  @Test func theTiltLineIsPrintedWithPlusSignsAndWithoutTrailingZeros() {
    let s = BandsOracleData.make(.main).stats()
    #expect(s.tiltText == "tilt sub -8.2  low -0.2  lomid +7.9  himid +13.9  high -13.6")
    // JS: `${v > 0 ? '+' : ''}${v}` with 1.2, -0.3, 0, -0, 5 -> "+1.2", "-0.3", "0", "0", "+5"
    var t = BandsStats()
    t.tiltDb = [("sub", 1.2), ("low", -0.3), ("lomid", 0), ("himid", -0.0), ("high", 5)].map {
      BandsStats.Tilt(band: $0.0, db: $0.1)
    }
    #expect(t.tiltText == "tilt sub +1.2  low -0.3  lomid 0  himid 0  high +5")
    #expect(BandsStats().tiltText == nil)
  }

  @Test func fewerThanTwoCommonBarsGiveOnlyTheCount() {
    // measAt 47: bar 1 (16 ... 31) is the only full bar
    let s = BandsOracleData.make(.main, measAt: 47).stats()
    #expect(s.bands.map(\.bars) == [1, 1, 1, 1, 1, 1])
    #expect(
      s.bands.allSatisfy { $0.corr == nil && $0.rmsResidualDb == nil && $0.offsetDb == nil })
    #expect(s.bars == 0, "bars counts only rows that have a fit")
    #expect(s.tiltDb == nil)
    // no bar at all
    let e = BandsOracleData.make(.main, measAt: 30).stats()
    #expect(e.bands.map(\.bars) == [0, 0, 0, 0, 0, 0] && e.tiltDb == nil)
    #expect(BandsModel.empty.stats().bands.count == 6)
  }

  @Test func aFlatSideHasNoCorrelationButStillAnOffsetAndResidual() {
    // the model is 0 dB in every bar, the measured side doubles from bar to bar
    var model = [Double](repeating: 0, count: 4 * 6)
    var meas = model
    for b in 0..<4 {
      for r in 0..<6 {
        model[b * 6 + r] = 1
        meas[b * 6 + r] = Double(1 << b)
      }
    }
    let d = BandsModel(
      modelBars: model, modelMaxBar: 3, modelFrom: 0, measBars: meas,
      measCnt: [1, 1, 1, 1], measMaxBar: 3, measFrom: 0, measAt: 64)
    let s = d.stats()
    for b in s.bands {
      #expect(b.bars == 4 && b.corr == nil, "\(b.band)")
      // levels 0, 3.01, 6.02, 9.03 dB: mean 4.515, rms about the mean 3.37, offset 4.5
      #expect(b.offsetDb == 4.5 && b.rmsResidualDb == 3.37, "\(b.band) \(b)")
    }
  }

  @Test func oneBandWithoutAMeasuredLevelHidesTheTilt() {
    let d = BandsOracleData.make(.main)
    var meas = d.measBars
    for b in 0..<14 { meas[b * 6] = 0 }  // no power in sub, ever
    let cut = BandsModel(
      modelBars: d.modelBars, modelMaxBar: 13, modelFrom: 0, measBars: meas, measCnt: d.measCnt,
      measMaxBar: 13, measFrom: 5, measAt: 215)
    let s = cut.stats()
    #expect(s.bands[0].bars == 0 && s.bands[0].offsetDb == nil)
    #expect(s.bands[1].offsetDb == -1.1, "the others are as before")
    #expect(s.tiltDb == nil && s.tiltText == nil)
  }
}

struct BandsResidualTests {
  @Test func theResidualRemovesEachRowsMeanOnBothSides() {
    let d = BandsOracleData.make(.main)
    let ag = d.agreement()
    #expect(ag.count == [12, 12, 12, 12, 12, 12])
    // scope.js D(b, r) for the cells of the oracle
    let want: [(Int, Int, Double?)] = [
      (1, 0, -0.18333333333333357), (1, 5, 4.303594686747107), (5, 2, 0.7416666666666654),
      (8, 3, 2.5124999999999975), (12, 4, -2.6333333333333258), (0, 0, nil), (13, 1, nil),
    ]
    for (b, r, w) in want {
      let got = d.residual(bar: b, row: r, agreement: ag)
      if let w {
        #expect(close(got, w), "D(\(b), \(r)) = \(String(describing: got))")
      } else {
        #expect(got == nil, "bar \(b) is not full")
      }
    }
    // the residual of a row has zero mean over the bars that went into the means
    for r in 0..<6 {
      let ds = (1...12).compactMap { d.residual(bar: $0, row: r, agreement: ag) }
      #expect(abs(ds.reduce(0, +)) < 1e-9, "row \(r)")
    }
  }

  @Test func theScaleIsSixDbUntilAResidualIsLargerAndNeverMoreThanTwentyFour() {
    let d = BandsOracleData.make(.main)
    let ag = d.agreement()
    // bars on screen 0 ... 13 and 6 ... 13 (from node)
    #expect(close(d.residualLimit(bars: 0..<14, agreement: ag), 9.46576174115211))
    #expect(close(d.residualLimit(bars: 6..<14, agreement: ag), 8.98125337234938))
    // with nothing on screen that is a full bar: the floor
    #expect(d.residualLimit(bars: 13..<14, agreement: ag) == 6)
    #expect(d.residualLimit(bars: 0..<0, agreement: ag) == 6)
    // a mirrored shape has residuals far above 24 dB: clamped
    let inv = BandsOracleData.make(.inverted)
    #expect(inv.residualLimit(bars: 0..<14, agreement: inv.agreement()) == 24)
  }

  @Test func theRdBuEntryIsRoundedHalfUpAndClamped() {
    // clamp(round((D / lim + 1) * 16), 0, 32), from node
    let table: [(Double, Double, Int)] = [
      (0, 6, 16), (0.1875, 6, 17), (6, 6, 32), (-6, 6, 0), (3, 6, 24), (-3, 6, 8), (30, 24, 32),
      (24, 24, 32), (-24, 24, 0), (0.1874, 6, 16), (-0.1875, 6, 16), (1.5, 12, 18),
    ]
    for (v, lim, want) in table {
      #expect(BandsModel.residualIndex(v, limit: lim) == want, "D \(v) / \(lim)")
    }
    #expect(BandsModel.residualIndex(-100, limit: 6) == 0)
    // blue for a measured side quieter than the model, red louder, near-white at no difference
    #expect(ScopeColors.residualColors[0].rgb8 == (33, 102, 172))
    #expect(ScopeColors.residualColors[32].rgb8 == (178, 24, 43))
    #expect(ScopeColors.residualColors[16].rgb8 == (247, 247, 247))
  }

  @Test func aSideWithNoLevelHasNoResidual() {
    let d = BandsOracleData.make(.main)
    var meas = d.measBars
    meas[5 * 6 + 2] = 0  // bar 5, lomid: no measured power
    let cut = BandsModel(
      modelBars: d.modelBars, modelMaxBar: 13, modelFrom: 0, measBars: meas, measCnt: d.measCnt,
      measMaxBar: 13, measFrom: 5, measAt: 215)
    let ag = cut.agreement()
    #expect(ag.count[2] == 11 && ag.count[1] == 12)
    #expect(cut.residual(bar: 5, row: 2, agreement: ag) == nil)
    #expect(cut.residual(bar: 5, row: 1, agreement: ag) != nil)
  }
}

struct BandsNumberFormatTests {
  @Test func toFixedIsJavaScriptsIncludingTheTies() {
    // node: (x).toFixed(d)
    let table: [(Double, Int, String)] = [
      (0.25, 1, "0.3"), (-0.25, 1, "-0.3"), (0.75, 1, "0.8"), (0.125, 2, "0.13"),
      (0.375, 2, "0.38"), (6.5, 0, "7"), (7.5, 0, "8"), (2.5, 0, "3"), (1.005, 2, "1.00"),
      (1.45, 1, "1.4"), (8.345, 2, "8.35"), (-0.04, 1, "-0.0"), (0, 1, "0.0"), (-0.0, 1, "0.0"),
      (-12.000000000000002, 1, "-12.0"), (12.34567, 3, "12.346"), (0.0005, 3, "0.001"),
      (0.0015, 3, "0.002"), (24, 0, "24"), (9.5, 0, "10"), (8.4999, 0, "8"), (9.465, 0, "9"),
    ]
    for (x, d, want) in table {
      #expect(BandsModel.toFixedText(x, d) == want, "(\(x)).toFixed(\(d))")
    }
  }

  @Test func toFixedAsANumberReadsTheStringBack() {
    #expect(BandsModel.toFixed(0.25, 1) == 0.3)
    #expect(BandsModel.toFixed(-12.000000000000002, 1) == -12)
    #expect(BandsModel.toFixed(-0.04, 1).sign == .minus, "+'-0.0' is -0")
    #expect(BandsModel.toFixed(3.14159, 3) == 3.142)
  }

  @Test func numbersPrintWithoutAPointZero() {
    #expect(BandsModel.numberText(3) == "3" && BandsModel.numberText(-0.0) == "0")
    #expect(BandsModel.numberText(1.2) == "1.2" && BandsModel.numberText(-0.3) == "-0.3")
    #expect(BandsModel.numberText(13.9) == "13.9" && BandsModel.numberText(-13.6) == "-13.6")
  }
}
