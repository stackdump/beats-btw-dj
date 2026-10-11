import AVFoundation
import Dispatch
import Foundation

@testable import DJCore

// What the app does at once: a scope window comes and goes (main thread: acquire / release)
// while an output toggle restarts the engine and rewires the routing from a pool thread (it
// is an `await`ed `enableCueOutput`, so the code after the await is not on the main thread).
// Lives apart from the `import Testing` files (Foundation next to Testing needs the overlay).

struct TapChurnReport {
  var restarts = 0
  var subscriptions = 0
  var subscribersAtEnd = 0
  var framesAtEnd = 0
  var engineFrame = 0
}

func churnMasterTap(restarts: Int) throws -> TapChurnReport {
  let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
  dj["A"]!.loadDemo()
  dj["A"]!.setPlaying(true)
  let stop = DoneFlag()
  let finished = DispatchSemaphore(value: 0)
  let count = ChurnCount()
  Thread.detachNewThread {
    while !stop.isSet {
      dj.masterTap.acquire()
      dj.masterTap.release()
      count.value += 1
    }
    finished.signal()
  }
  var report = TapChurnReport()
  for _ in 0..<restarts {
    try dj.start()
    _ = try renderOffline(dj, frames: 512)
    dj.stop()
    report.restarts += 1
  }
  stop.set()
  finished.wait()
  report.subscriptions = count.value
  report.subscribersAtEnd = dj.masterTap.subscribers
  // and the tap still works afterwards
  dj.masterTap.acquire()
  try dj.start()
  _ = try renderOffline(dj, frames: 2048)
  dj.stop()
  dj.masterTap.release()
  report.framesAtEnd = dj.masterTap.frames
  report.engineFrame = dj.frame
  return report
}

private final class ChurnCount: @unchecked Sendable {
  var value = 0
}
