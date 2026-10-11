// The pure half of the perf monitor (SPEC mode 27): how one measurement window is judged and how
// the visual level follows the verdicts. A direct port of beats `lib/perf/monitor.js`
// (`closeWindow` and the adapt block of it), pinned at beats-bitwrap-io 095d030; the object that
// collects the measurements and publishes the level is `PerfMonitor`.
//
//   input of a window  frame intervals (ms), its span, long-task blocking, the time spent in
//                      visual code per path, how much of the long-task time the visuals caused
//   PerfEvaluator      -> PerfWindowStats, with the verdict `cause`
//   PerfGovernor       the level state machine: 2 'visualization' windows step DOWN a level, 8
//                      clean windows step UP, a level re-entered within 30 s of stepping up
//                      becomes the floor, a fixed preference switches adapting off
//
// WHAT MOVED OVER FROM monitor.js, AND WHAT DID NOT
//   kept     LEVELS (full, reduced, minimal, paused), DEFAULTS (2 s window, down after 2, up after
//            8, viz share 0.12, p95 factor 2, dropped 0.15, blocking 50 ms/s, min fps 30), the
//            verdict rules, the floor rule, the notify text, the preference values.
//   dropped  everything about the audio engine's notes (`notes`, `late`, `tight`, `minMarginMs`,
//            `tightMs`, `perfNote`) and `waveLag`: those measure Tone scheduling against the
//            audio clock. The native engine renders on its own thread from sample-accurate
//            events; the UI cannot make a note late, and the JS itself says that in the wave
//            engine `notes` stays empty and the lag is only reported. `audioLate` therefore never
//            enters the verdict. Also dropped: telemetry, the `?perf=1` HUD and the bench modal.
//   replaced rAF frame deltas -> the intervals of a steady main-run-loop heartbeat (`PerfMonitor`
//            says why a heartbeat and not a display link); LoAF / longtask blocking -> the part
//            of a heartbeat interval beyond 50 ms (the JS fallback's own rule,
//            `max(0, duration - 50)`), the script attribution -> a visual draw that alone took
//            more than 50 ms counts as caused by the visuals.
//   paths    VIZ.TIMELINE / STAGE / NET / SCOPE are `VizKind.timeline / .stage / .ring / .scope`.
//            VIZ.FIRE (per-fire flashes) has no code path of its own here: the flashes are drawn
//            inside the Stage and the ring, and timed there.
//
// SMALL DIFFERENCES THAT ARE ON PURPOSE (each also in the report)
//   * The notice (the JS toast) is cleared when the monitor stops, and is aged by the heartbeat;
//     the toast outlives `perfStop` for its 8 s. Nothing plays when we stop, so nothing is left
//     to reassure about.
//   * An unknown stored preference reads as `auto`. In the JS an unknown string stays the
//     preference, which is not 'auto' and so pins the level at 0 without ever adapting: an
//     accident of `LEVELS.indexOf`, not something to copy.
//   * `vizEnd` books nothing while the monitor is stopped; the JS accumulates and clears the
//     totals at the next start. The outcome is the same.
//   * The notice's link reads "Keep full visuals" (the toast's is lower case).

/// The visual paths whose draw time the monitor accounts for (monitor.js `VIZ`).
public enum VizKind: Int, CaseIterable, Sendable {
  /// The rolling fire dots under a deck's section bar (`ScopeCanvas`, kind `.timeline`).
  case timeline
  /// The Stage's frame.
  case stage
  /// A net deck's rings (monitor.js `NET`).
  case ring
  /// The scope panel's modes and the master meter.
  case scope

  public var name: String {
    switch self {
    case .timeline: "timeline"
    case .stage: "stage"
    case .ring: "ring"
    case .scope: "scope"
    }
  }
}

/// monitor.js `LEVELS`.
public enum VizLevels {
  public static let names = ["full", "reduced", "minimal", "paused"]
  public static let count = names.count

  /// The level clamped to 0...3 and its name.
  public static func name(_ level: Int) -> String { names[min(max(level, 0), count - 1)] }
}

/// What the user chose for the visual quality: `auto` lets the monitor step the level, the rest
/// pin it (monitor.js `PREF_KEY` values, plus `paused`, which `LEVELS.indexOf` accepts too).
public enum VizPreference: String, CaseIterable, Sendable {
  case auto, full, reduced, minimal, paused

  /// The pinned level; nil for `auto`.
  public var fixedLevel: Int? {
    self == .auto ? nil : VizLevels.names.firstIndex(of: rawValue)
  }

  public var title: String {
    switch self {
    case .auto: "Auto"
    case .full: "Full"
    case .reduced: "Reduced"
    case .minimal: "Minimal"
    case .paused: "Paused"
    }
  }

