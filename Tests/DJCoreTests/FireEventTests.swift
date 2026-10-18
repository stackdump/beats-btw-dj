import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double, _ structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

private let sr = 22_050.0

/// A standalone net source, loaded and (optionally) playing at a fixed tempo.
private func makeSource(
  _ p: Project, tempo: Double = 300, play: Bool = true, startTick: Int = 0, rate: Double = sr
) -> WaveDeckSource {
  let src = WaveDeckSource(sampleRate: rate)
  src.load(WaveRunner.prepare(p, sampleRate: rate, startTick: startTick))
  src.setTempo(tempo)
  if play { src.play() }
  return src
}

/// Render `blocks` blocks of `size` frames at deck frame `from`; returns the frame after.
@discardableResult
private func run(_ src: WaveDeckSource, from: Int, blocks: Int, size: Int = 128) -> Int {
  var l = [Float](repeating: 0, count: size)
  var r = [Float](repeating: 0, count: size)
  var frame = from
  for _ in 0..<blocks {
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        src.render(frames: size, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: frame)
      }
    }
    frame += size
  }
  return frame
}

/// One reader of a source's two event streams, with its own cursors: `fires()` and `anchors()`
/// return what is new since the previous call; `flush()` forgets what is queued.
private final class Tape {
  let src: WaveDeckSource
  private var fireCursor = 0
  private var anchorCursor = 0
  /// Records lost to overwriting, over the tape's life.
  private(set) var lost = 0

  init(_ src: WaveDeckSource, fromNow: Bool = false) {
    self.src = src
    if fromNow {
      let c = src.eventCursorNow()
      fireCursor = c.fires
      anchorCursor = c.anchors
    }
  }

  func fires() -> [FireEvent] {
    var out: [FireEvent] = []
    lost += src.fires.drain(from: &fireCursor, into: &out)
    return out
  }

  func anchors() -> [TickAnchor] {
    var out: [TickAnchor] = []
    lost += src.anchors.drain(from: &anchorCursor, into: &out)
    return out
  }

  func flush() {
    fireCursor = src.fires.written
    anchorCursor = src.anchors.written
  }
}

/// What the graph says is audible on each of the next `ticks` ticks, from a second copy of
/// the project advanced by hand: the oracle for the event stream.
private struct Hit: Equatable {
  var tick: Int
  var net: Int
  var transition: Int
  var note: Int
  var velocity: Int
  var channel: Int
  var durSteps: Float
  var durMs: Float
}

private func oracle(_ p: Project, ticks: Int, tempo: Double, muting: [String] = []) -> [Hit] {
  let prepared = WaveRunner.prepare(p, sampleRate: sr)
  let g = prepared.graph
  for id in muting { g.muted[g.byId[id]!] = 1 }
  var out: [Hit] = []
  for _ in 0..<ticks {
    g.advance { n, t in
      guard n.lane[t] >= 0 else { return }
      let b = n.bundle.bindings[n.transIds[t]]!
      let steps = n.durSteps[t]
      out.append(
        Hit(
          tick: g.tick, net: n.index, transition: t, note: n.note[t], velocity: n.vel[t],
          channel: b.channel != 0 ? b.channel : n.bundle.track.channel, durSteps: Float(steps),
          durMs: Float(steps > 0 ? steps * 60000 / (tempo * 4) : n.durMs[t])))
    }
  }
  return out
}

private func hits(_ events: [FireEvent]) -> [Hit] {
  events.map {
    Hit(
      tick: Int($0.tick), net: Int($0.net), transition: Int($0.transition), note: Int($0.note),
      velocity: Int($0.velocity), channel: Int($0.channel), durSteps: $0.durSteps, durMs: $0.durMs)
  }
}

/// Frames in one tick at `tempo`, as a double.
private func ticksPerFrame(_ tempo: Double) -> Double { sr * 60 / (tempo * 4) }

