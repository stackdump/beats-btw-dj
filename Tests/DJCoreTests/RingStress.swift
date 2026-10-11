import Dispatch
import Foundation

@testable import DJCore

// Real two-thread stress for the rings. Lives apart from the `import Testing` files because
// Foundation threads next to Testing need the Xcode-only overlay (see AllocationCounter.swift).

/// A multi-word value whose words must always agree: a torn read shows up as a mismatch.
struct StressPayload: BitwiseCopyable {
  var seq: Int
  var inverse: Int
  var triple: Int
  var tag: Int
  init(_ n: Int) {
    seq = n
    inverse = ~n
    triple = n &* 3
    tag = 0x5EED
  }
  var isConsistent: Bool { inverse == ~seq && triple == seq &* 3 && tag == 0x5EED }
}

struct SPSCStressReport {
  var pushed = 0
  var received = 0
  var dropped = 0
  var outOfOrder = 0
  var corrupt = 0
}

private final class Box<T>: @unchecked Sendable {
  var value: T
  init(_ v: T) { value = v }
}

/// Producer thread pushes `total` payloads (single and in batches, never waiting); the main
/// thread pops (single and in batches). Everything popped must be consistent and in order;
/// received + dropped must account for every push.
func stressSPSC(total: Int, capacity: Int) -> SPSCStressReport {
  let ring = SPSCRing<StressPayload>(capacity: capacity)
  let done = DoneFlag()
  let finished = DispatchSemaphore(value: 0)
  var report = SPSCStressReport()
  let pushedBox = Box(0)
  Thread.detachNewThread {
    var n = 0
    var batch = [StressPayload](repeating: StressPayload(0), count: 37)
    while n < total {
      if n % 5 == 0 {
        let size = min(total - n, 1 + (n / 5) % 37)
        for i in 0..<size { batch[i] = StressPayload(n + i) }
        batch.withUnsafeBufferPointer {
          _ = ring.push(contentsOf: UnsafeBufferPointer(rebasing: $0[0..<size]))
        }
        n += size
      } else {
        ring.push(StressPayload(n))
        n += 1
      }
    }
    pushedBox.value = n
    done.set()
    finished.signal()
  }
  var last = -1
  var out = [StressPayload](repeating: StressPayload(0), count: 29)
  func take(_ p: StressPayload) {
    if !p.isConsistent { report.corrupt += 1 }
    if p.seq <= last { report.outOfOrder += 1 }
    last = p.seq
    report.received += 1
  }
  while true {
    let finishedNow = done.isSet
    var got = 0
    if report.received % 3 == 0 {
      got = out.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
      for i in 0..<got { take(out[i]) }
    } else if let p = ring.pop() {
      take(p)
      got = 1
    }
    if got == 0 && finishedNow && ring.available == 0 { break }
  }
  finished.wait()
  report.pushed = pushedBox.value
  report.dropped = ring.droppedCount
  return report
}

struct LatestStressReport {
  var written = 0
  var received = 0
  var lost = 0
  var reads = 0
  var corrupt = 0
  var misplaced = 0  // a returned value whose sequence number is not where the cursor says
  var lostReads = 0  // reads that reported lost data
}

/// Producer thread writes `total` consecutive payloads as fast as it can, in batches of 1...`maxBatch`,
/// into a deliberately small ring; the main thread pulls by sequence number. Whatever a read
/// returns must be untorn and exactly the sequence numbers the cursor arithmetic promises, and
/// every sequence number is either received or reported lost.
func stressLatest(total: Int, capacity: Int, maxBatch: Int) -> LatestStressReport {
  let ring = LatestRing<StressPayload>(capacity: capacity)
  let done = DoneFlag()
  var report = LatestStressReport()
  let writtenBox = Box(0)
  Thread.detachNewThread {
    var n = 0
    var batch = [StressPayload](repeating: StressPayload(0), count: maxBatch)
    var size = 1
    while n < total {
      size = size % maxBatch + 1
      let m = min(size, total - n)
      if m == 1 {
        ring.write(StressPayload(n))
      } else {
        for i in 0..<m { batch[i] = StressPayload(n + i) }
        batch.withUnsafeBufferPointer {
          ring.write(contentsOf: UnsafeBufferPointer(rebasing: $0[0..<m]))
        }
      }
      n += m
    }
    writtenBox.value = n
    done.set()
  }
  var cursor = 0
  var out = [StressPayload](repeating: StressPayload(0), count: 53)
  while true {
    let finishedNow = done.isSet
    let r = out.withUnsafeMutableBufferPointer { ring.read(from: cursor, into: $0) }
    report.reads += 1
    if r.lost > 0 { report.lostReads += 1 }
    for i in 0..<r.count {
      let p = out[i]
      if !p.isConsistent { report.corrupt += 1 }
      if p.seq != cursor + r.lost + i { report.misplaced += 1 }
    }
    report.received += r.count
    report.lost += r.lost
    cursor += r.lost + r.count
    if finishedNow && r.count == 0 && r.lost == 0 && cursor >= ring.written { break }
  }
  report.written = writtenBox.value
  return report
}

/// A flag one thread sets and another polls, without importing Synchronization into tests.
final class DoneFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() {
    lock.lock()
    flag = true
    lock.unlock()
  }
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }
}
