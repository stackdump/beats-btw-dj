import Testing

@testable import DJCore

// The LEFT-channel taps (`Deck.leftTap`, `DJEngine.masterLeftTap`) and the feed's lease on them
// (`ScopeFeed.setLeftChannelWanted`): what the stage's corona reads, because Tone's Analyser is
// `Gain -> ChannelSplitter(1) -> AnalyserNode` and so hears channel 0 only (AnalyserFFT header).
// Same contract as the mono taps: off until subscribed, bit-identical audio either way, the
// engine's frame time base.

private let rate = 22_050.0

private func project(_ genre: String, _ seed: Double) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["structure"] = .string("loop")
  return compose(genre: genre, overrides: .object(ov))
}

/// A deck in one of its two source modes, playing, on an engine that is never started.
private func makeDeck(net: Bool) throws -> (DJEngine, Deck) {
  let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
  let deck = try #require(dj["A"])
  if net {
    deck.loadSynthNet(project("techno", 42))
    deck.wave.setTempo(300)
  } else {
    deck.loadDemo()  // panned parts: left and right differ
  }
  deck.setPlaying(true)
  return (dj, deck)
}

private struct Block {
  var left: [Float]
  var right: [Float]
}

private func render(_ deck: Deck, _ sizes: [Int]) -> [Block] {
  sizes.map { n in
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        deck.renderBlock(frames: n, left: lp.baseAddress!, right: rp.baseAddress!)
      }
    }
    return Block(left: l, right: r)
  }
}

private func readAll(_ tap: ScopeTap, from: Int = 0) -> (samples: [Float], lost: Int) {
  var buf = [Float](repeating: .nan, count: tap.ring.capacity)
  let r = buf.withUnsafeMutableBufferPointer { tap.read(from: from, into: $0) }
  return (Array(buf[0..<r.count]), r.lost)
}

private let sizes = [128, 1000, 37, 512, 1, 777, 128]  // 2683 frames: fits the 8 K ring

struct DeckLeftTapTests {
  @Test(arguments: [false, true])
  func nothingIsPushedUntilASubscriberAsks(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    deck.tap.acquire()  // the mono tap being on does not switch the left one on
    _ = render(deck, sizes)
    #expect(!deck.leftTap.isEnabled)
    #expect(deck.leftTap.frames == 0, "an idle tap costs one load and writes nothing")
    #expect(deck.tap.frames == sizes.reduce(0, +))
  }

  @Test(arguments: [false, true])
  func theLeftTapCarriesTheLeftChannelAlone(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    deck.leftTap.acquire()
    // (the demo loop spins up from rest: render past its first notes so the pan shows)
    let blocks = render(deck, net ? sizes : sizes + [4096])
    let got = readAll(deck.leftTap)
    #expect(got.lost == 0)
    #expect(got.samples == blocks.flatMap(\.left), "exactly the left buffer, sample for sample")
    #expect(got.samples.contains { abs($0) > 0.01 }, "the deck must actually be making sound")
    #expect(deck.leftTap.endFrame == deck.renderedFrames && deck.leftTap.originFrame == 0)
    if !net {
      // the demo loop is panned: the down-mix is NOT the left channel (the point of this tap)
      let mono = blocks.flatMap { b in zip(b.left, b.right).map { ($0 + $1) * 0.5 } }
      #expect(zip(got.samples, mono).contains { abs($0 - $1) > 0.01 })
    } else {
      #expect(blocks.allSatisfy { $0.left == $0.right }, "the wave engine is dual-mono")
    }
  }

  @Test(arguments: [false, true])
  func bothTapsOnAtOnceEachCarryTheirOwnSignal(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    deck.tap.acquire()
    deck.leftTap.acquire()
    let blocks = render(deck, sizes)
    let left = blocks.flatMap(\.left)
    let mono = blocks.flatMap { b in zip(b.left, b.right).map { ($0 + $1) * 0.5 } }
    #expect(readAll(deck.leftTap).samples == left)
    #expect(readAll(deck.tap).samples == mono)
  }

  @Test func aSubscriptionMidStreamIsStampedInDeckFrames() throws {
    let (_, deck) = try makeDeck(net: true)
    _ = render(deck, [1000, 1000])
    deck.leftTap.acquire()
    let blocks = render(deck, [128, 128])
    #expect(deck.leftTap.originFrame == 2000 && deck.leftTap.frames == 256)
    #expect(deck.leftTap.endFrame == deck.renderedFrames)
    #expect(readAll(deck.leftTap).samples == blocks.flatMap(\.left))
  }

  @Test func theGapWhileUnsubscribedReadsAsSilenceAndStaysStamped() throws {
    let (_, deck) = try makeDeck(net: false)
    deck.leftTap.acquire()
    _ = render(deck, [200])
    deck.leftTap.release()
    _ = render(deck, [300])
    deck.leftTap.acquire()
    _ = render(deck, [100])
    let got = readAll(deck.leftTap).samples
    #expect(got.count == 600 && got[200..<500].allSatisfy { $0 == 0 })
    #expect(deck.leftTap.endFrame == deck.renderedFrames)
  }

  @Test func aDeckWithOnlyOneChannelBufferIsItsOwnLeft() throws {
    let (_, deck) = try makeDeck(net: true)
    deck.leftTap.acquire()
    var l = [Float](repeating: 0, count: 256)
    l.withUnsafeMutableBufferPointer {
      deck.renderBlock(frames: 256, left: $0.baseAddress!, right: nil)
    }
    #expect(readAll(deck.leftTap).samples == l)
  }

