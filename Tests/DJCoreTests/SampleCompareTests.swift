import Testing

@Suite struct SampleCompareTests {
  @Test func identicalSequencesAreIdentical() {
    let a: [Float] = [0, 0.25, -0.5, 1]
    #expect(sameSamples(a, a) == .identical)
    #expect(sameSamples(a[1...], [0.25, -0.5, 1]) == .identical)
    #expect(sameSamples([Float](), [Float]()) == .identical)
    #expect(sameSamples(a, a).description == "identical")
  }

  @Test func differentCountsSayHowMany() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [1, 2, 3, 4, 5]
    #expect(sameSamples(a, b) == .different("count 3 vs 5, first 3 identical"))
    #expect(sameSamples(b, a) != .identical)
  }

  @Test func firstDifferenceIsReported() {
    var a = [Float](repeating: 0, count: 1000)
    var b = a
    b.append(contentsOf: [0, 0])
    a[17] = 0.25
    b[17] = 0.5
    for i in 500..<839 { b[i] = 1 }
    #expect(
      sameSamples(a, b).description
        == "count 1000 vs 1002, first difference at 17: 0.25 vs 0.5, 340 of 1000 differ")
    // Same semantics as Array's `==`: NaN never equals itself.
    #expect(sameSamples([Float.nan], [Float.nan]) != .identical)
    #expect(sameSamples([Float(0)], [-Float(0)]) == .identical)
  }

  @Test func largeDifferencesStaySmall() {
    // What a failing #expect would have had to diff: two 500k-sample arrays, every sample
    // different. The summary stays one short line.
    let n = 500_000
    let a = (0..<n).map { Float($0) / Float(n) }
    let b = (0..<n + 3).map { -Float($0) / Float(n) - 1 }
    let diff = sameSamples(a, b)
    #expect(diff != .identical)
    #expect(diff.description.count < 120, "\(diff.description.count) characters")
    #expect(
      diff.description.hasPrefix("count 500000 vs 500003, first difference at 0: 0.0 vs -1.0"))
    // Nested elements (a channel per row) are cut short too.
    let rowsA = [a]
    let rowsB = [b]
    #expect(sameSamples(rowsA, rowsB).description.count < 200)
  }
}
