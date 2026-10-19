import Foundation

// Kept out of RoomShimmerTests.swift: Foundation next to Testing needs the
// _Testing_Foundation overlay, which ships only with Xcode.

/// 10^(dB/20), for the room tests (`ampDB` is AudioMeasure's).
func dbAmp(_ db: Double) -> Double { pow(10, db / 20) }

/// What the room adds against the dry render, dB (as `djctl render --room`'s `roomReturnDB`).
func roomReturnDB(wet: (l: [Float], r: [Float]), dry: (l: [Float], r: [Float])) -> Double {
  var w = 0.0
  var b = 0.0
  for i in 0..<min(wet.l.count, dry.l.count) {
    let dl = Double(wet.l[i] - dry.l[i])
    let dr = Double(wet.r[i] - dry.r[i])
    w += dl * dl + dr * dr
    b += Double(dry.l[i] * dry.l[i] + dry.r[i] * dry.r[i])
  }
  return 10 * log10(w / b)
}
