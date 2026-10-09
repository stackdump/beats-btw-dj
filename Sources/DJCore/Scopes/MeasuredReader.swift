// MeasuredReader: the MEASURED half of the analytic scopes (SPEC modes 3 and 5): scope.js
// `ensureAnalyser`'s bin tables and `readMeasured`, pinned at beats-bitwrap-io 095d030. Mode 3
// (the measured spectrogram) draws its frame ring; mode 5 (Bands) will consume the per-bar
// accumulation, which is already here.
//
// WHAT IT DOES. Once per drawn frame (`update(feed:enabled:)`) it takes the newest 4096 samples
// of the feed's history, runs `AnalyserFFT` (fftSize 4096, smoothing 0: 2048 bins of dB, a browser
// `getFloatFrequencyData`), and sums power over the 33 analysis rows (`ModelGrid.edges`: the 5
// bands, then the 28 spectrogram bins):
//
//     p[j] = Σ_{k in binLo[j] ..< binHi[j]}  10^(dB_k / 10)       (bins at or below -200 dB skipped)
//
// then
//   * BARS (mode 5): the step at "now" (the anchor at or before it plus the time since, at
//     `tickSec`) picks the bar; `measBars[bar * 6 + b] += p[b]` for the five bands and column 5
//     (E) += their sum, `measCnt[bar] += 1`, `maxBar`, `measFrom` (the first step seen since the
//     last reset or re-enable), `measAt` (the latest step seen). The mean power of a bar is
//     `measBars / measCnt` (`measDb(bar:row:)`). All of them are indexed by SONG STEP/BAR of the
//     feed's lead deck, the same axis as `ModelEngine.modelBars`, and reset together with it.
//   * FRAMES (mode 3): `10·log10(p[5 + j] + 1e-20)` of the 28 spectrogram rows, with the time of
//     the read, into a ring of 512 frames (`frames`).
//
// UNITS. `p` is a sum of squared NORMALISED magnitudes, `|X_k|/N` (the dB of an analyser bin is
// `20·log10` of that), not the Σx² of the time signal that `ModelEngine` speaks: a unit sine of
// amplitude A through the Blackman window reads `A²/4 · 0.3046` (0.3046 = mean of the squared
// window), the same sine is `N·A²/2` in Σx². The two sides therefore differ by a per-band offset
// (and by the analyser's window and the master's tanh) that a comparison removes by taking each
// side's mean per band, as the JS residual does; do not compare their levels directly.
//
// Row bin ranges (`MeasuredBins`) come from the edges and the SAMPLE RATE of the feed:
// `df = sr / 4096`, `a = max(1, round(lo / df))`, `hi = min(2048, max(a + 1, round(hi / df)))`
// (a row above Nyquist is an empty range and reads 0 power, -200 dB).
//
// THE CONTRACT FOR A MODE.
//   * One reader per feed: `MeasuredReaderStore.shared.reader(for: feed)`. It outlives the view
//     (the host builds a new view for every switch of scope kind), so the bars and frames carry
//     over a switch from Spectro to Bands. Both modes call `update(feed:enabled:)` every drawn
//     frame with the panel's `measured` flag; when it is false the reader does NOTHING (no FFT, no
//     ring writes), as the JS stops reading when "measured" is unticked. Unlike the JS, which
//     reads in `frame()` whichever view is open, only the mode that is drawing reads: a stretch
//     spent in Scope/Live or Raster leaves a gap in the bars (and in the frames, which draw as
//     black slices after the 0.25 s rule).
//   * Cadence. `analyse` is called once per `update` that finds new audio, at the drawn-frame
//     rate (<= 30 Hz through the pacer). Smoothing is 0, so there is no cadence-dependent state; a
//     second `update` in the same frame (no new audio since: `feed.nowFrame` is the guard) is
//     free and changes nothing.
//   * The audio read is `feed.history` up to `feed.nowFrame`, stamped with `feed.nowTime`: the
//     same "now" as every time axis. A deck feed is the deck's mono mixdown (pre-EQ, pre-fader); a
//     master feed is the master tap. Samples the history does not hold read as 0.
//   * `maxBar` here is the MEASURED side's last bar. The JS keeps one `maxBar` for both sides; a
//     mode that walks `0...maxBar` over both takes `max(model.maxBar, reader.maxBar)`.
//   * `measFrom` and `measAt` are Doubles in steps (the JS stores the fractional step), `Infinity`
//     and -1 when empty.
//
// RESETS. The bars (`measBars`, `measCnt`, `maxBar`, `measFrom`, `measAt`) are cleared when
// `feed.generation` changes (the feed's lanes, anchors and song restart) and, on a master feed,
// when the lead deck or its song changes: exactly when `ModelEngine` empties its bars, so a
// residual of the two compares like with like. The FRAME RING is NOT cleared: it is measured
// audio keyed by engine time, true across a track change (the JS `resetHistory` clears it, which
// would blank the master's spectrogram whenever the other deck loads a track; mode 1 keeps its
// waveform ring for the same reason). A gap in time (re-acquire) shows as black slices.
// Re-enabling `measured` restarts the coverage window (`measFrom = Infinity`), as the JS does.

