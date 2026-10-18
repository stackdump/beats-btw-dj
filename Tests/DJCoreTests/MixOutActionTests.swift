import Testing

@testable import DJCore

// `DeckAction.mixOut` / `.mixIn` (ROADMAP 6.2, performable form): the deck control over the
// runner's mix-out tail (MixOutTailTests) and a mix-in rest. A deck on an engine that is never
// started, driven block by block (`renderBlock`), playing `tailProject()` (eight bars: four of
// verse, four of outro; the melody on channel 1 hits every bar's first step) at 120 BPM and
// 48 kHz: a step is 6000 frames.

private let sr = 48_000.0
private let step = 6000
private let block = 256

/// A playing deck on `tailProject()`, replaying inline (`deterministic`, as a session replay).
private func playingDeck() throws -> (DJEngine, Deck) {
  let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sr)
  dj.deterministic = true
  let deck = try #require(dj["A"])
  deck.loadNet(tailProject(), title: "tail")
  deck.setPlaying(true)
  return (dj, deck)
}

/// What a deck did while rendering: its audio, its fires and tick anchors, and the block in
/// which it stopped (frames), if it did.
private struct Take {
  var out: [Float] = []
  var fires: [FireEvent] = []
  var anchors: [TickAnchor] = []
  var stop: Range<Int>?
}

/// Render until `until` says so (or `maxBlocks`), reading the deck's events after each block.
private func render(
  _ deck: Deck, into take: inout Take, cursor: inout WaveDeckSource.EventCursor,
  maxBlocks: Int, until: (Deck, Take) -> Bool = { _, _ in false }
) {
  var l = [Float](repeating: 0, count: block)
  for _ in 0..<maxBlocks {
    let off = take.out.count
    l.withUnsafeMutableBufferPointer {
      deck.renderBlock(frames: block, left: $0.baseAddress!, right: nil)
    }
    take.out += l
    deck.wave.readEvents(&cursor, fires: &take.fires, anchors: &take.anchors)
    if take.stop == nil && deck.wave.hasEnded { take.stop = off..<(off + block) }
    if until(deck, take) { return }
  }
}

/// The step a fire played (its tick is the graph's tick after the step).
private func playedStep(_ f: FireEvent) -> Int { Int(f.tick) - 1 }

