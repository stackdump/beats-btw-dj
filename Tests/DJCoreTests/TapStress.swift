import Dispatch
import Foundation
import Synchronization

@testable import DJCore

// Two-thread stress for the one place a `ScopeTap` skips time: a gap longer than the ring.
// Lives apart from the `import Testing` files (Foundation threads next to Testing need the
// Xcode-only overlay, see AllocationCounter.swift).

struct TapGapStressReport {
  var iterations = 0
  var reads = 0
  var received = 0
  var lost = 0
  /// Samples returned that are not what was pushed at that sequence number.
  var wrong = 0
}

private final class Counter: @unchecked Sendable {
  var value = 0
}

/// A producer pushes, over and over: `capacity` samples of 7, then a gap of `capacity + 904`
/// frames (silence), then a block of 3s. A reader that is caught up when the gap arrives pulls
/// continuously by sequence number. Every sample it is given must be what belongs at that
/// sequence number: 7 before the gap, silence in it, 3 after. Stale audio from the previous
/// lap, labelled as part of the gap, would show up as a 7 where a 0 belongs.
func stressTapGap(iterations: Int, capacity: Int = 1 << 12) -> TapGapStressReport {
  let tap = ScopeTap(capacity: capacity)
  let cap = tap.ring.capacity
  let gap = cap + 904
  let block = 600
  let period = cap + gap + block
  let done = DoneFlag()
  let produced = Counter()
  let readerAt = Atomic<Int>(0)  // sequence number the reader has consumed up to
  let sevens = [Float](repeating: 7, count: cap)
  let threes = [Float](repeating: 3, count: block)
  Thread.detachNewThread {
    var frame = 0
    for _ in 0..<iterations {
      sevens.withUnsafeBufferPointer { tap.push(mono: $0, startFrame: frame) }
      frame += cap
      // wait until the reader has caught up with everything pushed so far, then jump
      while readerAt.load(ordering: .acquiring) < tap.frames {}
      frame += gap  // nothing pushed for `gap` frames
      threes.withUnsafeBufferPointer { tap.push(mono: $0, startFrame: frame) }
      frame += block
      produced.value += 1
    }
    done.set()
  }
  var report = TapGapStressReport()
  var cursor = 0
  var buf = [Float](repeating: -1, count: 64)
  while true {
    let finished = done.isSet
    let r = buf.withUnsafeMutableBufferPointer { tap.read(from: cursor, into: $0) }
    report.reads += 1
    for k in 0..<r.count {
      let pos = (cursor + r.lost + k) % period
      let want: Float = pos < cap ? 7 : (pos < cap + gap ? 0 : 3)
      if buf[k] != want { report.wrong += 1 }
    }
    report.received += r.count
    report.lost += r.lost
    cursor += r.lost + r.count
    readerAt.store(cursor, ordering: .releasing)
    if finished && r.count == 0 && cursor >= tap.frames { break }
  }
  report.iterations = produced.value
  return report
}
