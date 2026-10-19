// Comparing sample arrays (renders, `.left` / `.right`, slices, WAV bytes) in tests.
//
// Never `#expect(a == b)` / `#require(a == b)` on large collections: when it fails,
// swift-testing diffs the two operands for its message, and that diff takes gigabytes
// (one failing 200k-sample comparison grew the test process from 0.03 to 8.4 GB; a full
// run was jetsam-killed at 143 GB). Compare through `sameSamples` instead:
//
//   #expect(sameSamples(a, b) == .identical)
//   #expect(sameSamples(a, b) != .identical)   // must differ
//
// A failure then prints one line: count, first difference, how many differ.
//
// Tests/DJViewsTests/SampleCompare.swift is a copy (test targets can't share sources): edit both.

/// The outcome of `sameSamples`: small, so swift-testing has nothing big to diff or print.
enum SampleDiff: Equatable, Sendable, CustomStringConvertible {
  case identical
  /// A one-line summary: "count 1000 vs 1002, first difference at 17: 0.25 vs 0.5, 340 of 1000 differ".
  case different(String)

  var description: String {
    switch self {
    case .identical: "identical"
    case .different(let summary): summary
    }
  }
}

/// Compares two sequences element by element with the elements' own `==` (so the same
/// result as `Array(a) == Array(b)`, NaN and −0 included), and summarises any difference.
func sameSamples<A: Sequence, B: Sequence>(_ a: A, _ b: B) -> SampleDiff
where A.Element == B.Element, A.Element: Equatable {
  var ia = a.makeIterator()
  var ib = b.makeIterator()
  var index = 0
  var common = 0
  var differ = 0
  var first: (Int, A.Element, A.Element)?
  var countA = 0
  var countB = 0
  while true {
    let x = ia.next()
    let y = ib.next()
    if x != nil { countA += 1 }
    if y != nil { countB += 1 }
    guard let x, let y else {
      // Count what's left of the longer one.
      if x != nil { while ia.next() != nil { countA += 1 } }
      if y != nil { while ib.next() != nil { countB += 1 } }
      break
    }
    common += 1
    if x != y {
      differ += 1
      if first == nil { first = (index, x, y) }
    }
    index += 1
  }
  if countA == countB && differ == 0 { return .identical }
  var parts: [String] = []
  if countA != countB {
    parts.append("count \(countA) vs \(countB)")
  } else {
    parts.append("count \(countA)")
  }
  if let (at, x, y) = first {
    parts.append("first difference at \(at): \(short(x)) vs \(short(y))")
    parts.append("\(differ) of \(common) differ")
  } else {
    parts.append("first \(common) identical")
  }
  return .different(parts.joined(separator: ", "))
}

/// An element's description, cut short (an element may itself be an array).
private func short<T>(_ value: T) -> String {
  let text = String(describing: value)
  return text.count <= 48 ? text : String(text.prefix(45)) + "..."
}
