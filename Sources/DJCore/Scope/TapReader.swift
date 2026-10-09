import Accelerate

/// What a scope view gets per pixel column: the block ring folded to one min / max /
/// mean-square per column (the loop at the top of scope.js `drawLive`).
public struct WaveformColumns: Equatable, Sendable {
  public var min: [Float]
  public var max: [Float]
  /// Mean of the blocks' mean squares summed per column (divide by `count` for RMS²).
  public var sq: [Float]
  /// Blocks that landed in the column; 0 = nothing to draw there.
  public var count: [UInt16]

  public init(width: Int) {
    min = [Float](repeating: 1, count: width)
    max = [Float](repeating: -1, count: width)
    sq = [Float](repeating: 0, count: width)
    count = [UInt16](repeating: 0, count: width)
  }

  /// RMS of column `x` (0 when empty).
  public func rms(_ x: Int) -> Float {
    count[x] == 0 ? 0 : (sq[x] / Float(count[x])).squareRoot()
  }
}

/// Main-thread reader of an `AudioTap`: scope.js `readWaveform` on our own audio.
///
/// Each `update` drains whatever the tap has gained since the last one into blocks of
/// `blockSize` frames (min / max / mean square, stamped with the engine time of the
/// block's last sample) in a ring of `blockCapacity` (`WF_CAP`). The raw tail is available
/// for FFT views through `recent` / `spectrum`.
public final class TapReader {
  /// scope.js `BLOCK` and `WF_CAP`.
  public static let blockSize = 256
  public static let blockCapacity = 8192
  /// scope.js `FFT_SIZE`.
  public static let fftSize = 4096

  public let tap: AudioTap
  public let sampleRate: Double

  public private(set) var blockT: [Double]
  public private(set) var blockMin: [Float]
  public private(set) var blockMax: [Float]
  public private(set) var blockSq: [Float]
  /// Ring head (next slot to write) and number of valid blocks.
  public private(set) var head = 0
  public private(set) var count = 0
  /// Absolute frame up to which the tap has been turned into blocks.
  public private(set) var cursor = 0
  /// Frames the tap overwrote before this reader got to them (a stalled UI).
  public private(set) var lostFrames = 0
  /// Largest |sample| among the blocks the last `update` added: what scope.js feeds
  /// its auto-gain peak with.
  public private(set) var lastPeak: Float = 0

  private var scratch: [Float]
  private let analyzer = SpectrumAnalyzer(size: fftSize)

  /// Most that one `update` will fold in (0.7 s at 48 kHz); older audio is skipped.
  public static let maxFramesPerUpdate = 32768

  public init(tap: AudioTap, sampleRate: Double) {
    self.tap = tap
    self.sampleRate = sampleRate
    blockT = [Double](repeating: 0, count: Self.blockCapacity)
    blockMin = [Float](repeating: 0, count: Self.blockCapacity)
    blockMax = [Float](repeating: 0, count: Self.blockCapacity)
    blockSq = [Float](repeating: 0, count: Self.blockCapacity)
    scratch = [Float](repeating: 0, count: Self.maxFramesPerUpdate)
    cursor = tap.framesWritten
  }

  /// Engine time (seconds) of the newest frame the tap holds.
  public var now: Double { Double(tap.framesWritten) / sampleRate }

  /// Fold new audio into blocks. Returns how many blocks were added.
  @discardableResult
  public func update() -> Int {
    lastPeak = 0
    let bs = Self.blockSize
    // Drop a backlog bigger than one update can take, as readWaveform does when
    // `n > FFT_SIZE`.
    let w = tap.framesWritten
    if w - cursor > Self.maxFramesPerUpdate {
      lostFrames += w - cursor - Self.maxFramesPerUpdate
      cursor = (w - Self.maxFramesPerUpdate) / bs * bs
    }
    let got = scratch.withUnsafeMutableBufferPointer {
      tap.read(from: cursor, into: $0.baseAddress!, maxFrames: Self.maxFramesPerUpdate)
    }
    lostFrames += got.lost
    guard got.count > 0 else { return 0 }
    // Blocks sit on multiples of `bs` of the tap clock, so columns line up between updates.
    let firstEdge = (got.start + bs - 1) / bs * bs
    let skip = firstEdge - got.start
    let nb = max(0, (got.count - skip) / bs)
    if nb == 0 {
      if got.start > cursor { cursor = got.start }
      return 0
    }
    scratch.withUnsafeBufferPointer { p in
      for b in 0..<nb {
        var mn: Float = 1
        var mx: Float = -1
        var sq: Float = 0
        let a = skip + b * bs
        for i in a..<(a + bs) {
          let x = p[i]
          if x < mn { mn = x }
          if x > mx { mx = x }
          sq += x * x
        }
        blockT[head] = Double(got.start + a + bs) / sampleRate
        blockMin[head] = mn
        blockMax[head] = mx
        blockSq[head] = sq / Float(bs)
        head = (head + 1) % Self.blockCapacity
        if count < Self.blockCapacity { count += 1 }
        lastPeak = Swift.max(lastPeak, Swift.max(-mn, mx))
      }
    }
    cursor = got.start + skip + nb * bs
    return nb
  }

