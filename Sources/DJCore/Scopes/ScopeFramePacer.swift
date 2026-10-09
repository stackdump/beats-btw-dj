// Frame pacing for the scope views: scope.js `VIZ_MIN_FRAME_MS` and the `el._vizLevel` check in
// its rAF loop. The perf monitor that raises the level when drawing gets expensive is a later
// mode (SPEC 27); this is the pure pacer it will drive, and the hub's `vizLevel` property.

/// "Is it time to draw again?" at one of four quality levels.
public struct ScopeFramePacer: Equatable, Sendable {
  /// Frames per second at levels 0...3 (scope.js `VIZ_MIN_FRAME_MS` = 1000 / these).
  public static let fps: [Double] = [30, 15, 8, 4]

  /// Seconds between frames at a level; levels are clamped to 0...3 (`Math.min(3, level | 0)`).
  public static func minInterval(level: Int) -> Double {
    1 / fps[min(max(level, 0), fps.count - 1)]
  }

  /// 0 = full rate ... 3 = slowest.
  public var level: Int {
    didSet { level = min(max(level, 0), Self.fps.count - 1) }
  }
  /// When the last frame was drawn (seconds); -infinity before the first.
  public private(set) var lastDraw = -Double.infinity

  public init(level: Int = 0) {
    self.level = min(max(level, 0), Self.fps.count - 1)
  }

  public var minInterval: Double { Self.minInterval(level: level) }

  /// scope.js: `if (now - s.lastDraw < VIZ_MIN_FRAME_MS[level]) return; s.lastDraw = now;`.
  /// `now` is any steadily increasing clock in seconds. The first call always draws. Returns true
  /// and records the time when a frame is due.
  public mutating func shouldDraw(now: Double) -> Bool {
    if now - lastDraw < minInterval { return false }
    lastDraw = now
    return true
  }

  /// Forget the last draw (the loop restarts: `s.lastDraw = 0` in scopeSync).
  public mutating func reset() { lastDraw = -.infinity }
}
