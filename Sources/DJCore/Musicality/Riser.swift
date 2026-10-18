import Foundation

// `.riser` (p62-riser): a noise riser over the last two bars of each buildup into a drop. A
// runner-owned stinger-class lane (`RiserVoice`, allocated at prepare): seeded xorshift noise
// through a state-variable lowpass swept 300 Hz → 8 kHz (even in log frequency) while its level
// climbs −30 → −12 dB (even in dB), cut at the drop. It never rests, is never ducked and stays
// out of the energy curve's tonal lowpass; it sends to the room (`.space`) and widens with a
// second, independent noise as its side under `.stereo`. Its place in the window is the song
// step the runner plays, so a project prepared mid-song (a section jump) starts it in phase.

extension DJMusicality {
  /// How long a riser lasts: the last two bars of the buildup, in sixteenths.
  public static let riserSteps = 32
  /// The sections a riser climbs out of, and the ones it lands on.
  static let riserFrom: Set<String> = ["buildup"]
  static let riserInto: Set<String> = ["drop", "chorus"]

  /// The riser windows of `p`: song steps `from ..< to`, `to` the first step of the drop (or
  /// chorus) a buildup lands on; `riserSteps` long, or the whole buildup when it is shorter.
  /// Ascending, disjoint. A pure function of the played project.
  public static func riserWindows(_ p: Project) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var t = 0
    for (k, s) in p.structure.enumerated() {
      if k > 0, riserInto.contains(s.name), riserFrom.contains(p.structure[k - 1].name) {
        let len = min(riserSteps, p.structure[k - 1].steps)
        if len > 0 { out.append((t - len)..<t) }
      }
      t += s.steps
    }
    return out
  }
}

/// The riser's sweep: where it starts and ends, in cutoff and level.
public enum RiserSpec {
  public static let fromHz = 300.0
  public static let toHz = 8000.0
  public static let fromDB = -30.0
  public static let toDB = -12.0
  /// Its share of the room send (`.space`), as `SpaceSpec.send` gives the lanes.
  public static let send = 0.3
  /// Side over mid at the start and at the end of the window (`.stereo`).
  public static let fromWidth = 0.2
  public static let toWidth = 0.8
  /// Time constant of the level's glide (ms): no click going in, and the cut at the drop.
  public static let glideMs = 3.0

  /// Cutoff (Hz) and level (dB) at `x` (0…1) through the window.
  public static func at(_ x: Double) -> (hz: Double, db: Double) {
    let x = min(1, max(0, x))
    return (fromHz * pow(toHz / fromHz, x), fromDB + (toDB - fromDB) * x)
  }
}

/// The riser lane of one `WaveProject`: built at prepare, rendered by the runner on the audio
/// thread one sample at a time (`render`). Allocation-free after init.
final class RiserVoice {
  /// Window starts and ends (song steps), ascending.
  let starts: [Int]
  let ends: [Int]
  let sampleRate: Double
  let stereo: Bool
  let send: Double
  private let invSr: Double
  private let glide: Double
  private let lnSweep: Double
  /// The window the runner is in (or the next one); moves forward, re-seeks going back.
  private var index = 0
  private var gain = 0.0
  private var rngMid: UInt32 = 1
  private var rngSide: UInt32 = 1
  // SVF states (mid, side)
  private var m1 = 0.0
  private var m2 = 0.0
  private var s1 = 0.0
  private var s2 = 0.0
  /// What the last `render` produced: mid, side (0 without `.stereo`), and the send's input.
  private(set) var mid = 0.0
  private(set) var side = 0.0

  init?(windows: [Range<Int>], sampleRate: Double, stereo: Bool, space: Bool) {
    guard !windows.isEmpty, sampleRate > 0 else { return nil }
    starts = windows.map(\.lowerBound)
    ends = windows.map(\.upperBound)
    self.sampleRate = sampleRate
    self.stereo = stereo
    send = space ? RiserSpec.send : 0
    invSr = 1 / sampleRate
    glide = 1 - exp(-1 / (RiserSpec.glideMs / 1000 * sampleRate))
    lnSweep = log(RiserSpec.toHz / RiserSpec.fromHz)
  }

  /// Back to silence, from the top (a stop, an install).
  func reset() {
    index = 0
    gain = 0
    m1 = 0
    m2 = 0
    s1 = 0
    s2 = 0
    mid = 0
    side = 0
  }

  /// One sample at song position `pos` (steps, fractional; nil: not playing). Returns false,
  /// touching nothing, while it is silent: renders before its first window are the bytes they
  /// were without it.
  @inline(__always)
  func render(at pos: Double?) -> Bool {
    var target = 0.0
    var x = 0.0
    if let pos {
      let n = starts.count
      if index > n || (index > 0 && Double(ends[index - 1]) > pos) { index = 0 }
      while index < n && Double(ends[index]) <= pos { index += 1 }
      if index < n && Double(starts[index]) <= pos {
        let a = Double(starts[index])
        x = (pos - a) / (Double(ends[index]) - a)
        target = pow(10, (RiserSpec.fromDB + (RiserSpec.toDB - RiserSpec.fromDB) * x) / 20)
        if gain == 0 { enter(window: starts[index]) }
      }
    }
    if gain == 0 && target == 0 { return false }
    gain += (target - gain) * glide
    if target == 0 && gain < 1e-6 {
      reset()
      return false
    }
    let hz = RiserSpec.fromHz * exp(lnSweep * min(1, max(0, x)))
    // trapezoidal SVF lowpass, Butterworth (k = √2); tan(π fc / sr) exact (8 kHz is well
    // under Nyquist at 44.1 / 48 kHz)
    let g = tan(Double.pi * hz * invSr)
    let k = 2.squareRoot()
    let a1 = 1 / (1 + g * (g + k))
    let a2 = g * a1
    let a3 = g * a2
    // white uniform noise (variance 1/3) through a Butterworth lowpass keeps 1.11 fc / (sr / 2)
    // of its power: scaled back so `gain` is the riser's RMS
    let norm = gain * (3 * 0.5 * sampleRate / (1.11 * hz)).squareRoot()
    mid = norm * Self.lowpass(Self.noise(&rngMid), &m1, &m2, a1, a2, a3)
    if stereo {
      let w = RiserSpec.fromWidth + (RiserSpec.toWidth - RiserSpec.fromWidth) * x
      side = w * norm * Self.lowpass(Self.noise(&rngSide), &s1, &s2, a1, a2, a3)
    }
    return true
  }