  /// Fold the blocks newer than `end - window` into `width` columns, newest at the right
  /// edge: `x = floor((t - t0) / window * width)`, scope.js `xOf`.
  public func columns(width: Int, window: Double, end: Double? = nil) -> WaveformColumns {
    var out = WaveformColumns(width: width)
    guard width > 0, window > 0 else { return out }
    let t1 = end ?? now
    let t0 = t1 - window
    for k in 1...Swift.max(1, count) where k <= count {
      let i = (head - k + Self.blockCapacity) % Self.blockCapacity
      let t = blockT[i]
      if t < t0 { break }
      let x = Int(((t - t0) / window * Double(width)).rounded(.down))
      guard x >= 0, x < width else { continue }
      if blockMin[i] < out.min[x] { out.min[x] = blockMin[i] }
      if blockMax[i] > out.max[x] { out.max[x] = blockMax[i] }
      out.sq[x] += blockSq[i]
      out.count[x] += 1
    }
    return out
  }

  /// The newest `n` raw samples (mono), oldest first.
  public func recent(_ n: Int = TapReader.fftSize) -> [Float] { tap.recent(n) }

  /// dB magnitude spectrum (`fftSize / 2` bins) of the newest `fftSize` samples: what an
  /// `AnalyserNode.getFloatFrequencyData` returns with `smoothingTimeConstant = 0`.
  public func spectrum() -> [Float] {
    var x = tap.recent(Self.fftSize)
    if x.count < Self.fftSize { x = [Float](repeating: 0, count: Self.fftSize - x.count) + x }
    return analyzer.decibels(x)
  }

  /// Frequency of bin `i`.
  public func binFrequency(_ i: Int) -> Double { Double(i) * sampleRate / Double(Self.fftSize) }
}

/// Real FFT with the Web Audio analyser's recipe: Blackman window (alpha 0.16), magnitude
/// divided by N, then `20 log10`. Allocates (main thread only).
public final class SpectrumAnalyzer {
  public let size: Int
  private let log2n: vDSP_Length
  private let setup: FFTSetup
  private var window: [Float]

  public init(size: Int) {
    precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
    self.size = size
    log2n = vDSP_Length(size.trailingZeroBitCount)
    setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    let a: Float = 0.16
    window = (0..<size).map { n in
      let x = Float(n) / Float(size)
      return (1 - a) / 2 - 0.5 * cosf(2 * .pi * x) + a / 2 * cosf(4 * .pi * x)
    }
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  /// Linear magnitude / N per bin (`size / 2` bins; bin 0 is DC).
  public func magnitudes(_ input: [Float]) -> [Float] {
    precondition(input.count == size)
    var windowed = [Float](repeating: 0, count: size)
    vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(size))
    let half = size / 2
    var re = [Float](repeating: 0, count: half)
    var im = [Float](repeating: 0, count: half)
    var out = [Float](repeating: 0, count: half)
    re.withUnsafeMutableBufferPointer { rp in
      im.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        windowed.withUnsafeBufferPointer { w in
          w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        // vDSP's packed real FFT is scaled by 2: undo that and the 1/N of the analyser.
        let scale = 1 / (2 * Float(size))
        for k in 0..<half {
          out[k] = (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot() * scale
        }
        out[0] = abs(rp[0]) * scale  // DC sits in re[0]; im[0] is Nyquist
      }
    }
    return out
  }

  /// `20 log10` of `magnitudes`, floored at -200 dB for silence.
  public func decibels(_ input: [Float]) -> [Float] {
    magnitudes(input).map { 20 * log10f(Swift.max($0, 1e-10)) }
  }
}
