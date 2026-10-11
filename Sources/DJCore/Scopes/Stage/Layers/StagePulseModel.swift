import Foundation

// Pulse particles (SPEC mode 14): "beats fade toward centre".
//
// stage.js `stageOnTransitionFired` spawns a particle at the fired transition's actual position on
// its sub-ring, and `renderPulses` draws it flying to the ring centre for 700 ms:
//
//     if (vizModes.has('pulse') && panel?.ringX != null) {
//         const origin = nodeCenterInStage(session, panel, transitionId) || { x: panel.ringX, y: panel.ringY };
//         if (session.pulses.length > 64) session.pulses.shift();
//         session.pulses.push({ x0, y0, cx: ringCenter.x, cy: ringCenter.y, born: performance.now(), life: 700 });
//     }
//     // per frame, for every particle:
//     t = (now - born) / life;  t >= 1 -> dropped
//     e = 1 - (1 - t)^2;  x = x0 + (cx - x0) e;  y = y0 + (cy - y0) e
//     r = max(1.5, 10 (1 - t));  fill #e94560 at opacity 0.7 (1 - t)
//
// Here the hook is `StageContext.fires` (every audible hit since the last frame, oldest first, with
// `origin` = `nodeCenterInStage`) and `born` is the fire's `wallTime`: the model's clock minus how
// far behind "now" the hit already is, so a particle that was read late starts late in its life.
//
//   * A lone panel has no ring position (`StagePanel.ring == nil`): stage.js never sets
//     `ringX` there, so it spawns nothing for it.
//   * The cap is the JS one: shift once the list is longer than 64, then push, so up to 65
//     particles live (the list is only trimmed of the dead once per frame, as `renderPulses`
//     does, so a flurry inside one frame counts the dead too).
//   * Turning the toggle off stops new particles only; the ones in flight finish their fade
//     ("trails off gracefully"). A rebuild (`reset()`: new track, source switch, expand toggle)
//     clears them like `rebuildStagePanels`' `pulses.length = 0`.
//   * Drawn by `StagePulseLayer` over the meta-net and under the panels.
//
// Nothing here reads a clock: `now` comes from the context.

/// The numbers of the pulse particles, and the two pure functions that turn a particle and the
/// clock into what is drawn.
public enum StagePulse {
  /// `life: 700`.
  public static let lifeMs = 700.0
  /// `if (session.pulses.length > 64) session.pulses.shift()` before the push.
  public static let shiftAbove = 64
  /// `Math.max(1.5, 10 * (1 - t))`.
  public static let maxRadius = 10.0
  public static let minRadius = 1.5
  /// `0.7 * (1 - t)`.
  public static let peakAlpha = 0.7

  /// `t = (now - born) / life`; below 0 only if the clock stepped back, held at 0.
  public static func progress(of p: StagePulseParticle, nowMs: Double) -> Double {
    max(0, (nowMs - p.bornMs) / p.lifeMs)
  }

  /// The particle at `nowMs`, or nil once it is dead (`t >= 1`).
  public static func dot(of p: StagePulseParticle, nowMs: Double) -> StagePulseDot? {
    let t = progress(of: p, nowMs: nowMs)
    if t >= 1 { return nil }
    // ease-in on position, linear fade on opacity, shrink toward centre
    let e = 1 - (1 - t) * (1 - t)
    return StagePulseDot(
      x: p.x0 + (p.cx - p.x0) * e, y: p.y0 + (p.cy - p.y0) * e,
      radius: max(minRadius, maxRadius * (1 - t)), alpha: peakAlpha * (1 - t))
  }
}

/// One pulse particle, in stage coordinates (before the container transform) and milliseconds on
/// the model's wall clock.
public struct StagePulseParticle: Equatable, Sendable {
  public var x0: Double
  public var y0: Double
  public var cx: Double
  public var cy: Double
  public var bornMs: Double
  public var lifeMs: Double

  public init(
    x0: Double, y0: Double, cx: Double, cy: Double, bornMs: Double,
    lifeMs: Double = StagePulse.lifeMs
  ) {
    self.x0 = x0
    self.y0 = y0
    self.cx = cx
    self.cy = cy
    self.bornMs = bornMs
    self.lifeMs = lifeMs
  }
}

/// A particle as it is drawn this frame: a filled circle of `#e94560` at `alpha`.
public struct StagePulseDot: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var radius: Double
  public var alpha: Double

  public init(x: Double, y: Double, radius: Double, alpha: Double) {
    self.x = x
    self.y = y
    self.radius = radius
    self.alpha = alpha
  }
}

@MainActor
public final class StagePulseModel: StageLayerModel {
  /// The live particles, oldest first.
  public private(set) var particles: [StagePulseParticle] = []

  public init() {}

  // MARK: frame

  public func advance(_ context: StageContext) {
    if context.isOn(.pulse) {
      for fire in context.fires { spawn(fire, context: context) }
    }
    // renderPulses: "evict dead particles first so the visible count matches state".
    let nowMs = context.nowMs
    particles.removeAll { StagePulse.progress(of: $0, nowMs: nowMs) >= 1 }
  }

  public func reset() { particles.removeAll() }

  private func spawn(_ fire: StageFire, context: StageContext) {
    guard let index = fire.panel, context.panels.indices.contains(index),
      let ring = context.panels[index].ring
    else { return }
    // `nodeCenterInStage(...) || { x: panel.ringX, y: panel.ringY }`
    let origin = fire.origin ?? ring
    if particles.count > StagePulse.shiftAbove { particles.removeFirst() }
    particles.append(
      StagePulseParticle(
        x0: origin.x, y0: origin.y, cx: context.ringCenter.x, cy: context.ringCenter.y,
        bornMs: fire.wallTime * 1000))
  }

  /// What the layer paints at `nowMs`, oldest first (so the newest is on top).
  public func dots(nowMs: Double) -> [StagePulseDot] {
    particles.compactMap { StagePulse.dot(of: $0, nowMs: nowMs) }
  }
}
