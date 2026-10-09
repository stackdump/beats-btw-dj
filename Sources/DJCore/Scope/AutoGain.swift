import Foundation

/// The scope's auto-gain, ported from beats `scope.js` (commit 095d030).
///
/// `peak` is the recent maximum |sample|: `readWaveform` raises it to every block's peak
/// (`if (pk > s.peak) s.peak = pk`) and `drawLive` decays it each frame
/// (`s.peak = Math.max(0.05, s.peak * Math.exp(-dt / 7))`, `dt` clamped to 0.05 s).
/// The displayed scale `disp` chases `peak` on an underdamped spring (k = 120, c = 9) so
/// a gain change bounces instead of snapping: `a = k (peak - disp) - c vel`,
/// `vel += a dt`, `disp = max(0.05, disp + vel dt)`. Views draw at `amplitude / disp`.
///
/// Pure value type; semi-implicit Euler exactly as the JS orders it.
public struct AutoGain: Equatable, Sendable {
  public static let floor = 0.05
  public static let maxStep = 0.05
  public static let decaySeconds = 7.0
  public static let stiffness = 120.0
  public static let damping = 9.0

  /// scope.js state defaults: `peak: 0.1, disp: 0.1, vel: 0`.
  public var peak = 0.1
  public var disp = 0.1
  public var vel = 0.0
  /// Time of the previous `advance(now:)` (JS `s.lastT`, 0 = never).
  public var lastT = 0.0

  public init() {}

  /// A block's peak arrived: raise `peak` to it (never lowers).
  public mutating func observe(peak pk: Double) {
    if pk > peak { peak = pk }
  }

  /// One frame of `dt` seconds (clamped to 0.05): decay the peak, step the spring.
  public mutating func step(dt rawDt: Double) {
    let dt = min(Self.maxStep, rawDt)
    peak = max(Self.floor, peak * exp(-dt / Self.decaySeconds))
    let a = Self.stiffness * (peak - disp) - Self.damping * vel
    vel += a * dt
    disp = max(Self.floor, disp + vel * dt)
  }

  /// One frame at wall-clock `now` (seconds): `dt = min(0.05, now - (lastT || now))`, so
  /// the first frame has dt 0.
  public mutating func advance(now: Double) {
    let dt = min(Self.maxStep, now - (lastT == 0 ? now : lastT))
    lastT = now
    step(dt: dt)
  }
}
