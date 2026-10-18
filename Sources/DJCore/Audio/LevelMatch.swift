import Foundation
import Synchronization

/// One loudness for everything the user can play: a generated track, a sample or stock loop on
/// a deck, a take of either. Each lands at `referenceLUFS` (integrated, BS.1770) at unity knobs
/// (trim centred, EQ flat), before the channel fader:
///  * net decks (`WaveOptions.extended`): the track's loudness gain (`Loudness.targetDB`,
///    calibrated to this) and the deck's `PeakLimiter` (true peaks ≤ −1 dBTP);
///  * sample decks: `SampleLevel.autoGainDB`, measured when the audio loads (derived from the
///    audio alone, so a replay reproduces it), off per deck (`Deck.autoGain`);
///  * takes record the deck after its EQ, so they come out at the level the deck played.
public enum LevelMatch {
  /// The app's reference, LUFS. Commercial dance masters sit at −8…−12, Apple's loops at
  /// −11…−14 for full beats and leads; −12 puts a generated track beside them with drops that
  /// keep their transients (the net deck's limiter takes ~1 dB off its peaks there, measured
  /// by `djctl render`'s `limiter` report) and leaves the channel strips headroom.
  public static let referenceLUFS = -12.0
  /// Where a loop with only part of a mix in it (a bass line, a kick, hats: one band holding
  /// most of its energy, `SampleLevel.partial`) is aimed, against a full mix: one part of a mix
  /// sits under the whole, so layered on a full deck at equal faders it adds instead of
  /// covering it.
  public static let partialOffsetDB = -4.0
  /// The auto-gain stays within ± this (a near-silent hat loop is not boosted to the moon)…
  public static let maxGainDB = 12.0
  /// …and never lifts a sample's peak over this (dBFS): samples have no limiter, so a boost
  /// that would clip is cut back to the headroom the audio has.
  public static let samplePeakCeilingDB = -1.0
  /// The integrated target for a genre's tracks (`MixTargets.integratedLUFS`): its family's
  /// `lufs` band once measured, else `referenceLUFS` (every family, today).
  public static func targetLUFS(genre: String?) -> Double {
    MixTargets.shared.integratedLUFS(family: MixTargets.family(genre: genre))
  }
  /// Exit M7 (ROADMAP 6.6): whole songs of every genre, synth or sampled, land within this of
  /// each other (max − min, LU; `LoudnessSpreadTests`)…
  public static let maxSpreadLU = 2.0
  /// …and a centred A→B crossfade within this of either deck alone (equal-power: −3 dB each,
  /// two uncorrelated tracks at one loudness sum back to it).
  public static let crossfadeToleranceLU = 1.0
}

/// How loud a sample is and the auto-gain that puts it at the app's reference
/// (`LevelMatch`). A pure function of the audio: the same buffer always gets the same gain, so a
/// session or journal replay that loads it reproduces it without recording it.
public struct SampleLevel: Sendable, Equatable {
  /// Integrated loudness, LUFS (nil: silent).
  public var lufs: Double?
  /// Sample peak, dBFS.
  public var peakDB: Double
  /// Share of the (unweighted) energy below 150 Hz and above 4 kHz.
  public var lowShare: Double
  public var highShare: Double

  /// Only part of a mix (a bass, a kick, hats): most of the energy in the lows (≥ 80 % under
  /// 150 Hz, with next to nothing over 4 kHz: no hats) or the highs (≥ 50 % over 4 kHz). Apple's
  /// loops measure: basses 0.74–0.97 low / 0.00 high, hi-hats 0.94 high, full beats 0.05–0.4
  /// high (an 808 beat with soft hats can still read as a bass: it then sits 4 LU lower).
  public var partial: Bool { (lowShare >= 0.8 && highShare < 0.02) || highShare >= 0.5 }

  /// The loudness this sample is aimed at.
  public var targetLUFS: Double {
    LevelMatch.referenceLUFS + (partial ? LevelMatch.partialOffsetDB : 0)
  }

  /// dB to play it at: toward `targetLUFS`, within ±`maxGainDB`, and no boost past the peak
  /// ceiling. 0 for silence.
  public var autoGainDB: Double {
    guard let lufs else { return 0 }
    let m = LevelMatch.maxGainDB
    var g = min(m, max(-m, targetLUFS - lufs))
    g = min(g, max(0, LevelMatch.samplePeakCeilingDB - peakDB))
    return (g * 100).rounded() / 100
  }

  public init(lufs: Double?, peakDB: Double, lowShare: Double, highShare: Double) {
    self.lufs = lufs
    self.peakDB = peakDB
    self.lowShare = lowShare
    self.highShare = highShare
  }

