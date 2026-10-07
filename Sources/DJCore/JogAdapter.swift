import Foundation

/// What a jog wheel drives. Port of the `clock` interface in web/jog/jog-adapter.js.
public protocol JogClock: AnyObject {
  /// Touch-on: hand is on the platter, stop the clock.
  func freeze()
  /// Rotation while touched: move the playhead by this much 1x time.
  func scrubBy(seconds: Double)
  /// Touch-off: the clock runs on its own again.
  func release()
  /// Outer ring: run at (1 + ratio)x; 0 = normal.
  func nudge(_ ratio: Double)
}

/// Jog events -> clock control for one deck. Knows the device (through a
/// profile) and time; knows nothing about audio. Not thread-safe: call
/// `handle` and `decay` from one thread (the main actor in the app).
///
/// Scrub is expressed as position deltas, not speed: a wheel returned to the
/// angle it started at puts the playhead back exactly where it started.
public final class JogAdapter {
  public let deck: String
  public private(set) var touching = false
  public private(set) var nudge = 0.0

  private let clock: JogClock
  private let secondsPerTick: Double
  private let shiftMultiplier: Double
  private let bendPerTick: Double
  private let bendTauSec: Double
  private let bendMax: Double
  private var lastSent = 0.0
  private var lastDecay: TimeInterval?

  public init(
    profile: JogProfile,
    clock: JogClock,
    deck: String = "A",
    shiftMultiplier: Double = 4,  // SHIFT + scratch = coarse seek, as in Mixxx/Serato
    bendDepth: Double = 0.10,  // nudge ratio when the ring turns at platter speed
    bendTauSec: Double = 0.15,  // how quickly a nudge dies away once the ring stops
    bendMax: Double = 0.5
  ) {
    self.clock = clock
    self.deck = deck
    self.shiftMultiplier = shiftMultiplier
    self.bendTauSec = bendTauSec
    self.bendMax = bendMax
    secondsPerTick = profile.secondsPerTick
    // With exponential decay of bendTauSec, the level settles at bendDepth
    // when ticks arrive at platter speed.
    bendPerTick = bendDepth / (bendTauSec * Double(profile.ticksPerRev) * (profile.platterRpm / 60))
  }

  public func handle(_ event: JogEvent) {
    switch event {
    case .touch(let d, _, let down):
      guard d == deck, down != touching else { return }
      touching = down
      if down {
        nudge = 0
        clock.freeze()
      } else {
        clock.release()
      }
    case .scratch(let d, let shift, let ticks):
      guard d == deck else { return }
      // Scratch with no touch: the note-on was missed or arrives in another
      // order than assumed. Bending is the safe reading.
      guard touching else { return bend(ticks) }
      clock.scrubBy(seconds: Double(ticks) * secondsPerTick * (shift ? shiftMultiplier : 1))
    case .bend(let d, _, let ticks):
      guard d == deck else { return }
      bend(ticks)
    }
  }

  /// Bend is a rate, so it needs a time base the message stream stops
  /// supplying once the ring stops. Call every ~10 ms.
  public func decay(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let dt = lastDecay.map { now - $0 } ?? 0
    lastDecay = now
    nudge *= exp(-dt / bendTauSec)
    if abs(nudge) < 1e-4 { nudge = 0 }
    if nudge != lastSent {
      lastSent = nudge
      clock.nudge(nudge)
    }
  }

  private func bend(_ ticks: Int) {
    nudge = max(-bendMax, min(bendMax, nudge + Double(ticks) * bendPerTick))
  }
}