struct FireEventTests {
  @Test func theEventStreamIsExactlyTheAudibleHitsOfTheGraph() {
    let p = project("techno", 42)
    let src = makeSource(p)
    let tape = Tape(src)
    let end = run(src, from: 0, blocks: 1600)
    let got = tape.fires()
    let ticksRun = src.tick
    #expect(ticksRun > 100, "the run crosses plenty of ticks")
    let want = oracle(p, ticks: ticksRun, tempo: 300)
    #expect(hits(got) == want)
    #expect(want.count > 100)
    #expect(tape.lost == 0)
    #expect(end == 1600 * 128)
  }

  @Test func everyFieldComesFromTheBindingAndTheLane() {
    let p = project("techno", 42)
    let src = makeSource(p)
    let tape = Tape(src)
    run(src, from: 0, blocks: 400)
    let got = tape.fires()
    let project = try! #require(src.latest)
    let g = project.graph
    var drums = 0
    var tonal = 0
    for e in got {
      #expect(e.generation == project.generation)
      let n = g.nets[Int(e.net)]
      let t = Int(e.transition)
      #expect(n.midi[t] && n.lane[t] >= 0, "only transitions with a voice")
      #expect(e.note == Int16(n.note[t]) && Int(e.velocity) == n.vel[t])
      #expect((1...16).contains(Int(e.channel)))
      #expect(e.flags.contains(.drum) == isDrumChannel(Int(e.channel)))
      if e.flags.contains(.drum) { drums += 1 } else { tonal += 1 }
    }
    #expect(drums > 10 && tonal > 5, "both kinds of lane show up (\(drums) drums, \(tonal) tonal)")
  }