  /// Measure `buffer` (as a loop: the filters run in from its end). Off the audio thread; tens
  /// of milliseconds for a loop in a release build, a few hundred for a long track.
  public init(_ buffer: SampleBuffer) {
    let n = buffer.length
    let mono = buffer.right == buffer.left
    lufs = IntegratedLoudness.integrated(
      left: buffer.left, right: mono ? nil : buffer.right, count: n,
      sampleRate: buffer.sampleRate, primeFrames: Int(buffer.sampleRate / 2))
    var peak: Float = 0
    var total = 0.0
    var low = 0.0
    var high = 0.0
    let lp = biquad(type: "lowpass", fc: 150, q: 0.7071, sr: buffer.sampleRate)
    let hp = biquad(type: "highpass", fc: 4000, q: 0.7071, sr: buffer.sampleRate)
    var l1 = 0.0
    var l2 = 0.0
    var h1 = 0.0
    var h2 = 0.0
    for i in 0..<n {
      let a = buffer.left[i]
      let b = buffer.right[i]
      peak = max(peak, max(abs(a), abs(b)))
      let x = 0.5 * (Double(a) + Double(b))
      total += x * x
      let yl = lp[0] * x + l1
      l1 = lp[1] * x - lp[3] * yl + l2
      l2 = lp[2] * x - lp[4] * yl
      low += yl * yl
      let yh = hp[0] * x + h1
      h1 = hp[1] * x - hp[3] * yh + h2
      h2 = hp[2] * x - hp[4] * yh
      high += yh * yh
    }
    peakDB = 20 * log10(max(Double(peak), 1e-10))
    lowShare = total > 0 ? min(1, low / total) : 0
    highShare = total > 0 ? min(1, high / total) : 0
  }

  public var dictionary: [String: Any] {
    var d: [String: Any] = [
      "peakDB": round3(peakDB), "lowShare": round3(lowShare), "highShare": round3(highShare),
      "partial": partial, "targetLUFS": targetLUFS, "autoGainDB": autoGainDB,
    ]
    if let lufs { d["lufs"] = round3(lufs) }
    return d
  }
}

extension SampleBuffer {
  /// `SampleLevel(self)`, measured once and kept (a buffer's audio never changes).
  public var level: SampleLevel {
    levelCache.withLock { cached in
      if let cached { return cached }
      let l = SampleLevel(self)
      cached = l
      return l
    }
  }
}

/// What the auto-gain does to a set of samples (`djctl levels`): each one's loudness as it is and
/// as a deck plays it, and the spread of both against their targets (a partial loop's is 4 LU
/// under a full mix's, so the spread is taken off each one's own target).
public struct LevelSurvey: Sendable {
  public struct Entry: Sendable {
    public var name: String
    public var category: String
    public var level: SampleLevel

    public init(name: String, category: String = "", level: SampleLevel) {
      self.name = name
      self.category = category
      self.level = level
    }

    /// LU off its target as it is (nil: silent).
    public var errorBefore: Double? { level.lufs.map { $0 - level.targetLUFS } }
    /// LU off its target as a deck plays it, auto-gain on.
    public var errorAfter: Double? { errorBefore.map { $0 + level.autoGainDB } }
    /// What kept it off its target: `peak` (the boost it wanted, after the ±12 dB clamp, was
    /// cut back to the peak ceiling) or `maxGain` (the clamp itself); nil when it lands within
    /// the tolerance or is silent. Decided from the gain actually applied: a sample past the
    /// clamp whose peak allowed less than the clamp is `peak`.
    public var limitedBy: String? {
      guard let e = errorAfter, abs(e) > LevelSurvey.toleranceLU, let lufs = level.lufs else {
        return nil
      }
      let m = LevelMatch.maxGainDB
      let want = min(m, max(-m, level.targetLUFS - lufs))
      let peakCap = max(0, LevelMatch.samplePeakCeilingDB - level.peakDB)
      return want > peakCap ? "peak" : "maxGain"
    }

    public var dictionary: [String: Any] {
      var d = level.dictionary
      d["name"] = name
      if !category.isEmpty { d["category"] = category }
      if let e = errorBefore { d["errorBeforeLU"] = round3(e) }
      if let e = errorAfter { d["errorAfterLU"] = round3(e) }
      if let l = limitedBy { d["limitedBy"] = l }
      return d
    }
  }

  /// A sample within this of its target counts as level matched.
  public static let toleranceLU = 1.5

  public var entries: [Entry]
  /// Samples that could not be read: name, why.
  public var failures: [(name: String, error: String)]

  public init(entries: [Entry], failures: [(name: String, error: String)] = []) {
    self.entries = entries
    self.failures = failures
  }

  /// Decode and measure each file (off the audio thread; at the decks' rate).
  public static func measure(
    _ files: [(name: String, category: String, url: URL)], sampleRate: Double = 48_000
  ) -> LevelSurvey {
    var entries: [Entry] = []
    var failures: [(name: String, error: String)] = []
    for f in files {
      do {
        let b = try Deck.decode(f.url, sampleRate: sampleRate)
        entries.append(Entry(name: f.name, category: f.category, level: b.level))
      } catch {
        failures.append((f.name, "\(error)"))
      }
    }
    return LevelSurvey(entries: entries, failures: failures)
  }

