import Darwin

@testable import DJCore

// Synthetic per-bar data for the Bands tests, the same generator as the node harness that pinned
// the expected values (scratchpad m5/oracle.js, which runs scope.js `modelDb`, `measDb`, `rowRefs`,
// `fullBar` and `scopeStats` verbatim). Kept out of the files that `import Testing`.
//
// 14 bars (0 ... 13), `LCG x -> x * 1664525 + 1013904223 mod 2^32`, seed 12345. Per bar and band
// the generator draws two numbers: the model level `dm = -40 + 0.25 * ((x >> 16) % 160)` dB and the
// noise `0.25 * ((x >> 16) % 24 - 12)`. Measured, by kind:
//   main      dx = 0.8 dm + offset[r] + noise      (a believable, imperfect agreement)
//   same      dx = dm + offset[r]                  (the shape is identical)
//   inverted  dx = -dm + offset[r]                 (the shape is mirrored)
// offsets sub -12, low -5, lomid 3, himid 8, high -20. A bar has `1 + b % 3` reads; the measured
// side stores their SUM (the reader's `measBars`) so the mean is the level. E is the sum of the
// five bands on both sides. modelFrom 0, measFrom 5, measAt 215: bars 1 ... 12 are full.

enum BandsOracleData {
  enum Kind {
    case main, same, inverted
  }

  static let offsets: [Double] = [-12, -5, 3, 8, -20]
  static let bars = 14

  static func make(
    _ kind: Kind, modelFrom: Int = 0, measFrom: Double = 5, measAt: Double = 215
  ) -> BandsModel {
    var x: UInt64 = 12345
    func next() -> UInt64 {
      x = (x * 1_664_525 + 1_013_904_223) % 4_294_967_296
      return x
    }
    let rows = BandsModel.rows
    var model = [Double](repeating: 0, count: ModelGrid.maxBars * rows)
    var meas = [Double](repeating: 0, count: ModelGrid.maxBars * rows)
    var cnt = [Float](repeating: 0, count: ModelGrid.maxBars)
    for b in 0..<bars {
      let reads = Double(1 + b % 3)
      cnt[b] = Float(reads)
      var em = 0.0
      var ex = 0.0
      for r in 0..<5 {
        let dm = -40 + 0.25 * Double(Int(next() / 65536) % 160)
        let nz = 0.25 * Double(Int(next() / 65536) % 24 - 12)
        let dx: Double
        switch kind {
        case .main: dx = dm * 0.8 + offsets[r] + nz
        case .same: dx = dm + offsets[r]
        case .inverted: dx = -dm + offsets[r]
        }
        let pm = pow(10, dm / 10)
        let px = pow(10, dx / 10)
        model[b * rows + r] = pm
        em += pm
        meas[b * rows + r] = px * reads
        ex += px * reads
      }
      model[b * rows + 5] = em
      meas[b * rows + 5] = ex
    }
    return BandsModel(
      modelBars: model, modelMaxBar: bars - 1, modelFrom: modelFrom, measBars: meas, measCnt: cnt,
      measMaxBar: bars - 1, measFrom: measFrom, measAt: measAt)
  }
}
