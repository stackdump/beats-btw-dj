import Testing

@testable import DJCore

// The audio-thread contract for everything the scopes added: the deck block with its frame
// counter, tap, fire and anchor rings and marking mirror; the rings themselves. Measured, not
// asserted: release builds only (`make swift-rt-test`), warmed up first, and every test also
// checks that the rings really received data (otherwise zero allocations prove nothing).

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private func project(_ genre: String, _ seed: Double, _ structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

/// Allocation totals over several measured regions.
private struct Tally {
  var allocs = 0
  var frees = 0
  /// The offending stacks over all regions, up to `maxStacks` (`Rig.measure` keeps them).
  var stacks: [String] = []
  mutating func add(_ r: AllocationReport) {
    allocs += r.allocations
    frees += r.frees
    stacks += r.stacks.prefix(maxStacks - stacks.count)
  }
  var stackText: String { stacks.isEmpty ? "" : "\n" + stacks.joined(separator: "\n\n") }
}

/// A deck driven block by block on this thread, as the audio thread would drive it. Commands
/// are sent from here (outside the measured regions, because a send also frees retired
/// projects: main-thread work); only `renderBlock` is measured.
private final class Rig {
  let dj: DJEngine
  let deck: Deck
  var tally = Tally()
  var fires: [FireEvent] = []
  var anchors: [TickAnchor] = []
  var cursor = WaveDeckSource.EventCursor()
  var lost = (fires: 0, anchors: 0)
  private var l = [Float](repeating: 0, count: 4096)
  private var r = [Float](repeating: 0, count: 4096)

  init(sampleRate: Double = 48_000) throws {
    dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sampleRate)
    deck = dj["A"]!
  }

  /// Render `n` blocks of `size` frames, measured.
  func measure(_ n: Int, size: Int = 128) {
    let deck = deck
    tally.add(
      countAllocations(stacks: true) {
        l.withUnsafeMutableBufferPointer { lp in
          r.withUnsafeMutableBufferPointer { rp in
            for _ in 0..<n {
              deck.renderBlock(frames: size, left: lp.baseAddress!, right: rp.baseAddress!)
            }
          }
        }
      })
  }

  /// Render without measuring (warm-up).
  func warm(_ n: Int, size: Int = 128) {
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        for _ in 0..<n {
          deck.renderBlock(frames: size, left: lp.baseAddress!, right: rp.baseAddress!)
        }
      }
    }
  }

  /// Reader side: take what the event rings hold since the last call.
  func drain() {
    let l = deck.wave.readEvents(&cursor, fires: &fires, anchors: &anchors)
    lost.fires += l.firesLost
    lost.anchors += l.anchorsLost
  }
}

struct DeckBlockRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aNetDeckWithTapFiresAndMarkingDoesNotAllocate() throws {
    let rig = try Rig()
    let deck = rig.deck
    deck.loadNet(project("techno", 42, "standard"))
    let second = WaveRunner.prepare(project("dnb", 3, "standard"), sampleRate: 48_000)
    let third = WaveRunner.prepare(project("house", 4, "standard"), sampleRate: 48_000)
    let firstGeneration = try #require(deck.wave.latest).generation
    deck.wave.setTempo(480)  // dense ticks: many fires, control nets, section changes
    deck.setPlaying(true)
    deck.tap.acquire()
    rig.warm(300)
    rig.drain()
    var snap = MarkingSnapshot()
    #expect(deck.wave.readMarking(into: &snap))
    let seq0 = snap.header.sequence

    // A "standard" song reaches stop-transport after a while, which stops the deck and resets
    // its marking in place: part of what is measured. `play()` restarts it between stretches.
    // a project queued behind the playing one, taken over at a bar boundary inside the region
    deck.wave.load(second)
    deck.wave.setMute("kick", true)
    deck.wave.setMute("kick", false)
    rig.measure(300)  // the swap lands (and resets the tempo to the new project's own)
    deck.wave.setTempo(520)
    rig.measure(1500)
    rig.drain()
    deck.wave.play()
    // the whole performance surface
    deck.wave.setRoleMuted("bass", true)
    deck.wave.setRoleMuted("bass", false)
    deck.wave.activateSlot("melody-1")
    deck.wave.fire(.drop)
    deck.wave.fire(.beatRepeat)
    deck.wave.fire(.doubleDrop)
    deck.wave.fire(.halfTime)
    deck.wave.fire(.tapeStop)
    deck.wave.fireStinger("hit1")
    deck.wave.noteOn(60, velocity: 100)
    deck.wave.noteOn(64, velocity: 90)
    deck.wave.noteOff(60)
    deck.wave.allNotesOff()
    deck.wave.align(ticks: 3.4)
    deck.wave.align(ticks: -2.25)
    rig.measure(1000)
    rig.drain()
    deck.wave.play()
    deck.wave.panic()
    deck.wave.fire(.cut)
    deck.wave.noteOn(67, velocity: 80)
    deck.wave.load(third)
    rig.measure(300, size: 64)
    deck.wave.setTempo(480)
    rig.measure(1500, size: 64)
    rig.drain()
    deck.wave.play()
    // scratch: freeze, forward over ticks, back over them (un-firing), let go
    deck.freeze()
    deck.wave.scrub(ticks: 9)
    rig.measure(150)
    deck.wave.scrub(ticks: -14)
    rig.measure(150)
    deck.release()
    rig.measure(300, size: 512)
    deck.wave.pause()
    deck.wave.stop()  // resets the marking in place
    rig.measure(20)
    deck.wave.play()
    rig.measure(300, size: 1024)
    rig.drain()
    deck.wave.readMarking(into: &snap)

