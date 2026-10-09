import Foundation

// StageSonarModel: SPEC mode 10, the sonar (stage.js `renderSonar`, and the sonar branch of
// `stageOnTransitionFired`). Every audible fire may spawn a ring that expands from the ring's
// centre to 55 % of the stage's diagonal over 900 ms, fading as it goes; the channel sets the
// colour, so drum hits, bass notes and lead notes read distinctly.
//
// Times are MILLISECONDS on the model's wall clock (what `performance.now()` is in the JS):
// `StageFire.wallTime` is when the fire was read, which is the clock the rings are born on and
// the one the rate limits compare, never audio time. Nothing in here reads a clock: `nowMs` is
// always passed in.

/// One expanding ring.
public struct SonarRing: Equatable, Sendable {
  /// Wall-clock ms at which it was spawned.
  public var born: Double
  /// `channelHue(ch)` at the fire.
  public var hue: Double
  /// How long it lives, ms (900).
  public var life: Double
}

/// A ring as it is drawn at an instant.
public struct SonarArc: Equatable, Sendable {
  public var cx: Double
  public var cy: Double
  public var radius: Double
  /// 0 at birth... 1 at the end of its life.
  public var t: Double
  public var lineWidth: Double
  /// `hsla(hue, 95%, 60%, (1 - t) * 0.85)`.
  public var stroke: ScopeColor
  /// `shadowColor hsla(hue, 95%, 55%, alpha * 0.5)`, `shadowBlur 8`.
  public var shadow: ScopeColor
  public var shadowBlur: Double
}

/// The sonar's rings and the rate limits that decide which fires spawn one.
public struct StageSonar: Equatable, Sendable {
  /// `life: 900`.
  public static let life = 900.0
  /// At most one ring per channel in this many ms (the older ring is still visibly expanding).
  public static let channelGap = 250.0
  /// And at most one new ring per this many ms whatever the channel.
  public static let anyGap = 80.0
  /// `if (rings.length > 8) rings.shift()` BEFORE the push: a ninth ring can exist.
  public static let capBeforePush = 8
  /// `maxR = hypot(w, h) * 0.55`.
  public static let radiusFraction = 0.55
  public static let shadowBlur = 8.0

  public private(set) var rings: [SonarRing] = []
  private var lastByChannel: [Int: Double] = [:]
  private var lastAny: Double?

  public init() {}

  /// A fire on `channel` at wall clock `nowMs`. Returns whether it spawned a ring: per channel
  /// at least 250 ms after that channel's last ring AND at least 80 ms after any ring.
  ///
  /// (stage.js reads a channel that has not rung yet as time 0, which only matters in the first
  /// quarter second of the page's clock; here "never" always passes.)
  @discardableResult
  public mutating func fire(channel: Int, nowMs: Double) -> Bool {
    let sinceChannel = lastByChannel[channel].map { nowMs - $0 } ?? .infinity
    let sinceAny = lastAny.map { nowMs - $0 } ?? .infinity
    guard sinceChannel >= Self.channelGap, sinceAny >= Self.anyGap else { return false }
    lastByChannel[channel] = nowMs
    lastAny = nowMs
    if rings.count > Self.capBeforePush { rings.removeFirst() }
    rings.append(
      SonarRing(born: nowMs, hue: ScopeColors.channelHue(channel), life: Self.life))
    return true
  }

  /// `renderSonar`'s first step: rings older than their life are removed (strictly older: a ring
  /// of exactly its life is still drawn, at alpha 0).
  public mutating func prune(nowMs: Double) {
    rings.removeAll { nowMs - $0.born > $0.life }
  }

  /// `setVisualizer`: leaving and returning starts fresh.
  public mutating func reset() {
    rings.removeAll()
    lastByChannel.removeAll()
    lastAny = nil
  }

  /// The radius a ring grows to.
  public static func maxRadius(width: Double, height: Double) -> Double {
    hypot(width, height) * radiusFraction
  }

  /// Where and how a ring is drawn at `nowMs`: `t = (now - born) / life`, radius `t * maxR`,
  /// alpha `(1 - t) * 0.85`, width `1 + (1 - t) * 4`.
  public static func arc(
    _ ring: SonarRing, nowMs: Double, center: StagePoint, width: Double, height: Double
  ) -> SonarArc {
    let t = (nowMs - ring.born) / ring.life
    let alpha = (1 - t) * 0.85
    return SonarArc(
      cx: center.x, cy: center.y, radius: t * maxRadius(width: width, height: height), t: t,
      lineWidth: 1 + (1 - t) * 4, stroke: .hsla(ring.hue, 95, 60, alpha),
      shadow: .hsla(ring.hue, 95, 55, alpha * 0.5), shadowBlur: shadowBlur)
  }

  /// Every ring, oldest first (the order they are stroked in).
  public func arcs(nowMs: Double, center: StagePoint, width: Double, height: Double)
    -> [SonarArc]
  {
    rings.map { Self.arc($0, nowMs: nowMs, center: center, width: width, height: height) }
  }
}
