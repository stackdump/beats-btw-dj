import Darwin
import Testing

@testable import DJCore

// The model image of the Spectro scope (SpectroImage), against scope.js drawSpectro run by node
// (scripts/scope-spectro-oracle.mjs -> SpectroOracleData.swift) and against hand-made cases whose
// answers are worked out in the comments.

/// "00ff..." -> bytes.
func hexBytes(_ rows: [String]) -> [UInt8] {
  var out: [UInt8] = []
  for row in rows {
    let u = Array(row.utf8)
    var i = 0
    while i + 1 < u.count {
      func v(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
      out.append(v(u[i]) << 4 | v(u[i + 1]))
      i += 2
    }
  }
  return out
}

/// The model scenario of the oracle: steps 0 ..< 200 final, except 150 and 151 whose slots were
/// never written; cell (st, j) is 2^(((13 st + 7 j) % 40) - 20), or 0 where (st + j) % 23 == 0.
func oracleColumns() -> SpectroColumns {
  var col = [Float](repeating: 0, count: ModelGrid.specCap * ModelGrid.ns)
  var step = [Int32](repeating: -1, count: ModelGrid.specCap)
  for st in 0..<200 where st != 150 && st != 151 {
    step[st % ModelGrid.specCap] = Int32(st)
    for j in 0..<ModelGrid.ns {
      let e = ((st * 13 + j * 7) % 40) - 20
      col[(st % ModelGrid.specCap) * ModelGrid.ns + j] =
        (st + j) % 23 == 0 ? 0 : Float(pow(2.0, Double(e)))
    }
  }
  return SpectroColumns(col: col, step: step, cur: 200)
}

struct SpectroImageTests {
  // MARK: the cell formula

  @Test func aCellIsTheTruncatedFractionOfTheFiftyDecibelRange() {
    // the literals are node: Math.max(0, Math.min(255, ((db - floor) / 50 * 255) | 0))
    for c in SpectroOracle.cells {
      #expect(
        Int(SpectroImage.level(db: c[0], floor: c[1])) == Int(c[2]),
        "db \(c[0]) floor \(c[1]) want \(c[2])")
    }
    // by hand: 25 dB over the floor is 127.5, which truncates to 127 (not rounds to 128)
    #expect(SpectroImage.level(db: -35, floor: -60) == 127)
    // a hair above the floor is still 0, 0.2 dB above is 1 (1.02), the top is 255, above clamps
    #expect(SpectroImage.level(db: -59.9999, floor: -60) == 0)
    #expect(SpectroImage.level(db: -59.8, floor: -60) == 1)
    #expect(SpectroImage.level(db: -10, floor: -60) == 255)
    #expect(SpectroImage.level(db: 40, floor: -60) == 255, "above the loudest clamps")
    #expect(SpectroImage.level(db: -61, floor: -60) == 0, "below the floor clamps")
  }

  @Test func nonFiniteCellsAreZeroLikeTheJsToInt32() {
    // `NaN | 0` and `Infinity | 0` are 0 in JS (ToInt32), whatever Math.min would make of them
    #expect(SpectroImage.level(db: .nan, floor: -60) == 0)
    #expect(SpectroImage.level(db: .infinity, floor: -60) == 0)
    #expect(SpectroImage.level(db: -.infinity, floor: -60) == 0)
    #expect(SpectroImage.level(db: -10, floor: .nan) == 0)
    #expect(SpectroImage.level(db: -10, floor: -.infinity) == 0)
  }

  @Test func theMagmaTableIsTheJsLutAtItsSamples() {
    for s in SpectroOracle.lutSamples {
      let c = ScopeColors.magma.rgb(at: s[0])
      #expect([Int(c.r), Int(c.g), Int(c.b)] == Array(s[1...3]), "index \(s[0])")
    }
  }

  @Test func theBitmapColoursThroughTheLutOpaque() {
    let b = SpectroBitmap(width: 2, height: 1, levels: [0, 255], peakDb: 0)
    #expect(b.rgba() == [0, 0, 4, 255, 252, 253, 191, 255])
  }

  // MARK: the model image

  @Test(arguments: [140, -3, 195])
  func theModelImageIsTheJsImageCellForCell(first: Int) throws {
    let want = hexBytes(
      try #require(
        [
          140: SpectroOracle.modelRows140, -3: SpectroOracle.modelRowsNeg3,
          195: SpectroOracle.modelRows195,
        ][first]))
    let peak = [
      140: SpectroOracle.modelPeak140, -3: SpectroOracle.modelPeakNeg3,
      195: SpectroOracle.modelPeak195,
    ][first]!
    let img = SpectroImage.model(first: first, columns: oracleColumns())
    #expect(img.width == 66 && img.height == 28 && img.levels.count == 66 * 28)
    #expect(abs(img.peakDb - peak) < 1e-9, "mx \(img.peakDb) vs \(peak)")
    var wrong: [String] = []
    for y in 0..<28 {
      for x in 0..<66 where img.level(x, y) != want[y * 66 + x] {
        wrong.append("(\(x),\(y)) \(img.level(x, y)) vs \(want[y * 66 + x])")
      }
    }
    #expect(wrong.isEmpty, "\(wrong.count) differ, first: \(wrong.prefix(5))")
    #expect(want.contains(255) || first == 195, "the scenario really exercises the top")
  }

  @Test func theLowestBinIsTheBottomRow() {
    // step 10, only bin 0 (30 Hz) and bin 27 (the top) sound: the loudest is 255 in its row
    var c = SpectroColumns.empty
    c.step[10] = 10
    c.col[10 * 28 + 0] = 1  // 0 dB
    c.col[10 * 28 + 27] = 0.1  // -10 dB
    c.cur = 11
    let img = SpectroImage.model(first: 8, columns: c)  // step 10 is column 2
    #expect(img.peakDb == 0)
    #expect(img.level(2, 27) == 255, "bin 0 at the bottom")
    // -10 dB over a floor of -50: 40/50 * 255 = 204
    #expect(img.level(2, 0) == 204, "bin 27 at the top")
    // nothing else is lit
    let lit = img.levels.enumerated().filter { $0.element != 0 }.map(\.offset)
    #expect(lit == [0 * 66 + 2, 27 * 66 + 2])
  }

  @Test func onlyFinalColumnsWhoseSlotHoldsThatStepAreDrawn() {
    var c = SpectroColumns.empty
    for st in [5, 6, 7, 8] {
      c.step[st] = Int32(st)
      for j in 0..<28 { c.col[st * 28 + j] = 1 }
    }
    c.step[6] = 6 - 2048  // a slot a step of the previous lap of the ring wrote
    c.cur = 8  // step 8 is not final yet
    let img = SpectroImage.model(first: 4, columns: c)  // columns: 4 5 6 7 8 9
    func column(_ x: Int) -> Bool { (0..<28).contains { img.level(x, $0) != 0 } }
    #expect(!column(0), "step 4 was never written")
    #expect(column(1), "step 5")
    #expect(!column(2), "step 6: the slot holds another step")
    #expect(column(3), "step 7")
    #expect(!column(4), "step 8 is at specCur: not final")
    #expect(!column(5))
    // a window that starts before the song: negative steps are never valid
    let before = SpectroImage.model(first: -2, columns: c)
    #expect((0..<28).allSatisfy { before.level(0, $0) == 0 && before.level(1, $0) == 0 })
    #expect((0..<28).contains { before.level(2 + 5, $0) != 0 }, "step 5 is column 7 here")
  }

  @Test func theRingWrapsAtTwoThousandAndFortyEightColumns() {
    var c = SpectroColumns.empty
    let st = 2048 + 9  // slot 9
    c.step[9] = Int32(st)
    c.col[9 * 28 + 4] = 1
    c.cur = st + 1
    let img = SpectroImage.model(first: st - 1, columns: c)
    #expect(img.level(1, 27 - 4) == 255)
    // the same slot no longer holds step 9
    #expect(SpectroImage.model(first: 8, columns: c).levels.allSatisfy { $0 == 0 })
  }

  @Test func withNothingAudibleTheImageIsAllBlackAndFittedToNothing() {
    var c = SpectroColumns.empty
    c.step[3] = 3
    c.cur = 4  // a valid column of zeros
    let img = SpectroImage.model(first: 0, columns: c)
    #expect(img.peakDb == -.infinity && img.levels.allSatisfy { $0 == 0 })
    // and with no columns at all
    #expect(SpectroImage.model(first: 0, columns: .empty).levels.allSatisfy { $0 == 0 })
  }

  @Test func cellsMoreThanFiftyDecibelsBelowTheLoudestAreBlack() {
    var c = SpectroColumns.empty
    c.step[0] = 0
    c.cur = 1
    c.col[0] = 1  // bin 0: 0 dB
    c.col[1] = 1e-5  // bin 1: -50 dB: the floor (a hair under it in float32)
    c.col[2] = 1e-4  // bin 2: -40 dB: 10/50 * 255 = 51
    c.col[3] = 1e-7  // bin 3: -70 dB
    let img = SpectroImage.model(first: 0, columns: c)
    #expect(img.level(0, 27) == 255)
    #expect(img.level(0, 26) == 0, "at the floor")
    // -40 dB, but float32 holds 1e-4 as 9.99999975e-5: 50.99999 truncates to 50
    #expect(img.level(0, 25) == 50, "-40 dB: \(img.level(0, 25))")
    #expect(img.level(0, 24) == 0, "below it")
  }

}
