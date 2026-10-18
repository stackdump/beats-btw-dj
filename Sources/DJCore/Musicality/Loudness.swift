import Foundation

/// Per-track gain so every track plays at about the same loudness (`DJMusicality.Fixes.loudness`).
///
/// beats' wave engine sums every voice and pushes the sum through `tanh(× 0.8)`: dense genres
/// sit in that curve all the time (−13 LUFS with −1 dB peaks: squashed), sparse ones come out
/// 10 dB quieter (lofi, jazz, ambient ≈ −23 LUFS). A DJ needs tracks at one level. This
/// measures what the track's loudest section would play, K-weighted like a loudness meter, and
/// returns the gain that puts it at `targetDB` before the curve — computed from the project
/// alone, so every prepare of the same track (a section jump, a replay) gets the same gain.
public enum Loudness {
  /// Loudness the busiest section is brought to, in dB of K-weighted mean square of the summed
  /// voices after the master gain: calibrated so a whole track plays at the app's reference
  /// (`LevelMatch.referenceLUFS`, integrated; the probe's two bars of the busiest section read
  /// about 0.4 dB under a whole track's integrated loudness, measured over six genres). The deck's
  /// `PeakLimiter` holds the peaks this brings over −1 dBTP. (Was −18 under beats' tanh curve:
  /// −17…−22 LUFS, about 10 dB under a stock loop.) The 0.4 is `targets.json`'s
  /// `loudness.probeOffsetDB` (`MixTargets`).
  public static let targetDB =
    LevelMatch.referenceLUFS + MixTargets.shared.loudness.probeOffsetDB.value!
  /// The gain stays within −12…+18 dB (the sparsest genres — lofi, ambient — need about +13 at
  /// the app's reference): `targets.json`'s `loudness.gainRange`.
  public static let range = (
    min: MixTargets.shared.loudness.gainRange.min, max: MixTargets.shared.loudness.gainRange.max
  )
  /// Probe length and rate: two bars of the loudest section, rendered at a low rate (a
  /// prepare in a debug build stays near a tenth of a second).
  static let probeBars = 2
  static let probeRate = 8_000.0

  /// How much quieter a part plays on a sampled instrument than on its synth voice, in a
  /// track (dB, by group): the fallback for a slot with no measured part level of its own. The
  /// probe can't play the deck's samplers, so it plays each sampled part's synth voice where
  /// the slot sits: the slot's `SamplerInstrument.partLevelDB` (measured at its load, which
  /// prepare waits for, so the same spec gets the same gain cold or cached) plus its `.balance`
  /// gain (`SampledBalance.probeLevel`). Only a bank that skipped the probes falls back here, to
  /// the palette's average: samplers are levelled on a short reference phrase to the lead voice
  /// (`SamplerInstrument.targetRMSdB`), so in a song they sit under the synth part they
  /// replace — most of all pads (slow attacks, long notes) and basses. Measured
  /// (`LevelSurveyTests.sampledPartsAgainstTheirSynthVoices`: soloed parts, 40 s of seed 4242,
  /// ten genres, the default palette, Studio; mean ± spread): bass −4.1 ± 1.9, harmony −5.0 ±
  /// 1.3, melody −1.7 ± 1.5 (2026-10-18; was −4.3 / −5.8 / −1.6). No genre plays its arp on a
  /// sampler there, so arps take the melody's.
  public static let sampledPartDB: [String: Double] = [
    "bass": -4.1, "harmony": -5.0, "melody": -1.7,
  ]

  /// The linear level the probe plays a sampled `group` part's synth voice at: `measuredDB`
  /// (the slot's part level) when there is one, else the table's average.
  static func sampledPartLevel(group: String, measuredDB: Double? = nil) -> Double {
    pow(10, (measuredDB ?? sampledPartDB[group] ?? sampledPartDB["melody"]!) / 20)
  }

  /// The fixes that change how the voices themselves sound (and so how loud they are): the
  /// probe plays those of the deck's, so the gain is measured on the voices the deck plays.
  /// (`.subOctave` plays only where the deck's options turn it on: `subOctave` below.)
  public static let voiceFixes: DJMusicality.Fixes = [.subtractive, .unison, .subOctave]

  /// The gain for `project` (1 when it plays nothing), measured with the `voiceFixes` among
  /// `fixes` on.
  /// `sampled`: net id → a level the probe plays that net's part at (the parts the deck plays
  /// on samplers, at each slot's measured part level and gain: `WaveRunner.prepare`).
  /// `subOctave`: the deck's `WaveOptions.subOctave` (the genre's), so the probe hears the
  /// sub the deck plays.
  public static func gain(
    for project: Project, fixes: DJMusicality.Fixes = [], balance: [String: Double]? = nil,
    sampled: [String: Double] = [:], subOctave: Bool = false
  ) -> Double {
    guard
      let db = measure(
        project, fixes: fixes, balance: balance, sampled: sampled, subOctave: subOctave)
    else {
      return 1
    }
    let g = pow(10, (targetDB - db) / 20)
    return min(range.max, max(range.min, g))
  }