    #expect(
      rig.tally.allocs == 0,
      "renderBlock allocated \(rig.tally.allocs) times\(rig.tally.stackText)")
    #expect(
      rig.tally.frees == 0, "renderBlock freed \(rig.tally.frees) times\(rig.tally.stackText)")
    // and the plumbing really ran
    #expect(deck.tap.frames == deck.renderedFrames && deck.tap.frames > 600_000)
    #expect(
      rig.fires.count > 200 && rig.anchors.count > 200,
      "fires \(rig.fires.count) anchors \(rig.anchors.count) tick \(deck.wave.tick) playing \(deck.wave.isPlaying) ended \(deck.wave.hasEnded)"
    )
    let generations = Set(rig.fires.map(\.generation))
    #expect(generations.contains(firstGeneration) && generations.contains(second.generation))
    #expect(Set(rig.anchors.map(\.generation)).count >= 3, "the swaps happened in the region")
    #expect(rig.anchors.contains { $0.flags.contains(.swap) })
    #expect(rig.fires.contains { $0.flags.contains(.macro) }, "macros ran")
    #expect(rig.fires.contains { $0.flags.contains(.drum) })
    #expect(snap.header.sequence > 1 && snap.header.sequence != seq0)
    #expect(deck.wave.activeGeneration == third.generation)
    #expect(snap.generation == third.generation)
    deck.wave.drainRetired()
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aSampleDeckWithTapAndCounterDoesNotAllocate() throws {
    let rig = try Rig()
    let deck = rig.deck
    deck.loadDemo()
    deck.setPlaying(true)
    deck.tap.acquire()
    rig.warm(300)
    var framesBefore = deck.renderedFrames
    rig.measure(1500)
    #expect(deck.renderedFrames == framesBefore + 1500 * 128)
    deck.pitch = 0.05
    deck.nudge(0.02)
    rig.measure(300, size: 256)
    deck.setPlaying(false)
    rig.measure(100)
    deck.setPlaying(true)
    deck.freeze()
    deck.scrubBy(seconds: 0.4)
    rig.measure(150)
    deck.scrubBy(seconds: -0.9)
    rig.measure(150)
    deck.release()
    rig.measure(200, size: 2048)
    framesBefore = deck.renderedFrames
    rig.measure(10, size: 4096)
    #expect(deck.renderedFrames == framesBefore + 40_960)
    #expect(
      rig.tally.allocs == 0,
      "renderBlock allocated \(rig.tally.allocs) times\(rig.tally.stackText)")
    #expect(
      rig.tally.frees == 0, "renderBlock freed \(rig.tally.frees) times\(rig.tally.stackText)")
    #expect(deck.tap.frames == deck.renderedFrames && deck.tap.frames > 250_000)
    var buf = [Float](repeating: 0, count: 20_000)
    let got = buf.withUnsafeMutableBufferPointer {
      deck.tap.read(from: deck.tap.frames - 20_000, into: $0)
    }
    #expect(got.count == 20_000 && got.lost == 0)
    #expect(buf.contains { abs($0) > 0.01 }, "the tap carries the loop")
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func switchingTheTapOnAndOffAroundTheBlocksDoesNotAllocate() throws {
    let rig = try Rig()
    let deck = rig.deck
    deck.loadNet(project("techno", 42))
    deck.wave.setTempo(480)
    deck.setPlaying(true)
    rig.warm(200)
    // idle: nothing may reach the ring
    rig.measure(500)
    #expect(deck.tap.frames == 0)
    deck.tap.acquire()
    rig.measure(500)
    let first = deck.tap.frames
    #expect(first == 500 * 128 && deck.tap.originFrame == 700 * 128)
    deck.tap.release()
    rig.measure(400)
    #expect(deck.tap.frames == first, "released: untouched")
    // back after a gap shorter than the ring: filled in place with silence, in the first block
    deck.tap.acquire()
    rig.measure(300, size: 4096)
    #expect(deck.tap.gapFrames == 400 * 128)
    #expect(deck.tap.frames > first + 400 * 128)
    #expect(deck.tap.endFrame == deck.renderedFrames)
    deck.tap.release()
    // and after a gap longer than the whole ring: the ring just skips ahead
    rig.measure(700)
    deck.tap.acquire()
    rig.measure(300)
    #expect(deck.tap.gapFrames >= 700 * 128 + 400 * 128)
    #expect(deck.tap.endFrame == deck.renderedFrames)
    #expect(
      rig.tally.allocs == 0,
      "renderBlock allocated \(rig.tally.allocs) times\(rig.tally.stackText)")
    #expect(
      rig.tally.frees == 0, "renderBlock freed \(rig.tally.frees) times\(rig.tally.stackText)")
    deck.tap.release()
  }

  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aLongDenseRunThatOverflowsTheRingsStillDoesNotAllocate() throws {
    let rig = try Rig()
    let deck = rig.deck
    deck.loadNet(project("techno", 42))  // a loop: never reaches stop-transport
    deck.wave.setTempo(480)
    deck.setPlaying(true)
    deck.tap.acquire()
    rig.warm(200)
    rig.drain()
    rig.fires.removeAll()
    rig.anchors.removeAll()
    let firesBefore = deck.wave.fires.written
    // 100000 blocks of 128 frames at 48 kHz = 4.4 minutes: ~8500 ticks, with nobody reading
    rig.measure(100_000)
    #expect(
      rig.tally.allocs == 0,
      "renderBlock allocated \(rig.tally.allocs) times\(rig.tally.stackText)")
    #expect(
      rig.tally.frees == 0, "renderBlock freed \(rig.tally.frees) times\(rig.tally.stackText)")
    #expect(deck.wave.fires.written - firesBefore > deck.wave.fireCapacity, "the fire ring wrapped")
    #expect(deck.wave.anchors.written > deck.wave.anchorCapacity, "and so did the anchor ring")
    rig.drain()
    #expect(rig.fires.count == deck.wave.fireCapacity, "a late reader gets the newest ring-full")
    #expect(rig.anchors.count == deck.wave.anchorCapacity)
    #expect(rig.lost.fires > 0 && rig.lost.anchors > 0, "and is told it missed the rest")
    #expect(rig.lost.fires + rig.fires.count == deck.wave.fires.written - firesBefore)
    // what survived is the newest, still in order
    #expect(zip(rig.fires, rig.fires.dropFirst()).allSatisfy { $1.frame >= $0.frame })
    #expect(rig.anchors.last!.tick == Int32(deck.wave.tick))
    #expect(deck.tap.frames == deck.renderedFrames, "the tap overwrites and never drops")
    #expect(deck.wave.tick > 8000, "tick \(deck.wave.tick)")
    // and the rings go on taking events, for free
    rig.measure(300)
    #expect(deck.wave.fires.written > firesBefore + deck.wave.fireCapacity)
    #expect(rig.tally.allocs == 0 && rig.tally.frees == 0)
  }
}

