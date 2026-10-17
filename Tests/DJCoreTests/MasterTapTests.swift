import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["structure"] = .string("loop")
  return compose(genre: genre, overrides: .object(ov))
}

private let rate = 22_050.0

/// Two decks making sound: A plays the demo loop, B a generated net.
private func makeEngine(channels: Int = 2) throws -> DJEngine {
  let dj = try DJEngine(
    decks: ["A", "B"], offline: true, sampleRate: rate, outputChannels: channels)
  dj["A"]!.loadDemo()
  dj["B"]!.loadSynthNet(project("techno", 42))
  dj["B"]!.wave.setTempo(240)
  dj["A"]!.setPlaying(true)
  dj["B"]!.setPlaying(true)
  return dj
}

private func mono(_ c: [[Float]]) -> [Float] {
  zip(c[0], c[1]).map { ($0 + $1) * 0.5 }
}

/// The tap's samples for engine frames `lo..<hi` (as many as it has).
private func tapped(_ tap: ScopeTap, from lo: Int, to hi: Int) -> [Float] {
  var buf = [Float](repeating: .nan, count: max(0, hi - lo))
  let r = buf.withUnsafeMutableBufferPointer { tap.read(from: tap.sequence(ofFrame: lo), into: $0) }
  #expect(r.lost == 0, "the window was still in the ring")
  return Array(buf[0..<r.count])
}

/// Does the tap hold exactly `want` for engine frames `lo..<lo + want.count`?
private func tapMatches(_ tap: ScopeTap, from lo: Int, _ want: [Float]) -> Bool {
  let got = tapped(tap, from: lo, to: lo + want.count)
  return got.count == want.count && maxDiff(got, want[...]) == 0
}

private func maxDiff(_ a: [Float], _ b: ArraySlice<Float>) -> Float {
  precondition(a.count == b.count)
  var m: Float = 0
  for (x, y) in zip(a, b) { m = max(m, abs(x - y)) }
  return m
}

struct MasterTapTests {
  @Test func theTapCarriesThePostMasterSignalExactly() throws {
    let dj = try makeEngine()
    dj.master = 0.6
    dj.masterTap.acquire()
    defer { dj.masterTap.release() }
    try dj.start()
    defer { dj.stop() }
    let total = Int(rate) * 2
    let out = mono(try renderChannels(dj, frames: total))
    let tap = dj.masterTap
    #expect(tap.originFrame == 0, "the first buffer starts at the first frame rendered")
    #expect(tap.endFrame == total && tap.frames == total, "nothing is held back")
    #expect(tapMatches(tap, from: 0, out), "tap == (L+R)/2 of what the engine put out, exactly")
    #expect(out.contains { abs($0) > 0.05 })
    #expect(tap.gapFrames == 0)
  }

  @Test func masterVolumeShowsInTheTap() throws {
    // One deck, so the master tap is the deck's own tap times known gains: strip gain
    // (volume x trim x crossfader) x master volume. Nothing else touches the signal.
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let a = try #require(dj["A"])
    a.loadDemo()
    a.setPlaying(true)
    a.tap.acquire()
    dj.masterTap.acquire()
    defer {
      a.tap.release()
      dj.masterTap.release()
    }
    try dj.start()
    defer { dj.stop() }
    let second = Int(rate)
    let strip = Float(a.volume * a.trim * dj.crossfadeGain("A"))
    var from = 0
    for master: Float in [1, 0.25, 0.6] {
      dj.master = Double(master)
      _ = try renderOffline(dj, frames: 2 * second)
      let to = from + 2 * second
      // away from the switch: AVAudioMixerNode ramps a volume change over ~3000 frames
      let lo = from + 8192
      let hi = dj.masterTap.endFrame
      #expect(hi == to)
      let m = tapped(dj.masterTap, from: lo, to: hi)
      let d = tapped(a.tap, from: lo, to: hi)
      #expect(m.count == hi - lo && hi - lo > second)
      var checked = 0
      var worst: Float = 0
      for (x, y) in zip(m, d) where abs(y) > 0.05 {
        worst = max(worst, abs(x - y * strip * master))
        checked += 1
      }
      #expect(worst < 1e-5, "master \(master): tap = deck x strip x master (worst error \(worst))")
      #expect(checked > 1000, "enough loud samples to mean something")
      from = to
    }
  }