  @Test(arguments: [false, true])
  func theLeftTapOnOrOffLeavesTheDecksOutputBitIdentical(net: Bool) throws {
    let (_, quiet) = try makeDeck(net: net)
    let (_, watched) = try makeDeck(net: net)
    watched.leftTap.acquire()
    let a = render(quiet, sizes + sizes)
    let b = render(watched, sizes + sizes)
    for (x, y) in zip(a, b) { #expect(x.left == y.left && x.right == y.right) }
    #expect(a.contains { $0.left.contains { abs($0) > 0.01 } })
  }

  @Test(arguments: [false, true])
  func theLeftTapOnOrOffLeavesTheEnginesOutputBitIdentical(net: Bool) throws {
    func run(tapped: Bool) throws -> [Float] {
      let (dj, deck) = try makeDeck(net: net)
      if tapped { deck.leftTap.acquire() }
      try dj.start()
      defer { dj.stop() }
      return try renderOffline(dj, frames: 44_100)
    }
    let off = try run(tapped: false)
    let on = try run(tapped: true)
    #expect(off.count == 44_100 && off == on)
    #expect(off.contains { abs($0) > 0.01 })
  }
}

struct MasterLeftTapTests {
  private func setUp(renderedSoFar: Int = 1000) -> (ScopeTap, ScopeTap, FrameClock, MasterTapProbe)
  {
    let mono = ScopeTap()
    let left = ScopeTap(capacity: ScopeTap.leftCapacity)
    left.acquire()
    let clock = FrameClock()
    clock.frames.store(renderedSoFar, ordering: .relaxed)
    return (mono, left, clock, MasterTapProbe(tap: mono, leftTap: left, clock: clock))
  }

  private let four: [[Float]] = [[1, 2, 3], [5, 6, 7], [10, 20, 30], [30, 40, 50]]

  @Test func aCycleGivesTheLeftOfTheMasterPairWithoutTheMonoTapOn() {
    let (mono, left, _, probe) = setUp()
    feedMasterProbe(probe, channels: four)
    #expect(readAll(left).samples == [1, 2, 3], "channel 0 alone, not the down-mix [3, 4, 5]")
    #expect(left.originFrame == 997 && left.endFrame == 1000, "stamped like the mono tap")
    #expect(mono.frames == 0, "the mono tap was not asked for")
  }

  @Test func bothTapsFromOneNotification() {
    let (mono, left, _, probe) = setUp()
    mono.acquire()
    feedMasterProbe(probe, channels: four)
    #expect(readAll(mono).samples == [3, 4, 5] && readAll(left).samples == [1, 2, 3])
    #expect(mono.originFrame == left.originFrame && mono.endFrame == left.endFrame)
  }

  @Test func theMasterPairCanSitAnywhereInterleavedOrNot() {
    for interleaved in [false, true] {
      let (_, left, clock, probe) = setUp(renderedSoFar: 3)
      probe.setMasterChannel(2)
      feedMasterProbe(probe, channels: four, interleaved: interleaved)
      #expect(readAll(left).samples == [10, 20, 30], "interleaved: \(interleaved)")
      clock.frames.store(6, ordering: .relaxed)
      probe.setMasterChannel(3)  // the last channel has no partner: it is its own left
      feedMasterProbe(probe, channels: four, interleaved: interleaved)
      #expect(readAll(left).samples.suffix(3) == [30, 40, 50], "interleaved: \(interleaved)")
    }
  }

  @Test func aMasterPairBeyondTheOutputsAndAnUnsubscribedTapPushNothing() {
    let (_, left, _, probe) = setUp(renderedSoFar: 3)
    probe.setMasterChannel(9)
    feedMasterProbe(probe, channels: four)
    feedMasterProbe(probe, channels: four, interleaved: true)
    #expect(left.frames == 0)
    probe.setMasterChannel(0)
    left.release()
    feedMasterProbe(probe, channels: four)
    #expect(left.frames == 0)
  }

  @Test func theEnginesMasterLeftTapIsTheLeftChannelOfWhatItPutsOutExactly() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadDemo()
    dj["B"]!.loadSynthNet(project("techno", 42))
    dj["B"]!.wave.setTempo(240)
    dj["A"]!.setPlaying(true)
    dj["B"]!.setPlaying(true)
    dj.master = 0.6
    dj.masterTap.acquire()
    dj.masterLeftTap.acquire()
    try dj.start()
    defer { dj.stop() }
    let total = Int(rate)  // one second: the 8 K ring keeps only the last 8192 of it
    let out = try renderChannels(dj, frames: total)
    let left = dj.masterLeftTap
    #expect(left.endFrame == total && left.endFrame == dj.frame && left.gapFrames == 0)
    let got = readAll(left, from: left.frames - 8192)
    #expect(got.lost == 0 && got.samples == Array(out[0].suffix(8192)))
    #expect(out[0] != out[1], "the demo loop is panned: L and R really differ")
    let mono = readAll(dj.masterTap, from: dj.masterTap.frames - 8192).samples
    #expect(mono == zip(out[0], out[1]).suffix(8192).map { ($0 + $1) * 0.5 })
    #expect(mono != got.samples, "the two taps carry different signals")
  }

  @Test func theMasterLeftTapOnOrOffLeavesTheEnginesOutputBitIdentical() throws {
    func run(tapped: Bool) throws -> [[Float]] {
      let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
      dj["A"]!.loadDemo()
      dj["A"]!.setPlaying(true)
      if tapped { dj.masterLeftTap.acquire() }
      try dj.start()
      defer { dj.stop() }
      return try renderChannels(dj, frames: 30_000)
    }
    let off = try run(tapped: false)
    let on = try run(tapped: true)
    #expect(off == on && off[0].contains { abs($0) > 0.01 })
  }
}
