import Dispatch
import Foundation

@testable import DJCore

// A reader that follows a playing source from another thread, as a feed does: whatever fires
// it has read, it must also hold the tick anchors of. Lives apart from the `import Testing`
// files (Foundation threads next to Testing need the Xcode-only overlay).

struct EventOrderReport {
  var blocks = 0
  var fires = 0
  var anchors = 0
  var polls = 0
  var lost = 0
  /// Fires returned by a read whose own tick's anchor had not been read by the end of that read.
  var fireWithoutAnchor = 0
}

/// Render `blocks` blocks of `size` frames on a producer thread, as fast as it can go, at a
/// tempo so high that ticks come every few blocks; read the event streams from this thread
/// the whole time.
func stressEventOrder(
  project: Project, blocks: Int, size: Int = 64, resubscribeEvery: Int = 0
) -> EventOrderReport {
  let rate = 8000.0
  let src = WaveDeckSource(sampleRate: rate, fireCapacity: 1 << 17, anchorCapacity: 1 << 16)
  src.load(WaveRunner.prepare(project, sampleRate: rate))
  src.setTempo(3000)
  src.play()
  let done = DoneFlag()
  Thread.detachNewThread {
    var l = [Float](repeating: 0, count: size)
    var r = [Float](repeating: 0, count: size)
    var frame = 0
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        for _ in 0..<blocks {
          src.render(frames: size, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: frame)
          frame += size
        }
      }
    }
    done.set()
  }
  var report = EventOrderReport()
  report.blocks = blocks
  var cursor = resubscribeEvery > 0 ? src.eventCursorNow() : WaveDeckSource.EventCursor()
  var seen = Set<Int64>()  // (generation, tick) of every anchor read so far
  var fires: [FireEvent] = []
  var anchors: [TickAnchor] = []
  func key(_ generation: Int32, _ tick: Int32) -> Int64 { Int64(generation) << 32 | Int64(tick) }
  while true {
    let finished = done.isSet
    if resubscribeEvery > 0 && report.polls % resubscribeEvery == 0 {
      cursor = src.eventCursorNow()  // a new feed opening on a deck that is mid-tick
      seen.removeAll()
    }
    fires.removeAll(keepingCapacity: true)
    anchors.removeAll(keepingCapacity: true)
    let lost = src.readEvents(&cursor, fires: &fires, anchors: &anchors)
    report.polls += 1
    report.lost += lost.firesLost + lost.anchorsLost
    for a in anchors { seen.insert(key(a.generation, a.tick)) }
    for f in fires where !seen.contains(key(f.generation, f.tick)) { report.fireWithoutAnchor += 1 }
    report.fires += fires.count
    report.anchors += anchors.count
    if finished && fires.isEmpty && anchors.isEmpty { break }
  }
  return report
}