struct EngineRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theWholeEngineWithEveryTapOnDoesNotAllocate() throws {
    // Not just the blocks: the real source-node closures, the frame clock node, the output
    // unit's render notification that feeds the master tap, and AVAudioEngine around them.
    let rate = 48_000.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    a.loadDemo()
    b.loadNet(project("techno", 42, "standard"))
    b.wave.setTempo(480)
    a.setPlaying(true)
    b.setPlaying(true)
    a.tap.acquire()
    b.tap.acquire()
    dj.masterTap.acquire()
    try dj.start()
    defer { dj.stop() }
    let buffer = makeEngineRenderBuffer(dj, frames: 4096)
    var cursor = b.wave.eventCursorNow()
    var fires: [FireEvent] = []
    var anchors: [TickAnchor] = []

    pullEngine(dj, buffer, cycles: 400, frames: 512)  // warm up: everything allocates once
    var tally = Tally()
    let frameBefore = dj.frame
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 1000, frames: 512) })
    // other cycle sizes, including one bigger than the tap's scratch chunk
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 30, frames: 4096) })
    tally.add(countAllocations { pullEngine(dj, buffer, cycles: 200, frames: 37) })
    #expect(tally.allocs == 0, "the engine's render path allocated \(tally.allocs) times")
    #expect(tally.frees == 0, "and freed \(tally.frees) times")

    // ...and all of it really ran
    #expect(dj.frame == frameBefore + 1000 * 512 + 30 * 4096 + 200 * 37)
    #expect(a.tap.endFrame == dj.frame && b.tap.endFrame == dj.frame)
    #expect(dj.masterTap.endFrame == dj.frame && dj.masterTap.gapFrames == 0)
    b.wave.readEvents(&cursor, fires: &fires, anchors: &anchors)
    #expect(
      fires.count > 100 && anchors.count > 100, "fires \(fires.count) anchors \(anchors.count)")
    var heard = [Float](repeating: 0, count: 8192)
    let got = heard.withUnsafeMutableBufferPointer {
      dj.masterTap.read(from: dj.masterTap.frames - 8192, into: $0)
    }
    #expect(got.count == 8192 && got.lost == 0)
    #expect(heard.contains { abs($0) > 0.01 }, "the master tap carries the mix")
  }
}

