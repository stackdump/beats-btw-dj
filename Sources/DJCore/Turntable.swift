import Foundation
import Synchronization

/// Decoded audio held in manually managed memory, so the audio thread can read
/// it without touching Swift array reference counts.
public final class SampleBuffer: @unchecked Sendable {
  public let length: Int
  public let sampleRate: Double
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>  // == left for mono

  public init(left l: [Float], right r: [Float]? = nil, sampleRate: Double) {
    precondition(!l.isEmpty, "empty audio")
    precondition(r == nil || r!.count == l.count, "channel lengths differ")
    length = l.count
    self.sampleRate = sampleRate
    left = .allocate(capacity: length)
    left.initialize(from: l, count: length)
    if let r {
      right = .allocate(capacity: length)
      right.initialize(from: r, count: length)
    } else {
      right = left
    }
  }

  deinit {
    if right != left { right.deallocate() }
    left.deallocate()
  }

  public var duration: TimeInterval { Double(length) / sampleRate }
}

/// Messages from the main thread to the audio thread.
public enum TurntableCommand: BitwiseCopyable {
  /// An `Unmanaged<SampleBuffer>` retained by the sender.
  case load(UnsafeMutableRawPointer)
  case transport(playing: Bool)
  /// Play at full speed at once, with no motor spin-up: a clip launched in time.
  case start
  /// Hand on the platter: switch to scrub mode at the current position.
  case freeze
  /// Move the scrub target by this many samples (negative = backwards).
  case scrub(samples: Double)
  /// Hand off: back to motor-driven play.
  case release
  /// Run at (1 + ratio)x while playing. Momentary (jog ring), on top of pitch.
  case nudge(ratio: Double)
  /// Tempo fader: run at (1 + ratio)x while playing.
  case pitch(ratio: Double)
  /// Jump the playhead (and scrub target) to this sample.
  case seek(sample: Double)
  /// While playing, wrap the playhead from `end` back to `start` (unwrapped samples).
  case loop(start: Double, end: Double)
  case loopOff
  /// Seconds the platter takes to catch up with the hand.
  case chase(seconds: Double)
}

/// A turntable: reads a looped buffer at a variable, signed rate with linear
/// interpolation, updated per sample. Port of web/jog/scrub-worklet.js.
///
///   play   rate eases toward (playing ? (1 + pitch)(1 + nudge) : 0) — motor spin-up/brake
///   scrub  rate = (target - pos) / chaseTau — the platter follows the hand
///
/// Threading: `send`/`load`/`drainRetired` and the read-only accessors are for
/// one non-audio thread; `render` is for the audio thread only.
public final class Turntable: @unchecked Sendable {
  public let sampleRate: Double

  private let commands = SPSCRing<TurntableCommand>(capacity: 1024)
  /// Buffers the audio thread has let go of, for the main thread to free.
  private let retired = SPSCRing<UnsafeMutableRawPointer>(capacity: 64)
  private let posBits = Atomic<UInt64>(0)
  private let rateBits = Atomic<UInt64>(0)
  private let lengthAtomic = Atomic<Int>(0)