  /// A stored string. Nothing stored (`|| 'auto'`) is `auto`, and so is anything unknown, which
  /// the JS would keep as a preference that is not `auto` and so pins level 0 for good (see the
  /// header, "small differences").
  public init(stored: String?) {
    self = stored.flatMap { VizPreference(rawValue: $0) } ?? .auto
  }
}

/// monitor.js `DEFAULTS`, minus the note-scheduling threshold.
public struct PerfConfig: Equatable, Sendable {
  /// Length of a measurement window (ms).
  public var windowMs = 2000.0
  /// Consecutive 'visualization' windows that step the level down.
  public var downAfter = 2
  /// Consecutive clean windows that step it up (8 x 2 s = 16 s).
  public var upAfter = 8
  /// Viz ms / window ms above which the visuals count as heavy.
  public var vizShare = 0.12
  /// A p95 frame interval above this many medians is jank.
  public var jankP95Factor = 2.0
  /// A frame is dropped when it is longer than this many medians (monitor.js: the literal 1.7).
  public var droppedFactor = 1.7
  /// More than this fraction of dropped frames is jank.
  public var jankDropped = 0.15
  /// Long-task time above this many ms per second is jank.
  public var jankBlockingMsPerS = 50.0
  /// A median frame slower than 1000 / this is jank ("uniformly slow frames count too").
  public var minFps = 30.0
  /// A stall longer than this is a long task (the LoAF / longtask threshold); only what is
  /// beyond it counts as blocking.
  public var longTaskMs = 50.0
  /// Stepping down again within this many seconds of a step up makes that level the floor.
  public var floorWithinSeconds = 30.0

  public init() {}

  public static let standard = PerfConfig()
}

/// Why a window was bad, if it was.
public enum PerfCause: String, Equatable, Sendable {
  /// A smooth window.
  case none
  /// The main thread janked and the visuals are a large share of it.
  case visualization
  /// It janked, but not because of the visuals.
  case other
}

/// What one window measured (the raw side of monitor.js `closeWindow`).
public struct PerfWindowInput: Equatable, Sendable {
  /// Heartbeat intervals in ms, in any order.
  public var frameIntervalsMs: [Double]
  /// Wall length of the window (ms).
  public var spanMs: Double
  /// Long-task time beyond the threshold (ms).
  public var blockingMs: Double
  /// Number of long stalls.
  public var longCount: Int
  /// Time in single visual draws that were long tasks on their own (ms).
  public var vizAttributedMs: Double
  /// Time in visual code per path (ms), indexed by `VizKind.rawValue`.
  public var vizMs: [Double]

  public init(
    frameIntervalsMs: [Double], spanMs: Double, blockingMs: Double = 0, longCount: Int = 0,
    vizAttributedMs: Double = 0, vizMs: [Double] = [0, 0, 0, 0]
  ) {
    self.frameIntervalsMs = frameIntervalsMs
    self.spanMs = spanMs
    self.blockingMs = blockingMs
    self.longCount = longCount
    self.vizAttributedMs = vizAttributedMs
    self.vizMs = vizMs
  }
}

/// A judged window (monitor.js `w`).
public struct PerfWindowStats: Equatable, Sendable {
  public var spanMs: Double
  /// The level in force while it was measured.
  public var level: Int
  public var cause: PerfCause
  /// Frames per second at the median interval; 0 with no frames.
  public var fps: Double
  public var medianFrameMs: Double
  public var p95FrameMs: Double
  /// Fraction of frames longer than 1.7 medians.
  public var dropped: Double
  public var longFrames: Int
  public var blockingMsPerS: Double
  /// Time in visual code per path (ms), indexed by `VizKind.rawValue`.
  public var vizMs: [Double]
  public var vizSharePct: Double
  /// The jank test alone, before the visuals are asked.
  public var jank: Bool
  /// The visuals are a large share of the main thread, or of its long stalls.
  public var vizHeavy: Bool
}

public enum PerfEvaluator {
  /// monitor.js `median`: the element at `floor(n / 2)` of a sorted list, 0 for none.
  static func median(_ sorted: [Double]) -> Double {
    sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }

