import Foundation

// Loudness through auto-mix hand-offs, measured (docs/AUTOMIX.md §8): an offline set on the
// same engine path as a replay (`OfflineConductor`, deterministic composes), then per hand-off
// the outgoing deck alone before it, the incoming alone after it, and the mix's short-term
// loudness (BS.1770, 3 s) per beat across it. `djctl automix` prints it.

/// One hand-off's levels.
public struct AutoMixHandoffLevels: Sendable {
  public var n: Int
  public var from: String
  public var to: String
  public var move: String
  /// Integrated LUFS of the outgoing deck alone over the 8 bars before the hand-off, and of the
  /// incoming alone over the 8 bars after it.
  public var before: Double
  public var after: Double
  /// The lowest and highest short-term LUFS (per beat) during the hand-off's bars.
  public var minDuring: Double
  public var maxDuring: Double
  /// `minDuring − min(before, after)`: negative is a dip.
  public var dipLU: Double { minDuring - min(before, after) }
  /// `maxDuring − max(before, after)`: positive is a bump.
  public var bumpLU: Double { maxDuring - max(before, after) }
  /// Short-term LUFS per beat from 8 bars before to 8 bars after.
  public var curve: [Double]

  public var dictionary: [String: Any] {
    func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    return [
      "n": n, "from": from, "to": to, "move": move, "before": r(before), "after": r(after),
      "minDuring": r(minDuring), "maxDuring": r(maxDuring), "dipLU": r(dipLU),
      "bumpLU": r(bumpLU), "curve": curve.map(r),
    ]
  }
}

public struct AutoMixMeasure: Sendable {
  public var genre: String
  public var seed: Double
  public var bars: Int
  public var every: Int
  public var crossfadeOnly: Bool
  public var handoffs: [AutoMixHandoffLevels] = []
  public var samplePeakDB = -200.0
  public var truePeakDBTP = -200.0
  public var audio: RenderedAudio?

  public var dictionary: [String: Any] {
    func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    return [
      "genre": genre, "seed": seed, "bars": bars, "every": every, "crossfadeOnly": crossfadeOnly,
      "samplePeakDB": r(samplePeakDB), "truePeakDBTP": r(truePeakDBTP),
      "handoffs": handoffs.map(\.dictionary),
    ]
  }

  /// Render a set: `genre` / `seed` (a song in `structure`) on deck A, the crossfader on A,
  /// auto-mix on with `bars` / `every`, until `count` hand-offs have finished and 8 more bars
  /// have played. `crossfadeOnly`: no mix-in / mix-out rests (the gain law alone).
  public static func run(
    genre: String, seed: Double, structure: String? = "standard", bars: Int = 8, every: Int = 4,
    count: Int = 1, crossfadeOnly: Bool = false, sampleRate: Double = 48_000,
    keepAudio: Bool = false
  ) throws -> AutoMixMeasure {
    var m = AutoMixMeasure(
      genre: genre, seed: seed, bars: bars, every: every, crossfadeOnly: crossfadeOnly)
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sampleRate)
    dj.deterministic = true
    dj.autoMixCrossfadeOnly = crossfadeOnly
    let a = dj["A"]!
    a.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: genre, seed: seed, structure: structure), sampleRate: sampleRate,
        opts: a.waveOptions))
    dj["B"]!.loadDemo()
    dj.crossfader = 0
    dj.setAutoMix(on: true, bars: bars, every: every)
    try dj.start()
    defer { dj.stop() }
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    dj["A"]!.setPlaying(true)
    var left: [Float] = []
    var right: [Float] = []
    // per hand-off: the frame its incoming deck started (its first tick) and ended
    var starts: [Int] = []
    var ends: [Int] = []
    var wasRunning = false
    var startSeen = false
    var bpm = a.effectiveBPM ?? 120
    var tail = -1
    let limit = Int(sampleRate * 60 * 30)  // half an hour, at most
    while left.count < limit {
      let (l, r) = try conductor.step()
      if l.isEmpty { break }
      left += l
      right += r
      if let run = dj.autoMix.run {
        wasRunning = true
        if !startSeen, let inc = dj[run.inc], inc.wave.tick > 0 {
          // the first tick landed in this block: back to it by the ticks' own clock
          let spt = sampleRate * 60 / ((inc.effectiveBPM ?? 120) * 4)
          let into = (Double(inc.wave.tick - 1) + inc.wave.tickPhase) * spt
          starts.append(left.count - Int(into.rounded()))
          bpm = dj[run.out]?.effectiveBPM ?? bpm
          startSeen = true
        }
      } else if wasRunning {
        wasRunning = false
        startSeen = false
        ends.append(left.count)
        if ends.count >= count { tail = left.count + Int(sampleRate * 60 / bpm * 4 * 9) }
      }
      if tail >= 0 && left.count >= tail { break }
    }
    let barFrames = sampleRate * 60 / bpm * 4
    let window = Int(barFrames * 8)
    // short-term loudness per beat across the whole set
    let meter = LoudnessMeter(sampleRate: sampleRate)
    let beat = barFrames / 4
    var st: [(frame: Int, lufs: Double)] = []
    var nextBeat = beat
    var i = 0
    left.withUnsafeBufferPointer { lb in
      right.withUnsafeBufferPointer { rb in
        while i < left.count {
          let n = min(256, left.count - i)
          meter.push(lb.baseAddress! + i, rb.baseAddress! + i, frames: n)
          i += n
          while Double(i) >= nextBeat {
            st.append((i, meter.shortTermLUFS))
            nextBeat += beat
          }
        }
      }
    }
    func lufs(_ from: Int, _ to: Int) -> Double {
      let a = max(0, from)
      let b = min(left.count, to)
      guard b > a else { return -200 }
      return IntegratedLoudness.integrated(
        left: Array(left[a..<b]), right: Array(right[a..<b]), sampleRate: sampleRate) ?? -200
    }
    for (k, (s, e)) in zip(starts, ends).enumerated() {
      let during = st.filter { $0.frame > s && $0.frame <= e }.map(\.lufs)
      let row = dj.autoMix.log.indices.contains(k) ? dj.autoMix.log[k] : nil
      m.handoffs.append(
        AutoMixHandoffLevels(
          n: row?.n ?? k, from: row?.from ?? "?", to: row?.to ?? "?", move: row?.move ?? "",
          before: lufs(s - window, s), after: lufs(e, e + window),
          minDuring: during.min() ?? -200, maxDuring: during.max() ?? -200,
          curve: st.filter { $0.frame > s - window && $0.frame <= e + window }.map(\.lufs)))
    }
    var peak: Float = 0
    for x in left { peak = max(peak, abs(x)) }
    for x in right { peak = max(peak, abs(x)) }
    m.samplePeakDB = peak > 0 ? 20 * log10(Double(peak)) : -200
    m.truePeakDBTP = TruePeak.dbtp(left: left, right: right)
    if keepAudio { m.audio = RenderedAudio(sampleRate: sampleRate, left: left, right: right) }
    return m
  }
}
