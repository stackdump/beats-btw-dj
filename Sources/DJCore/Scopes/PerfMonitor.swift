// PerfMonitor: "is the visualization making the app lag?" (SPEC mode 27, beats `lib/perf/monitor.js`).
//
// It runs while a deck plays. Every 2 s window it combines
//   frames   the intervals of a steady heartbeat on the main run loop: median, p95, dropped share
//   stalls   the part of an interval beyond 50 ms (blocking), and visual draws that alone took
//            longer than that
//   viz      the milliseconds spent inside the visual code, per path (`VizKind`)
// into a verdict (`PerfEvaluator`: none / visualization / other), and in `auto` mode a
// `PerfGovernor` steps the level 0 full -> 1 reduced -> 2 minimal -> 3 paused after two
// 'visualization' windows and back up after eight smooth ones. The level is published to
// `ScopeHub.vizLevel` (this class is its first writer: the hub wires `onLevelChange`), which every
// visual driver reads: the scope canvases (30 / 15 / 8 / 4 fps), the Stage (every frame / 30 / 15
// / 4), the timeline dots, the ring snapshot (every poll / every poll / 0.5 s / 2 s) and the
// small animations. A preference menu pins a level (`setPreference`), and is remembered.
//
//   let hub = ScopeHub(engine: dj)          // owns `hub.perf`
//   hub.perf.start()                         // when a deck starts playing (AppModel.poll)
//   hub.timed(.scope) { …draw… }             // vizBegin/vizEnd around a draw; ScopeCanvas does it
//   perf.frame()                             // from the heartbeat, or by hand in a test
//   hub.perf.stop()                          // when nothing plays
//
// TIME. Everything is on one injected clock in seconds (default: `systemUptime`), so a test drives
// whole sessions by moving a fake clock and calling `frame(at:)`.
//
// WHY A HEARTBEAT AND NOT A DISPLAY LINK. The JS measures requestAnimationFrame pacing. macOS has
// no rAF; the nearest is a display link, but on a ProMotion display that slows down by itself when
// little moves, and a slowing refresh reads as jank. A 60 Hz repeating timer on the main run
// loop (`.common` mode) has no relation to the panel: it fires late exactly when the main thread
// is busy, which is the thing being judged. `heartbeatInterval: nil` (the default) schedules
// nothing; the app asks for 1/60.
//
// WHERE IT UNDER-COUNTS (honest limits, also in the report):
//   * Every visual path is timed inside its Canvas closure (the scopes, the timeline, the rings
//     and, through `StageCanvas`, the Stage's layers), plus the Stage model's frame (pump, engine
//     reads, layer models). Not timed: SwiftUI's evaluation of a view `body` (a Stage layer that
//     does its model work there, like the solo visualizers' paint list, is cheap but unbooked)
//     and whatever the render server does with the commands a closure recorded. What the monitor
//     sees is the main thread's share, which is what janks the app.
//   * Nothing of this was run against a real display; the thresholds are the JS ones.

import Foundation
import Observation

/// Where the visual preference is remembered. `.none` forgets it (tests); `.userDefaults` keeps
/// it under monitor.js' key `pn-viz-quality`.
public struct PerfPreferenceStore {
  public var load: () -> VizPreference
  public var save: (VizPreference) -> Void

  public init(load: @escaping () -> VizPreference, save: @escaping (VizPreference) -> Void) {
    self.load = load
    self.save = save
  }

  public static var none: PerfPreferenceStore {
    PerfPreferenceStore(load: { .auto }, save: { _ in })
  }

  public static let key = "pn-viz-quality"

  public static func userDefaults(_ defaults: UserDefaults = .standard, key: String = Self.key)
    -> PerfPreferenceStore
  {
    PerfPreferenceStore(
      load: { VizPreference(stored: defaults.string(forKey: key)) },
      save: { defaults.set($0.rawValue, forKey: key) })
  }
}

@MainActor @Observable
public final class PerfMonitor {
  /// The visual level in force, 0 (full) ... 3 (paused). Observable.
  public private(set) var level: Int
  /// What the user chose. Observable.
  public private(set) var preference: VizPreference
  /// The notice raised by the last step down, until it times out or is dismissed. Observable.
  public private(set) var notice: PerfNotice?
  /// Is the monitor measuring (a deck is playing)?
  public private(set) var isRunning = false

  public let config: PerfConfig
  /// Told the new level whenever it changes (the hub writes `vizLevel` from it).
  @ObservationIgnored public var onLevelChange: ((Int) -> Void)?
  /// The newest windows, oldest first (60 kept).
  @ObservationIgnored public private(set) var history: [PerfWindowStats] = []
  @ObservationIgnored public private(set) var last: PerfWindowStats?

  @ObservationIgnored private let clock: () -> Double
  @ObservationIgnored private let store: PerfPreferenceStore
  @ObservationIgnored private let heartbeatInterval: Double?
  @ObservationIgnored private var heartbeat: Timer?
  @ObservationIgnored private var governor: PerfGovernor

  // The window being measured.
  @ObservationIgnored private var intervalsMs: [Double] = []
  @ObservationIgnored private var lastFrameAt: Double?
  @ObservationIgnored private var blockingMs = 0.0
  @ObservationIgnored private var longCount = 0
  @ObservationIgnored private var attributedMs = 0.0
  @ObservationIgnored private var vizMs = [Double](repeating: 0, count: VizKind.allCases.count)
  @ObservationIgnored private var vizCalls = [Int](repeating: 0, count: VizKind.allCases.count)
  @ObservationIgnored private var windowStart = 0.0

