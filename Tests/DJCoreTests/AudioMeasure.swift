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

/// How far a mix sits from the 12-TET grid (A440), in cents: in each of up to `windows`
/// loud stretches of `size` samples, the strongest semitone partial in `notes` (Hann-windowed
/// DFT), refined to its peak within ±60 cents. A bass's own fundamentals smear at this
/// window length, so `notes` should start above them: its upper partials still tell.
func gridDeviations(
  _ x: [Float], sampleRate sr: Double, notes: ClosedRange<Int> = 52...96, size: Int = 16_384,
  windows: Int = 12
) -> [Double] {
  guard x.count >= size else { return [] }
  let hann = (0..<size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size - 1)) }
  let starts = stride(from: 0, through: x.count - size, by: size / 2)
    .filter { rmsDB(x[$0..<($0 + size)]) > -50 }
  let picked = stride(from: 0, to: starts.count, by: max(1, starts.count / windows)).map {
    starts[$0]
  }
  func mag(_ s: Int, _ f: Double) -> Double {
    let k = 2 * Double.pi * f / sr
    let cr = cos(k)
    let ci = -sin(k)
    var pr = 1.0
    var pi = 0.0
    var re = 0.0
    var im = 0.0
    for i in 0..<size {
      let v = Double(x[s + i]) * hann[i]
      re += v * pr
      im += v * pi
      let t = pr * cr - pi * ci
      pi = pr * ci + pi * cr
      pr = t
    }
    return re * re + im * im
  }
  return picked.map { s in
    let n = notes.map { ($0, mag(s, midiHz($0))) }.max { $0.1 < $1.1 }!.0
    var best = (cents: 0.0, mag: -1.0)
    for c in stride(from: -60.0, through: 60, by: 1) {
      let m = mag(s, midiHz(n) * pow(2, c / 1200))
      if m > best.mag { best = (c, m) }
    }
    return best.cents
  }
}

/// An amplitude ratio in dB.
func ampDB(_ x: Double) -> Double { 20 * log10(x) }
