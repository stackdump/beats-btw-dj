import Darwin
import Testing

@testable import DJCore

// Oracle: Chrome rendering beats' own master nodes (real Tone 15.1.22, built as tone-engine.js
// builds them, moved by its setters) in an OfflineAudioContext, one node at a time:
// scripts/master-chain-chrome-reference.html → Fixtures/beats/master-chain-chrome.json
// (`node scripts/master-chain-chrome.mjs`). The chain runs here with its rest bypass off (Tone's
// nodes run at rest too) and only the stage under test, on the same input, with the same setter
// calls at the same render quanta.

private let fixture: JSONValue? = try? JSONValue.parse(try beatsFixtureText("master-chain-chrome"))

/// The page's input (two tones and LCG noise per channel), as Float32.
private func input(frames n: Int, sampleRate sr: Double) -> (l: [Float], r: [Float]) {
  var l = [Float](repeating: 0, count: n)
  var r = [Float](repeating: 0, count: n)
  var seed: UInt32 = 12345
  for i in 0..<n {
    seed = seed &* 1_103_515_245 &+ 12345
    let noise = (Double(seed) / 4_294_967_296) * 2 - 1
    let t = Double(i) / sr
    l[i] = Float(
      0.3 * sin(2 * Double.pi * 220 * t) + 0.2 * sin(2 * Double.pi * 1375 * t) + 0.1 * noise)
    r[i] = Float(
      0.3 * sin(2 * Double.pi * 330 * t) + 0.15 * sin(2 * Double.pi * 2750 * t) + 0.1 * noise)
  }
  return (l, r)
}

private func stage(_ name: String) -> MasterChain.Stage {
  switch name {
  case "lowpass": .lowpass
  case "highpass": .highpass
  case "phaser": .phaser
  case "crusher": .crusher
  case "distortion": .distortion
  default: .pitch
  }
}

/// The chain's output for a scenario: 128-frame quanta, each op applied before its quantum.
private func render(_ sc: JSONValue, frames n: Int, sampleRate sr: Double) -> (
  l: [Float], r: [Float]
) {
  var (l, r) = input(frames: n, sampleRate: sr)
  let chain = MasterChain(sampleRate: sr)
  chain.restBypass = false
  chain.solo = stage(sc["name"]!.string!)
  let ops = sc["ops"]!.array!.map {
    (Int($0[0]!.double!), MasterFxKey(id: $0[1]!.string!)!, Int($0[2]!.double!))
  }
  var start = 0
  l.withUnsafeMutableBufferPointer { lp in
    r.withUnsafeMutableBufferPointer { rp in
      while start < n {
        let m = min(128, n - start)
        for (f, key, v) in ops where f == start { chain.apply(key, v, at: chain.time(at: 0)) }
        chain.process(lp.baseAddress! + start, rp.baseAddress! + start, from: 0, to: m)
        chain.finish(frames: m)
        start += m
      }
    }
  }
  return (l, r)
}

/// Magnitude spectrum (Hann window, every 4th bin up to Nyquist) of a stretch.
private func spectrum(_ x: ArraySlice<Float>) -> [Double] {
  let xs = Array(x)
  let n = xs.count
  return stride(from: 1, to: n / 2, by: 4).map { k in
    var re = 0.0
    var im = 0.0
    for (i, v) in xs.enumerated() {
      let h = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
      let a = 2 * Double.pi * Double(k) * Double(i) / Double(n)
      re += Double(v) * h * cos(a)
      im -= Double(v) * h * sin(a)
    }
    return (re * re + im * im).squareRoot()
  }
}

/// Normalised correlation of two spectra (1: the same shape).
private func similarity(_ a: [Double], _ b: [Double]) -> Double {
  let ab = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
  let aa = a.reduce(0.0) { $0 + $1 * $1 }
  let bb = b.reduce(0.0) { $0 + $1 * $1 }
  return ab / (aa * bb).squareRoot()
}

/// RMS of each 128-frame stretch.
private func envelope(_ x: ArraySlice<Float>) -> [Double] {
  stride(from: x.startIndex, to: x.endIndex, by: 128).map { i in
    let s = x[i..<min(i + 128, x.endIndex)]
    return (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
  }
}

struct MasterChainChromeTests {
  /// Worst |Swift − Chrome| over the windows, per scenario. The biquads, the crusher and the
  /// distortion (with their wet ramps and Tone's −56 dB leak at wet 0) sample for sample within
  /// 1e-4. The phaser and the pitch shifter (per-sample allpass coefficients from an LFO, delay
  /// lines swept by Chrome's band-limited wavetables) within 2e-3, their 128-frame RMS envelopes
  /// within 0.1 % and their spectra alike (correlation > 0.9999).
  @Test(arguments: ["lowpass", "highpass", "crusher", "distortion", "phaser", "pitch"])
  func matchesChrome(_ name: String) throws {
    let f = try #require(fixture)
    let sr = f["sampleRate"]!.double!
    let n = Int(f["frames"]!.double!)
    let sc = try #require(f["scenarios"]!.array!.first { $0["name"]?.string == name })
    let (l, r) = render(sc, frames: n, sampleRate: sr)
    var worst = 0.0
    var worstEnv = 0.0
    var leastSimilar = 1.0
    var report: [String] = []
    for w in sc["windows"]!.array! {
      let s = Int(w["start"]!.double!)
      for (mine, theirs) in [
        (l, decodeFloat32(base64: w["left"]!.string!)),
        (r, decodeFloat32(base64: w["right"]!.string!)),
      ] {
        let a = mine[s..<(s + theirs.count)]
        var d = 0.0
        for (x, y) in zip(a, theirs) { d = max(d, abs(Double(x) - Double(y))) }
        let ea = envelope(a)
        let eb = envelope(theirs[...])
        var de = 0.0
        for (x, y) in zip(ea, eb) { de = max(de, abs(x - y) / max(y, 0.05)) }
        worst = max(worst, d)
        worstEnv = max(worstEnv, de)
        let sim =
          name == "pitch" || name == "phaser" ? similarity(spectrum(a), spectrum(theirs[...])) : 1
        leastSimilar = min(leastSimilar, sim)
        report.append("\(s): \(d) env \(de) spectrum \(sim)")
      }
    }
    print("chrome \(name): max |Δ| \(worst), envelope \(worstEnv), spectrum \(leastSimilar)")
    switch name {
    case "pitch", "phaser":
      #expect(worst < 2e-3, "\(name): \(worst): \(report)")
      #expect(worstEnv < 1e-3 && leastSimilar > 0.9999, "\(name): \(report)")
    default:
      #expect(worst < 1e-4, "\(name): \(worst): \(report)")
    }
  }
}