import Foundation

// MARK: - bin tables

/// scope.js `ensureAnalyser`'s `binLo` / `binHi`: which FFT bins make up each of the 33 rows at a
/// sample rate.
public struct MeasuredBins: Equatable, Sendable {
  /// scope.js `FFT_SIZE`.
  public static let fftSize = 4096
  /// `frequencyBinCount`.
  public static let binCount = fftSize / 2

  public let sampleRate: Double
  /// First bin of every row (`ModelGrid.nr` values).
  public let lo: [Int]
  /// One past the last bin of every row; a row with `hi <= lo` is empty.
  public let hi: [Int]

  /// A non-positive or non-finite rate counts as 44100.
  public init(sampleRate: Double) {
    let sr = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 44100
    self.sampleRate = sr
    let df = sr / Double(Self.fftSize)
    var lo: [Int] = []
    var hi: [Int] = []
    for e in ModelGrid.edges {
      let a = Int(min(1e9, max(1, jsRound(e.lo / df))))
      let b = Int(min(1e9, jsRound(e.hi / df)))
      lo.append(a)
      hi.append(min(Self.binCount, max(a + 1, b)))
    }
    self.lo = lo
    self.hi = hi
  }

  /// The power of every row for one analysis: `Σ 10^(dB/10)` over the row's bins, skipping bins
  /// at or below -200 dB (silence is -∞), accumulated in double and stored as float (the JS
  /// `mpow` is a Float32Array). `decibels` is `getFloatFrequencyData` (2048 values).
  public func power(decibels: UnsafeBufferPointer<Float>, into p: UnsafeMutableBufferPointer<Float>)
  {
    let n = min(p.count, lo.count)
    for j in 0..<n {
      var sum = 0.0
      var k = lo[j]
      let end = min(hi[j], decibels.count)
      while k < end {
        sum += AnalyserFFT.measuredPower(decibels: decibels[k])
        k += 1
      }
      p[j] = Float(sum)
    }
  }

  /// `power` as arrays (tests and one-off reads).
  public func power(decibels: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: lo.count)
    decibels.withUnsafeBufferPointer { d in
      out.withUnsafeMutableBufferPointer { power(decibels: d, into: $0) }
    }
    return out
  }
}

// MARK: - frames

/// The measured spectrogram's frames (scope.js `mspT`, `mspV`, `mspHead`, `mspCount`): the newest
/// 512 reads, each the time of the read and the 28 rows in dB.
public struct MeasuredFrameRing: Sendable {
  /// scope.js `MSPEC_CAP`.
  public static let capacity = 512
  public static let rows = ModelGrid.ns

  // Allocated by the first push, so an empty ring costs nothing.
  private var ts: [Double] = []
  private var vs: [Float] = []
  private var head = 0
  /// Frames held (<= capacity).
  public private(set) var count = 0

  public init() {}

  public var isEmpty: Bool { count == 0 }

