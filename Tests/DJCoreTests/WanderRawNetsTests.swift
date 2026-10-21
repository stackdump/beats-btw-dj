import Testing

@testable import DJCore

private let rate = 22_050.0

/// A raw-nets deck (a composed roll) has no `TrackSpec`, but it wanders on the moves that need
/// none, seeded from its own share CID.
@MainActor
struct WanderRawNetsTests {
  static let roll = """
    {"name":"Wander Roll","tempo":128,"steps":128,"parts":{
      "kick":{"every":16,"until":128,"notes":[[0],[4],[8],[12]]},
      "snare":{"every":16,"until":128,"notes":[[4],[12]]},
      "hihat":{"every":16,"until":128,"notes":[[2,46],[6,46],[10,46],[14,46]]},
      "bass":{"every":16,"until":128,"notes":[[2,45,2],[6,45,2],[10,45,2],[14,45,2]]},
      "melody":{"every":64,"until":128,"notes":[[0,72,4],[8,76,4],[16,79,8],[32,74,8]]},
      "harmony":{"every":32,"until":128,"notes":[[0,57,16],[0,60,16],[0,64,16]]}}}
    """

  func rawDeck(_ roll: String = roll) throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    let d = dj["A"]!
    let env = try PianoRoll.envelope(JSONValue.parse(roll))
    let track = try #require(
      PreparedTrack(source: .rawNets(payload: env), sampleRate: rate, opts: d.waveOptions))
    d.loadNet(track)
    dj["B"]!.loadDemo()
    try dj.start()
    return (dj, d)
  }

  /// Walk `bars` bars at pace 4: one move per phrase, on its last bar.
  func walk(_ d: Deck, bars: Int) {
    d.setWander(true)
    d.setWanderPace(4)
    for bar in 0..<bars { d.advanceWander(toBar: bar, lockedActions: []) }
  }

  @Test func aRawDeckHasAWalkToTake() throws {
    let (dj, d) = try rawDeck()
    defer { dj.stop() }
    #expect(d.currentSpec == nil && d.currentRawNets != nil)
    d.setWander(true)
    #expect(d.wanderIdleReason(lockedActions: []) == nil)
    #expect(d.wanderCountdown != nil)
  }

  @Test func itTakesOnlyTheMovesThatNeedNoSeedAndRecordsNoSpec() throws {
    let (dj, d) = try rawDeck()
    defer { dj.stop() }
    walk(d, bars: 80)  // 20 phrases
    #expect(d.wander.step == 20 && d.wander.log.count == 20)
    for m in d.wander.log {
      #expect(Wander.rawKinds.contains(m.kind), "\(m.kind): \(m.detail)")
      #expect(m.spec == nil && m.cid == nil)
    }
    // the mix did something: parts came and went, macros and FX fired
    let kinds = Set(d.wander.log.map(\.kind))
    #expect(kinds.contains(.role) && kinds.count >= 3, "\(kinds)")
  }

  @Test func theSamePayloadWalksTheSamePathAndAnotherDoesNot() throws {
    let (dj1, a) = try rawDeck()
    let (dj2, b) = try rawDeck()
    let (dj3, c) = try rawDeck(
      Self.roll.replacingOccurrences(of: "\"tempo\":128", with: "\"tempo\":130"))
    defer {
      dj1.stop()
      dj2.stop()
      dj3.stop()
    }
    walk(a, bars: 80)
    walk(b, bars: 80)
    walk(c, bars: 80)
    #expect(a.wander.log.map(\.detail) == b.wander.log.map(\.detail))
    #expect(a.wander.log.map(\.detail) != c.wander.log.map(\.detail))
  }

  @Test func locksStillHoldAndEveryMoveLockedSaysSo() throws {
    let (dj, d) = try rawDeck()
    defer { dj.stop() }
    d.setWander(true)
    for lock in ["arrangement", "fx", "palette"] { d.setWanderLock(lock, true) }
    #expect(d.wanderIdleReason(lockedActions: []) == "every move is locked: nothing left to change")
    // arrangement and palette stay locked, fx freed: only macros, FX and stingers remain
    d.setWanderLock("fx", false)
    walk(d, bars: 60)
    #expect(!d.wander.log.isEmpty)
    #expect(d.wander.log.allSatisfy { [.macro, .fx, .stinger].contains($0.kind) })
  }

  @Test func theWalkIsPureOverThePlannerToo() throws {
    let (dj, d) = try rawDeck()
    defer { dj.stop() }
    let c = try #require(d.wanderContext(lockedActions: []))
    #expect(c.isRaw && c.rawBase != nil)
    var kinds: Set<WanderMoveKind> = []
    for step in 0..<400 {
      if let p = Wander.plan(c, step: step) { kinds.insert(p.kind) }
    }
    #expect(kinds.isSubset(of: Wander.rawKinds) && kinds.contains(.role))
    #expect(!kinds.contains(.seed) && !kinds.contains(.genre) && !kinds.contains(.structure))
  }
}
