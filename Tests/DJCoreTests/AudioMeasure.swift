import Foundation

@testable import DJCore

// Signal measurements for the instrument tests (Foundation kept out of files that
// `import Testing`; see FixtureLoader.swift).

func rmsDB(_ x: ArraySlice<Float>) -> Double {
  guard !x.isEmpty else { return -200 }
  let s = x.reduce(0.0) { $0 + Double($1) * Double($1) }
  return 10 * log10(max(s / Double(x.count), 1e-20))
}

/// Fundamental over 40 Hz…2 kHz (first strong peak of the autocorrelation). Each lag is
/// normalised by the energy of the two segments it compares, so a decaying note does not
/// pull the estimate sharp.
func fundamental(_ x: ArraySlice<Float>, sampleRate sr: Double) -> Double {
  let v = Array(x).map(Double.init)
  let minLag = Int(sr / 2000)
  let maxLag = min(Int(sr / 40), v.count / 2)
  var r = [Double](repeating: 0, count: maxLag + 2)
  for lag in (minLag - 1)...(maxLag + 1) {
    var s = 0.0
    var ea = 0.0
    var eb = 0.0
    for i in 0..<(v.count - lag) {
      s += v[i] * v[i + lag]
      ea += v[i] * v[i]
      eb += v[i + lag] * v[i + lag]
    }
    r[lag] = s / max((ea * eb).squareRoot(), 1e-30)
  }
  let best = r[minLag...maxLag].max() ?? 0
  // first lag that reaches 90% of the best peak, refined to its local maximum
  var lag = minLag
  while lag < maxLag && r[lag] < 0.9 * best { lag += 1 }
  while lag < maxLag && r[lag + 1] > r[lag] { lag += 1 }
  // parabolic interpolation
  let a = r[lag - 1]
  let b = r[lag]
  let c = r[lag + 1]
  let p = (a - c) / (2 * (a - 2 * b + c))
  return sr / (Double(lag) + (p.isFinite ? p : 0))
}

func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

func midiHz(_ n: Int) -> Double { 440 * pow(2, Double(n - 69) / 12) }

/// Frequency of the strongest partial within ±100 cents of `near` (Hann-windowed DFT,
/// scanned in 0.5-cent steps): the pitch of the fundamental itself, untouched by how
/// stretched the upper partials are.
func partialPeak(_ x: ArraySlice<Float>, near: Double, sampleRate sr: Double) -> Double {
  let v = Array(x)
  let n = v.count
  let w = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
  var best = near
  var bestMag = -1.0
  var c = -100.0
  while c <= 100 {
    let f = near * pow(2, c / 1200)
    let k = 2 * Double.pi * f / sr
    var re = 0.0
    var im = 0.0
    for i in 0..<n {
      let s = Double(v[i]) * w[i]
      re += s * cos(k * Double(i))
      im -= s * sin(k * Double(i))
    }
    let mag = re * re + im * im
    if mag > bestMag {
      bestMag = mag
      best = f
    }
    c += 0.5
  }
  return best
}

/// `ExsNames.patch` on raw bytes (Data stays out of the Testing files).
func exsPatch(_ bytes: [UInt8]) -> [UInt8]? { ExsNames.patch(Data(bytes)).map { [UInt8]($0) } }

/// `DJ_SAMPLER_SWEEP=1` (`make sampler-sweep`): check every installed sound, not one per category.
let samplerSweep = ProcessInfo.processInfo.environment["DJ_SAMPLER_SWEEP"] == "1"