  /// K-weighted mean square (dB) of the voices, times the master gain, over the probe: two
  /// bars from `start` (a step), else from the busiest section's start. `balance`: the parts'
  /// trims (`MixBalance.trims`) to play them with.
  static func measure(
    _ project: Project, start: Int? = nil, fixes: DJMusicality.Fixes = [],
    balance: [String: Double]? = nil, sampled: [String: Double] = [:],
    subOctave: Bool = false, sampleRate probeRate: Double = probeRate
  ) -> Double? {
    let start = start ?? busiestStart(project)
    var o = WaveOptions()
    o.instruments = .shared
    o.master = "linear"
    o.musicality = fixes.intersection(voiceFixes)
    o.probeLevels = sampled
    o.subOctave = subOctave
    if let balance {
      o.musicality.insert(.balance)
      o.trackBalance = balance
    }
    let runner = WaveRunner(sampleRate: probeRate, opts: o)
    runner.load(
      prepared: WaveRunner.prepare(project, sampleRate: probeRate, opts: o, startTick: start))
    runner.play()
    let tempo = project.tempo > 0 ? project.tempo : 120
    let frames = Int(Double(probeBars) * 4 * 60 / tempo * probeRate)
    var buf = [Float](repeating: 0, count: 512)
    var hp = KWeighting(sampleRate: probeRate)
    var sum = 0.0
    var n = 0
    buf.withUnsafeMutableBufferPointer { b in
      while n < frames {
        let k = min(512, frames - n)
        runner.process(b.baseAddress!, nil, frames: k)
        for i in 0..<k {
          let y = hp.process(Double(b[i]) * o.masterGain)
          sum += y * y
        }
        n += k
        if runner.stopped { break }
      }
    }
    guard n > 0, sum > 0 else { return nil }
    return 10 * log10(sum / Double(n))
  }

  /// Where the full arrangement plays, by the section names beats' blueprints use: the first
  /// drop, else chorus, solo, verse, buildup; else the longest section (0 for a loop).
  static func busiestStart(_ project: Project) -> Int {
    guard !project.structure.isEmpty else { return 0 }
    var starts: [(name: String, start: Int, steps: Int)] = []
    var t = 0
    for s in project.structure {
      starts.append((s.name, t, s.steps))
      t += s.steps
    }
    for name in ["drop", "chorus", "solo", "verse", "buildup"] {
      if let s = starts.first(where: { $0.name == name }) { return s.start }
    }
    return starts.max { $0.steps < $1.steps }!.start
  }
}

/// ITU-R BS.1770's K-weighting, from its analog prototypes so it works at any rate: a high
/// shelf (+4 dB above ~1.7 kHz) then a second-order highpass at 38 Hz. Plain stored scalars, so
/// it runs on the audio thread too (`LoudnessMeter`).
struct KWeighting {
  private let b0, b1, b2, a1, a2: Double
  private let c0, c1, c2, d1, d2: Double
  private var s1 = 0.0, s2 = 0.0, h1 = 0.0, h2 = 0.0

  init(sampleRate sr: Double) {
    // RBJ high shelf, f0 1681.97 Hz, +3.9998 dB, Q 0.7072
    let a = pow(10, 3.99984 / 40)
    let w = 2 * Double.pi * 1681.974 / sr
    let alpha = sin(w) / (2 * 0.7071752)
    let c = cos(w)
    let sa = 2 * a.squareRoot() * alpha
    let a0 = (a + 1) - (a - 1) * c + sa
    b0 = a * ((a + 1) + (a - 1) * c + sa) / a0
    b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0
    b2 = a * ((a + 1) + (a - 1) * c - sa) / a0
    a1 = 2 * ((a - 1) - (a + 1) * c) / a0
    a2 = ((a + 1) - (a - 1) * c - sa) / a0
    let hp = biquad(type: "highpass", fc: 38.13, q: 0.5003, sr: sr)
    c0 = hp[0]
    c1 = hp[1]
    c2 = hp[2]
    d1 = hp[3]
    d2 = hp[4]
  }

  mutating func process(_ x: Double) -> Double {
    let y = b0 * x + s1
    s1 = b1 * x - a1 * y + s2
    s2 = b2 * x - a2 * y
    let z = c0 * y + h1
    h1 = c1 * y - d1 * z + h2
    h2 = c2 * y - d2 * z
    return z
  }
}
