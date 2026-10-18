import Accelerate
import Foundation

/// Section boundaries of a render or a reference file, in its own bars (ROADMAP 6.1: a
/// reference's section lengths). Offline, on the main thread or any worker; never the audio
/// thread.
///
/// 1. Bars: the downbeats `BeatTracker` finds (or a grid the caller knows). Each bar runs from
///    one downbeat to the next; the last one to its start plus the median bar, if it fits.
/// 2. Features, one vector per bar (bar-synchronous, so a section change lands on a bar line):
///    `bandCount` log-spaced band energies (dB, `minHz`…`maxHz`), a 12-bin chroma (magnitudes
///    folded by pitch class, `chromaMinHz`…`chromaMaxHz`, summing to 1) and the bar's RMS (dB),
///    from Hann frames of ~93 ms, half overlapped, averaged over the frames centred in the bar.
///    Each dimension is z-scored across the bars (its deviation floored at `sdFloorDB` /
///    `sdFloorChroma`) and each group scaled by 1/√dims, so bands, chroma and level weigh alike.
/// 3. A cosine self-similarity matrix of those vectors (norms floored at `normFloor`, so a
///    steady loop's bars are similar to nothing and make no novelty).
/// 4. Foote novelty (2000): a Gaussian-tapered checkerboard kernel, `kernelBars` bars a side,
///    slid along the diagonal; at bar b it compares bars b-k…b-1 with b…b+k-1. Near the ends
///    the kernel is cut and renormalised by the weight it keeps, and needs `minSide` bars on
///    each side.
/// 5. Peaks: a bar whose novelty is the largest within ±`peakRadius` bars (`kernelBars` / 2),
///    above `threshold` standard deviations over the mean novelty and at least `minNovelty`.
///
/// Ground truth so far is our own synth renders, whose structure we know
/// (SectionSegmenterTests); today's structures hold 4-bar sections, so the kernel stays short.
public struct SectionSegmenter: Sendable {
  public static let kernelBars = 4
  public static let bandCount = 8
  public static let minHz = 40.0
  public static let maxHz = 16_000.0
  public static let chromaMinHz = 60.0
  public static let chromaMaxHz = 4_000.0
  /// Bars the kernel needs on each side of a boundary.
  public static let minSide = 2
  /// Standard deviations over the mean novelty a peak must reach.
  public static let threshold = 0.5
  /// The least novelty a peak must reach (cosine units, -2…2).
  public static let minNovelty = 0.05
  /// The least standard deviation a feature is scaled by: 1 dB for bands and RMS, 0.01 of a
  /// chroma's total.
  public static let sdFloorDB = 1.0
  public static let sdFloorChroma = 0.01
  /// The least norm a bar's vector is divided by in the similarity (a bar a group's standard
  /// deviation off the mean in every dimension has norm √3).
  public static let normFloor = 0.5

  /// Bar start times, seconds (the bars measured).
  public var barStarts: [Double] = []
  /// The bar the tracker or caller gave, seconds (median).
  public var barSeconds = 0.0
  /// Tempo, BPM, when the bars came from `BeatTracker` (else 0).
  public var bpm = 0.0
  /// The kernel used, bars a side.
  public var kernel = SectionSegmenter.kernelBars
  /// Cosine self-similarity of the bars' feature vectors.
  public var similarity: [[Double]] = []
  /// Foote novelty at each bar's start (0 where the kernel does not fit).
  public var novelty: [Double] = []
  /// Section starts, bar indices (bar 0 is the start of the first section, not listed).
  public var boundaries: [Int] = []

  /// Section starts, seconds.
  public var boundaryTimes: [Double] { boundaries.map { barStarts[$0] } }

  /// The sections' lengths in bars, first to last (they sum to the bars measured).
  public var sectionBars: [Int] {
    guard !barStarts.isEmpty else { return [] }
    let edges = [0] + boundaries + [barStarts.count]
    return zip(edges, edges.dropFirst()).map { $1 - $0 }
  }

  /// Bars from `BeatTracker`'s downbeats over the mid of the two channels.
  public init(
    left: [Float], right: [Float], sampleRate sr: Double, kernelBars: Int = Self.kernelBars
  ) {
    let n = min(left.count, right.count)
    var mono = [Float](repeating: 0, count: n)
    var h: Float = 0.5
    vDSP_vasm(left, 1, right, 1, &h, &mono, 1, vDSP_Length(n))
    self.init(mono: mono, sampleRate: sr, kernelBars: kernelBars)
  }

  /// Bars from `BeatTracker`'s downbeats.
  public init(mono x: [Float], sampleRate sr: Double, kernelBars: Int = Self.kernelBars) {
    let b = BeatTracker(mono: x, sampleRate: sr)
    self.init(mono: x, sampleRate: sr, downbeats: b.downbeats, kernelBars: kernelBars)
    bpm = b.bpm
  }

