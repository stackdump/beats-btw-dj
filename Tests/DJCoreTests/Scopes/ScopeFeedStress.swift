@preconcurrency import AVFoundation
import Dispatch
import Foundation

@testable import DJCore

// What the app does at once: the audio thread renders (here a real thread pulling an offline
// engine as fast as it can) while the main thread pumps the scope feeds every few milliseconds
// and, at random, acquires and releases feeds, loads another song on a deck, changes a tempo,
// stops a deck, turns it into a sample deck and back, moves the crossfader. After every pump the
// invariants a mode relies on are checked. Lives apart from the `import Testing` files
// (Foundation next to Testing needs the overlay).

struct FeedStressReport {
  var pumps = 0
  var acquires = 0
  var releases = 0
  var loads = 0
  var actions = 0
  var framesRendered = 0
  var tapsOnAtEnd = 0
  var violations: [String] = []

  mutating func violate(_ message: String) {
    if violations.count < 12 { violations.append(message) }
  }
}

private final class StopFlag: @unchecked Sendable {
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

/// What the render thread owns.
private final class RenderLoop: @unchecked Sendable {
  let dj: DJEngine
  let buffer: AVAudioPCMBuffer
  var frames = 0
  init(_ dj: DJEngine, block: Int) {
    self.dj = dj
    buffer = makeEngineRenderBuffer(dj, frames: block)
  }
}

private struct XorShift {
  var state: UInt64
  mutating func next() -> Int {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Int(truncatingIfNeeded: state >> 1)
  }
}

@MainActor
func stressFeeds(seconds: Double, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) throws -> FeedStressReport {
  let block = 512
  let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
  let genres = ["techno", "house", "ambient", "dnb", "trap", "dub"]
  var songs = 0
  func nextSong() -> Project {
    songs += 1
    return scopeProject(genres[songs % genres.count], seed: Double(songs))
  }
  for name in ["A", "B"] {
    dj[name]!.loadNet(nextSong())
    dj[name]!.wave.setTempo(600)
    dj[name]!.setPlaying(true)
  }
  let hub = ScopeHub(engine: dj)
  let sources: [ScopeSource] = [.deck("A"), .deck("B"), .master]
  try dj.start()
  let loop = RenderLoop(dj, block: block)
  let stop = StopFlag()
  let finished = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
    while !stop.isSet {
      pullEngine(loop.dj, loop.buffer, cycles: 1, frames: block)
      loop.frames += block
      // ~10x real time (a block is 23 ms of audio). Flat out the render thread holds the
      // engine's locks so much that the main thread's own calls (a crossfader move) starve.
      Thread.sleep(forTimeInterval: 0.002)
    }
    finished.signal()
  }

  var report = FeedStressReport()
  var rng = XorShift(state: seed)
  var held = [Bool](repeating: false, count: sources.count)
  var lastNow = [Int?](repeating: nil, count: sources.count)
  var lastGen = [Int](repeating: 0, count: sources.count)
  var lastTotal = [Int](repeating: 0, count: sources.count)
  var issuer: [Int: Int] = [:]  // generation number -> the feed (index) that reported it first
  let deadline = Date().addingTimeInterval(seconds)

  func check(_ i: Int) {
    let f = hub.feed(sources[i])
    let tag = "\(sources[i].label)"
    if f.history.endFrame > f.nowFrame {
      report.violate("\(tag): history ends at \(f.history.endFrame) past now \(f.nowFrame)")
    }
    if let before = lastNow[i], f.nowFrame < before {
      report.violate("\(tag): now went back \(before) -> \(f.nowFrame)")
    }
    lastNow[i] = f.nowFrame
    if f.history.count > f.history.capacity { report.violate("\(tag): history over capacity") }
    if f.generation < lastGen[i] { report.violate("\(tag): generation went back") }
    if f.generation != lastGen[i] {
      if let other = issuer[f.generation], other != i {
        report.violate("\(tag): generation \(f.generation) was already \(sources[other].label)'s")
      }
      issuer[f.generation] = i
      lastGen[i] = f.generation
    }
    if f.fireCount < lastTotal[i] { report.violate("\(tag): fire count went back") }
    lastTotal[i] = f.fireCount
    var previous = -1
    for n in f.fireLog.numbers(since: 0) {
      guard let fire = f.fireLog.fire(number: n) else {
        report.violate("\(tag): fire \(n) missing inside the held range")
        break
      }
      if !f.lanes.indices.contains(fire.lane) {
        report.violate("\(tag): fire on lane \(fire.lane) of \(f.lanes.count)")
        break
      }
      if fire.frame < previous {
        report.violate("\(tag): fire log not time ordered: \(fire.frame) after \(previous)")
        break
      }
      if fire.frame >= f.nowFrame {
        report.violate("\(tag): fire at \(fire.frame) at or past now \(f.nowFrame)")
        break
      }
      previous = fire.frame
    }
    let ring = f.anchors
    for k in 1..<max(1, ring.count) where ring[k].frame <= ring[k - 1].frame {
      report.violate("\(tag): anchors out of order")
      break
    }
    if f.lanes.count > ScopeLaneSet.maxLanes * 2 { report.violate("\(tag): too many lanes") }
    for w in f.deckWeights.values where !(w.isFinite && w >= 0) {
      report.violate("\(tag): weight \(w)")
    }
  }

  while Date() < deadline {
    hub.pump()
    report.pumps += 1
    for i in sources.indices where held[i] { check(i) }
    // something happens
    let roll = rng.next() % 16
    let deck = dj[rng.next() % 2 == 0 ? "A" : "B"]!
    switch roll {
    case 0, 1, 2:
      let i = rng.next() % sources.count
      let f = hub.feed(sources[i])
      if held[i] {
        f.release()
        report.releases += 1
      } else {
        f.acquire()
        report.acquires += 1
        lastNow[i] = nil  // a (re)acquire starts the axis over
      }
      held[i].toggle()
    case 3:
      deck.loadNet(nextSong())
      deck.wave.setTempo(Double(300 + (rng.next() % 6) * 300))
      deck.setPlaying(true)
      report.loads += 1
    case 4: deck.wave.setTempo(Double(120 + (rng.next() % 40) * 30))
    case 5: deck.setPlaying(rng.next() % 3 != 0)
    case 6:
      deck.loadDemo()
      deck.setPlaying(true)
    case 7: dj.crossfader = Double(rng.next() % 101) / 100
    default: break
    }
    if roll < 8 { report.actions += 1 }
    Thread.sleep(forTimeInterval: 0.003)
  }

  stop.set()
  finished.wait()
  report.framesRendered = loop.frames
  hub.pump()
  for i in sources.indices where held[i] { check(i) }
  for i in sources.indices where held[i] { hub.feed(sources[i]).release() }
  dj.stop()
  report.tapsOnAtEnd = [dj["A"]!.tap, dj["B"]!.tap, dj.masterTap].filter(\.isEnabled).count
  return report
}