  /// `perCategory` stock loops from each category, evenly spaced through it by path: the same
  /// pick every run for the same library.
  public static func pick(_ loops: [StockLoop], perCategory: Int) -> [StockLoop] {
    let byCategory = Dictionary(grouping: loops, by: \.category)
    var out: [StockLoop] = []
    for c in byCategory.keys.sorted() {
      let all = byCategory[c]!.sorted { $0.path < $1.path }
      let n = min(perCategory, all.count)
      for i in 0..<n { out.append(all[i * all.count / max(n, 1)]) }
    }
    return out
  }

  /// max − min of the errors (LU), as is and as played; nil with nothing measured.
  public var spreadBefore: Double? { Self.range(entries.compactMap(\.errorBefore)) }
  public var spreadAfter: Double? { Self.range(entries.compactMap(\.errorAfter)) }
  /// The samples that miss their target by more than the tolerance as played.
  public var exceptions: [Entry] {
    entries.filter { e in e.errorAfter.map { abs($0) > Self.toleranceLU } ?? false }
  }

  private static func range(_ x: [Double]) -> Double? {
    guard let lo = x.min(), let hi = x.max() else { return nil }
    return hi - lo
  }

  private static func maxAbs(_ x: [Double]) -> Double? { x.map(abs).max() }

  public var summary: [String: Any] {
    var d: [String: Any] = [
      "measured": entries.count, "silent": entries.filter { $0.level.lufs == nil }.count,
      "toleranceLU": Self.toleranceLU,
      "within": entries.count - exceptions.count - entries.filter { $0.level.lufs == nil }.count,
      "exceptions": exceptions.map { e -> [String: Any] in
        var x: [String: Any] = ["name": e.name, "errorAfterLU": round3(e.errorAfter ?? 0)]
        if let l = e.limitedBy { x["limitedBy"] = l }
        return x
      },
    ]
    if let s = spreadBefore { d["spreadBeforeLU"] = round3(s) }
    if let s = spreadAfter { d["spreadAfterLU"] = round3(s) }
    if let m = Self.maxAbs(entries.compactMap(\.errorBefore)) { d["maxErrorBeforeLU"] = round3(m) }
    if let m = Self.maxAbs(entries.compactMap(\.errorAfter)) { d["maxErrorAfterLU"] = round3(m) }
    if !failures.isEmpty { d["failures"] = failures.map { ["name": $0.name, "error": $0.error] } }
    return d
  }
}

/// A deck's short-term loudness (BS.1770, the last 3 s) and momentary (400 ms), on the audio
/// thread: K-weighted squares summed per 100 ms into a ring of 30, published once per 100 ms.
/// Allocation-free after init. Readable from any thread.
final class LoudnessMeter: @unchecked Sendable {
  private var kl: KWeighting
  private var kr: KWeighting
  private let sub: Int
  private let ring: UnsafeMutablePointer<Double>
  private static let slots = 30
  private var slot = 0
  private var filled = 0
  private var acc = 0.0
  private var k = 0
  private let shortTermBits = Atomic<UInt64>((-200.0).bitPattern)
  private let momentaryBits = Atomic<UInt64>((-200.0).bitPattern)

  init(sampleRate: Double) {
    kl = KWeighting(sampleRate: sampleRate)
    kr = KWeighting(sampleRate: sampleRate)
    sub = max(1, Int(sampleRate / 10))
    ring = .allocate(capacity: Self.slots)
    ring.initialize(repeating: 0, count: Self.slots)
  }

  deinit { ring.deallocate() }

  /// Audio thread.
  func push(
    _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, frames: Int
  ) {
    for i in 0..<frames {
      let a = kl.process(Double(left[i]))
      let b = kr.process(Double((right ?? left)[i]))
      acc += a * a + b * b
      k += 1
      if k == sub {
        ring[slot] = acc / Double(sub)
        slot = slot + 1 == Self.slots ? 0 : slot + 1
        filled = min(Self.slots, filled + 1)
        acc = 0
        k = 0
        var s = 0.0
        var m = 0.0
        for j in 0..<filled {
          let v = ring[(slot - 1 - j + Self.slots) % Self.slots]
          s += v
          if j < 4 { m += v }
        }
        let st = s / Double(filled)
        let mo = m / Double(min(4, filled))
        shortTermBits.store(
          (st > 1e-20 ? -0.691 + 10 * log10(st) : -200).bitPattern, ordering: .relaxed)
        momentaryBits.store(
          (mo > 1e-20 ? -0.691 + 10 * log10(mo) : -200).bitPattern, ordering: .relaxed)
      }
    }
  }

  var shortTermLUFS: Double { Double(bitPattern: shortTermBits.load(ordering: .relaxed)) }
  var momentaryLUFS: Double { Double(bitPattern: momentaryBits.load(ordering: .relaxed)) }
}