  @Test func eachFireIsStampedAtItsTicksAnchorAndTicksAreMonotonic() {
    let p = project("house", 7)
    let src = makeSource(p, tempo: 900)
    let tape = Tape(src)
    run(src, from: 0, blocks: 800)
    let a = tape.anchors()
    let f = tape.fires()
    #expect(a.count > 100 && f.count > 100)
    #expect(a.first?.frame == 0, "play lands the first tick on the first sample")
    // anchors: frames strictly increasing, ticks consecutive, spacing is the tempo's
    let per = ticksPerFrame(900)
    for (x, y) in zip(a, a.dropFirst()) {
      #expect(y.frame > x.frame && y.tick == x.tick + 1 && y.generation == x.generation)
      let gap = Double(y.frame - x.frame)
      #expect(gap == per.rounded(.down) || gap == per.rounded(.up), "gap \(gap) vs \(per)")
    }
    #expect(a.allSatisfy { $0.tempo == 900 })
    #expect(a[0].flags == .discontinuity, "the first anchor starts a run")
    #expect(a.dropFirst().allSatisfy { $0.flags.isEmpty }, "and the rest follow on from it")
    // no accumulated drift: the k-th tick is within a frame of k * per
    for x in a { #expect(abs(Double(x.frame) - Double(x.tick - 1) * per) < 1.5) }
    // every fire sits exactly on the anchor of its own tick
    let byTick = Dictionary(uniqueKeysWithValues: a.map { (Int($0.tick), $0.frame) })
    for e in f { #expect(byTick[Int(e.tick)] == e.frame) }
    // and the stream is ordered
    for (x, y) in zip(f, f.dropFirst()) { #expect(y.frame >= x.frame && y.tick >= x.tick) }
  }

  @Test func theStampsUseTheBlockStartFrameWhateverTheBlockSize() {
    let p = project("techno", 42)
    // the same song rendered in different block sizes puts every tick on the same frame
    var stamps: [[Int64]] = []
    for size in [32, 128, 509, 4096] {
      let src = makeSource(p)
      run(src, from: 10_000, blocks: 60_000 / size, size: size)
      stamps.append(Tape(src).anchors().prefix(40).map(\.frame))
    }
    #expect(stamps[0].count == 40)
    #expect(stamps.allSatisfy { $0 == stamps[0] })
    #expect(stamps[0].first == 10_000, "offset by the deck frame the block started at")
  }

  @Test func theTickStaysTheSameWhenPlayStartsMidStream() {
    let p = project("techno", 42)
    let src = makeSource(p, play: false)
    let tape = Tape(src)
    let at = run(src, from: 0, blocks: 7, size: 128)  // stopped: frames pass, nothing fires
    #expect(tape.anchors().isEmpty && tape.fires().isEmpty)
    src.play()
    run(src, from: at, blocks: 50)
    #expect(tape.anchors().first?.frame == Int64(at))
  }

  @Test func mutedNetsAndStoppedDecksMakeNoEvents() {
    let p = project("techno", 42)
    let src = makeSource(p, play: false)
    let tape = Tape(src)
    src.setMute("kick", true)
    src.play()
    run(src, from: 0, blocks: 400)
    let got = tape.fires()
    let kick = src.latest!.graph.byId["kick"]!
    #expect(!got.isEmpty && !got.contains { Int($0.net) == kick })
    #expect(hits(got) == oracle(p, ticks: src.tick, tempo: 300, muting: ["kick"]))
    // pause: the clock stops, so do the events
    src.pause()
    run(src, from: 400 * 128, blocks: 1)
    tape.flush()
    run(src, from: 401 * 128, blocks: 300)
    #expect(tape.fires().isEmpty && tape.anchors().isEmpty)
  }

  @Test func muteChangesTakeEffectOnTheNextTick() {
    let p = project("techno", 42)
    let src = makeSource(p)
    let tape = Tape(src)
    run(src, from: 0, blocks: 100)
    src.setRoleMuted("kick", true)
    run(src, from: 100 * 128, blocks: 1)  // the command lands at the top of this block
    tape.flush()
    run(src, from: 101 * 128, blocks: 300)
    let kick = src.latest!.graph.byId["kick"]!
    let got = tape.fires()
    #expect(!got.isEmpty && !got.contains { Int($0.net) == kick })
    src.setRoleMuted("kick", false)
    run(src, from: 401 * 128, blocks: 300)
    #expect(tape.fires().contains { Int($0.net) == kick })
  }

  @Test func silentReplaysMakeNoEvents() {
    let p = project("techno", 42, "standard")
    // a section launch rebuilds the marking by replaying 200 ticks: silent
    let src = makeSource(p, play: false, startTick: 200)
    let tape = Tape(src)
    run(src, from: 0, blocks: 20)
    #expect(tape.fires().isEmpty && tape.anchors().isEmpty, "the replay ran no events")
    src.play()
    run(src, from: 20 * 128, blocks: 200)
    let a = tape.anchors()
    #expect(a.first?.tick == 201, "the song resumes where the replay left it")
    #expect(tape.fires().allSatisfy { $0.tick >= 201 })

    // align() advances whole ticks silently: the ticks it skips have no events, and the
    // anchor after it says the numbering jumped
    let moved = makeSource(p)
    let mtape = Tape(moved)
    run(moved, from: 0, blocks: 60)
    _ = mtape.fires()
    let before = mtape.anchors()
    let lastTick = Int(before.last!.tick)
    moved.align(ticks: 5)
    run(moved, from: 60 * 128, blocks: 60)
    let after = mtape.anchors()
    let firstAfter = Int(after.first!.tick)
    #expect(firstAfter == lastTick + 6, "5 ticks were replayed silently, then the next one ran")
    #expect(after[0].flags.contains(.discontinuity), "and the anchor says the steps jumped")
    #expect(after.dropFirst().allSatisfy { $0.flags.isEmpty })
    let skipped = (lastTick + 1)...(lastTick + 5)
    #expect(!mtape.fires().contains { skipped.contains(Int($0.tick)) })
  }

  @Test func alignWithNegativeTicksHoldsTheClockBackAndIsFlagged() {
    let src = makeSource(project("techno", 42))
    let tape = Tape(src)
    var frame = run(src, from: 0, blocks: 60)
    let before = tape.anchors()
    src.align(ticks: -2.5)  // the next tick comes 2.5 ticks later
    frame = run(src, from: frame, blocks: 120)
    let after = tape.anchors()
    #expect(after[0].tick == before.last!.tick + 1, "no steps were skipped")
    #expect(after[0].flags.contains(.discontinuity), "but the spacing is no longer regular")
    let gap = Double(after[0].frame - before.last!.frame)
    #expect(gap > 3 * ticksPerFrame(300), "the late tick: \(gap) frames")
  }

  @Test func startingStoppingAndResumingTheClockAreDiscontinuities() {
    let src = makeSource(project("techno", 42))
    let tape = Tape(src)
    var frame = run(src, from: 0, blocks: 60)
    let first = tape.anchors()
    #expect(first[0].flags == .discontinuity && first.dropFirst().allSatisfy { $0.flags.isEmpty })
    // pause and resume: the tick numbers go on, the spacing does not
    src.pause()
    frame = run(src, from: frame, blocks: 30)
    #expect(tape.anchors().isEmpty)
    src.play()
    frame = run(src, from: frame, blocks: 60)
    let resumed = tape.anchors()
    #expect(resumed[0].tick == first.last!.tick + 1 && resumed[0].flags == .discontinuity)
    #expect(resumed.dropFirst().allSatisfy { $0.flags.isEmpty })
    // stop resets the song to the start: the numbering begins again, within the same project
    src.stop()
    frame = run(src, from: frame, blocks: 10)
    src.play()
    frame = run(src, from: frame, blocks: 60)
    let restarted = tape.anchors()
    #expect(restarted[0].tick == 1 && restarted[0].generation == first[0].generation)
    #expect(restarted[0].flags == .discontinuity)
  }

  @Test func aProjectLoadedOnAStoppedDeckIsAGenerationChangeWithoutASwap() {
    let src = makeSource(project("techno", 42))
    let tape = Tape(src)
    var frame = run(src, from: 0, blocks: 60)
    src.pause()
    frame = run(src, from: frame, blocks: 5)
    tape.flush()
    let next = WaveRunner.prepare(project("house", 4), sampleRate: sr)
    src.load(next)  // not playing: installed at once, no bar to wait for
    frame = run(src, from: frame, blocks: 5)
    src.play()
    frame = run(src, from: frame, blocks: 60)
    let a = tape.anchors()
    #expect(a.allSatisfy { $0.generation == next.generation })
    #expect(!a.contains { $0.flags.contains(.swap) }, "there was no bar boundary to swap at")
    #expect(a[0].flags == .discontinuity && a[0].tick == 1)
  }

  @Test func scratchingTheNetClockMakesNoEventsButTheClockResumesAfterward() {
    let p = project("techno", 42)
    let src = makeSource(p)
    let tape = Tape(src)
    var frame = run(src, from: 0, blocks: 100)
    tape.flush()
    let tickBefore = src.tick
    src.freeze()
    src.scrub(ticks: 12)
    src.send(.chase(seconds: 0.01))
    frame = run(src, from: frame, blocks: 150)
    #expect(src.tick > tickBefore + 6, "the scratch moved the net clock")
    #expect(tape.fires().isEmpty && tape.anchors().isEmpty, "scrubbed hits are not tick events")
    src.scrub(ticks: -20)  // backwards: un-firing
    frame = run(src, from: frame, blocks: 150)
    #expect(tape.fires().isEmpty && tape.anchors().isEmpty)
    let tickAtRelease = src.tick
    src.release()
    frame = run(src, from: frame, blocks: 200)
    let a = tape.anchors()
    #expect(!tape.fires().isEmpty && !a.isEmpty, "back on the tick clock")
    #expect(a[0].flags.contains(.discontinuity), "the tick jumped while the hand was on it")
    #expect(Int(a[0].tick) == tickAtRelease + 1 || Int(a[0].tick) == tickAtRelease)
    #expect(a.dropFirst().allSatisfy { $0.flags.isEmpty })
  }

  @Test func aProjectSwapIsAnAnchorWithANewGeneration() {
    let sr = sr
    let src = makeSource(project("techno", 42))
    let tape = Tape(src)
    run(src, from: 0, blocks: 50)
    let first = src.latest!
    let next = WaveRunner.prepare(project("house", 4), sampleRate: sr)
    src.load(next)
    #expect(next.generation > first.generation)
    run(src, from: 50 * 128, blocks: 600)
    let a = tape.anchors()
    let f = tape.fires()
    let swaps = a.filter { $0.flags.contains(.swap) }
    #expect(swaps.count == 1)
    let swap = swaps[0]
    #expect(
      swap.generation == next.generation && swap.tick == 0, "the new project's clock restarts")
    #expect(swap.flags == .swap, "time stays regular across a swap: it is not a discontinuity")
    let idx = a.firstIndex { $0.flags.contains(.swap) }!
    #expect(a[..<idx].allSatisfy { $0.generation == first.generation })
    #expect(a[(idx + 1)...].allSatisfy { $0.generation == next.generation })
    #expect(a[idx + 1].tick == 1)
    #expect(Int(a[idx - 1].tick + 1) % 16 == 0, "the swap lands on a bar boundary")
    // fires carry the generation of the project that fired them
    #expect(f.filter { $0.generation == first.generation }.allSatisfy { $0.frame < swap.frame })
    #expect(f.filter { $0.generation == next.generation }.allSatisfy { $0.frame > swap.frame })
    #expect(f.contains { $0.generation == next.generation })
  }

  @Test func macrosAndStingersAreFlagged() {
    let p = project("techno", 42, "standard")
    let src = makeSource(p)
    let tape = Tape(src)
    run(src, from: 0, blocks: 100)
    tape.flush()
    #expect(tape.fires().isEmpty)
    #expect(!src.isMacroActive)
    src.fire(.beatRepeat, ticks: 32)
    src.fireStinger("hit1", ticks: 32)
    var frame = run(src, from: 100 * 128, blocks: 150)
    #expect(src.isMacroActive, "the beat repeat is running")
    let during = tape.fires()
    #expect(!during.isEmpty)
    #expect(
      during.allSatisfy { $0.flags.contains(.macro) }, "beat repeat is running the whole time")
    let hit1 = src.latest!.graph.byId["hit1"]!
    let stingers = during.filter { $0.flags.contains(.stinger) }
    #expect(stingers.allSatisfy { Int($0.net) == hit1 })
    #expect(stingers.count == during.filter { Int($0.net) == hit1 }.count)
    frame = run(src, from: frame, blocks: 300)  // let both run out (32 ticks ~ 280 blocks)
    _ = tape.fires()
    frame = run(src, from: frame, blocks: 300)
    let after = tape.fires()
    #expect(!after.isEmpty)
    #expect(!after.contains { $0.flags.contains(.macro) || $0.flags.contains(.stinger) })
    #expect(!src.isMacroActive, "and it is over")
  }

  @Test func aReaderAlwaysHoldsTheAnchorOfEveryFireItHasRead() {
    // A reader on another thread polls while the source renders flat out at a tempo that
    // puts a tick every few blocks: the anchor is written before the tick's fires.
    let report = stressEventOrder(project: project("techno", 42), blocks: 1_000)
    #expect(report.lost == 0, "the rings were big enough for the reader to keep up")
    #expect(report.fires > 200 && report.anchors > 200 && report.polls > 50, "\(report)")
    #expect(
      report.fireWithoutAnchor == 0, "\(report.fireWithoutAnchor) fires read without their anchor")
  }

