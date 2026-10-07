import Synchronization

/// Lock-free single-producer / single-consumer queue of plain values.
///
/// The way the main thread and the audio thread talk: one side only pushes,
/// the other only pops, neither ever blocks or allocates. `T` is
/// `BitwiseCopyable` so a push/pop never retains or releases anything.
public final class SPSCRing<T: BitwiseCopyable>: @unchecked Sendable {
  private let slots: UnsafeMutablePointer<T>
  private let count: Int
  private let head = Atomic<Int>(0)  // next slot to write; producer-owned
  private let tail = Atomic<Int>(0)  // next slot to read; consumer-owned

  /// Holds up to `capacity` values.
  public init(capacity: Int) {
    count = capacity + 1  // one slot stays empty to tell full from empty
    slots = .allocate(capacity: count)
  }

  deinit { slots.deallocate() }

  /// Producer side. Returns false (and drops `value`) when full.
  @discardableResult
  public func push(_ value: T) -> Bool {
    let h = head.load(ordering: .relaxed)
    let next = (h + 1) % count
    if next == tail.load(ordering: .acquiring) { return false }
    (slots + h).initialize(to: value)
    head.store(next, ordering: .releasing)
    return true
  }

  /// Consumer side.
  public func pop() -> T? {
    let t = tail.load(ordering: .relaxed)
    if t == head.load(ordering: .acquiring) { return nil }
    let value = slots[t]
    tail.store((t + 1) % count, ordering: .releasing)
    return value
  }
}
