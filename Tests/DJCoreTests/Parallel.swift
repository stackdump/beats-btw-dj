import Dispatch
import Foundation

// Work spread over threads of the test's own. Real `Thread`s, never `DispatchQueue.global()`:
// a test body runs on Swift's cooperative pool, and while a full `swift test` keeps every pool
// thread busy (at a higher QoS than the global default queue), GCD admits no worker for the
// global queue, so a test waiting on one blocks until the run's tail (seen in the full debug
// run: `hammerSubscriptions` parked in `group.wait()` for over an hour with no worker alive).
// Kept out of the files that `import Testing` (Foundation next to Testing needs the Xcode-only
// overlay).

/// Runs `body(0..<count)` on `count` threads of its own and waits for all of them.
func onThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
  let finished = DispatchSemaphore(value: 0)
  for t in 0..<count {
    Thread.detachNewThread {
      body(t)
      finished.signal()
    }
  }
  for _ in 0..<count { finished.wait() }
}

/// `transform` over `items` on up to `width` threads of their own, results in `items`' order.
/// For independent, slow pieces of one test (whole-song renders), so a debug run's tail is not
/// one core working through them one by one.
func parallelMap<T: Sendable, R: Sendable>(
  _ items: [T], width: Int, _ transform: @escaping @Sendable (T) -> R
) -> [R] {
  let work = ParallelWork<R>()
  onThreads(max(1, min(width, items.count))) { _ in
    while let i = work.claim(below: items.count) {
      work.put(transform(items[i]), at: i)
    }
  }
  return items.indices.map { work.results[$0]! }
}

private final class ParallelWork<R>: @unchecked Sendable {
  private let lock = NSLock()
  private var next = 0
  private(set) var results: [Int: R] = [:]

  func claim(below count: Int) -> Int? {
    lock.withLock {
      guard next < count else { return nil }
      next += 1
      return next - 1
    }
  }

  func put(_ r: R, at i: Int) { lock.withLock { results[i] = r } }
}
