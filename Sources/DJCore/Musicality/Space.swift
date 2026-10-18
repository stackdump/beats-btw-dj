import Foundation

/// The room a deck plays in (`DJMusicality.Fixes.space`). beats' wave engine is bone dry: every
/// voice is an oscillator or a noise burst straight into the master curve, so pads stop dead,
/// snares are clicks and nothing sits in a space. This is a send reverb, as a mixing desk has:
/// each lane sends some of itself (pads and leads the most, snare and claps some, kick and bass
/// none, so the low end stays dry and mono), the return comes back in stereo.
public struct SpaceSpec: Sendable, Equatable {
  /// Reverb time (RT60), seconds.
  public var seconds: Double
  /// Return level: what the reverb adds, as a gain on its normalised output.
  public var wet: Double
  /// Lowpass in the reverb's loop, Hz: a darker room for lofi and jazz, a brighter hall for trance.
  public var damping: Double

  public init(seconds: Double, wet: Double, damping: Double) {
    self.seconds = seconds
    self.wet = wet
    self.damping = damping
  }

  /// A neutral medium room, for a deck whose genre has none of its own (`targets.json`'s
  /// `space.default`).
  public static let room = MixTargets.shared.space.default.spec

  /// The room for a genre (`targets.json`'s `space.genres`, `MixTargets`): long and bright for
  /// trance, synthwave, edm and ambient; a short, tight one for techno, house and funk; darker
  /// rooms for lofi, jazz and bossa. Returns measured against the dry mix (`djctl render <g> 42
  /// --synth --room`): ambient −8 dB; trance, synthwave −14 … −15; edm, dnb −17; lofi, jazz,
  /// bossa −13 … −16 (pad-heavy mixes send most of themselves, so their wet is lower); techno,
  /// house, dubstep, funk −19 … −22.
  public static func forGenre(_ name: String) -> SpaceSpec {
    MixTargets.shared.room(genre: name)
  }

  /// How much of itself a lane sends to the room (`kind`: its drum kind or "tonal"; `group`:
  /// its part): pads most, arp and leads next, snare / clap / crash some, hats a touch; kick and
  /// bass none.
  public static func send(kind: String, group: String) -> Double {
    switch kind {
    case "tonal":
      switch group {
      case "harmony", "pad": 0.5
      case "arp": 0.4
      case "bass": 0
      default: 0.3
      }
    case "snare": 0.22
    case "clap": 0.3
    case "crash": 0.25
    case "openhat": 0.1
    case "hat": 0.05
    default: 0
    }
  }

  /// What the sampled instruments that send (pads, leads, arps: they render as one bus) send.
  public static let samplerSend = 0.35
}

/// A stereo feedback-delay-network reverb: eight delay lines of mutually prime lengths, mixed
/// through a Hadamard matrix (lossless, every line feeds every other), each with a lowpass and
/// the gain that makes it decay by 60 dB in the room's time. The input is highpassed (12 dB per
/// octave: no low end in the room) and pre-delayed; left is the sum of the even lines, right of
/// the odd ones, so the return is wide and folds back to mono without cancelling, and its side
/// is highpassed at `sideHz` (`SideHighpass`) so what is left low is in the middle. Buffers
/// are allocated at init (off the audio thread); `tune` and `process` allocate nothing.
final class FDNReverb {
  static let lineMs: [Double] = [29.7, 37.1, 41.1, 43.7, 53.0, 59.9, 67.7, 79.3]
  static let predelayMs = 18.0
  static let highpassHz = 200.0
  /// The return's side is highpassed higher: a pad's reverb is wide from 300 Hz up, the low
  /// mids (where a measurement or a mono club system would hear it as mud) are central.
  static let sideHz = 300.0
  /// Brings the normalised output up to `wet` = 1 meaning a return about as loud as what was
  /// sent (calibrated on renders: `djctl render … --room`).
  static let makeup = 12.0

