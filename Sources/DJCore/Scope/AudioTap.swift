import Synchronization

/// A read-only copy of one audio path (a deck's own output, or the master) for the
/// scope views: a lock-free single-producer / single-consumer ring of mono floats.
///
/// **Overwrite-oldest, not drop-newest.** A scope wants the most recent audio, and a
/// UI that stalls for a second must not make the audio thread choose between blocking
/// and losing the *new* samples. So the producer never looks at the consumer at all:
/// it writes at `written & mask` and publishes the running total. The consumer keeps
/// its own cursor, copies what it wants and then re-checks the total; if the producer
/// lapped it mid-copy the overwritten head of the copy is discarded and reported as
/// `lost`. That keeps the SPSC rule (each index has exactly one writer) without a tail
/// the producer would have to respect, and costs the render path one store per block.
///
/// Preallocated and power-of-two sized. `write` allocates, locks and releases nothing.
public final class AudioTap: @unchecked Sendable {
  public let capacity: Int
  private let mask: Int
  private let slots: UnsafeMutablePointer<Float>
  /// Total frames ever written: the tap's own clock. Producer stores, anyone loads.
  private let written = Atomic<Int>(0)

  /// `minimumCapacity` is rounded up to a power of two (default 2^17 = 2.7 s at 48 kHz).
  public init(minimumCapacity: Int = 1 << 17) {
    var c = 1024
    while c < minimumCapacity { c <<= 1 }
    capacity = c
    mask = c - 1
    slots = .allocate(capacity: c)
    slots.initialize(repeating: 0, count: c)
  }

  deinit { slots.deallocate() }

  /// Frames written since the tap was built. On an engine's taps this equals
  /// `DJEngine.frame` (every node is pulled once per cycle), so it is the shared timebase.
  public var framesWritten: Int { written.load(ordering: .acquiring) }

  /// Producer (audio thread): append the mono mix `(l + r) / 2` of `frames` samples.
  public func write(
    _ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>?, frames: Int
  ) {
    let pos = written.load(ordering: .relaxed)
    if let r {
      for i in 0..<frames { slots[(pos &+ i) & mask] = (l[i] + r[i]) * 0.5 }
    } else {
      for i in 0..<frames { slots[(pos &+ i) & mask] = l[i] }
    }
    written.store(pos &+ frames, ordering: .releasing)
  }

  /// Consumer: copy up to `maxFrames` samples starting at absolute frame `from` into
  /// `out`. If `from` is older than the ring still holds, the copy starts at the oldest
  /// intact frame. Returns the absolute frame of `out[0]`, how many samples were copied,
  /// and how many frames between `from` and that start were overwritten (`lost`).
  public func read(
    from: Int, into out: UnsafeMutablePointer<Float>, maxFrames: Int
  ) -> (start: Int, count: Int, lost: Int) {
    let w = written.load(ordering: .acquiring)
    var start = max(from, w - capacity)
    let n = min(maxFrames, max(0, w - start))
    guard n > 0 else { return (start, 0, max(0, start - from)) }
    for i in 0..<n { out[i] = slots[(start &+ i) & mask] }
    // The producer may have run on while we copied: the oldest `bad` samples may be new.
    let w2 = written.load(ordering: .acquiring)
    let bad = min(n, max(0, w2 - capacity - start))
    if bad > 0 {
      for i in 0..<(n - bad) { out[i] = out[i + bad] }
      start += bad
    }
    return (start, n - bad, start - from)
  }

  /// The newest `count` samples (fewer before that many exist), oldest first.
  public func recent(_ count: Int) -> [Float] {
    let w = framesWritten
    let n = min(count, w, capacity / 2)
    guard n > 0 else { return [] }
    var out = [Float](repeating: 0, count: n)
    let r = out.withUnsafeMutableBufferPointer {
      read(from: w - n, into: $0.baseAddress!, maxFrames: n)
    }
    if r.count < n { out.removeFirst(n - r.count) }
    return out
  }
}