struct RunnerRingRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func aBareRunnerReportingIntoRingsDoesNotAllocate() {
    let sr = 48_000.0
    let runner = WaveRunner(sampleRate: sr)
    let fires = LatestRing<FireEvent>(capacity: 512)
    let anchors = LatestRing<TickAnchor>(capacity: 128)
    runner.fireRing = fires
    runner.anchorRing = anchors
    runner.load(project("techno", 42))
    runner.setTempo(480)
    runner.play()
    var l = [Float](repeating: 0, count: 128)
    var r = [Float](repeating: 0, count: 128)
    var frame = 0
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n {
            runner.process(lp.baseAddress!, rp.baseAddress!, frames: 128, startFrame: frame)
            frame += 128
          }
        }
      }
    }
    run(200)
    let firesBefore = fires.written
    let anchorsBefore = anchors.written
    let report = countAllocations { run(3000) }
    #expect(runner.graph!.tick > 100)
    #expect(report.allocations == 0 && report.frees == 0, "\(report)")
    #expect(fires.written - firesBefore > 512 && anchors.written - anchorsBefore > 128)
    #expect(runner.macroActive == false, "and the macro query is allocation-free too")
  }
}

struct RingRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func ringOperationsDoNotAllocate() {
    let spsc = SPSCRing<FireEvent>(capacity: 64)
    let latest = LatestRing<Float>(capacity: 4096)
    let tap = ScopeTap(capacity: 8192)
    let event = FireEvent(
      frame: 1, tick: 2, generation: 3, net: 4, transition: 5, note: 60, velocity: 100,
      channel: 1, durSteps: 2, durMs: 125, flags: [.drum])
    var batch = [FireEvent](repeating: event, count: 40)
    var out = [FireEvent](repeating: event, count: 9)
    let samples = [Float](repeating: 0.25, count: 3000)
    var readBack = [Float](repeating: 0, count: 5000)
    var popped = 0
    var read = 0
    let report = countAllocations {
      for i in 0..<200 {
        batch.withUnsafeBufferPointer { _ = spsc.push(contentsOf: $0) }  // overflows: drops
        spsc.push(event)
        popped += out.withUnsafeMutableBufferPointer { spsc.pop(into: $0) }
        _ = spsc.available + spsc.freeSlots + spsc.droppedCount
        if i % 7 == 0 { spsc.discardAll() }
        samples.withUnsafeBufferPointer { latest.write(contentsOf: $0) }
        latest.write(0.5)
        latest.write(repeating: 0, count: 100)
        read += readBack.withUnsafeMutableBufferPointer {
          latest.read(from: latest.written - 5000, into: $0).count
        }
        samples.withUnsafeBufferPointer { s in
          tap.push(left: s.baseAddress!, right: s.baseAddress!, frames: 3000, startFrame: i * 3000)
        }
        tap.push(
          left: samples.withUnsafeBufferPointer { $0.baseAddress! }, right: nil, frames: 10,
          startFrame: i * 3000 + 5000)
        samples.withUnsafeBufferPointer { s in  // interleaved stereo: the pair at channel 2 of 4
          tap.push(
            left: s.baseAddress! + 2, right: s.baseAddress! + 3, frames: 700,
            startFrame: i * 3000 + 5010, stride: 4)
        }
      }
    }
    #expect(report.allocations == 0 && report.frees == 0, "\(report)")
    #expect(popped > 0 && read > 0 && spsc.droppedCount > 0 && tap.frames > 0)
    _ = (batch.count, out.count)
    batch.removeAll()
  }
}
