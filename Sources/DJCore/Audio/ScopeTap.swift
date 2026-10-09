import Synchronization

/// A mono history of one audio stream (a deck's output, or the master) for the scopes to
/// read, plus the bookkeeping that ties it to the engine's common time base.
///
/// **Time base.** Every sample in the ring has an absolute sequence number `s` (0 is the
/// first sample ever pushed). `frame(ofSequence:)` turns it into the engine's frame count:
/// the same units as `Deck.renderedFrames`, `DJEngine.frame` and `FireEvent.frame`, so a
/// scope can put a waveform and the fires on one axis. Audio seconds = frames / sampleRate.
/// If the producer skipped time (a gap between two pushes) the gap is filled with silence,
/// so the mapping stays `frame = origin + sequence` for the life of the tap.
///
/// **Off until someone looks.** `acquire()` / `release()` count subscribers. While the count
/// is zero the producer does nothing but test `isEnabled` (one relaxed atomic load); an idle
/// app pays nothing.
///
/// **Threading.**
///  * Producer (exactly one thread at a time: the render thread. For a deck it is its source
///    node's block, for the master the output unit's post-render notification, both on the
///    engine's render thread): `isEnabled`, `push`.
///  * Any thread: everything else (`acquire`, `release`, `read`, `frames`, `endFrame`,
///    `frame(ofSequence:)`, ...).
public final class ScopeTap: @unchecked Sendable {
  /// 64 K samples: 1.4 s at 48 kHz, comfortably more than a scope's window needs between frames.
  public static let defaultCapacity = 1 << 16

  /// The mono samples. Pull from it with `read(from:into:)`.
  public let ring: LatestRing<Float>

  private let subscriberCount = Atomic<Int>(0)

  // Time base. `originFrame` is written by the producer before the first sample becomes
  // visible; it only changes again if the producer's clock jumps backwards (`epoch` then counts).
  private let originFrameAtomic = Atomic<Int>(0)
  private let epochAtomic = Atomic<Int>(0)
  private let gapAtomic = Atomic<Int>(0)

  // Producer-owned.
  private var started = false
  private var nextFrame = 0
  private let scratch: UnsafeMutablePointer<Float>
  private static let chunk = 1024

  public init(capacity: Int = ScopeTap.defaultCapacity) {
    ring = LatestRing<Float>(capacity: max(capacity, 1 << 12))
    scratch = .allocate(capacity: Self.chunk)
    scratch.initialize(repeating: 0, count: Self.chunk)
  }

  deinit { scratch.deallocate() }

  // MARK: subscribing

  /// A scope starts reading. The tap is fed from the next block on. Balance every call with
  /// `release()`. Any thread.
  public func acquire() { subscriberCount.add(1, ordering: .relaxed) }

  /// A scope stops reading. The last release switches the tap off. Extra releases are ignored.
  public func release() {
    var current = subscriberCount.load(ordering: .relaxed)
    while current > 0 {
      let exchange = subscriberCount.compareExchange(
        expected: current, desired: current - 1, ordering: .relaxed)
      if exchange.exchanged { return }
      current = exchange.original
    }
  }

  public var subscribers: Int { subscriberCount.load(ordering: .relaxed) }

  /// Is anyone reading? The one thing the producer checks per block.
  public var isEnabled: Bool { subscriberCount.load(ordering: .relaxed) > 0 }

  // MARK: reading (any thread)

  /// Total samples pushed since the tap was made (== `ring.written`): the next sequence number.
  public var frames: Int { ring.written }

  /// The engine frame of sequence number 0 (meaningful once `frames > 0`).
  public var originFrame: Int { originFrameAtomic.load(ordering: .relaxed) }

  /// Counts the times the producer's clock jumped backwards and the origin was re-based.
  /// Never happens with an engine-driven time base; a scope that sees it change should reset.
  public var epoch: Int { epochAtomic.load(ordering: .relaxed) }

  /// Frames of silence the tap had to insert because the producer skipped time (the tap was
  /// switched off for a while, or the deck's block was handed no buffers).
  public var gapFrames: Int { gapAtomic.load(ordering: .relaxed) }

  /// The engine frame that follows the newest sample: the right edge of the data, "now" as
  /// far as this tap is concerned. For a deck's tap, and for the master tap, it is the render
  /// head: the same as `Deck.renderedFrames` / `DJEngine.frame` after the cycle that produced
  /// the newest sample (nothing is delivered late). What the listener hears is
  /// `DJEngine.outputLatencyFrames` behind it.
  public var endFrame: Int { originFrame + frames }

  public func frame(ofSequence s: Int) -> Int { originFrame + s }
  public func sequence(ofFrame f: Int) -> Int { f - originFrame }

  /// Copy samples from sequence number `from` on (see `LatestRing.read`).
  public func read(from: Int, into out: UnsafeMutableBufferPointer<Float>) -> (
    count: Int, lost: Int
  ) {
    ring.read(from: from, into: out)
  }

  // MARK: producing (single producer)

  /// Append the mono mixdown `(left + right) / 2` of `frames` samples that start at engine
  /// frame `startFrame` (`right` nil: `left` is already mono). `stride` is the distance in
  /// elements between a channel's consecutive samples: 1 for one buffer per channel, the
  /// channel count for interleaved audio. Allocates nothing, takes no lock; chunked through a
  /// preallocated scratch buffer. Call only when `isEnabled`.
  public func push(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames n: Int, startFrame: Int,
    stride: Int = 1
  ) {
    guard n > 0 else { return }
    align(to: startFrame)
    var done = 0
    while done < n {
      let m = min(Self.chunk, n - done)
      let l = left + done * stride
      if let right {
        let r = right + done * stride
        if stride == 1 {
          for i in 0..<m { scratch[i] = (l[i] + r[i]) * 0.5 }
        } else {
          for i in 0..<m { scratch[i] = (l[i * stride] + r[i * stride]) * 0.5 }
        }
      } else if stride == 1 {
        for i in 0..<m { scratch[i] = l[i] }
      } else {
        for i in 0..<m { scratch[i] = l[i * stride] }
      }
      ring.write(contentsOf: UnsafeBufferPointer(start: scratch, count: m))
      done += m
    }
    nextFrame = startFrame + n
  }

  /// Append already-mono samples that start at engine frame `startFrame`.
  public func push(mono: UnsafeBufferPointer<Float>, startFrame: Int) {
    guard !mono.isEmpty else { return }
    align(to: startFrame)
    ring.write(contentsOf: mono)
    nextFrame = startFrame + mono.count
  }

  /// Make the next sample land at `frame`: set the origin on the first push, fill a gap with
  /// silence, re-base if the clock went backwards.
  private func align(to frame: Int) {
    let w = ring.written
    if !started {
      started = true
      originFrameAtomic.store(frame - w, ordering: .relaxed)
    } else if frame > nextFrame {
      let gap = frame - nextFrame
      gapAtomic.add(gap, ordering: .relaxed)
      // Silence for the whole gap in one claim. (Not "skip ahead, then fill the last lap":
      // between those two steps a reader that was caught up would be handed the previous
      // lap's audio as if it belonged to the gap.)
      ring.write(repeating: 0, count: gap)
    } else if frame < nextFrame {
      epochAtomic.add(1, ordering: .relaxed)
      originFrameAtomic.store(frame - w, ordering: .relaxed)
    }
  }
}
