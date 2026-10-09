import Synchronization

/// A ring of plain values where the producer never waits and never fails: when it is full
/// the oldest values are overwritten. For history that is sampled, not consumed — the last
/// N audio samples for a scope — where a late reader prefers "the newest data and a count
/// of what it missed" to back-pressure on the audio thread.
///
/// Every value has an absolute sequence number: the first ever written is 0. A consumer
/// keeps its own cursor and pulls by sequence number; nothing it does affects the producer.
///
/// Threading contract: exactly one producer thread (`write`, `write(contentsOf:)`); any
/// number of consumers (`read`, `written`, `capacity`), each with its own cursor. Neither
/// side allocates or locks after `init`.
///
/// Protocol (a seqlock over the ring): the producer first publishes `claimed` — "everything
/// below `claimed - capacity` may be overwritten from now on" — then writes the values,
/// then publishes `written` ("everything below this is complete"). A reader copies up to
/// `written`, and afterwards re-reads `claimed`: any copied value older than
/// `claimed - capacity` may have been overwritten while it was being copied, so that prefix
/// is thrown away and counted as lost. Nothing torn is ever returned.
public final class LatestRing<T: BitwiseCopyable>: @unchecked Sendable {
  private let slots: UnsafeMutablePointer<T>
  private let mask: Int
  private let claimedTotal = Atomic<Int>(0)  // producer-owned; sequence numbers started
  private let writtenTotal = Atomic<Int>(0)  // producer-owned; sequence numbers completed
  /// Test seam: runs in the middle of a reader's copy, as if the reader were preempted there
  /// while the producer lapped it. Nil in production.
  var midCopyHook: (() -> Void)?

  /// `capacity` is rounded up to a power of two (at least 2).
  public init(capacity: Int) {
    var n = 2
    while n < capacity { n <<= 1 }
    slots = .allocate(capacity: n)
    mask = n - 1
  }

  deinit { slots.deallocate() }

  /// How many values the ring holds.
  public var capacity: Int { mask + 1 }

  /// Total values completed so far: the sequence number the next write will get. Readable
  /// from any thread.
  public var written: Int { writtenTotal.load(ordering: .acquiring) }

  /// Producer side. Never blocks; overwrites the oldest value when full.
  public func write(_ value: T) {
    let w = writtenTotal.load(ordering: .relaxed)
    claimedTotal.store(w + 1, ordering: .relaxed)
    atomicMemoryFence(ordering: .releasing)  // the claim is visible before the slot changes
    (slots + (w & mask)).initialize(to: value)
    writtenTotal.store(w + 1, ordering: .releasing)
  }

  /// Producer side. Appends all of `values`. A batch bigger than the ring keeps only its last
  /// `capacity` values; the rest read as lost.
  public func write(contentsOf values: UnsafeBufferPointer<T>) {
    guard let src = values.baseAddress, !values.isEmpty else { return }
    let w = writtenTotal.load(ordering: .relaxed)
    let n = values.count
    claimedTotal.store(w + n, ordering: .relaxed)
    atomicMemoryFence(ordering: .releasing)
    let skip = max(0, n - capacity)  // the batch would overwrite these itself
    let m = n - skip
    let start = (w + skip) & mask
    let first = min(m, capacity - start)
    (slots + start).initialize(from: src + skip, count: first)
    if m > first { slots.initialize(from: src + skip + first, count: m - first) }
    writtenTotal.store(w + n, ordering: .releasing)
  }

  /// Consumer side. Copies the values from sequence number `from` on into `out` (as many as
  /// are complete and fit). Returns `count`, the number copied (into `out[0..<count]`), and
  /// `lost`, how many values were skipped before the first copied one because they were
  /// already overwritten: the consumer was more than a capacity behind, or the producer
  /// lapped it during the copy (the torn prefix is dropped). The first value returned has
  /// sequence number `from + lost`; advance the cursor by `lost + count`.
  public func read(from: Int, into out: UnsafeMutableBufferPointer<T>) -> (count: Int, lost: Int) {
    guard let dst = out.baseAddress, !out.isEmpty else { return (0, 0) }
    let w = writtenTotal.load(ordering: .acquiring)
    var start = max(from, 0)
    var lost = 0
    if start >= w { return (0, 0) }
    if start < w - capacity {  // fell behind by a whole lap
      lost = w - capacity - start
      start = w - capacity
    }
    let n = min(w - start, out.count)
    let s = start & mask
    let first = min(n, capacity - s)
    dst.update(from: slots + s, count: first)
    midCopyHook?()
    if n > first { (dst + first).update(from: slots, count: n - first) }
    atomicMemoryFence(ordering: .acquiring)  // the copy is done before we look at the claim
    let safeFrom = claimedTotal.load(ordering: .relaxed) - capacity
    if safeFrom > start {  // the producer lapped part of what we just copied
      let torn = min(n, safeFrom - start)
      lost += torn
      let kept = n - torn
      if kept > 0 { dst.update(from: dst + torn, count: kept) }
      return (kept, lost)
    }
    return (n, lost)
  }
}

extension LatestRing {
  /// Consumer side. Appends everything from `cursor` on, as of this call, to `out` and moves
  /// `cursor` past it. Returns how many values were lost (already overwritten when the reader
  /// got to them; skipped, never repeated). Allocates only if `out` has to grow, so it is for
  /// a consumer's own thread, never the producer's.
  @discardableResult
  public func drain(from cursor: inout Int, into out: inout [T]) -> Int {
    let end = written
    var lost = 0
    withUnsafeTemporaryAllocation(of: T.self, capacity: 128) { chunk in
      while cursor < end {
        let r = read(from: cursor, into: chunk)
        if r.count == 0 && r.lost == 0 { break }
        out.append(contentsOf: UnsafeBufferPointer(rebasing: chunk[0..<r.count]))
        lost += r.lost
        cursor += r.lost + r.count
      }
    }
    return lost
  }
}