  /// Add a frame: `values` are the 28 rows' dB (`rows` values; extras ignored, missing ones 0).
  public mutating func push(time: Double, values: [Float]) {
    if ts.isEmpty {
      ts = [Double](repeating: 0, count: Self.capacity)
      vs = [Float](repeating: 0, count: Self.capacity * Self.rows)
    }
    ts[head] = time
    let o = head * Self.rows
    for j in 0..<Self.rows { vs[o + j] = j < values.count ? values[j] : 0 }
    head = (head + 1) % Self.capacity
    if count < Self.capacity { count += 1 }
  }

  private func slot(newest k: Int) -> Int { (head - k + Self.capacity) % Self.capacity }

  /// Time of the `k`-th newest frame, `k` in 1...count (1 = the newest).
  public func time(newest k: Int) -> Double { ts[slot(newest: k)] }

  /// Row `j` (0 = lowest) of the `k`-th newest frame, in dB.
  public func value(newest k: Int, row j: Int) -> Float { vs[slot(newest: k) * Self.rows + j] }

  public mutating func removeAll() {
    head = 0
    count = 0
  }
}

// MARK: - the reader

@MainActor
public final class MeasuredReader {
  public static let rows = ModelGrid.rows
  public static let maxBars = ModelGrid.maxBars

  /// The analyser: fftSize 4096, smoothing 0.
  public let analyser = AnalyserFFT(
    fftSize: MeasuredBins.fftSize, smoothingTimeConstant: 0)
  /// The row bin ranges at the feed's sample rate.
  public private(set) var bins = MeasuredBins(sampleRate: 44100)
  /// The last read's power per row (`ModelGrid.nr` values; scope.js `mpow`).
  public private(set) var power = [Float](repeating: 0, count: ModelGrid.nr)
  /// The spectrogram frames.
  public private(set) var frames = MeasuredFrameRing()

  /// `bar * rows + b`: the five bands' summed power per read, column 5 = E (their sum).
  public private(set) var measBars = [Double](
    repeating: 0, count: ModelGrid.maxBars * ModelGrid.rows)
  /// Reads that landed in each bar.
  public private(set) var measCnt = [Float](repeating: 0, count: ModelGrid.maxBars)
  /// The last bar with a read (-1: none). The measured side's own; see the header.
  public private(set) var maxBar = -1
  /// The first (fractional) step read since the last reset or re-enable; `.infinity` for none.
  public private(set) var measFrom = Double.infinity
  /// The latest (fractional) step read; -1 for none.
  public private(set) var measAt = -1.0
  /// Reads done (frames pushed), never reset.
  public private(set) var reads = 0

  private var window = [Float](repeating: 0, count: MeasuredBins.fftSize)
  private var decibels = [Float](repeating: 0, count: MeasuredBins.binCount)
  private var frameValues = [Float](repeating: 0, count: ModelGrid.ns)
  private var binsFor = 44100.0
  private var wasEnabled = false
  private var lastFrame = -1
  private var generation = 0
  private var leadKey: LeadKey?

  private struct LeadKey: Equatable {
    var deck: String?
    var serial: Int32
  }

  public init() {}

  // MARK: reading

  /// One drawn frame. `enabled` is the panel's "measured" flag: false does nothing at all (and
  /// the next true starts a fresh coverage window). True: forget the bars if the feed's
  /// generation (or a master's lead) changed, then read the newest 4096 samples if the engine
  /// has moved since the last read. Idempotent within a frame.
  public func update(feed: ScopeFeed, enabled: Bool) {
    guard enabled else {
      wasEnabled = false
      return
    }
    if feed.generation != generation {
      generation = feed.generation
      resetBars()
    }
    if feed.source == .master {
      let key = LeadKey(deck: feed.leadDeck, serial: feed.trackSerial)
      if key != leadKey {
        leadKey = key
        resetBars()
      }
    }
    if !wasEnabled {
      wasEnabled = true
      measFrom = .infinity
    }
    let end = feed.nowFrame
    guard end != lastFrame else { return }
    lastFrame = end
    window.withUnsafeMutableBufferPointer {
      feed.history.copyWindow(into: $0, endingAt: end)
    }
    ingest(
      window: window, sampleRate: feed.sampleRate, time: feed.nowTime,
      anchor: feed.anchorAt(feed.nowTime), tickSec: feed.tickSec)
  }