  @Test func aReaderThatSubscribesMidTickStillHoldsTheAnchorOfEveryFire() {
    // Feeds open and close all the time. One that opens while a tick is half written must
    // not be handed fires whose anchor is already behind its cursor.
    let report = stressEventOrder(
      project: project("techno", 42), blocks: 1_000, resubscribeEvery: 3)
    #expect(report.lost == 0)
    #expect(report.fires > 100 && report.polls > 100, "\(report)")
    #expect(report.fireWithoutAnchor == 0, "\(report.fireWithoutAnchor) fires without an anchor")
  }

  @Test func aMacroThatChangedNothingIsStillRunningForExactlyItsDuration() {
    // beats `markMacroRunning`: `el._runningMacro` is set for the macro's duration whatever the
    // macro did. Here every net a "solo drums" would mute is already muted, so it sets no restore
    // timer; the drums go on playing and their hits must carry the macro flag all the same.
    let src = makeSource(project("techno", 42, "standard"))
    let tape = Tape(src)
    for role in ["bass", "melody", "harmony", "arp"] { src.setRoleMuted(role, true) }
    var frame = run(src, from: 0, blocks: 60)
    tape.flush()
    frame = run(src, from: frame, blocks: 60)
    #expect(!tape.fires().isEmpty && !src.isMacroActive, "the drums play, no macro")
    let fired = src.tick  // the last tick before it: the macro covers the next 16
    src.fire(.soloDrums, ticks: 16)
    frame = run(src, from: frame, blocks: 1)
    #expect(src.latest!.graph.pendingMacroTimers == 0, "premise: nothing to mute, no timer")
    #expect(src.isMacroActive, "but a macro was fired")
    _ = tape.fires()
    frame = run(src, from: frame, blocks: 400)  // 16 ticks are ~140 blocks; this is ~46 ticks
    let after = tape.fires()
    #expect(!src.isMacroActive, "it ran out")
    let flagged = after.filter { $0.flags.contains(.macro) }
    let plain = after.filter { !$0.flags.contains(.macro) }
    #expect(flagged.count >= 6, "the drums' hits during it: \(flagged.count)")
    #expect(flagged.allSatisfy { Int($0.tick) > fired && Int($0.tick) <= fired + 16 })
    #expect(plain.allSatisfy { Int($0.tick) <= fired || Int($0.tick) > fired + 16 })
    #expect(plain.contains { Int($0.tick) > fired + 16 }, "and the drums go on after it")
  }

