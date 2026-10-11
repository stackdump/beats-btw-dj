// How the visual level (`ScopeHub.vizLevel`, written by `PerfMonitor`) slows each kind of driver
// down. One table per driver family, all from beats:
//
//   scope canvases, timeline dots   30 / 15 / 8 / 4 fps      scope.js and audio-io.js VIZ_MIN_FRAME_MS
//                                                             (`ScopeFramePacer`)
//   the Stage                       every frame / 30 / 15 / 4 stage.js STAGE_MIN_FRAME_MS
//                                                             (`StageFramePacer`)
//   the net rings                   every poll / every poll / 0.5 s / 2 s
//                                                             backend/index.js `onStateSync` minGap
//                                                             (`RingRenderGate`, below)
//   small animations (a running macro's glow, an LED blink)
//                                   their own rate, never faster than the scope table allows
//                                                             (`VizPacing.interval(level:cappedAt:)`)

/// backend/index.js `onStateSync`: at visual level 2 the net canvas is re-rendered at most every
/// 500 ms, at level 3 every 2 s; levels 0 and 1 render on every state sync.
public struct RingRenderGate: Equatable, Sendable {
  /// Seconds between renders at a level (0: every sync).
  public static func minGap(level: Int) -> Double {
    level >= 3 ? 2.0 : level >= 2 ? 0.5 : 0
  }

  /// When the last render was let through (seconds, any steady clock); -infinity before the first.
  public private(set) var lastRender = -Double.infinity

  public init() {}

  /// Is a render due at `now` (seconds)? True lets it through and records the time:
  /// `if (!minGap || now - last >= minGap) { last = now; render }`.
  public mutating func due(now: Double, level: Int) -> Bool {
    let gap = Self.minGap(level: level)
    if gap == 0 || now - lastRender >= gap {
      lastRender = now
      return true
    }
    return false
  }
}

public enum VizPacing {
  /// Seconds between frames for an animation that wants `cap` seconds (its own rate) at a visual
  /// level: the slower of the two, so a level never speeds an animation up.
  public static func interval(level: Int, cappedAt cap: Double) -> Double {
    max(cap, ScopeFramePacer.minInterval(level: level))
  }
}
