import Foundation

/// A tempo-synced echo (`DJMusicality.Fixes.echo`): the dotted-eighth ping-pong delay a trance or
/// synthwave lead lives in, the eighth-note slapback of lofi, a long dotted-quarter wash for
/// ambient. beats' engine has no delay at all, so a lead's phrase stops dead at its last note.
/// A send, as the room is: leads and arps send, the rhythm section and pads do not.
public struct EchoSpec: Sendable, Equatable {
  /// Delay time in sixteenths (3 = a dotted eighth), followed as the tempo moves.
  public var steps: Double
  /// How much of each repeat comes back (per repeat, each side to the other).
  public var feedback: Double
  /// Return level.
  public var wet: Double
  /// Lowpass inside the loop, Hz: each repeat darker than the one before.
  public var damping: Double

  public init(steps: Double, feedback: Double, wet: Double, damping: Double) {
    self.steps = steps
    self.feedback = feedback
    self.wet = wet
    self.damping = damping
  }

  /// The echo for a genre, or nil where the style is dry (techno's and house's leads are stabs
  /// in a room; jazz, bossa, funk are played, not produced).
  public static func forGenre(_ name: String) -> EchoSpec? {
    switch name {
    case "trance": EchoSpec(steps: 3, feedback: 0.42, wet: 0.32, damping: 5000)
    case "synthwave": EchoSpec(steps: 3, feedback: 0.38, wet: 0.3, damping: 4000)
    case "edm": EchoSpec(steps: 3, feedback: 0.35, wet: 0.26, damping: 6000)
    case "dubstep", "dnb", "trap": EchoSpec(steps: 3, feedback: 0.35, wet: 0.24, damping: 4500)
    case "ambient": EchoSpec(steps: 6, feedback: 0.5, wet: 0.3, damping: 3500)
    case "lofi": EchoSpec(steps: 2, feedback: 0.3, wet: 0.22, damping: 2500)
    default: nil
    }
  }

  /// How much of itself a lane sends to the echo: the lead most, the arp less (its own
  /// sixteenths are busy already), nothing else.
  public static func send(kind: String, group: String) -> Double {
    guard kind == "tonal" else { return 0 }
    switch group {
    case "melody": return 0.4
    case "arp": return 0.22
    default: return 0
    }
  }

  /// The repeats go on into the room (`.space`) this much, so they sit in the same space as
  /// the lead they echo.
  public static let roomSend = 0.3
}

/// A stereo ping-pong delay: the send goes into the left line, each line feeds the other, so
/// repeats alternate left, right, left. A lowpass in the loop darkens each repeat; the input is
/// highpassed (no low end in the echoes). The delay time glides to a new tempo (a tape stop
/// bends the repeats with it rather than clicking). Buffers are allocated at init (off the audio
/// thread); `tune`, `setTime` and `process` allocate nothing.
final class PingPong {
  static let maxSeconds = 2.5
  static let highpassHz = 250.0

  private let sampleRate: Double
  private var left: [Float]
  private var right: [Float]
  private var pos = 0
  private var delay = 0.0
  private var target = 0.0
  private let glide: Double
  private var feedback = 0.0
  private var wet = 0.0
  private var dampA = 1.0
  private var lpL = 0.0
  private var lpR = 0.0
  private var hpA = 1.0
  private var hpX = 0.0
  private var hpY = 0.0
  private(set) var spec: EchoSpec?

  init(sampleRate sr: Double) {
    sampleRate = sr
    let n = Int(Self.maxSeconds * sr) + 4
    left = [Float](repeating: 0, count: n)
    right = [Float](repeating: 0, count: n)
    glide = 1 - exp(-1 / (0.05 * sr))
    let rc = 1 / (2 * Double.pi * Self.highpassHz)
    hpA = rc / (rc + 1 / sr)
  }

  /// Set the echo (nil: silent). Allocation-free.
  func tune(_ spec: EchoSpec?, bpm: Double) {
    self.spec = spec
    guard let spec else {
      wet = 0
      return
    }
    feedback = spec.feedback
    wet = spec.wet
    dampA = 1 - exp(-2 * Double.pi * min(spec.damping, sampleRate * 0.45) / sampleRate)
    setTempo(bpm)
    delay = target
  }

  /// Follow the tempo (the delay glides there over ~50 ms). Allocation-free.
  @inline(__always)
  func setTempo(_ bpm: Double) {
    guard let spec, bpm > 0 else { return }
    let seconds = spec.steps * 60 / (bpm * 4)
    target = min(Double(left.count - 3), max(1, seconds * sampleRate))
  }

  var isOn: Bool { wet > 0 }

  /// One sample in (the send), one stereo sample out (the repeats).
  @inline(__always)
  func process(_ x: Double) -> (Double, Double) {
    delay += (target - delay) * glide
    let hp = hpA * (hpY + x - hpX)
    hpX = x
    hpY = hp
    var rp = Double(pos) - delay
    if rp < 0 { rp += Double(left.count) }
    // a read a hair behind the write head (`delay` settling onto a whole sample from above)
    // wraps to exactly `count` in floating point: fold it back onto sample 0
    if rp >= Double(left.count) { rp -= Double(left.count) }
    let i0 = Int(rp)
    let fr = rp - Double(i0)
    let i1 = i0 + 1 == left.count ? 0 : i0 + 1
    let l = Double(left[i0]) + (Double(left[i1]) - Double(left[i0])) * fr
    let r = Double(right[i0]) + (Double(right[i1]) - Double(right[i0])) * fr
    lpL += dampA * (l - lpL)
    lpR += dampA * (r - lpR)
    left[pos] = Float(hp + feedback * lpR)
    right[pos] = Float(feedback * lpL)
    pos = pos + 1 == left.count ? 0 : pos + 1
    return (lpL * wet, lpR * wet)
  }
}
