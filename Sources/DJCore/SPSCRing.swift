import Synchronization

/// Lock-free single-producer / single-consumer queue of plain values.
///
/// The way the main thread and the audio thread talk: one side only pushes,
/// the other only pops, neither ever blocks or allocates. `T` is
/// `BitwiseCopyable` so a push/pop never retains or releases anything.
///
/// Threading contract (one thread per side, fixed for the ring's life):
///  * producer: `push`, `push(contentsOf:)`, `freeSlots`
///  * consumer: `pop`, `pop(into:)`, `available`, `discardAll`
///  * any thread: `capacity`, `droppedCount`
public final class SPSCRing<T: BitwiseCopyable>: @unchecked Sendable {
  private let slots: UnsafeMutablePointer<T>
  private let count: Int
  private let head = Atomic<Int>(0)  // next slot to write; producer-owned
  private let tail = Atomic<Int>(0)  // next slot to read; consumer-owned
  private let dropped = Atomic<Int>(0)  // values refused because the ring was full; producer-owned

  /// Holds up to `capacity` values.
  public init(capacity: Int) {
    count = capacity + 1  // one slot stays empty to tell full from empty
    slots = .allocate(capacity: count)
  }

  deinit { slots.deallocate() }

  /// The most values the ring holds at once.
  public var capacity: Int { count - 1 }

  /// How many values are queued right now. Consumer side: the producer can only add to it
  /// meanwhile, so at least this many pops will succeed.
  public var available: Int {
    let h = head.load(ordering: .acquiring)
    let t = tail.load(ordering: .relaxed)
    return h >= t ? h - t : h - t + count
  }

  /// How many values fit right now. Producer side: the consumer can only add to it meanwhile,
  /// so at least this many pushes will succeed.
  public var freeSlots: Int {
    let h = head.load(ordering: .relaxed)
    let t = tail.load(ordering: .acquiring)
    return t > h ? t - h - 1 : t - h - 1 + count
  }

  /// How many values the producer has had to throw away because the ring was full, since
  /// the ring was made. Counted by the producer, readable from any thread.
  public var droppedCount: Int { dropped.load(ordering: .relaxed) }

  /// Producer side. Returns false (and drops `value`, counting it in `droppedCount`) when full.
  @discardableResult
  public func push(_ value: T) -> Bool {
    let h = head.load(ordering: .relaxed)
    let next = h + 1 == count ? 0 : h + 1
    if next == tail.load(ordering: .acquiring) {
      dropped.add(1, ordering: .relaxed)
      return false
    }
    (slots + h).initialize(to: value)
    head.store(next, ordering: .releasing)
    return true
  }

  /// Producer side. Pushes as many of `values` as fit, in order, and returns how many that
  /// was; the rest are dropped and counted in `droppedCount`.
  @discardableResult
  public func push(contentsOf values: UnsafeBufferPointer<T>) -> Int {
    guard let src = values.baseAddress, !values.isEmpty else { return 0 }
    let h = head.load(ordering: .relaxed)
    let t = tail.load(ordering: .acquiring)
    let free = t > h ? t - h - 1 : t - h - 1 + count
    let n = min(free, values.count)
    if n < values.count { dropped.add(values.count - n, ordering: .relaxed) }
    if n == 0 { return 0 }
    let first = min(n, count - h)  // up to the physical end, then wrap
    (slots + h).initialize(from: src, count: first)
    if n > first { slots.initialize(from: src + first, count: n - first) }
    let next = h + n
    head.store(next >= count ? next - count : next, ordering: .releasing)
    return n
  }

  /// Consumer side.
  public func pop() -> T? {
    let t = tail.load(ordering: .relaxed)
    if t == head.load(ordering: .acquiring) { return nil }
    let value = slots[t]
    tail.store(t + 1 == count ? 0 : t + 1, ordering: .releasing)
    return value
  }

  /// Consumer side. Pops up to `out.count` values into `out` (oldest first) and returns how
  /// many it popped.
  public func pop(into out: UnsafeMutableBufferPointer<T>) -> Int {
    guard let dst = out.baseAddress, !out.isEmpty else { return 0 }
    let t = tail.load(ordering: .relaxed)
    let h = head.load(ordering: .acquiring)
    let queued = h >= t ? h - t : h - t + count
    let n = min(queued, out.count)
    if n == 0 { return 0 }
    let first = min(n, count - t)
    dst.update(from: slots + t, count: first)
    if n > first { (dst + first).update(from: slots, count: n - first) }
    let next = t + n
    tail.store(next >= count ? next - count : next, ordering: .releasing)
    return n
  }

  /// Consumer side. Throws away everything queued right now (not counted as dropped).
  public func discardAll() {
    tail.store(head.load(ordering: .acquiring), ordering: .releasing)
  }
}