  @Test func aDeckClickIsAtTheSameFrameInTheMasterTap() throws {
    // A sample with one click in a second of silence. The deck tap says at which deck frame
    // the click is rendered; the master tap must show it at that same engine frame.
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let a = try #require(dj["A"])
    var pcm = [Float](repeating: 0, count: Int(rate) * 4)
    let clickAt = 6000
    for i in 0..<8 { pcm[clickAt + i] = 0.9 }
    a.load(SampleBuffer(left: pcm, sampleRate: rate), title: "click")
    a.setPlaying(true)
    a.tap.acquire()
    dj.masterTap.acquire()
    defer {
      a.tap.release()
      dj.masterTap.release()
    }
    try dj.start()
    defer { dj.stop() }
    let total = Int(rate) * 2  // the 64 K-sample rings still hold all of it
    _ = try renderOffline(dj, frames: total)
    func peakFrame(_ tap: ScopeTap) -> Int? {
      let s = tapped(tap, from: tap.originFrame, to: min(tap.endFrame, total))
      guard let (i, v) = s.enumerated().max(by: { abs($0.element) < abs($1.element) }), abs(v) > 0.1
      else { return nil }
      return tap.frame(ofSequence: i)
    }
    let deckFrame = try #require(peakFrame(a.tap))
    let masterFrame = try #require(peakFrame(dj.masterTap))
    #expect(deckFrame > 1000, "the platter had to spin up to the click")
    #expect(masterFrame == deckFrame, "no node between the source and the mixer delays anything")
  }

