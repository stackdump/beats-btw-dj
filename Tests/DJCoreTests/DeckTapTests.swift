import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["structure"] = .string("loop")
  return compose(genre: genre, overrides: .object(ov))
}

/// A deck in one of its two source modes, playing, on an engine that is never started: the
/// test calls `renderBlock` itself, as the audio thread would.
private func makeDeck(net: Bool, sampleRate: Double = 22_050) throws -> (DJEngine, Deck) {
  let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sampleRate)
  let deck = try #require(dj["A"])
  if net {
    deck.loadSynthNet(project("techno", 42))
    deck.wave.setTempo(300)
  } else {
    deck.loadDemo()
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

private let sizes = [128, 1000, 37, 4096, 128, 512, 1, 777]

struct DeckFrameCounterTests {
  @Test(arguments: [false, true])
  func everyRenderCallIsCountedInBothSourceModes(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    #expect(deck.renderedFrames == 0)
    var total = 0
    var last = 0
    for n in sizes {
      _ = render(deck, [n])
      total += n
      #expect(deck.renderedFrames == total)
      #expect(deck.renderedFrames > last, "monotonic")
      last = deck.renderedFrames
    }
    #expect(total == sizes.reduce(0, +))
  }

  @Test func theCountKeepsGoingWhenTheDeckSwitchesMode() throws {
    let (_, deck) = try makeDeck(net: false)
    _ = render(deck, [500])
    deck.loadSynthNet(project("house", 4))
    #expect(deck.mode == .net)
    _ = render(deck, [300])
    #expect(deck.renderedFrames == 800, "one counter across both sources")
    deck.load(DemoLoop.make(sampleRate: 22_050), title: "x")
    #expect(deck.mode == .sample)
    _ = render(deck, [200])
    #expect(deck.renderedFrames == 1000)
  }

  @Test func aStoppedDeckStillCounts() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let deck = try #require(dj["A"])
    _ = render(deck, [256, 256])  // nothing loaded, nothing playing
    #expect(deck.renderedFrames == 512)
  }

  @Test func everyDeckCountsTheSameFramesAsTheEngine() throws {
    // The deck's time base is the engine's: a source node is pulled once per render cycle
    // whatever the faders do, so the counters stay in step (this is what lets a tap stamped
    // in engine time line up with a deck's fire events).
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    a.loadDemo()
    b.loadSynthNet(project("techno", 42))
    a.setPlaying(true)
    b.setPlaying(true)
    a.volume = 0
    dj.crossfader = 0  // B is faded out completely, A's fader is down: nothing audible at all
    b.pfl = true
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 5000)
    a.volume = 0.8
    dj.crossfader = 1
    _ = try renderOffline(dj, frames: 7777)
    #expect(a.renderedFrames == dj.frame && b.renderedFrames == dj.frame)
    #expect(dj.frame == 5000 + 7777)
  }
}

struct DeckBlockEntryTests {
  @Test(arguments: [false, true])
  func theBufferListEntryRendersWhatRenderBlockDoes(net: Bool) throws {
    let (_, viaList) = try makeDeck(net: net)
    let (_, direct) = try makeDeck(net: net)
    for n in sizes {
      let got = renderThroughBufferList(viaList, frames: n)
      let want = render(direct, [n])[0]
      #expect(sameSamples(got.left, want.left) == .identical)
      #expect(sameSamples(got.right, want.right) == .identical)
    }
    #expect(viaList.renderedFrames == direct.renderedFrames)
  }

  @Test(arguments: [false, true])
  func aBufferListWithoutDataStillCountsItsFrames(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    deck.tap.acquire()
    _ = render(deck, [256])
    renderWithoutBuffers(deck, frames: 300)
    #expect(deck.renderedFrames == 556, "the engine pulled 300 frames: the deck's clock moves on")
    renderWithoutBuffers(deck, frames: 100, buffers: 0)
    #expect(deck.renderedFrames == 656)
    _ = render(deck, [128])
    #expect(deck.renderedFrames == 784)
    // the tap sees the hole as silence and stays in step with the deck's frame count
    #expect(deck.tap.frames == 256 + 400 + 128, "the hole is silence in the sequence numbers")
    #expect(deck.tap.gapFrames == 400)
    #expect(deck.tap.endFrame == deck.renderedFrames)
    #expect(deck.tap.frame(ofSequence: 256 + 400) == 656)
  }
}

struct DeckTapTests {
  @Test(arguments: [false, true])
  func nothingIsPushedUntilAScopeSubscribes(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    _ = render(deck, sizes)
    #expect(!deck.tap.isEnabled)
    #expect(deck.tap.frames == 0, "an idle tap costs one load and writes nothing")
  }

