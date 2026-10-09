import Foundation
import Synchronization

@testable import DJCore

// Kept out of files that `import Testing` (Foundation next to Testing needs the Xcode overlay).

/// Run `render` (armed with the malloc counter) on this thread while another thread keeps
/// draining `feed`, as the UI does. Returns what the render thread allocated and freed.
func countRenderWhileDraining(feed: ScopeFeed, render: () -> Void) -> AllocationReport {
  let stop = Atomic<Bool>(false)
  let drained = Atomic<Int>(0)
  let done = DispatchSemaphore(value: 0)
  let reader = Thread {
    var now = 1000.0
    while !stop.load(ordering: .relaxed) {
      now += 0.016
      feed.update(now: now)
      _ = feed.reader.columns(width: 200, window: 2)
      _ = feed.reader.recent(4096)
      drained.add(1, ordering: .relaxed)
      Thread.sleep(forTimeInterval: 0.001)
    }
    done.signal()
  }
  reader.start()
  let report = countAllocations(render)
  stop.store(true, ordering: .relaxed)
  done.wait()
  return report
}

func monoMix(_ l: [Float], _ r: [Float]) -> [Float] { zip(l, r).map { ($0 + $1) * 0.5 } }
