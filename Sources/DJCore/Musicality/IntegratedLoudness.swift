import Foundation

/// ITU-R BS.1770-4 integrated loudness, in LUFS: each channel K-weighted (`KWeighting`), mean
/// square over 400 ms blocks (75 % overlap) summed over the channels (weights 1 for L and R), the
/// blocks under −70 LUFS dropped, then those more than 10 LU under the rest's level. What a
/// loudness meter reads; offline only (palette level checks, `SampleLevel`, `djctl render`). The
/// app's one BS.1770 implementation (the live meter, `LoudnessMeter`, is its short-term form);
/// `range` is EBU Tech 3342's loudness range over the same K-weighting (true peak: `TruePeak`).
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
    let (subs, acc) = subBlocks(
      left: left, right: right, count: n, sampleRate: sr, primeFrames: primeFrames)
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

  /// EBU Tech 3342 loudness range, LU: short-term loudness (3 s blocks every 100 ms, both
  /// channels K-weighted as for `integrated`), blocks under −70 LUFS dropped, then those more
  /// than 20 LU under the rest's level; the spread between the 10th and 95th percentiles of what
  /// is left. 0 for silence or anything shorter than one block.
  public static func range(left: [Float], right: [Float]?, sampleRate sr: Double) -> Double {
    left.withUnsafeBufferPointer { l in
      guard let right else {
        return range(left: l.baseAddress!, right: nil, count: l.count, sampleRate: sr)
      }
      return right.withUnsafeBufferPointer { r in
        range(
          left: l.baseAddress!, right: r.baseAddress!, count: min(l.count, r.count),
          sampleRate: sr)
      }
    }
  }

  /// The same over `count` frames of raw channels.
  public static func range(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>?, count n: Int, sampleRate sr: Double
  ) -> Double {
    guard n > 0 else { return 0 }
    let sub = max(1, Int(sr / 10))
    let subs = subBlocks(left: left, right: right, count: n, sampleRate: sr, primeFrames: 0).subs
    guard subs.count >= 30 else { return 0 }
    var window = subs[0..<30].reduce(0, +)
    var blocks: [Double] = [window / Double(30 * sub)]
    blocks.reserveCapacity(subs.count - 29)
    for j in 30..<subs.count {
      window += subs[j] - subs[j - 30]
      blocks.append(max(0, window) / Double(30 * sub))
    }
    func loudness(_ ms: Double) -> Double { -0.691 + 10 * log10(ms) }
    let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
    guard !absolute.isEmpty else { return 0 }
    let relative = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 20
    let gated = absolute.map(loudness).filter { $0 > relative }.sorted()
    guard gated.count > 1 else { return 0 }
    // nearest rank, as Tech 3342's reference code
    func percentile(_ p: Double) -> Double {
      gated[min(gated.count - 1, max(0, Int((p * Double(gated.count - 1)).rounded())))]
    }
    return percentile(0.95) - percentile(0.10)
  }

  /// 100 ms sums of both channels' K-weighted squares, and what is left over past the last.
  private static func subBlocks(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>?, count n: Int, sampleRate sr: Double,
    primeFrames: Int
  ) -> (subs: [Double], rest: Double) {
    let sub = max(1, Int(sr / 10))
    var kl = KWeighting(sampleRate: sr)
    var kr = KWeighting(sampleRate: sr)
    let prime = min(primeFrames, n)
    for i in (n - prime)..<n {
      _ = kl.process(Double(left[i]))
      _ = kr.process(Double((right ?? left)[i]))
    }
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
    return (subs, acc)
  }
}
