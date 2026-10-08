/// mulberry32 as beats' `createRng` (generator/core.js) writes it, including the
/// `|0` / `Math.imul` / `>>>` int32 semantics. Same seed → same stream as the JS.
public struct Mulberry32: Sendable {
  private var s: Int32

  /// `seed | 0` — pass the JS number; it is reduced with ToInt32.
  public init(seed: Double) { s = jsToInt32(seed) }
  public init(seed: Int) { s = Int32(truncatingIfNeeded: seed) }

  /// `rng.next()` — a double in [0, 1).
  public mutating func next() -> Double {
    s = s &+ 0x6D2B_79F5
    var t = imul(s ^ Int32(bitPattern: UInt32(bitPattern: s) >> 15), 1 | s)
    t = (t &+ imul(t ^ Int32(bitPattern: UInt32(bitPattern: t) >> 7), 61 | t)) ^ t
    let r = UInt32(bitPattern: t ^ Int32(bitPattern: UInt32(bitPattern: t) >> 14))
    return Double(r) / 4_294_967_296
  }

  /// `Math.floor(next() * max)`
  public mutating func nextInt(_ max: Int) -> Int { Int((next() * Double(max)).rounded(.down)) }

  /// `Math.floor(next() * 2147483647)`
  public mutating func nextInt63() -> Int { Int((next() * 2_147_483_647).rounded(.down)) }

  // Go-style aliases the ported modules use.
  public mutating func float64() -> Double { next() }
  public mutating func int63() -> Int { nextInt63() }
  public mutating func intn(_ max: Int) -> Int { nextInt(max) }
}

/// `Math.imul`
@inline(__always)
public func imul(_ a: Int32, _ b: Int32) -> Int32 { a &* b }