  @Test func everyMacroKindAndAStingerMarksItsDuration() {
    // The one entry point every kind goes through: fire each net macro on a quiet deck, and a
    // stinger on a net that does not exist (no restore timer either).
    for macro in NetMacro.allCases {
      let src = makeSource(project("techno", 42, "standard"))
      run(src, from: 0, blocks: 10)
      #expect(!src.isMacroActive)
      src.fire(macro, ticks: 4)
      run(src, from: 10 * 128, blocks: 2)
      #expect(src.isMacroActive, "\(macro) marks itself running")
      run(src, from: 12 * 128, blocks: 120)  // 4 ticks and a good margin
      #expect(!src.isMacroActive, "\(macro) is over")
    }
    let src = makeSource(project("techno", 42, "standard"))
    run(src, from: 0, blocks: 10)
    src.fireStinger("no-such-net", ticks: 4)
    run(src, from: 10 * 128, blocks: 2)
    #expect(src.isMacroActive, "a stinger marks itself running")
    run(src, from: 12 * 128, blocks: 120)
    #expect(!src.isMacroActive)
  }

  @Test func panicAndStopClearTheMarkedMacro() {
    let src = makeSource(project("techno", 42, "standard"))
    var frame = run(src, from: 0, blocks: 10)
    src.fireStinger("no-such-net", ticks: 64)
    frame = run(src, from: frame, blocks: 2)
    #expect(src.isMacroActive)
    src.panic()
    frame = run(src, from: frame, blocks: 2)
    #expect(!src.isMacroActive, "panic: beats effects.js sets _runningMacro back to null")
    src.fireStinger("no-such-net", ticks: 64)
    frame = run(src, from: frame, blocks: 2)
    #expect(src.isMacroActive)
    src.stop()
    frame = run(src, from: frame, blocks: 2)
    #expect(!src.isMacroActive)
  }

