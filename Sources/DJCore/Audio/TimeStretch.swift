import Accelerate

/// Time stretching for key lock: a loop played at another tempo keeps its pitch by being
/// re-rendered at that tempo, here, off the audio thread, and swapped in (`DJEngine.serviceLoops`).
///
/// WSOLA (waveform-similarity overlap-add, Verhelst & Roelands 1993): the output is built from
/// Hann-windowed frames of the input laid down at a fixed hop. Each frame is read near where the
/// tempo says it should be (`m · hop · ratio`), shifted by up to `tolerance` samples to the place
/// that looks most like the natural continuation of the frame before it (the cross-correlation
/// peak), so the overlapping halves add in phase and the pitch is the input's.
///
/// A loop is periodic, so input and output are both treated as circular: frames read across the
/// loop's end from its start, and the output's last frame overlaps its first. The result is a
/// seamless loop of exactly `length / ratio` samples (rounded), holding the same beats.
public enum TimeStretch {
  /// Frame length in samples at `sampleRate`: ~21 ms (1024 at 48 kHz), even.
  static func frameLength(_ sampleRate: Double) -> Int { 2 * max(32, Int(sampleRate * 0.01067)) }

  /// The loop `left`/`right` played `ratio` times as fast with its pitch kept: the output is
  /// `round(count / ratio)` samples. Stereo channels share one alignment (worked out on their mid),
  /// so the image holds. A loop shorter than two frames is resampled instead.
  public static func wsola(
    left: [Float], right: [Float], ratio: Double, sampleRate: Double
  ) -> (left: [Float], right: [Float]) {
    precondition(left.count == right.count && ratio > 0)
    let nIn = left.count
    let nOut = max(1, Int((Double(nIn) / ratio).rounded()))
    let frame = frameLength(sampleRate)
    guard nIn >= 2 * frame, nOut >= 2 * frame else {
      return (resample(left, nOut), resample(right, nOut))
    }
    let hop = frame / 2
    let tolerance = frame / 2
    // the analysis rate that lands exactly nIn input samples on nOut output samples
    let rate = Double(nIn) / Double(nOut)
    let window = (0..<frame).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frame)) }
    let mid = zip(left, right).map { ($0 + $1) * 0.5 }

    var outL = [Float](repeating: 0, count: nOut)
    var outR = [Float](repeating: 0, count: nOut)
    var weight = [Float](repeating: 0, count: nOut)
    // scratch for the search: the region around the nominal position, the continuation, scores
    var region = [Float](repeating: 0, count: frame + 2 * tolerance)
    var natural = [Float](repeating: 0, count: frame)
    var score = [Float](repeating: 0, count: 2 * tolerance + 1)

    /// Copy `count` samples of `x` from `start` (any integer: the loop wraps) into `into`.
    func gather(_ x: [Float], from start: Int, count: Int, into: inout [Float]) {
      var p = start % nIn
      if p < 0 { p += nIn }
      x.withUnsafeBufferPointer { src in
        into.withUnsafeMutableBufferPointer { dst in
          for k in 0..<count {
            dst[k] = src[p]
            p += 1
            if p == nIn { p = 0 }
          }
        }
      }
    }

    let frames = (nOut + hop - 1) / hop
    var read = 0  // where the previous frame was read from (input samples, unwrapped)
    for m in 0..<frames {
      if m > 0 {
        // the frame that would follow the last one seamlessly, and the best match near nominal
        gather(mid, from: read + hop, count: frame, into: &natural)
        let nominal = Int((Double(m * hop) * rate).rounded())
        gather(mid, from: nominal - tolerance, count: region.count, into: &region)
        vDSP_conv(
          region, 1, natural, 1, &score, 1, vDSP_Length(score.count), vDSP_Length(frame))
        var best: Float = 0
        var at: vDSP_Length = 0
        vDSP_maxvi(score, 1, &best, &at, vDSP_Length(score.count))
        read = nominal - tolerance + Int(at)
      }
      overlapAdd(
        left, right, from: read, to: m * hop, window: window, nIn: nIn,
        outL: &outL, outR: &outR, weight: &weight)
    }
    for i in 0..<nOut where weight[i] > 1e-6 {
      outL[i] /= weight[i]
      outR[i] /= weight[i]
    }
    return (outL, outR)
  }

  /// Add one windowed frame of the input, read from `from`, at output sample `to` (both wrap).
  private static func overlapAdd(
    _ left: [Float], _ right: [Float], from: Int, to: Int, window: [Float], nIn: Int,
    outL: inout [Float], outR: inout [Float], weight: inout [Float]
  ) {
    let nOut = outL.count
    var p = from % nIn
    if p < 0 { p += nIn }
    var q = to % nOut
    left.withUnsafeBufferPointer { l in
      right.withUnsafeBufferPointer { r in
        window.withUnsafeBufferPointer { w in
          outL.withUnsafeMutableBufferPointer { ol in
            outR.withUnsafeMutableBufferPointer { orr in
              weight.withUnsafeMutableBufferPointer { wt in
                for k in 0..<w.count {
                  ol[q] += l[p] * w[k]
                  orr[q] += r[p] * w[k]
                  wt[q] += w[k]
                  p += 1
                  if p == nIn { p = 0 }
                  q += 1
                  if q == nOut { q = 0 }
                }
              }
            }
          }
        }
      }
    }
  }

  /// `x` read at a constant rate to `n` samples (linear interpolation, wrapping): the fallback for
  /// a loop too short to stretch.
  static func resample(_ x: [Float], _ n: Int) -> [Float] {
    let step = Double(x.count) / Double(n)
    return (0..<n).map { i in
      let p = Double(i) * step
      let i0 = min(Int(p), x.count - 1)
      let i1 = i0 + 1 == x.count ? 0 : i0 + 1
      return x[i0] + (x[i1] - x[i0]) * Float(p - Double(i0))
    }
  }

  /// A loop's audio stretched to play at `ratio` times its speed with its pitch kept.
  public static func stretch(_ b: SampleBuffer, ratio: Double) -> SampleBuffer {
    let l = Array(UnsafeBufferPointer(start: b.left, count: b.length))
    let r = Array(UnsafeBufferPointer(start: b.right, count: b.length))
    let out = wsola(left: l, right: r, ratio: ratio, sampleRate: b.sampleRate)
    return SampleBuffer(left: out.left, right: out.right, sampleRate: b.sampleRate)
  }
}