  /// A window starts from silence: fresh filters, and noise seeded by the window, so a replay
  /// (or a jump that lands before it) plays the same riser.
  private func enter(window start: Int) {
    m1 = 0
    m2 = 0
    s1 = 0
    s2 = 0
    rngMid = UInt32(truncatingIfNeeded: start &* 2_654_435_761) | 1
    rngSide = (rngMid ^ 0x9E37_79B9) | 1
  }

  @inline(__always)
  private static func noise(_ x: inout UInt32) -> Double {
    x ^= x << 13
    x ^= x >> 17
    x ^= x << 5
    return Double(Int32(bitPattern: x)) / 2_147_483_648
  }

  @inline(__always)
  private static func lowpass(
    _ v: Double, _ ic1: inout Double, _ ic2: inout Double, _ a1: Double, _ a2: Double,
    _ a3: Double
  ) -> Double {
    let v3 = v - ic2
    let v1 = a1 * ic1 + a2 * v3
    let v2 = ic2 + a2 * ic1 + a3 * v3
    ic1 = 2 * v1 - ic1
    ic2 = 2 * v2 - ic2
    return v2
  }
}

/// How a render's high band climbs through each riser window: what `djctl render` reports as
/// `riserRiseDB`.
public struct RiserRise: Equatable, Sendable {
  /// The window, in song steps.
  public var window: Range<Int>
  /// High-band (≥ `RiserRise.highHz`) RMS of each beat of the window, dB.
  public var beatsDB: [Double]
  /// Last beat over the first, dB.
  public var riseDB: Double { (beatsDB.last ?? 0) - (beatsDB.first ?? 0) }
  /// Spearman rank correlation of the beats' levels with time (1: every beat louder).
  public var spearman: Double { Self.spearman(beatsDB) }

  public static let highHz = 4000.0

  /// Each riser window of `project` that the mono-folded render `left` / `right` holds whole.
  public static func measure(
    left: [Float], right: [Float], sampleRate sr: Double, project: Project
  ) -> [RiserRise] {
    let windows = DJMusicality.riserWindows(project)
    let n = min(left.count, right.count)
    guard !windows.isEmpty, n > 0 else { return [] }
    let tempo = project.tempo > 0 ? project.tempo : 120
    let perStep = sr * 60 / (tempo * 4)
    var hi = [Double](repeating: 0, count: n)
    for i in 0..<n { hi[i] = (Double(left[i]) + Double(right[i])) / 2 }
    for _ in 0..<2 {
      let b = biquad(type: "highpass", fc: highHz, q: 0.7071, sr: sr)
      var z1 = 0.0
      var z2 = 0.0
      for i in 0..<n {
        let v = hi[i]
        let y = b[0] * v + z1
        z1 = b[1] * v - b[3] * y + z2
        z2 = b[2] * v - b[4] * y
        hi[i] = y
      }
    }
    var out: [RiserRise] = []
    for w in windows {
      guard Int(Double(w.upperBound) * perStep) <= n else { continue }
      var beats: [Double] = []
      var s = w.lowerBound
      while s + 4 <= w.upperBound {
        let a = Int(Double(s) * perStep)
        let b = Int(Double(s + 4) * perStep)
        var e = 0.0
        for i in a..<b { e += hi[i] * hi[i] }
        beats.append(10 * log10(max(e / Double(max(1, b - a)), 1e-20)))
        s += 4
      }
      if beats.count >= 2 { out.append(RiserRise(window: w, beatsDB: beats)) }
    }
    return out
  }

  /// Spearman's ρ of `ys` against their index (ties ranked by their mean).
  public static func spearman(_ ys: [Double]) -> Double {
    let n = ys.count
    guard n >= 2 else { return 0 }
    let order = ys.indices.sorted { ys[$0] < ys[$1] }
    var rank = [Double](repeating: 0, count: n)
    var i = 0
    while i < n {
      var j = i
      while j + 1 < n && ys[order[j + 1]] == ys[order[i]] { j += 1 }
      for k in i...j { rank[order[k]] = Double(i + j) / 2 }
      i = j + 1
    }
    let mean = Double(n - 1) / 2
    var num = 0.0
    var dx = 0.0
    var dy = 0.0
    for k in 0..<n {
      let a = Double(k) - mean
      let b = rank[k] - mean
      num += a * b
      dx += a * a
      dy += b * b
    }
    return dx > 0 && dy > 0 ? num / (dx * dy).squareRoot() : 0
  }
}