  private let sampleRate: Double
  private var buf: [Float]
  private let stride: Int
  private var len = [Int](repeating: 1, count: 8)
  private var pos = [Int](repeating: 0, count: 8)
  private var gain = [Double](repeating: 0, count: 8)
  private var lp = [Double](repeating: 0, count: 8)
  private var t = [Double](repeating: 0, count: 8)
  private var dampA = 1.0
  private var pre: [Float]
  private var prePos = 0
  private var hpA = 1.0
  private var hpX = (0.0, 0.0)
  private var hpY = (0.0, 0.0)
  private var sideHP: SideHighpass
  /// Output gain: the spec's `wet`, normalised so a longer room is not simply louder.
  private(set) var outGain = 0.0

  init(sampleRate sr: Double) {
    sampleRate = sr
    stride = Int((Self.lineMs.max()! / 1000 * sr).rounded(.up)) + 1
    buf = [Float](repeating: 0, count: 8 * stride)
    pre = [Float](repeating: 0, count: max(1, Int(Self.predelayMs / 1000 * sr)))
    for i in 0..<8 { len[i] = min(stride, max(1, Int((Self.lineMs[i] / 1000 * sr).rounded()))) }
    let rc = 1 / (2 * Double.pi * Self.highpassHz)
    hpA = rc / (rc + 1 / sr)
    sideHP = SideHighpass(hz: Self.sideHz, sampleRate: sr)
  }

  /// Set the room. Allocation-free (the audio thread calls it when a project is installed).
  func tune(_ spec: SpaceSpec?) {
    guard let spec, spec.wet > 0, spec.seconds > 0 else {
      outGain = 0
      return
    }
    var mean = 0.0
    for i in 0..<8 {
      gain[i] = pow(10, -3 * Double(len[i]) / (spec.seconds * sampleRate))
      mean += gain[i] / 8
    }
    dampA = 1 - exp(-2 * Double.pi * min(spec.damping, sampleRate * 0.45) / sampleRate)
    outGain = Self.makeup * spec.wet * (1 - mean * mean).squareRoot()
  }

  /// Clear the room (the tail stops). Allocation-free.
  func reset() {
    for i in 0..<buf.count { buf[i] = 0 }
    for i in 0..<pre.count { pre[i] = 0 }
    for i in 0..<8 { lp[i] = 0 }
    hpX = (0, 0)
    hpY = (0, 0)
    sideHP.reset()
  }

  /// One sample in (the send bus), one stereo sample out (the return).
  @inline(__always)
  func process(_ x: Double) -> (Double, Double) {
    let h1 = hpA * (hpY.0 + x - hpX.0)
    hpX.0 = x
    hpY.0 = h1
    let hp = hpA * (hpY.1 + h1 - hpX.1)
    hpX.1 = h1
    hpY.1 = hp
    let d = Double(pre[prePos])
    pre[prePos] = Float(hp)
    prePos = prePos + 1 == pre.count ? 0 : prePos + 1
    var l = 0.0
    var r = 0.0
    for i in 0..<8 {
      let y = Double(buf[i * stride + pos[i]])
      lp[i] += dampA * (y - lp[i])
      t[i] = lp[i]
      if i % 2 == 0 { l += lp[i] } else { r += lp[i] }
    }
    // 8-point fast Walsh-Hadamard transform, scaled to be orthonormal
    var h = 1
    while h < 8 {
      var i = 0
      while i < 8 {
        for j in i..<(i + h) {
          let a = t[j]
          let b = t[j + h]
          t[j] = a + b
          t[j + h] = a - b
        }
        i += 2 * h
      }
      h *= 2
    }
    let norm = 1 / 8.0.squareRoot()
    let inject = 0.35 * d
    for i in 0..<8 {
      let v = gain[i] * t[i] * norm + (i % 2 == 0 ? inject : -inject)
      buf[i * stride + pos[i]] = Float(v)
      pos[i] = pos[i] + 1 == len[i] ? 0 : pos[i] + 1
    }
    var ol = Float(0.5 * l * outGain)
    var or = Float(0.5 * r * outGain)
    sideHP.process(&ol, &or)
    return (Double(ol), Double(or))
  }
}
