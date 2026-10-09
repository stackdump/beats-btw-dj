import Dispatch
import Foundation

@testable import DJCore

// Two-thread stress for the marking mirror. Foundation threads live here, away from the
// files that `import Testing`.

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  func set() {
    lock.lock()
    on = true
    lock.unlock()
  }
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return on
  }
}

struct MirrorStressReport {
  var reads = 0
  var failedReads = 0
  var torn = 0  // a snapshot whose tokens/mutes/frame disagree with its own tick
  var backwards = 0  // a later read that returned an older sequence
  var published = 0
  var changesSeen = 0
  var retried = 0
}

/// A writer thread publishes `publishes` states in which every token equals the tick, every
/// mute flag equals the tick's parity and the frame equals the tick; a reader on this thread
/// checks every snapshot it can get for exactly that. Any mix of two states fails the check.
func stressMirror(publishes: Int, preemptReader: Bool) -> MirrorStressReport {
  var ov = JSONObject()
  ov["seed"] = .number(42)
  let project = WaveRunner.prepare(
    compose(genre: "techno", overrides: .object(ov)), sampleRate: 8000)
  let mirror = project.marking
  let g = project.graph
  // A reader that is descheduled halfway through its copy while the writer laps the buffer.
  if preemptReader {
    let calls = Box(0)
    mirror.midCopyHook = {
      calls.value += 1
      if calls.value % 3 == 0 { Thread.sleep(forTimeInterval: 0.0002) }
    }
  }
  let done = Flag()
  let count = Box(0)
  Thread.detachNewThread {
    for i in 1...publishes {
      for n in g.nets { for p in 0..<n.nPlaces { n.state[p] = Double(i) } }
      for k in 0..<g.muted.count { g.muted[k] = UInt8(i & 1) }
      g.tick = i
      if mirror.publish(g, endFrame: i) { count.value += 1 }
    }
    done.set()
  }
  var report = MirrorStressReport()
  var snap = MarkingSnapshot()
  var lastSeq = 0
  var lastTick = -1
  while true {
    let finished = done.isSet
    guard mirror.read(into: &snap) else {
      report.failedReads += 1
      if finished { break }
      continue
    }
    report.reads += 1
    let h = snap.header
    if h.sequence < lastSeq { report.backwards += 1 }
    lastSeq = h.sequence
    if h.tick != lastTick { report.changesSeen += 1 }
    lastTick = h.tick
    if h.tick > 0 {  // tick 0 is the seed: the project's real initial marking, not uniform
      let v = Double(h.tick)
      if h.frame != h.tick || !snap.tokens.allSatisfy({ $0 == v })
        || !snap.muted.allSatisfy({ $0 == UInt8(h.tick & 1) })
      {
        report.torn += 1
      }
    }
    if finished && h.tick == publishes { break }
  }
  report.published = count.value
  report.retried = mirror.retries
  return report
}

private final class Box<T>: @unchecked Sendable {
  var value: T
  init(_ v: T) { value = v }
}

struct EngineMirrorReport {
  var reads = 0
  var swapsSeen = 0  // distinct generations observed
  var mismatched = 0  // snapshot arrays not the size of its own layout, or generation != layout's
  var backwards = 0  // sequence or tick went back within one generation
  var unknownLayouts = 0
  var framesRendered = 0
}

/// The audio thread is a real thread running `render` in a loop on a net deck; this thread
/// loads one prepared project after another (so the audio thread swaps at bar boundaries)
/// and reads the mirror as fast as it can. Every snapshot must be sized like its own layout.
func stressEngineMirror(projects: [WaveProject], rate: Double)
  -> EngineMirrorReport
{
  let src = WaveDeckSource(sampleRate: rate)
  src.load(projects[0])
  src.setTempo(3000)
  src.play()
  let stop = Flag()
  let frames = Box(0)
  Thread.detachNewThread {
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    var f = 0
    while !stop.isSet {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          src.render(frames: 128, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: f)
        }
      }
      f += 128
    }
    frames.value = f
  }
  var report = EngineMirrorReport()
  var snap = MarkingSnapshot()
  var lastSeq: [Int32: Int] = [:]
  var lastTick: [Int32: Int] = [:]
  var seen = Set<Int32>()
  var next = 1  // the next project to hand over
  var afterLast = 0
  var onCurrent = 0  // reads since the current project was first seen
  let deadline = Date().addingTimeInterval(120)
  // Paced by progress, not by the clock: the next project is handed over only once a snapshot
  // of the previous one has been read, so a loaded machine only makes this slower, and every
  // project is guaranteed to be observed while it runs.
  while afterLast < 300 && Date() < deadline {
    if seen.contains(projects[next - 1].generation) { onCurrent += 1 }
    if next < projects.count, onCurrent >= 200 {
      src.load(projects[next])
      next += 1
      onCurrent = 0
      src.drainRetired()
    }
    if next == projects.count, onCurrent >= 200 { afterLast += 1 }
    guard src.readMarking(into: &snap), let layout = snap.layout else { continue }
    report.reads += 1
    let h = snap.header
    if h.generation != layout.generation || snap.tokens.count != layout.placeCount
      || snap.muted.count != layout.netCount
    {
      report.mismatched += 1
    }
    if src.markingLayout(generation: h.generation) == nil { report.unknownLayouts += 1 }
    if let s = lastSeq[h.generation], h.sequence < s { report.backwards += 1 }
    if let t = lastTick[h.generation], h.tick < t { report.backwards += 1 }
    lastSeq[h.generation] = h.sequence
    lastTick[h.generation] = h.tick
    seen.insert(h.generation)
  }
  stop.set()
  Thread.sleep(forTimeInterval: 0.05)
  report.swapsSeen = seen.count
  report.framesRendered = frames.value
  return report
}
