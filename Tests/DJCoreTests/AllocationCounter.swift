import Darwin
import Foundation

// Counts malloc-family allocations made by the calling thread while a closure runs,
// via libsystem_malloc's `malloc_logger` hook. Kept out of files that `import Testing`
// (Foundation next to Testing needs the Xcode-only overlay).
//
// This is how the "audio thread must not allocate" contract is *measured*, not
// asserted: render a few thousand blocks and expect zero allocations.

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private let stackLoggingTypeAlloc: UInt32 = 2
private let stackLoggingTypeDealloc: UInt32 = 4

// Storage the hook can touch without allocating or locking.
nonisolated(unsafe) private let counters = UnsafeMutablePointer<Int>.allocate(capacity: 2)  // [allocs, frees]
nonisolated(unsafe) private let armed = UnsafeMutablePointer<pthread_t?>.allocate(capacity: 1)

private let hook: MallocLogger = { type, _, _, _, _, _ in
  guard let t = armed.pointee, pthread_equal(t, pthread_self()) != 0 else { return }
  if type & stackLoggingTypeAlloc != 0 { counters[0] += 1 }
  if type & stackLoggingTypeDealloc != 0 { counters[1] += 1 }
}

nonisolated(unsafe) private var installed = false
private let gate = NSLock()  // one measurement at a time: the hook state is process-global

public struct AllocationReport: Sendable {
  public var allocations: Int
  public var frees: Int
}

/// Run `body` and report malloc/free calls made on this thread. One counter at a time:
/// tests that use it must not run it concurrently on the same process.
public func countAllocations(_ body: () -> Void) -> AllocationReport {
  gate.lock()
  defer { gate.unlock() }
  if !installed {
    installed = true
    counters.initialize(repeating: 0, count: 2)
    armed.initialize(to: nil)
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") {
      sym.assumingMemoryBound(to: MallocLogger?.self).pointee = hook
    }
  }
  counters[0] = 0
  counters[1] = 0
  armed.pointee = pthread_self()
  body()
  armed.pointee = nil
  return AllocationReport(allocations: counters[0], frees: counters[1])
}