  /// monitor.js keeps 2048 frame deltas per window.
  static let intervalCapacity = 2048
  static let historyCapacity = 60

  public init(
    config: PerfConfig = .standard,
    clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
    store: PerfPreferenceStore = .none, heartbeatInterval: Double? = nil
  ) {
    self.config = config
    self.clock = clock
    self.store = store
    self.heartbeatInterval = heartbeatInterval
    let p = store.load()
    governor = PerfGovernor(preference: p)
    preference = p
    level = governor.level
    intervalsMs.reserveCapacity(Self.intervalCapacity)
  }

  // MARK: running

  /// Begin measuring (a deck started playing). Idempotent. The level, the floor and the time of
  /// the last step up carry over from the last run, but the streaks of bad and clean windows do
  /// not: monitor.js' `perfStart` zeroes `bad` and `clean`, so a pause between two bad windows
  /// (or between the clean ones) breaks the run. The window starts empty.
  public func start() {
    guard !isRunning else { return }
    isRunning = true
    governor.resetStreaks()
    resetWindow(at: clock())
    lastFrameAt = nil
    if let interval = heartbeatInterval {
      let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.frame() }
      }
      t.tolerance = interval * 0.05
      RunLoop.main.add(t, forMode: .common)
      heartbeat = t
    }
  }

  /// Stop measuring (nothing plays). The notice goes with it.
  public func stop() {
    guard isRunning else { return }
    isRunning = false
    heartbeat?.invalidate()
    heartbeat = nil
    notice = nil
  }

  /// `start` or `stop` to match "is anything playing".
  public func setRunning(_ on: Bool) {
    if on { start() } else { stop() }
  }

  // MARK: measuring

  /// A heartbeat tick: record the interval since the previous one, and close the window if its
  /// time is up. `now` defaults to the clock; a test passes its own.
  public func frame(at now: Double? = nil) {
    guard isRunning else { return }
    let t = now ?? clock()
    if let previous = lastFrameAt {
      let ms = (t - previous) * 1000
      if intervalsMs.count < Self.intervalCapacity { intervalsMs.append(ms) }
      if ms > config.longTaskMs {
        longCount += 1
        blockingMs += ms - config.longTaskMs
      }
    }
    lastFrameAt = t
    if let n = notice, t - n.at >= PerfNotice.seconds { notice = nil }
    if (t - windowStart) * 1000 >= config.windowMs { closeWindow(at: t) }
  }

  /// `vizBegin`: the time a visual path starts. Pass it to `vizEnd`.
  public func vizBegin() -> Double { clock() }

  /// `vizEnd`: add the time since `t0` to the path's total. A single draw longer than the
  /// long-task threshold also counts as caused by the visuals (the JS attributes the scripts of
  /// long animation frames the same way).
  public func vizEnd(_ kind: VizKind, _ t0: Double) {
    guard isRunning else { return }
    let ms = (clock() - t0) * 1000
    vizMs[kind.rawValue] += ms
    vizCalls[kind.rawValue] += 1
    if ms > config.longTaskMs { attributedMs += ms }
  }

  /// Visual time (ms) and calls per path in the window being measured.
  public func currentViz(_ kind: VizKind) -> (ms: Double, calls: Int) {
    (vizMs[kind.rawValue], vizCalls[kind.rawValue])
  }

  /// Judge the window, adapt, and start the next one.
  private func closeWindow(at now: Double) {
    let input = PerfWindowInput(
      frameIntervalsMs: intervalsMs, spanMs: (now - windowStart) * 1000, blockingMs: blockingMs,
      longCount: longCount, vizAttributedMs: attributedMs, vizMs: vizMs)
    let stats = PerfEvaluator.evaluate(input, level: governor.level, config: config)
    history.append(stats)
    if history.count > Self.historyCapacity { history.removeFirst() }
    last = stats
    switch governor.apply(cause: stats.cause, now: now, config: config) {
    case .down(let to):
      publish(level: to)
      notice = PerfNotice(level: to, at: now)
    case .up(let to):
      publish(level: to)
    case .none:
      break
    }
    resetWindow(at: now)
  }

  private func resetWindow(at now: Double) {
    intervalsMs.removeAll(keepingCapacity: true)
    blockingMs = 0
    longCount = 0
    attributedMs = 0
    for i in vizMs.indices {
      vizMs[i] = 0
      vizCalls[i] = 0
    }
    windowStart = now
  }

  private func publish(level new: Int) {
    guard new != level else { return }
    level = new
    onLevelChange?(new)
  }

  // MARK: preference

  /// The user's choice (the menu): remembered, streaks and floor forgotten, a pinned level
  /// applied at once, any notice dismissed.
  public func setPreference(_ p: VizPreference) {
    governor.setPreference(p)
    store.save(p)
    preference = p
    notice = nil
    publish(level: governor.level)
  }

  /// "keep full visuals" on the notice.
  public func keepFullVisuals() { setPreference(.full) }

  /// One line for a tooltip: what the monitor sees.
  public var summary: String {
    guard let w = last else { return "no data yet — play a track for a few seconds" }
    let share = (w.vizSharePct * 10).rounded() / 10
    return "\(Int(w.fps.rounded())) fps, visuals use \(share)% of the main thread, last window: "
      + w.cause.rawValue
  }
}
