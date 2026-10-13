import Foundation

/// The arrangement's energy arc, as the deck plays it (`DJMusicality.Fixes.energy`).
///
/// beats' cohesion-v2 composer gives every section an `energy` and a `filterOpen` (techno: intro
/// 0.3 / 0.35, buildup 0.65 / 0.4, drop 0.95 / 0.9, breakdown 0.3 / 0.25) and writes them into
/// a `feel-curve` net as `set-feel` controls. The wave engine reports those and applies nothing,
/// so an intro, a breakdown and a drop play at one level (0.2 dB apart in techno 42); beats'
/// Tone path hands them to its feel pad, whose y axis is tempo, so there a breakdown slows down.
/// dj plays them as what they describe: `energy` sets the section's level (the loudest section
/// at unity, the gain `Loudness` measured), `filterOpen` a lowpass on the tonal parts (drums stay
/// full-band, so an intro is still mixable), and a buildup sweeps both up into the section after
/// it. Built from the project off the audio thread; the runner only reads it.
public struct EnergyCurve: Sendable, Equatable {
  /// First step of each section, ascending.
  public var start: [Int]
  /// Each section's gain (linear) and the tonal lowpass cutoff (Hz).
  public var gain: [Double]
  public var cutoff: [Double]
  /// The section ramps from its own values to the next section's (a buildup).
  public var ramp: [Bool]

  /// dB under the loudest section for a section with no energy at all.
  public static let spanDB = 8.0
  /// A section the composer already made sparse (a breakdown of pads alone) is brought up
  /// towards its level by at most this much, never pushed further down than `spanDB`.
  public static let maxBoostDB = 4.0
  /// Cutoff of a fully open section, and the octaves it falls at `filterOpen` 0.
  public static let openHz = 18_000.0
  public static let closedOctaves = 5.5
  /// Sections that build into the next one.
  static let rampSections: Set<String> = ["buildup", "pre-chorus"]

  /// The curve the project's `feel-curve` net describes, or nil (a loop, a project without one,
  /// or one whose sections all have the same energy and filter).
  ///
  /// A section's level is set against what it already plays: each section is probed
  /// (`Loudness.measure`) and given the gain that puts it `spanDB × (1 − energy)` under the most
  /// energetic one — an intro that plays as loud as the drop comes down, a breakdown the
  /// composer thinned to pads alone stays about where it is.
  public init?(project: Project) {
    guard project.structure.count > 1, let feel = project.nets["feel-curve"] else { return nil }
    var points: [Int: (x: Double, y: Double)] = [:]
    for (t, c) in feel.controlBindings.pairs where c.action == "set-feel" {
      guard t.hasPrefix("ft"), let step = Int(t.dropFirst(2)),
        let x = c.macroParams?["x"]?.double, let y = c.macroParams?["y"]?.double
      else { continue }
      points[step] = (x, y)
    }
    // the composer marks each section name once, at its first start
    var byName: [String: (x: Double, y: Double)] = [:]
    var firstStart: [String: Int] = [:]
    var at = 0
    for s in project.structure {
      if firstStart[s.name] == nil {
        firstStart[s.name] = at
        if let p = points[at] { byName[s.name] = p }
      }
      at += s.steps
    }
    guard let xMax = byName.values.map(\.x).max(), let yMax = byName.values.map(\.y).max(),
      xMax > 0, yMax > 0,
      Set(byName.values.map(\.x)).count > 1 || Set(byName.values.map(\.y)).count > 1,
      let peak = byName.max(by: { $0.value.x < $1.value.x })?.key,
      let reference = Loudness.measure(project, start: firstStart[peak]!)
    else { return nil }
    var sectionDB: [String: Double] = [:]
    for (name, p) in byName {
      let target = -Self.spanDB * (1 - min(1, p.x / xMax))
      guard name != peak, let level = Loudness.measure(project, start: firstStart[name]!) else {
        sectionDB[name] = name == peak ? 0 : target
        continue
      }
      sectionDB[name] = max(-Self.spanDB, min(Self.maxBoostDB, target - (level - reference)))
    }
    var start: [Int] = []
    var gain: [Double] = []
    var cutoff: [Double] = []
    var ramp: [Bool] = []
    at = 0
    for s in project.structure {
      let y = byName[s.name]?.y ?? yMax
      start.append(at)
      gain.append(pow(10, (sectionDB[s.name] ?? 0) / 20))
      cutoff.append(Self.openHz * pow(2, -Self.closedOctaves * (1 - min(1, y / yMax))))
      ramp.append(Self.rampSections.contains(s.name))
      at += s.steps
    }
    ramp[ramp.count - 1] = false
    self.start = start
    self.gain = gain
    self.cutoff = cutoff
    self.ramp = ramp
  }

  /// Gain and cutoff at `step` (the song's sixteenth). Allocation-free: the runner calls it once
  /// a block.
  @inline(__always)
  public func at(step: Int) -> (gain: Double, cutoff: Double) {
    var k = 0
    while k + 1 < start.count && start[k + 1] <= step { k += 1 }
    guard ramp[k] else { return (gain[k], cutoff[k]) }
    let len = Double(start[k + 1] - start[k])
    // accelerating, as a riser does: most of the sweep in the section's last bars
    let x = max(0, min(1, Double(step - start[k]) / len))
    let w = x * x
    return (
      gain[k] + (gain[k + 1] - gain[k]) * w,
      cutoff[k] * pow(cutoff[k + 1] / cutoff[k], w)
    )
  }
}

/// A two-pole lowpass (Q 0.707) that can be retuned every sample without clicks: the
/// trapezoidal state-variable filter (Zavalishin / Simper). One channel.
struct SweepFilter {
  private var ic1 = 0.0
  private var ic2 = 0.0
  private var a1 = 1.0
  private var a2 = 0.0
  private var a3 = 0.0

  mutating func tune(_ hz: Double, sampleRate sr: Double) {
    let g = tan(Double.pi * min(hz, sr * 0.45) / sr)
    let k = 2.0.squareRoot()
    a1 = 1 / (1 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
  }

  mutating func reset() {
    ic1 = 0
    ic2 = 0
  }

  @inline(__always)
  mutating func process(_ x: Double) -> Double {
    let v3 = x - ic2
    let v1 = a1 * ic1 + a2 * v3
    let v2 = ic2 + a2 * ic1 + a3 * v3
    ic1 = 2 * v1 - ic1
    ic2 = 2 * v2 - ic2
    return v2
  }
}