  /// Bars on a known grid: `downbeats` (seconds, ascending), e.g. a render's own bar lines.
  public init(
    mono x: [Float], sampleRate sr: Double, downbeats: [Double], kernelBars: Int = Self.kernelBars
  ) {
    kernel = max(1, kernelBars)
    guard sr > 0, downbeats.count >= 2 else { return }
    let end = Double(x.count) / sr
    let gaps = zip(downbeats, downbeats.dropFirst()).map { $1 - $0 }.sorted()
    barSeconds = gaps[gaps.count / 2]
    var starts = downbeats.filter { $0 >= 0 && $0 < end }
    if let last = starts.last, last + barSeconds > end + 0.25 * barSeconds { starts.removeLast() }
    guard starts.count >= 2 else { return }
    barStarts = starts
    let features = Self.features(x, sampleRate: sr, barStarts: starts, barSeconds: barSeconds)
    similarity = Self.cosineSimilarity(features)
    novelty = Self.novelty(similarity, kernel: kernel)
    boundaries = Self.peaks(novelty, radius: max(1, kernel / 2))
  }

  /// What `djctl measure --sections` prints.
  public var dictionary: [String: Any] {
    var d: [String: Any] = [
      "bars": barStarts.count,
      "barSeconds": round3(barSeconds),
      "kernelBars": kernel,
      "boundaries": boundaries,
      "boundarySeconds": boundaryTimes.map(round3),
      "sectionBars": sectionBars,
      "novelty": novelty.map(round3),
    ]
    if bpm > 0 { d["bpm"] = round3(bpm) }
    if let first = barStarts.first { d["firstBarSeconds"] = round3(first) }
    return d
  }

  // MARK: - Features

  /// The analysis frame: the power of two nearest 93 ms (2048 at 22.05 kHz, 4096 at 44.1k).
  static func frameSize(_ sr: Double) -> Int {
    1 << max(9, Int((log2(sr * 0.093)).rounded()))
  }

