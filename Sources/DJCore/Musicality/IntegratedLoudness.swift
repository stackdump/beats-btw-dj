import Foundation

/// ITU-R BS.1770-4 integrated loudness of a stereo render, in LUFS: each channel K-weighted
/// (`KWeighting`), mean square over 400 ms blocks (75 % overlap) summed over the channels, the
/// blocks under −70 LUFS dropped, then those more than 10 LU under the rest's level. What a
/// loudness meter reads; offline only (palette level checks, `djctl render`).
public enum IntegratedLoudness {
  public static func lufs(left: [Float], right: [Float], sampleRate sr: Double) -> Double {
    let n = min(left.count, right.count)
    let block = Int(0.4 * sr)
    let hop = block / 4
    guard n >= block, hop > 0 else { return -200 }
    var kl = KWeighting(sampleRate: sr)
    var kr = KWeighting(sampleRate: sr)
    // squared K-weighted samples, both channels summed (channel weights 1 for L and R)
    var sq = [Double](repeating: 0, count: n)
    for i in 0..<n {
      let a = kl.process(Double(left[i]))
      let b = kr.process(Double(right[i]))
      sq[i] = a * a + b * b
    }
    var blocks: [Double] = []
    var sum = sq[0..<block].reduce(0, +)
    var start = 0
    while start + block <= n {
      blocks.append(sum / Double(block))
      let next = start + hop
      guard next + block <= n else { break }
      for i in start..<next { sum -= sq[i] }
      for i in (start + block)..<(next + block) { sum += sq[i] }
      start = next
    }
    func loudness(_ ms: Double) -> Double { -0.691 + 10 * log10(max(ms, 1e-20)) }
    let absolute = blocks.filter { loudness($0) > -70 }
    guard !absolute.isEmpty else { return -200 }
    let relative = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
    let gated = absolute.filter { loudness($0) > relative }
    guard !gated.isEmpty else { return -200 }
    return loudness(gated.reduce(0, +) / Double(gated.count))
  }
}
