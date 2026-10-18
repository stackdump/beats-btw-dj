import Foundation

/// ITU-R BS.1770-4 integrated loudness, in LUFS: each channel K-weighted (`KWeighting`), mean
/// square over 400 ms blocks (75 % overlap) summed over the channels (weights 1 for L and R), the
/// blocks under −70 LUFS dropped, then those more than 10 LU under the rest's level. What a
/// loudness meter reads; offline only (palette level checks, `SampleLevel`, `djctl render`). The
/// app's one BS.1770 implementation (the live meter, `LoudnessMeter`, is its short-term form).
public enum IntegratedLoudness {
  /// Integrated loudness of a stereo render, LUFS; −200 for silence.
  public static func lufs(left: [Float], right: [Float], sampleRate sr: Double) -> Double {
    integrated(left: left, right: right, sampleRate: sr) ?? -200
  }

  /// Integrated loudness, LUFS, or nil for silence. `right` nil = mono, played on both channels
  /// of a stereo deck (as the turntable does), so counted twice.
  public static func integrated(left: [Float], right: [Float]?, sampleRate: Double) -> Double? {
    left.withUnsafeBufferPointer { l in
      guard let right else {
        return integrated(
          left: l.baseAddress!, right: nil, count: l.count, sampleRate: sampleRate)
      }
      return right.withUnsafeBufferPointer { r in
        integrated(
          left: l.baseAddress!, right: r.baseAddress!, count: min(l.count, r.count),
          sampleRate: sampleRate)
      }
    }
  }

  /// The same over `count` frames of raw channels (`SampleBuffer`). Something shorter than one
  /// block is measured as one block. `primeFrames`: run the filters over that many frames from
  /// the end first (a loop, which plays round).
  public static func integrated(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>?, count n: Int, sampleRate sr: Double,
    primeFrames: Int = 0
  ) -> Double? {
    guard n > 0 else { return nil }
    let sub = max(1, Int(sr / 10))
    var kl = KWeighting(sampleRate: sr)
    var kr = KWeighting(sampleRate: sr)
    let prime = min(primeFrames, n)
    for i in (n - prime)..<n {
      _ = kl.process(Double(left[i]))
      _ = kr.process(Double((right ?? left)[i]))
    }
    // 100 ms sums of both channels' squares; a 400 ms block is four of them
    var subs: [Double] = []
    subs.reserveCapacity(n / sub + 1)
    var acc = 0.0
    var k = 0
    for i in 0..<n {
      let a = kl.process(Double(left[i]))
      let b = kr.process(Double((right ?? left)[i]))
      acc += a * a + b * b
      k += 1
      if k == sub {
        subs.append(acc)
        acc = 0
        k = 0
      }
    }
    var blocks: [Double] = []  // mean square of each block
    if subs.count < 4 {
      // shorter than a block: the whole thing is one
      blocks = [(subs.reduce(0, +) + acc) / Double(n)]
    } else {
      for j in 3..<subs.count {
        blocks.append((subs[j - 3] + subs[j - 2] + subs[j - 1] + subs[j]) / Double(4 * sub))
      }
    }
    func loudness(_ ms: Double) -> Double { -0.691 + 10 * log10(ms) }
    let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
    guard !absolute.isEmpty else { return nil }
    let relative = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
    let gated = absolute.filter { loudness($0) > relative }
    guard !gated.isEmpty else { return nil }
    return loudness(gated.reduce(0, +) / Double(gated.count))
  }
}
