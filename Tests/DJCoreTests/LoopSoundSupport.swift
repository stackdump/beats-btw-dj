import Foundation

// Signal helpers for LoopSoundTests (Foundation kept out of the Testing file).

/// `count` samples of a sine at `hz`, amplitude 0.5.
func sineTone(hz: Double, count: Int, sampleRate sr: Double) -> [Float] {
  (0..<count).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / sr)) }
}

/// The frequency of a tone from its rising zero crossings (interpolated between samples).
func zeroCrossingHz(_ x: ArraySlice<Float>, sampleRate sr: Double) -> Double {
  var crossings: [Double] = []
  var i = x.startIndex + 1
  while i < x.endIndex {
    let a = x[i - 1]
    let b = x[i]
    if a < 0 && b >= 0 {
      crossings.append(Double(i - 1) + Double(-a / (b - a)))
    }
    i += 1
  }
  guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else {
    return 0
  }
  return Double(crossings.count - 1) / ((last - first) / sr)
}