  @Test func aFireIsLocatedInTheMasterTapByItsDeckFrame() throws {
    // A net deck, silent until it is started. The first audible fire is stamped with the
    // deck frame its tick began on; the master tap must be silent up to the sample before
    // that frame and sounding on it: the deck time base reaches the master stream exactly.
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let deck = try #require(dj["A"])
    deck.loadSynthNet(project("techno", 42))
    deck.wave.setTempo(240)
    dj.masterTap.acquire()
    defer { dj.masterTap.release() }
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 8192)
    deck.setPlaying(true)
    let total = 8192 + Int(rate) * 2
    _ = try renderOffline(dj, frames: total - 8192)
    var events: [FireEvent] = []
    var cursor = 0
    deck.wave.fires.drain(from: &cursor, into: &events)
    let first = try #require(events.first)
    let f = Int(first.frame)
    #expect(f == 8192, "the play command lands at the next render cycle")
    let tap = dj.masterTap
    let before = tapped(tap, from: f - 512, to: f)
    let after = tapped(tap, from: f, to: f + 256)
    #expect(before.count == 512 && after.count == 256)
    #expect(before.allSatisfy { $0 == 0 }, "silent right up to the frame before the fire")
    // (a tonal voice's envelope rises from zero, so the first non-zero sample is a few in)
    let onset = try #require(after.firstIndex { $0 != 0 })
    // (and the net deck's peak limiter delays its output by its lookahead)
    let latency = deck.wave.limiter?.lookahead ?? 0
    #expect(
      onset < 16 + latency, "sounding within a few samples of the fire's own frame (onset \(onset))")
    #expect(after.contains { abs($0) > 0.01 })
    // every fire is followed by sound just after its frame (the tap is the post-master mix)
    let covered = events.filter { Int($0.frame) + 1024 <= tap.endFrame }
    #expect(covered.count > 20 && covered.count >= events.count - 8, "the tap has every fire")
    let silent = covered.filter { e in
      let w = tapped(tap, from: Int(e.frame), to: Int(e.frame) + 1024)
      return !w.contains { abs($0) > 1e-5 }
    }
    #expect(silent.isEmpty, "\(silent.count) fires with nothing in the master tap after them")
  }

  @Test func theMasterTapHasNoLatencyAfterAnyCycle() throws {
    let dj = try makeEngine()
    dj.masterTap.acquire()
    defer { dj.masterTap.release() }
    try dj.start()
    defer { dj.stop() }
    var total = 0
    for n in [512, 100, 4096, 1, 777, 2048, 33] {
      total += try renderOffline(dj, frames: n).count
      #expect(dj.masterTap.endFrame == total && dj.frame == total)
      #expect(dj["A"]!.renderedFrames == total && dj["B"]!.renderedFrames == total)
    }
    #expect(dj.masterTap.gapFrames == 0)
  }

  @Test func theTapIsFedByTheFirstSubscriberAndStopsWithTheLast() throws {
    let dj = try makeEngine()
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: Int(rate))
    #expect(dj.masterTap.frames == 0, "nothing flows while nobody is subscribed")
    dj.masterTap.acquire()  // subscribing to a running engine
    dj.masterTap.acquire()
    dj.masterTap.release()
    let first = dj.frame
    _ = try renderOffline(dj, frames: 5000)
    #expect(dj.masterTap.originFrame == first, "starts at the subscription, not before")
    #expect(dj.masterTap.frames == 5000, "one scope still looking")
    dj.masterTap.release()
    _ = try renderOffline(dj, frames: 5000)
    #expect(dj.masterTap.frames == 5000, "the last release switches it off")
  }

  @Test func theTapSurvivesAnEngineStopAndStart() throws {
    let dj = try makeEngine()
    dj.masterTap.acquire()
    defer { dj.masterTap.release() }
    try dj.start()
    var out = mono(try renderChannels(dj, frames: Int(rate) * 2))
    #expect(dj.masterTap.endFrame == out.count)
    dj.stop()
    try dj.start()
    defer { dj.stop() }
    out += mono(try renderChannels(dj, frames: Int(rate) * 2))
    let tap = dj.masterTap
    #expect(tap.endFrame == out.count && tap.gapFrames == 0, "data kept arriving after the restart")
    let tail = Array(out.suffix(60_000))
    #expect(tapMatches(tap, from: out.count - tail.count, tail), "before and after the restart")
  }

  @Test func theTapSurvivesCueRoutingBeingSwitchedOnAndOff() async throws {
    let dj = try makeEngine(channels: 4)
    dj.masterTap.acquire()  // subscribed before the main mixer's output is rewired
    defer { dj.masterTap.release() }
    try await dj.enableCueRouting()
    try dj.start()
    // the master pair is channels 0/1 of the routed output
    let routed = try renderChannels(dj, frames: Int(rate) * 2)
    #expect(routed.count == 4)
    let routedMaster = mono(Array(routed[0..<2]))
    let tap = dj.masterTap
    #expect(tap.endFrame == routedMaster.count)
    #expect(tapMatches(tap, from: 0, routedMaster), "the master pair")
    #expect(routedMaster.contains { abs($0) > 0.05 })

    // and back to the plain path
    dj.stop()
    try dj.disableCueRouting()
    try dj.start()
    defer { dj.stop() }
    let start = dj.frame
    let plain = try renderChannels(dj, frames: Int(rate) * 2)
    let plainMaster = mono(Array(plain[0..<2]))
    #expect(tap.endFrame == start + plainMaster.count && tap.gapFrames == 0)
    #expect(tapMatches(tap, from: start, plainMaster))
  }

  @Test func theTapFollowsTheMasterPairWhereverTheRouterPutsIt() async throws {
    let dj = try makeEngine(channels: 4)
    dj.masterTap.acquire()
    defer { dj.masterTap.release() }
    try await dj.enableCueRouting(channels: 4, masterPair: 2, cuePair: 0)
    try dj.start()
    defer { dj.stop() }
    let routed = try renderChannels(dj, frames: Int(rate))
    let onPair = mono(Array(routed[2..<4]))
    #expect(onPair.contains { abs($0) > 0.05 }, "the master is on channels 3/4 now")
    let cueIsMaster = routed[0] == routed[2]
    #expect(!cueIsMaster, "and channels 1/2 are not the master")
    #expect(tapMatches(dj.masterTap, from: 0, onPair))
  }

  @Test func resubscribingAfterAGapKeepsTheStampsTrue() throws {
    let dj = try makeEngine()
    try dj.start()
    defer { dj.stop() }
    let second = Int(rate)
    dj.masterTap.acquire()
    var out = mono(try renderChannels(dj, frames: second))
    dj.masterTap.release()
    out += mono(try renderChannels(dj, frames: second / 2))  // nobody listening
    dj.masterTap.acquire()
    defer { dj.masterTap.release() }
    out += mono(try renderChannels(dj, frames: second))
    let tap = dj.masterTap
    #expect(tap.endFrame == out.count && tap.gapFrames == second / 2)
    let after = second + second / 2  // where the second subscription began
    #expect(tapMatches(tap, from: after, Array(out[after...])))
    #expect(tapped(tap, from: second, to: after).allSatisfy { $0 == 0 }, "the gap is silence")
    #expect(tapMatches(tap, from: 0, Array(out[0..<second])))
  }

  @Test func theOutputLatencyIsZeroWhenRenderingOffline() throws {
    let dj = try makeEngine()
    #expect(dj.outputLatencyFrames == 0)
  }

  @Test func theTapIsWiredToTheOutputUnitFromTheStartAndStaysSo() async throws {
    let dj = try makeEngine(channels: 4)
    #expect(dj.masterTapAttached, "registered when the engine is built, before anyone looks")
    try await dj.enableCueRouting()
    try dj.start()
    dj.stop()
    try dj.disableCueRouting()
    try dj.start()
    dj.stop()
    #expect(dj.masterTapAttached, "and not touched by routing or restarts")
  }
}