struct MixOutActionTests {
  /// Both actions encode with their op and bars and decode back; without bars they take the
  /// defaults (16 bars out, 4 in).
  @Test func theActionsRoundTripThroughJSON() throws {
    for a in [DeckAction.mixOut(deck: "A", bars: 8), .mixIn(deck: "B", bars: 2)] {
      #expect(DeckAction(json: a.json) == a)
      let text = a.json.canonicalJS
      #expect(DeckAction(json: try JSONValue.parse(text)) == a)
    }
    #expect(DeckAction.mixOut(deck: "A", bars: 8).json["op"]?.string == "mixOut")
    #expect(DeckAction.mixIn(deck: "A", bars: 2).json["bars"]?.int == 2)
    #expect(
      DeckAction(json: try JSONValue.parse(#"{"op":"mixOut","deck":"A"}"#))
        == .mixOut(deck: "A", bars: MixOutTail.defaultBars))
    #expect(
      DeckAction(json: try JSONValue.parse(#"{"op":"mixIn","deck":"A"}"#))
        == .mixIn(deck: "A", bars: DeckAction.defaultMixInBars))
    #expect(MixOutTail.defaultBars == 16 && DeckAction.defaultMixInBars == 4)
    #expect(DeckAction.jsonOps.contains("mixOut") && DeckAction.jsonOps.contains("mixIn"))
    // as a session event too
    let e = SessionEvent(frame: 960, kind: .action(.mixOut(deck: "A", bars: 16)))
    #expect(SessionEvent(json: e.json) == e)
  }

  /// A mix-in's rest is the tail's mask, from its bar line for its bars.
  @Test func aMixInRestsWhatATailRests() {
    let r = RestSchedule.mixIn(fromTick: 32, bars: 2)
    #expect(r == RestSchedule.Entry(from: 32, to: 64, mask: MixOutTail.restMask))
    #expect(MixOutTail.restMask == .melodic && MixOutTail(fromTick: 0).entry.mask == r.mask)
    let s = RestSchedule.empty.with(rest: r)
    #expect(s.mask(at: 31).isEmpty && s.mask(at: 32) == .melodic && s.mask(at: 64).isEmpty)
  }

  /// Mix out in the verse: at the next bar the deck jumps to the outro, plays it (and on past
  /// the song's end) drums-forward, and stops 16 bars after the jump: its last step is the
  /// tail's last, and the deck is silent once the room has rung out.
  @Test func silenceLandsSixteenBarsAfterTheJump() throws {
    let (dj, deck) = try playingDeck()
    var take = Take()
    var cursor = deck.wave.eventCursorNow()
    render(deck, into: &take, cursor: &cursor, maxBlocks: 2_000) { d, _ in d.wave.tick >= 20 }
    #expect(deck.wave.tick >= 20 && deck.wave.tick < 31, "in the verse's second bar")
    let before = deck.wave.activeGeneration
    dj.perform(.mixOut(deck: "A", bars: 16))
    let tail = try #require(deck.wave.latest?.tail)
    #expect(tail == MixOutTail(fromTick: 64, bars: 16), "from the outro")
    render(deck, into: &take, cursor: &cursor, maxBlocks: 9_000) { d, t in
      d.wave.hasEnded && t.out.count > (t.stop?.upperBound ?? 0) + 2 * Int(sr)
    }
    let stop = try #require(take.stop)
    let tailed = take.anchors.filter { $0.generation != before }
    #expect(deck.isMixingOut || deck.wave.hasEnded)
    // the outro's first step, then every step of the 16 bars, and no more
    let first = try #require(tailed.first { $0.tick == Int32(tail.fromTick + 1) })
    let last = try #require(tailed.map(\.tick).max())
    #expect(Int(last) == tail.endTick, "the last step played is the tail's last")
    let silence = Int(first.frame) + 16 * 16 * step
    #expect(
      stop.contains(silence) || abs(stop.lowerBound - silence) <= block,
      "stopped in \(stop); 16 bars after the jump is frame \(silence)")
    // only the drums-forward lanes in the tail: no melody fire from the outro on
    let melody = take.fires.filter { $0.generation != before && $0.channel == 1 }
    #expect(melody.allSatisfy { playedStep($0) < tail.fromTick })
    #expect(take.fires.contains { $0.generation != before && $0.channel == 10 })
    // silent once the voices and the room have died away
    let quiet = silence + Int(1.5 * sr)
    #expect(rmsDB(take.out[quiet..<min(take.out.count, quiet + Int(sr) / 2)]) < -80)
  }

  /// Mix out already in the outro holds where it is: the tail starts on the next bar line.
  @Test func aMixOutInTheOutroPlaysOnFromTheNextBar() throws {
    let (dj, deck) = try playingDeck()
    var take = Take()
    var cursor = deck.wave.eventCursorNow()
    render(deck, into: &take, cursor: &cursor, maxBlocks: 9_000) { d, _ in d.wave.tick >= 70 }
    dj.perform(.mixOut(deck: "A", bars: 2))
    #expect(deck.wave.latest?.tail == MixOutTail(fromTick: 80, bars: 2))
  }

  /// Mix in for 2 bars in the verse's second bar: the melody rests from the next bar line (32)
  /// and its first note after the action lands exactly 2 bars after it (step 64); the drums
  /// play throughout. Without the action the melody plays on those bar lines.
  @Test func theFirstMelodicNoteLandsNBarsAfterTheActionBar() throws {
    let (dj, deck) = try playingDeck()
    var take = Take()
    var cursor = deck.wave.eventCursorNow()
    render(deck, into: &take, cursor: &cursor, maxBlocks: 2_000) { d, _ in d.wave.tick >= 20 }
    let before = deck.wave.activeGeneration
    let actionBar = 32
    dj.perform(.mixIn(deck: "A", bars: 2))
    #expect(deck.isMixingIn)
    #expect(deck.wave.latest?.rests.mask(at: actionBar) == MixOutTail.restMask)
    render(deck, into: &take, cursor: &cursor, maxBlocks: 9_000) { d, _ in d.wave.tick >= 90 }
    let after = take.fires.filter { $0.generation != before }
    let melody = after.filter { $0.channel == 1 }.map(playedStep).sorted()
    let firstMelodic = try #require(melody.first { $0 >= actionBar })
    #expect(firstMelodic == actionBar + 2 * 16, "the first melodic note is 2 bars after the bar")
    #expect(!melody.contains { $0 >= actionBar && $0 < actionBar + 32 })
    let drums = after.filter { $0.channel == 10 }.map(playedStep)
    #expect(drums.contains(actionBar) && drums.contains(actionBar + 16), "drums play through")
    #expect(!deck.isMixingIn, "over")
    // the reference: the same song without the action hits those bar lines
    let (_, ref) = try playingDeck()
    var refTake = Take()
    var refCursor = ref.wave.eventCursorNow()
    render(ref, into: &refTake, cursor: &refCursor, maxBlocks: 9_000) { d, _ in d.wave.tick >= 90 }
    let refMelody = refTake.fires.filter { $0.channel == 1 }.map(playedStep)
    #expect(refMelody.contains(actionBar) && refMelody.contains(actionBar + 16))
  }

  /// A sample deck has no net to mix: both are no-ops (nil).
  @Test func aSampleDeckIgnoresThem() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sr)
    let deck = try #require(dj["A"])
    deck.loadDemo()
    #expect(deck.mixOut() == nil && deck.mixIn(bars: 2) == nil)
    #expect(!deck.isMixingOut && !deck.isMixingIn)
  }
}