  @Test(arguments: [false, true])
  func theTapCarriesTheMonoMixdownOfTheDecksOutput(net: Bool) throws {
    let (_, deck) = try makeDeck(net: net)
    deck.tap.acquire()
    let blocks = render(deck, sizes)
    let want = blocks.flatMap { b in zip(b.left, b.right).map { ($0 + $1) * 0.5 } }
    let got = readAll(deck.tap)
    #expect(got.lost == 0)
    #expect(sameSamples(got.samples, want) == .identical)
    #expect(want.contains { abs($0) > 0.01 }, "the deck must actually be making sound")
    // the common time base: the tap's right edge is exactly what the deck has rendered
    #expect(deck.tap.endFrame == deck.renderedFrames)
    #expect(deck.tap.originFrame == 0)
  }

  @Test func aTapSubscribedMidStreamIsStampedInDeckFrames() throws {
    let (_, deck) = try makeDeck(net: true)
    _ = render(deck, [1000, 1000])
    deck.tap.acquire()
    let blocks = render(deck, [128, 128])
    #expect(deck.tap.originFrame == 2000)
    #expect(deck.tap.frames == 256)
    #expect(deck.tap.frame(ofSequence: 128) == 2128)
    #expect(deck.tap.endFrame == deck.renderedFrames && deck.renderedFrames == 2256)
    let want = blocks.flatMap { b in zip(b.left, b.right).map { ($0 + $1) * 0.5 } }
    #expect(sameSamples(readAll(deck.tap).samples, want) == .identical)
  }

  @Test func unsubscribingAndComingBackLeavesSilenceForTheGap() throws {
    let (_, deck) = try makeDeck(net: false)
    deck.tap.acquire()
    _ = render(deck, [200])
    deck.tap.release()
    _ = render(deck, [300])  // nobody listening
    deck.tap.acquire()
    _ = render(deck, [100])
    let got = readAll(deck.tap).samples
    #expect(got.count == 600)
    #expect(
      got[200..<500].allSatisfy { $0 == 0 }, "the stretch nobody listened to reads as silence")
    #expect(deck.tap.frame(ofSequence: 500) == 500, "and the stamps stay true")
    #expect(deck.tap.endFrame == deck.renderedFrames)
  }

  @Test(arguments: [false, true])
  func theTapIsPreFaderAndPreEQ(net: Bool) throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let deck = try #require(dj["A"])
    if net {
      deck.loadSynthNet(project("techno", 42))
      deck.wave.setTempo(300)
    } else {
      deck.loadDemo()
    }
    deck.setPlaying(true)
    deck.volume = 0  // the master hears nothing
    deck.eqLow = 0
    deck.eqMid = 0
    deck.eqHigh = 0
    deck.tap.acquire()
    try dj.start()
    defer { dj.stop() }
    let master = try renderOffline(dj, frames: 22_050)
    let tapped = readAll(deck.tap).samples
    #expect(tapped.count == 22_050)
    #expect(master.allSatisfy { abs($0) < 1e-6 }, "fader down: the master is silent")
    #expect(tapped.contains { abs($0) > 0.05 }, "but the tap hears the deck")
  }

  @Test(arguments: [false, true])
  func tapOnOrOffTheDecksOutputIsBitIdentical(net: Bool) throws {
    let (_, quiet) = try makeDeck(net: net)
    let (_, watched) = try makeDeck(net: net)
    watched.tap.acquire()
    let a = render(quiet, sizes + sizes)
    let b = render(watched, sizes + sizes)
    #expect(watched.tap.frames == sizes.reduce(0, +) * 2)
    for (x, y) in zip(a, b) {
      #expect(sameSamples(x.left, y.left) == .identical)
      #expect(sameSamples(x.right, y.right) == .identical)
    }
    #expect(a.contains { $0.left.contains { abs($0) > 0.01 } })
  }

  @Test(arguments: [false, true])
  func tapOnOrOffTheEnginesOutputIsBitIdentical(net: Bool) throws {
    func run(tapped: Bool) throws -> [Float] {
      let (dj, deck) = try makeDeck(net: net)
      if tapped { deck.tap.acquire() }
      try dj.start()
      defer { dj.stop() }
      return try renderOffline(dj, frames: 44_100)
    }
    let off = try run(tapped: false)
    let on = try run(tapped: true)
    #expect(off.count == 44_100)
    #expect(sameSamples(off, on) == .identical)
    #expect(off.contains { abs($0) > 0.01 })
  }
}