  @Test func theMacroFlagFollowsMuteTimersAndTempoEffects() {
    let src = makeSource(project("techno", 42, "standard"))
    var frame = run(src, from: 0, blocks: 50)
    #expect(!src.isMacroActive)
    src.fire(.cut, ticks: 8)  // mutes what is audible, restores it after 8 ticks
    frame = run(src, from: frame, blocks: 20)
    #expect(src.isMacroActive)
    frame = run(src, from: frame, blocks: 400)
    #expect(!src.isMacroActive)
    src.fire(.halfTime, ticks: 8)  // a tempo effect
    frame = run(src, from: frame, blocks: 20)
    #expect(src.isMacroActive)
    src.panic()
    frame = run(src, from: frame, blocks: 5)
    #expect(!src.isMacroActive, "panic cancels everything")
  }

  @Test func theDefaultRingsHoldSecondsOfTheDensestSong() {
    let src = WaveDeckSource(sampleRate: sr)
    #expect(src.fireCapacity >= 4096 && src.anchorCapacity >= 1024)
  }

  @Test func aReaderMoreThanARingBehindLosesTheOldestAndIsToldHowMany() {
    let p = project("techno", 42)
    let src = WaveDeckSource(sampleRate: 8000, fireCapacity: 100, anchorCapacity: 50)
    src.load(WaveRunner.prepare(p, sampleRate: 8000))
    src.setTempo(3000)  // 40 frames a tick
    src.play()
    let tape = Tape(src)
    run(src, from: 0, blocks: 300, size: 128)  // nobody reads
    #expect(src.fires.written > src.fireCapacity && src.anchors.written > src.anchorCapacity)
    #expect(src.fireCapacity == 128 && src.anchorCapacity == 64, "rounded up to powers of two")
    let kept = tape.fires()
    let keptAnchors = tape.anchors()
    #expect(kept.count == 128 && keptAnchors.count == 64)
    #expect(tape.lost == src.fires.written - 128 + src.anchors.written - 64)
    // what is kept is the newest, in order and gap-free (anchors are one per tick)
    #expect(keptAnchors.last!.tick == Int32(src.tick))
    #expect(zip(keptAnchors, keptAnchors.dropFirst()).allSatisfy { $1.tick == $0.tick + 1 })
    #expect(zip(kept, kept.dropFirst()).allSatisfy { $1.frame >= $0.frame })
    let want = oracle(p, ticks: Int(kept.last!.tick), tempo: 3000)
    #expect(hits(kept) == want.suffix(128).map { $0 }, "the tail of the song")
    // the reader is up to date now; the ring goes on taking events
    run(src, from: 300 * 128, blocks: 5, size: 128)
    #expect(!tape.fires().isEmpty)
  }

