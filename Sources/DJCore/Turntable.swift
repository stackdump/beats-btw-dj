import Foundation
import Synchronization

/// Decoded audio held in manually managed memory, so the audio thread can read
/// it without touching Swift array reference counts.
public final class SampleBuffer: @unchecked Sendable {
  public let length: Int
  public let sampleRate: Double
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>  // == left for mono
  /// `level`, once measured (LevelMatch.swift).
  let levelCache = Mutex<SampleLevel?>(nil)

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
  /// Replace the audio with another take of the same loop at another length (an
  /// `Unmanaged<SampleBuffer>` retained by the sender: key lock's time-stretched copy, or the
  /// original back), in phase: the playhead and the loop region scale with the length, and a
  /// playing turntable runs at its new speed at once (no motor ease). `pitch` is its tempo
  /// fader for the new audio (as `.pitch`), set in the same step so no block plays between.
  case swap(UnsafeMutableRawPointer, pitch: Double)
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
  /// Output gain (linear): the deck's auto-gain (`SampleLevel.autoGainDB`). Glides there over
  /// about 10 ms unless `now` (a load: the new audio starts at its own level).
  case gain(Float, now: Bool)
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
  private var gain: Float = 1
  private var gainTarget: Float = 1
  private let gainSmooth: Float

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    chaseTau = 0.035 * sampleRate
    rateSmooth = 1 - exp(-1 / (0.004 * sampleRate))
    motorSmooth = 1 - exp(-1 / (0.045 * sampleRate))
    gainSmooth = Float(1 - exp(-1 / (0.003 * sampleRate)))
  }

  deinit {
    while let c = commands.pop() {
      switch c {
      case .load(let p), .swap(let p, _): Unmanaged<SampleBuffer>.fromOpaque(p).release()
      default: break
      }
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

  /// Hand `buffer` over in place of the loaded one, in phase (`TurntableCommand.swap`).
  public func swap(_ buffer: SampleBuffer, pitch: Double) {
    precondition(buffer.sampleRate == sampleRate, "resample before loading")
    let p = Unmanaged.passRetained(buffer).toOpaque()
    drainRetired()
    if !commands.push(.swap(p, pitch: pitch)) { Unmanaged<SampleBuffer>.fromOpaque(p).release() }
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
    // the auto-gain: nothing at unity, so a deck without one renders the audio's own samples
    if gain != 1 || gainTarget != 1 {
      for i in 0..<frames {
        if gain != gainTarget {
          gain += (gainTarget - gain) * gainSmooth
          if abs(gain - gainTarget) < 1e-6 { gain = gainTarget }
        }
        left[i] *= gain
        right?[i] *= gain
      }
    }
    posBits.store(pos.bitPattern, ordering: .relaxed)
    rateBits.store(rate.bitPattern, ordering: .relaxed)
    // with the playhead, not when a swap is applied mid-render: a reader then never sees the
    // new audio's length beside the old audio's position (the loop clock divides one by the other)
    lengthAtomic.store(buffer._withUnsafeGuaranteedRef { $0.length }, ordering: .relaxed)
  }

  /// Audio thread: move the playhead on by `frames` output frames at the current rate, wrapped
  /// inside the loop region (a loop voice catching up after the loops' vinyl brake, as an
  /// unbraked voice would have played on). Nothing else changes.
  func skip(frames: Double) {
    guard buffer != nil, !scrubbing, frames > 0 else { return }
    pos += rate * frames
    if looping {
      let len = loopEnd - loopStart
      if len > 0, pos >= loopEnd {
        pos = loopStart + (pos - loopStart).truncatingRemainder(dividingBy: len)
      }
    }
    posBits.store(pos.bitPattern, ordering: .relaxed)
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
    case .swap(let p, let newPitch):
      pitch = newPitch
      let b = Unmanaged<SampleBuffer>.fromOpaque(p)
      let newLength = Double(b._withUnsafeGuaranteedRef { $0.length })
      if let old = buffer {
        let oldLength = Double(old._withUnsafeGuaranteedRef { $0.length })
        let scale = newLength / oldLength
        var q = pos.truncatingRemainder(dividingBy: oldLength)
        if q < 0 { q += oldLength }
        pos = q * scale
        target = pos
        if looping {
          loopStart *= scale
          loopEnd = max(loopStart + 1, loopEnd * scale)
        }
        if !retired.push(old.toOpaque()) {
          // Retire queue full (main thread not draining): leak rather than free here.
        }
      } else {
        pos = 0
        target = 0
      }
      buffer = b  // its length is published with the playhead, at the end of the render
      if playing && !scrubbing { rate = (1 + pitch) * (1 + nudge) }
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
    case .gain(let g, let now):
      gainTarget = g
      if now { gain = g }
    }
  }
}