  /// scope.js `readMeasured` on a window of samples the caller cut: analyse it (the newest 4096
  /// are used, a shorter window is zero-padded at the front), sum the rows, add the read to its
  /// bar and push the frame. `time` is the audio time of the window's last sample; `anchor` the
  /// step anchor at or before it (nil: no bars, as the JS without one).
  public func ingest(
    window samples: [Float], sampleRate: Double, time tNow: Double, anchor: ScopeAnchor?,
    tickSec: Double
  ) {
    guard tNow.isFinite else { return }
    if binsFor != sampleRate {
      binsFor = sampleRate
      bins = MeasuredBins(sampleRate: sampleRate)
    }
    analyser.analyse(samples)
    decibels.withUnsafeMutableBufferPointer { analyser.floatFrequencyData(into: $0) }
    decibels.withUnsafeBufferPointer { d in
      power.withUnsafeMutableBufferPointer { bins.power(decibels: d, into: $0) }
    }
    // bars: the mean power per bar, mapped through the step anchors
    if let a = anchor {
      let step = Double(a.step) + (tNow - a.time) / tickSec
      let barD = (step / 16).rounded(.down)
      if step.isFinite, barD >= 0, barD < Double(Self.maxBars) {
        let bar = Int(barD)
        let o = bar * Self.rows
        var sum = 0.0
        for b in 0..<ModelGrid.nb {
          let x = Double(power[b])
          measBars[o + b] += x
          sum += x
        }
        measBars[o + ModelGrid.nb] += sum
        measCnt[bar] += 1
        if bar > maxBar { maxBar = bar }
        if step < measFrom { measFrom = step }
        measAt = step
      }
    }
    // the frame: 10·log10(p + 1e-20) of the spectrogram rows, as float
    for j in 0..<ModelGrid.ns {
      frameValues[j] = Float(10 * log10(Double(power[ModelGrid.nb + j]) + 1e-20))
    }
    frames.push(time: tNow, values: frameValues)
    reads += 1
  }

  /// scope.js `measDb`: `10·log10` of the mean power of bar `bar`, row `row` (0...4 the bands,
  /// 5 = E); nil when the bar has no read or no power.
  public func measDb(bar: Int, row: Int) -> Double? {
    guard bar >= 0, bar < Self.maxBars, row >= 0, row < Self.rows else { return nil }
    let n = measCnt[bar]
    let v = n > 0 ? measBars[bar * Self.rows + row] / Double(n) : 0
    return v > 0 ? 10 * log10(v) : nil
  }

  // MARK: resetting

  /// The bar accumulation back to empty (the part of scope.js `resetHistory` that is about bars).
  public func resetBars() {
    for i in measBars.indices { measBars[i] = 0 }
    for i in measCnt.indices { measCnt[i] = 0 }
    maxBar = -1
    measFrom = .infinity
    measAt = -1
  }

  /// Everything: bars, frames, the analyser's state. For tests and an explicit restart.
  public func reset() {
    resetBars()
    frames.removeAll()
    analyser.reset()
    lastFrame = -1
    wasEnabled = false
  }
}

// MARK: - one reader per feed

/// The readers of the measured modes, one per feed (see the header). Keyed by the feed's identity
/// and checked against a weak reference to it, so an entry of a feed that is gone is never handed
/// to a new feed that reuses its address.
@MainActor
public final class MeasuredReaderStore {
  public static let shared = MeasuredReaderStore()

  private struct Entry {
    weak var feed: ScopeFeed?
    let reader: MeasuredReader
  }

  private var entries: [ObjectIdentifier: Entry] = [:]

  public init() {}

  /// Readers held for feeds that still exist.
  public var count: Int { entries.values.filter { $0.feed != nil }.count }

  /// The reader of `feed`: the same object every time, made on the first ask.
  public func reader(for feed: ScopeFeed) -> MeasuredReader {
    let id = ObjectIdentifier(feed)
    if let e = entries[id], e.feed === feed { return e.reader }
    entries = entries.filter { $0.value.feed != nil }
    let r = MeasuredReader()
    entries[id] = Entry(feed: feed, reader: r)
    return r
  }
}