/// A recorded set with a mix-in and a mix-out: each is one recorded action (the relocations
/// they make are not), and the replay is the live set to the byte.
struct MixOutSessionTests {
  private static let rate = 22_050.0

  private static func perform(blocks: Int) throws -> (Session, RenderedAudio) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: rate,
        opts: dj["A"]!.waveOptions))
    dj["B"]!.loadDemo()
    try dj.start()
    defer { dj.stop() }
    let router = ControllerRouter(engine: dj)
    let recorder = try SessionRecorder.start(on: dj)
    let conductor = OfflineConductor(engine: dj, router: router)
    var l: [Float] = []
    var r: [Float] = []
    for b in 0..<blocks {
      let (bl, br) = try conductor.step {
        switch b {
        case 0: dj.perform(.play(deck: "A", on: true))
        case 10: dj.perform(.mixIn(deck: "A", bars: 1))
        case 400: dj.perform(.mixOut(deck: "A", bars: 1))
        default: break
        }
      }
      l += bl
      r += br
    }
    return (recorder.finish(), RenderedAudio(sampleRate: rate, left: l, right: r))
  }

  @Test func aSetWithAMixOutReplaysToTheByte() throws {
    let (session, live) = try Self.perform(blocks: 1_400)
    let actions = session.events.compactMap { e -> DeckAction? in
      if case .action(let a) = e.kind { return a }
      return nil
    }
    #expect(
      actions == [
        .play(deck: "A", on: true), .mixIn(deck: "A", bars: 1), .mixOut(deck: "A", bars: 1),
      ], "one recorded action each, nothing for the relocations")
    let a = try SessionPlayer(session: session).render()
    let b = try SessionPlayer(session: session).render()
    #expect(a.left == live.left && a.right == live.right, "the replay is the live set")
    #expect(a.left == b.left && a.right == b.right, "two renders, same bytes")
    // the JSON round-trips with the actions in it
    #expect(try Session.decode(session.canonical, cid: session.cid) == session)
  }
}