  @Test func readersAreIndependentAndAFreshOneStartsWhereYouSay() {
    let src = makeSource(project("techno", 42))
    let early = Tape(src)
    run(src, from: 0, blocks: 100)
    let late = Tape(src, fromNow: true)  // subscribes now: sees no fires of the past
    let newestAnchor = late.anchors()
    #expect(late.fires().isEmpty && newestAnchor.count == 1, "but starts from the latest anchor")
    #expect(newestAnchor[0].tick == Int32(src.tick), "which is the clock as it stands")
    let fromStart = early.fires()
    run(src, from: 100 * 128, blocks: 100)
    let newer = late.fires()
    let newest = early.fires()
    #expect(!fromStart.isEmpty && !newer.isEmpty)
    #expect(newer.map(\.frame) == newest.map(\.frame), "the same events, each reader its own")
    // a cursor from `eventCursorNow` is the same as a reader that started then
    var cursor = src.eventCursorNow()
    run(src, from: 200 * 128, blocks: 100)
    var f: [FireEvent] = []
    var a: [TickAnchor] = []
    let lost = src.readEvents(&cursor, fires: &f, anchors: &a)
    #expect(lost.firesLost == 0 && lost.anchorsLost == 0)
    #expect(f.map(\.frame) == late.fires().map(\.frame))
    #expect(cursor.fires == src.eventCursorNow().fires, "a second read finds nothing new")
    var again: [FireEvent] = []
    var againAnchors: [TickAnchor] = []
    src.readEvents(&cursor, fires: &again, anchors: &againAnchors)
    #expect(again.isEmpty && againAnchors.isEmpty)
    #expect(a.count == Int(src.tick) - Int(a.first!.tick) + 1, "an anchor for every tick")
  }