  // Audio-thread state.
  private var buffer: Unmanaged<SampleBuffer>?
  private var pos = 0.0
  private var rate = 0.0
  private var target = 0.0
  private var scrubbing = false
  private var playing = false
  private var nudge = 0.0
  private var pitch = 0.0
  private var loopStart = 0.0
  private var loopEnd = 0.0
  private var looping = false
  private var chaseTau: Double
  private let rateSmooth: Double
  private let motorSmooth: Double
  private let maxRate = 12.0

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    chaseTau = 0.035 * sampleRate
    rateSmooth = 1 - exp(-1 / (0.004 * sampleRate))
    motorSmooth = 1 - exp(-1 / (0.045 * sampleRate))
  }

  deinit {
    while let c = commands.pop() {
      if case .load(let p) = c { Unmanaged<SampleBuffer>.fromOpaque(p).release() }
    }
    drainRetired()
    buffer?.release()
  }

  // MARK: main-thread side

  public func send(_ command: TurntableCommand) {
    drainRetired()
    commands.push(command)
  }

  /// Hand `buffer` to the audio thread. It must match `sampleRate`.
  public func load(_ buffer: SampleBuffer) {
    precondition(buffer.sampleRate == sampleRate, "resample before loading")
    let p = Unmanaged.passRetained(buffer).toOpaque()
    drainRetired()
    if !commands.push(.load(p)) { Unmanaged<SampleBuffer>.fromOpaque(p).release() }
  }

  /// Free buffers the audio thread has swapped out. Called by `send`/`load`;
  /// call it from a timer too if loads are rare.
  public func drainRetired() {
    while let p = retired.pop() { Unmanaged<SampleBuffer>.fromOpaque(p).release() }
  }

  /// Unwrapped playhead in samples (can go negative or past the end).
  public var position: Double { Double(bitPattern: posBits.load(ordering: .relaxed)) }
  public var currentRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }
  /// Loaded length in samples, 0 when empty.
  public var length: Int { lengthAtomic.load(ordering: .relaxed) }

  // MARK: audio-thread side

  /// Fill `frames` samples of `left` (and `right` if given). Real-time safe.
  public func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    while let c = commands.pop() { apply(c) }
    guard let buffer else {
      left.update(repeating: 0, count: frames)
      right?.update(repeating: 0, count: frames)
      return
    }
    buffer._withUnsafeGuaranteedRef { b in
      let len = Double(b.length)
      for i in 0..<frames {
        if scrubbing {
          let want = min(maxRate, max(-maxRate, (target - pos) / chaseTau))
          rate += (want - rate) * rateSmooth
        } else {
          let want = playing ? (1 + pitch) * (1 + nudge) : 0
          rate += (want - rate) * motorSmooth
        }
        pos += rate
        if looping && !scrubbing {
          let len = loopEnd - loopStart
          if pos >= loopEnd { pos -= len } else if pos < loopStart && rate < 0 { pos += len }
        }

        var p = pos.truncatingRemainder(dividingBy: len)
        if p < 0 { p += len }
        let i0 = min(Int(p), b.length - 1)
        let i1 = i0 + 1 == b.length ? 0 : i0 + 1
        let f = Float(p - Double(i0))
        left[i] = b.left[i0] + (b.left[i1] - b.left[i0]) * f
        right?[i] = b.right[i0] + (b.right[i1] - b.right[i0]) * f
      }
    }
    posBits.store(pos.bitPattern, ordering: .relaxed)
    rateBits.store(rate.bitPattern, ordering: .relaxed)
  }

  private func apply(_ c: TurntableCommand) {
    switch c {
    case .load(let p):
      if let old = buffer, !retired.push(old.toOpaque()) {
        // Retire queue full (main thread not draining): leak rather than free here.
      }
      let b = Unmanaged<SampleBuffer>.fromOpaque(p)
      buffer = b
      lengthAtomic.store(b._withUnsafeGuaranteedRef { $0.length }, ordering: .relaxed)
      pos = 0
      target = 0
      looping = false  // a loop region belongs to the audio it was set on
    case .transport(let on): playing = on
    case .start:
      playing = true
      scrubbing = false
      rate = (1 + pitch) * (1 + nudge)
    case .freeze:
      scrubbing = true
      target = pos
    case .scrub(let samples): target += samples
    case .release: scrubbing = false
    case .nudge(let ratio): nudge = ratio
    case .pitch(let ratio): pitch = ratio
    case .seek(let sample):
      pos = sample
      target = sample
    case .loop(let start, let end):
      loopStart = start
      loopEnd = max(end, start + 1)
      looping = true
    case .loopOff: looping = false
    case .chase(let seconds): chaseTau = max(0.002, seconds) * sampleRate
    }
  }
}
