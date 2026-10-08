import Foundation

/// Min/max peaks of a buffer, one pair per display column (channels mixed to mono). The
/// whole-track strip of a deck. Pure data: nothing here knows about drawing.
public struct WaveformOverview: Equatable, Sendable {
  public let columns: Int
  /// `2 * columns` floats: min0, max0, min1, max1, …
  public let peaks: [Float]
  public let length: Int
  public let sampleRate: Double

  public init(buffer: SampleBuffer, columns: Int) {
    let n = max(1, columns)
    self.columns = n
    length = buffer.length
    sampleRate = buffer.sampleRate
    peaks = Self.compute(
      left: buffer.left, right: buffer.right, from: 0, to: buffer.length, columns: n)
  }

  public func peak(_ column: Int) -> (min: Float, max: Float) {
    (peaks[column * 2], peaks[column * 2 + 1])
  }

  /// Peaks of the window `[start, end)` (in samples, clamped) at `columns` resolution: the
  /// zoomed view around the playhead. Computed straight from the samples.
  public static func window(buffer: SampleBuffer, start: Int, end: Int, columns: Int) -> [Float] {
    let s = max(0, min(buffer.length, start))
    let e = max(s, min(buffer.length, end))
    return compute(left: buffer.left, right: buffer.right, from: s, to: e, columns: max(1, columns))
  }

  private static func compute(
    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, from: Int, to: Int,
    columns: Int
  ) -> [Float] {
    var out = [Float](repeating: 0, count: columns * 2)
    let count = to - from
    guard count > 0 else { return out }
    let mono = left == right
    for c in 0..<columns {
      let a = from + c * count / columns
      var b = from + (c + 1) * count / columns
      if b <= a { b = min(to, a + 1) }
      var lo = Float.greatestFiniteMagnitude
      var hi = -Float.greatestFiniteMagnitude
      for i in a..<b {
        let v = mono ? left[i] : (left[i] + right[i]) * 0.5
        if v < lo { lo = v }
        if v > hi { hi = v }
      }
      if lo > hi {
        lo = 0
        hi = 0
      }
      out[c * 2] = lo
      out[c * 2 + 1] = hi
    }
    return out
  }
}

/// Where a deck's markers sit along its waveform, as fractions (0…1) of the track.
public struct WaveformOverlay: Equatable, Sendable {
  public var playhead: Double
  /// The active (or armed) loop.
  public var loop: ClosedRange<Double>?
  public var loopActive: Bool
  public var cues: [Int: Double]
  /// Bar lines from the beat grid (every 4 beats); empty without a grid or if too dense to read.
  public var barLines: [Double]

  public init(
    playhead: Double, loop: ClosedRange<Double>? = nil, loopActive: Bool = false,
    cues: [Int: Double] = [:], barLines: [Double] = []
  ) {
    self.playhead = playhead
    self.loop = loop
    self.loopActive = loopActive
    self.cues = cues
    self.barLines = barLines
  }
}

extension Deck {
  public var waveformOverlay: WaveformOverlay? {
    guard mode == .sample, let b = loaded, b.length > 0 else { return nil }
    let len = Double(b.length)
    var p = turntable.position.truncatingRemainder(dividingBy: len)
    if p < 0 { p += len }
    var loopRange: ClosedRange<Double>?
    if let s = loopStart, let e = loopEnd, e > s {
      loopRange = max(0, min(1, s / len))...max(0, min(1, e / len))
    }
    var bars: [Double] = []
    if let g = beatGrid {
      let bar = g.samplesPerBeat(sampleRate: turntable.sampleRate) * 4
      if bar > 0 && len / bar <= 400 {
        var x = g.offset
        while x < len {
          bars.append(x / len)
          x += bar
        }
      }
    }
    return WaveformOverlay(
      playhead: p / len, loop: loopRange, loopActive: looping,
      cues: hotCues.mapValues { max(0, min(1, $0 / len)) }, barLines: bars)
  }
}