  /// `closeWindow`'s judgement, for the window `input` measured at `level`.
  ///
  /// frames:  med = sorted[n/2], p95 = sorted[floor(n * 0.95)], dropped = share of frames beyond
  ///          1.7 x med
  /// jank:    n > 5 and (p95 > 2 x med  or  dropped > 0.15  or  med > 1000 / minFps),
  ///          or long-task time above 50 ms per second
  /// heavy:   viz ms / span > 0.12, or the visuals caused more than half the blocking time
  /// cause:   jank ? (heavy ? visualization : other) : none
  public static func evaluate(
    _ input: PerfWindowInput, level: Int, config cfg: PerfConfig = .standard
  ) -> PerfWindowStats {
    let deltas = input.frameIntervalsMs.sorted()
    let n = deltas.count
    let med = median(deltas)
    let p95 = n > 0 ? deltas[min(n - 1, Int((Double(n) * 0.95).rounded(.down)))] : 0
    let dropped =
      med > 0
      ? Double(deltas.filter { $0 > med * cfg.droppedFactor }.count) / Double(max(1, n)) : 0
    let span = input.spanMs
    let blockingPerS = span > 0 ? input.blockingMs * 1000 / span : 0
    var vizTotal = 0.0
    for v in input.vizMs { vizTotal += v }
    let vizShare = span > 0 ? vizTotal / span : 0
    let jank =
      (n > 5
        && (p95 > med * cfg.jankP95Factor || dropped > cfg.jankDropped
          || med > 1000 / cfg.minFps))
      || blockingPerS > cfg.jankBlockingMsPerS
    let vizHeavy =
      vizShare > cfg.vizShare
      || (input.blockingMs > 0 && input.vizAttributedMs > 0.5 * input.blockingMs)
    let cause: PerfCause = jank ? (vizHeavy ? .visualization : .other) : .none
    return PerfWindowStats(
      spanMs: span, level: level, cause: cause, fps: med > 0 ? 1000 / med : 0,
      medianFrameMs: med, p95FrameMs: p95, dropped: dropped, longFrames: input.longCount,
      blockingMsPerS: blockingPerS, vizMs: input.vizMs, vizSharePct: vizShare * 100, jank: jank,
      vizHeavy: vizHeavy)
  }
}

/// The level state machine (monitor.js: the adapt block of `closeWindow`, `setVizPreference`).
public struct PerfGovernor: Equatable, Sendable {
  /// What `apply` did.
  public enum Step: Equatable, Sendable {
    case none
    case down(to: Int)
    case up(to: Int)
  }

  public private(set) var level: Int
  /// The level auto mode will not go below (0 = full) until the preference is set again.
  public private(set) var floor = 0
  /// Consecutive 'visualization' windows.
  public private(set) var bad = 0
  /// Consecutive smooth windows.
  public private(set) var clean = 0
  /// When the level last stepped up (seconds on the monitor's clock).
  public private(set) var lastStepUpAt = -Double.infinity
  public private(set) var preference: VizPreference

  /// `perfStart` on a fresh monitor: the pinned level, else full.
  public init(preference: VizPreference = .auto) {
    self.preference = preference
    level = preference.fixedLevel ?? 0
  }

  /// `setVizPreference`: forget the streaks and the floor; a pinned level takes effect at once,
  /// `auto` keeps the current level and adapts from there.
  public mutating func setPreference(_ p: VizPreference) {
    preference = p
    floor = 0
    clean = 0
    bad = 0
    if let fixed = p.fixedLevel { level = fixed }
  }

  /// `perfStart` on a monitor that has run before: the streaks start from zero (`bad: 0,
  /// clean: 0` in its `Object.assign`); the level, the floor and the time of the last step up
  /// carry over.
  public mutating func resetStreaks() {
    bad = 0
    clean = 0
  }

  /// Feed one window's verdict (only when the preference is `auto`; a pinned level never moves).
  /// `now` is on the monitor's clock, in seconds.
  public mutating func apply(cause: PerfCause, now: Double, config cfg: PerfConfig = .standard)
    -> Step
  {
    guard preference == .auto else { return .none }
    if cause == .visualization {
      bad += 1
      clean = 0
      if bad >= cfg.downAfter && level < VizLevels.count - 1 {
        // Re-entering a level we left recently: make it the floor.
        if now - lastStepUpAt < cfg.floorWithinSeconds { floor = max(floor, level + 1) }
        level += 1
        bad = 0
        return .down(to: level)
      }
    } else {
      bad = 0
      if cause == .none { clean += 1 } else { clean = 0 }
      if clean >= cfg.upAfter && level > floor {
        level -= 1
        clean = 0
        lastStepUpAt = now
        return .up(to: level)
      }
    }
    return .none
  }
}

/// The notice shown when auto mode steps down (monitor.js `notify`).
public struct PerfNotice: Equatable, Sendable {
  /// How long it stays up (s): the JS toast's 8000 ms.
  public static let seconds = 8.0

  public var text: String
  public var level: Int
  /// When it was raised (the monitor's clock, seconds).
  public var at: Double

  public init(level: Int, at: Double) {
    self.level = level
    self.at = at
    text = "Visuals reduced (\(VizLevels.name(level))) to keep playback smooth"
  }
}