  /// One vector per bar: bands (dB), chroma (sums to 1), RMS (dB); each dimension z-scored
  /// across bars, each group scaled by 1/√dims.
  static func features(
    _ x: [Float], sampleRate sr: Double, barStarts: [Double], barSeconds: Double
  ) -> [[Double]] {
    let bars = barStarts.count
    let size = frameSize(sr)
    let half = size / 2
    let hop = half
    let binHz = sr / Double(size)
    // band and pitch class of each bin (-1: outside)
    let edges = (0...bandCount).map {
      minHz * pow(maxHz / minHz, Double($0) / Double(bandCount))
    }
    var bandOf = [Int](repeating: -1, count: half)
    var classOf = [Int](repeating: -1, count: half)
    for k in 1..<half {
      let f = Double(k) * binHz
      if f >= minHz, f < min(maxHz, sr / 2) {
        bandOf[k] = min(bandCount - 1, edges.lastIndex { $0 <= f } ?? 0)
      }
      if f >= chromaMinHz, f < chromaMaxHz {
        let midi = 69 + 12 * log2(f / 440)
        classOf[k] = ((Int(midi.rounded()) % 12) + 12) % 12
      }
    }
    var bandSum = [[Double]](repeating: [Double](repeating: 0, count: bandCount), count: bars)
    var chroma = [[Double]](repeating: [Double](repeating: 0, count: 12), count: bars)
    var frames = [Int](repeating: 0, count: bars)
    func bar(at t: Double) -> Int? {
      guard let first = barStarts.first, t >= first, t < barStarts[bars - 1] + barSeconds
      else { return nil }
      var lo = 0
      var hi = bars - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if barStarts[mid] <= t { lo = mid } else { hi = mid - 1 }
      }
      return lo
    }
    if x.count >= size {
      let log2n = vDSP_Length(log2(Double(size)))
      if let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) {
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var buf = [Float](repeating: 0, count: size)
        var re = [Float](repeating: 0, count: half)
        var im = re
        var mag = re
        let count = (x.count - size) / hop + 1
        x.withUnsafeBufferPointer { xp in
          for f in 0..<count {
            guard let b = bar(at: (Double(f * hop) + Double(half)) / sr) else { continue }
            vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &buf, 1, vDSP_Length(size))
            re.withUnsafeMutableBufferPointer { rp in
              im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                  bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                  }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0  // Nyquist, packed
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
              }
            }
            for k in 1..<half {
              let m = Double(mag[k])
              if bandOf[k] >= 0 { bandSum[b][bandOf[k]] += m * m }
              if classOf[k] >= 0 { chroma[b][classOf[k]] += m }
            }
            frames[b] += 1
          }
        }
      }
    }
    // RMS straight from the samples
    var rms = [Double](repeating: 0, count: bars)
    for b in 0..<bars {
      let a = max(0, min(x.count, Int(barStarts[b] * sr)))
      let e =
        b + 1 < bars
        ? Int(barStarts[b + 1] * sr) : Int((barStarts[b] + barSeconds) * sr)
      let z = max(a, min(x.count, e))
      var ms: Float = 0
      if z > a {
        x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + a, 1, &ms, vDSP_Length(z - a)) }
      }
      rms[b] = 10 * log10(Double(ms) + 1e-12)
    }
    var bands = bandSum
    for b in 0..<bars {
      let n = Double(max(1, frames[b]))
      bands[b] = bandSum[b].map { 10 * log10($0 / n + 1e-12) }
      let total = chroma[b].reduce(0, +)
      chroma[b] =
        total > 0 ? chroma[b].map { $0 / total } : [Double](repeating: 1.0 / 12, count: 12)
    }
    let groups = [
      zScored(bands, floor: sdFloorDB), zScored(chroma, floor: sdFloorChroma),
      zScored(rms.map { [$0] }, floor: sdFloorDB),
    ]
    return (0..<bars).map { b in
      groups.flatMap { g in
        let s = 1 / Double(g[b].count).squareRoot()
        return g[b].map { $0 * s }
      }
    }
  }

  /// Each dimension minus its mean over the rows, over its standard deviation or `floor`,
  /// whichever is larger (so a steady loop's last-digit wobble is not blown up to a section).
  static func zScored(_ rows: [[Double]], floor: Double = 0) -> [[Double]] {
    guard let dims = rows.first?.count, !rows.isEmpty else { return rows }
    var out = rows
    let n = Double(rows.count)
    for d in 0..<dims {
      let mean = rows.reduce(0) { $0 + $1[d] } / n
      let sd = (rows.reduce(0) { $0 + ($1[d] - mean) * ($1[d] - mean) } / n).squareRoot()
      let div = max(sd, floor)
      for r in rows.indices { out[r][d] = div > 1e-9 ? (rows[r][d] - mean) / div : 0 }
    }
    return out
  }

  /// Cosine similarity of every pair of rows, each norm at least `normFloor` (rows that hardly
  /// leave the mean are similar to nothing, rather than to whatever their noise points at).
  static func cosineSimilarity(_ v: [[Double]]) -> [[Double]] {
    let norms = v.map { max(normFloor, $0.reduce(0) { $0 + $1 * $1 }.squareRoot()) }
    var s = [[Double]](repeating: [Double](repeating: 0, count: v.count), count: v.count)
    for i in v.indices {
      for j in i..<v.count {
        let d = norms[i] * norms[j]
        var dot = 0.0
        for k in v[i].indices { dot += v[i][k] * v[j][k] }
        let c = dot / d
        s[i][j] = c
        s[j][i] = c
      }
    }
    return s
  }

  // MARK: - Novelty

  /// Foote novelty at each bar's start: a Gaussian-tapered checkerboard of `kernel` bars a
  /// side (σ = kernel / 2), cut at the ends and renormalised by the weight it keeps; 0 with
  /// fewer than `minSide` bars on either side.
  static func novelty(_ s: [[Double]], kernel k: Int) -> [Double] {
    let n = s.count
    var out = [Double](repeating: 0, count: n)
    let sigma = max(0.5, Double(k) / 2)
    let side = min(minSide, k)
    guard n >= 2 * side else { return out }
    for b in side...(n - side) where b < n {
      var sum = 0.0
      var weight = 0.0
      for i in -k..<k where b + i >= 0 && b + i < n {
        for j in -k..<k where b + j >= 0 && b + j < n {
          let ti = Double(i) + 0.5
          let tj = Double(j) + 0.5
          let g = exp(-(ti * ti + tj * tj) / (2 * sigma * sigma))
          let sign: Double = (i < 0) == (j < 0) ? 1 : -1
          sum += sign * g * s[b + i][b + j]
          weight += g
        }
      }
      // weight / 2 per same-side and cross-side half: novelty is mean within − mean across
      out[b] = weight > 0 ? 2 * sum / weight : 0
    }
    return out
  }

  /// Bars whose novelty is the largest within ±`radius`, over mean + `threshold`·sd of the
  /// bars where the kernel fits, and at least `minNovelty`.
  static func peaks(_ nov: [Double], radius: Int) -> [Int] {
    let valid = nov.filter { $0 != 0 }
    guard !valid.isEmpty else { return [] }
    let mean = valid.reduce(0, +) / Double(valid.count)
    let sd = (valid.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(valid.count))
      .squareRoot()
    let floor = max(minNovelty, mean + threshold * sd)
    var out: [Int] = []
    for b in nov.indices where b > 0 && nov[b] >= floor {
      let lo = max(0, b - radius)
      let hi = min(nov.count - 1, b + radius)
      // the largest in reach; on a tie, the first
      let isPeak = (lo...hi).allSatisfy { j in
        j == b || nov[j] < nov[b] || (nov[j] == nov[b] && j > b)
      }
      if isPeak { out.append(b) }
    }
    return out
  }
}