struct MasterTapProbeTests {
  private func setUp(renderedSoFar: Int = 1000) -> (ScopeTap, FrameClock, MasterTapProbe) {
    let tap = ScopeTap()
    tap.acquire()
    let clock = FrameClock()
    clock.frames.store(renderedSoFar, ordering: .relaxed)
    return (tap, clock, MasterTapProbe(tap: tap, clock: clock))
  }

  private func read(_ tap: ScopeTap) -> [Float] {
    var out = [Float](repeating: .nan, count: 64)
    let r = out.withUnsafeMutableBufferPointer { tap.read(from: 0, into: $0) }
    return Array(out[0..<r.count])
  }

  private let four: [[Float]] = [[1, 2, 3], [5, 6, 7], [10, 20, 30], [30, 40, 50]]

  @Test func aCycleIsPlacedByTheClockAndMixedDownFromTheMasterPair() {
    let (tap, _, probe) = setUp()
    feedMasterProbe(probe, channels: four)
    #expect(tap.originFrame == 997, "the clock has counted the cycle: it began 3 frames ago")
    #expect(tap.endFrame == 1000)
    #expect(read(tap) == [3, 4, 5], "(L + R) / 2 of channels 0 and 1")
  }

  @Test func theMasterPairCanSitAnywhereInTheOutputChannels() {
    for interleaved in [false, true] {
      let (tap, clock, probe) = setUp(renderedSoFar: 3)
      probe.setMasterChannel(2)
      feedMasterProbe(probe, channels: four, interleaved: interleaved)
      #expect(read(tap) == [20, 30, 40], "channels 2 and 3 (interleaved: \(interleaved))")
      clock.frames.store(6, ordering: .relaxed)
      probe.setMasterChannel(3)  // the last channel has no partner: it is the mono signal
      feedMasterProbe(probe, channels: four, interleaved: interleaved)
      #expect(read(tap).suffix(3) == [30, 40, 50], "interleaved: \(interleaved)")
    }
  }

  @Test func aMonoOutputIsTheMonoSignal() {
    let (tap, _, probe) = setUp(renderedSoFar: 3)
    feedMasterProbe(probe, channels: [[0.5, 0.25, -1]])
    #expect(read(tap) == [0.5, 0.25, -1])
  }

  @Test func aMasterPairBeyondTheOutputsPushesNothingAndDoesNotCrash() {
    let (tap, _, probe) = setUp(renderedSoFar: 3)
    probe.setMasterChannel(9)
    feedMasterProbe(probe, channels: four)
    feedMasterProbe(probe, channels: four, interleaved: true)
    #expect(tap.frames == 0)
  }

  @Test func anUnsubscribedTapIsLeftAlone() {
    let (tap, _, probe) = setUp()
    tap.release()
    feedMasterProbe(probe, channels: four)
    #expect(tap.frames == 0)
  }
}

struct MasterTapChurnTests {
  @Test func subscribingWhileTheEngineRestartsIsSafeAndLeavesTheTapWorking() throws {
    let report = try churnMasterTap(restarts: 60)
    #expect(report.restarts == 60 && report.subscriptions > 0)
    #expect(report.subscribersAtEnd == 0, "every acquire was balanced")
    #expect(report.framesAtEnd >= 2048, "and the tap still gets the master")
  }
}