  @Test func audioIsUnchangedByReporting() {
    // The deck source (rings wired) against a bare runner (rings nil): sample-identical.
    let p = project("techno", 42)
    let runner = WaveRunner(sampleRate: sr)
    runner.load(p)
    runner.setTempo(300)
    runner.play()
    #expect(runner.fireRing == nil && runner.anchorRing == nil)
    let src = makeSource(p, play: false)
    src.play()
    var want: [Float] = []
    var got: [Float] = []
    var l = [Float](repeating: 0, count: 128)
    var l2 = [Float](repeating: 0, count: 128)
    for b in 0..<500 {
      l.withUnsafeMutableBufferPointer { runner.process($0.baseAddress!, nil, frames: 128) }
      want += l
      l2.withUnsafeMutableBufferPointer {
        src.render(frames: 128, left: $0.baseAddress!, right: nil, startFrame: b * 128)
      }
      got += l2
    }
    #expect(sameSamples(got, want) == .identical)
    #expect(got.contains { $0 != 0 })
  }
}

struct DeckFireTests {
  @Test func aDeckStampsFiresInItsRenderedFrames() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sr)
    let deck = try #require(dj["A"])
    deck.loadSynthNet(project("techno", 42))
    deck.wave.setTempo(300)
    let tape = Tape(deck.wave)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 5000)  // stopped: frames pass
    #expect(deck.renderedFrames == 5000)
    deck.setPlaying(true)
    _ = try renderOffline(dj, frames: 44_100)
    let a = tape.anchors()
    #expect(a.count > 20)
    // the play command is applied at the top of the next render cycle (4096 frames each here)
    #expect(a[0].frame >= 5000 && a[0].frame < 5000 + 4096)
    #expect(Int(a[0].frame) == 5000, "offline cycles are 4096 frames: play lands at the next one")
    #expect(a.allSatisfy { $0.frame < Int64(deck.renderedFrames) })
    let f = tape.fires()
    #expect(f.allSatisfy { $0.frame < Int64(deck.renderedFrames) })
    #expect(!f.isEmpty && f[0].frame == a[0].frame, "the first tick fires on the first sample")
  }

  @Test func aDeckThatLeavesNetModeStopsFeedingTheNetMirrorsSoReadersGateOnItsMode() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sr)
    let deck = try #require(dj["A"])
    deck.loadSynthNet(project("techno", 42))
    deck.wave.setTempo(300)
    deck.setPlaying(true)
    let tape = Tape(deck.wave)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 22_050)
    #expect(deck.mode == .net && deck.wave.isPlaying && deck.wave.tick > 5)
    tape.flush()
    let tick = deck.wave.tick
    deck.loadDemo()  // back to a sample: the wave source is no longer rendered
    #expect(deck.mode == .sample)
    _ = try renderOffline(dj, frames: 22_050)
    #expect(deck.renderedFrames == 44_100, "the deck's time base goes on")
    #expect(tape.fires().isEmpty && tape.anchors().isEmpty && deck.wave.tick == tick)
    #expect(deck.wave.isPlaying, "the mirror still says what it last saw: gate on Deck.mode")
  }

  @Test func aSampleDeckProducesNoNetEventsButKeepsCounting() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sr)
    let deck = try #require(dj["A"])
    deck.loadDemo()
    deck.setPlaying(true)
    let tape = Tape(deck.wave)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 10_000)
    #expect(deck.renderedFrames == 10_000)
    #expect(tape.fires().isEmpty && tape.anchors().isEmpty)
  }
}
