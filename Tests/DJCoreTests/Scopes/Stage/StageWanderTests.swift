import Testing

@testable import DJCore

// The Wander walk on the stage: what the stage model reads off the decks into the context, and
// the layer model's flash and ticker.

@MainActor
struct StageWanderTests {
  static func move(_ step: Int, _ detail: String = "bass off") -> WanderMove {
    WanderMove(step: step, bar: (step + 1) * 16 - 1, kind: .role, detail: detail)
  }

  static func context(now: Double, epoch: Int = 0, _ decks: [StageWanderDeck]) -> StageContext {
    StageContext(
      width: 800, height: 600,
      layout: StagePanelLayout.layoutRing(width: 800, height: 600, count: 0), now: now,
      epoch: epoch, wander: decks)
  }

  static func deck(_ moves: [WanderMove]) -> StageWanderDeck { deck("A", moves) }

  static func deck(_ name: String, _ moves: [WanderMove]) -> StageWanderDeck {
    StageWanderDeck(
      deck: name, on: true, pace: 16, countdown: 4, barInPhrase: 11,
      step: (moves.last?.step ?? -1) + 1, moves: moves)
  }

  // MARK: the context value

  @Test func aDeckCarriesOnlyItsLastFourMoves() {
    let d = Self.deck((0..<9).map { Self.move($0) })
    #expect(d.moves.map(\.step) == [5, 6, 7, 8])
    #expect(d.phraseProgress == 11.0 / 16.0)
    #expect(StageWanderDeck(deck: "A", on: false).phraseProgress == nil)
  }

  @Test func aSyntheticContextHasNoWalks() {
    let c = StageContext(
      width: 1, height: 1, layout: StagePanelLayout.layoutRing(width: 1, height: 1, count: 0))
    #expect(c.wander.isEmpty)
  }

  // MARK: the layer model

  @Test func whatTheStageFindsIsNotNews() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 10, [Self.deck([Self.move(0), Self.move(1)])]))
    #expect(m.flash(deck: "A", now: 10) == 0 && m.rows(now: 10).isEmpty)
    #expect(m.deck("A")?.moves.count == 2)
  }

  @Test func aNewStepFlashesForTwoAndAHalfSeconds() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 10, [Self.deck([Self.move(0)])]))
    m.advance(Self.context(now: 11, [Self.deck([Self.move(0), Self.move(1, "drop")])]))
    #expect(m.flash(deck: "A", now: 11) == 1)
    #expect(stageNear(m.flash(deck: "A", now: 12.25), 0.5))
    #expect(m.flash(deck: "A", now: 13.5) == 0, "gone at 2.5 s")
    #expect(m.flash(deck: "A", now: 10.5) == 0, "a clock that stepped back shows nothing")
    #expect(m.activeFlashes(now: 12).map(\.move.detail) == ["drop"])
    #expect(m.flash(deck: "B", now: 11) == 0)
    // the same step again is not a new move
    m.advance(Self.context(now: 12, [Self.deck([Self.move(0), Self.move(1, "drop")])]))
    #expect(stageNear(m.flash(deck: "A", now: 12), 0.6))
    m.advance(Self.context(now: 14, [Self.deck([Self.move(0), Self.move(1, "drop")])]))
    #expect(m.flashes["A"] == nil, "an expired flash is dropped")
  }

  @Test func theTickerFadesAndKeepsFour() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 0, [Self.deck([])]))
    var moves: [WanderMove] = []
    for s in 0..<6 {
      moves.append(Self.move(s, "move \(s)"))
      m.advance(Self.context(now: Double(s), [Self.deck(moves)]))
    }
    let rows = m.rows(now: 5)
    #expect(rows.map(\.move.step) == [2, 3, 4, 5], "the last four, oldest first")
    #expect(rows.last?.alpha == 1)
    #expect(stageNear(rows[0].alpha, 1 - 3 / StageWanderModel.tickerSeconds))
    #expect(rows.last?.caption == "A · move 5")
    #expect(m.rows(now: 5 + StageWanderModel.tickerSeconds).isEmpty, "all faded out")
    m.advance(Self.context(now: 30, [Self.deck(moves)]))
    #expect(m.ticker.isEmpty, "the dead are dropped")
  }

  @Test func severalMovesInOneFrameAllReachTheTicker() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 0, [Self.deck([Self.move(0)])]))
    m.advance(
      Self.context(now: 1, [Self.deck([Self.move(0), Self.move(1), Self.move(2, "last")])]))
    #expect(m.rows(now: 1).map(\.move.step) == [1, 2])
    #expect(m.flashes["A"]?.move.detail == "last")
  }

  @Test func twoDecksFlashApart() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 0, [Self.deck("A", []), Self.deck("B", [])]))
    m.advance(Self.context(now: 1, [Self.deck("A", [Self.move(0)]), Self.deck("B", [])]))
    m.advance(
      Self.context(now: 2, [Self.deck("A", [Self.move(0)]), Self.deck("B", [Self.move(0)])]))
    #expect(m.flash(deck: "A", now: 2) < m.flash(deck: "B", now: 2))
    #expect(m.rows(now: 2).map(\.deck) == ["A", "B"])
  }

  @Test func aRebuildDoesNotResetIt() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 0, epoch: 1, [Self.deck([])]))
    m.advance(Self.context(now: 1, epoch: 1, [Self.deck([Self.move(0)])]))
    // the swap rebuilt the panels: the epoch moves, the flash and ticker stay
    m.advance(Self.context(now: 1.1, epoch: 2, [Self.deck([Self.move(0)])]))
    #expect(m.flash(deck: "A", now: 1.1) > 0.9 && m.rows(now: 1.1).count == 1)
    m.reset()
    #expect(m.flashes["A"] != nil && m.ticker.count == 1)
    let layers = StageLayerModels()
    #expect(layers.all.contains { $0 === layers.wander })
    #expect(!layers.clearedOnRebuild.contains { $0 === layers.wander })
  }

  @Test func aLogThatGoesBackwardsIsReRead() {
    let m = StageWanderModel()
    m.advance(Self.context(now: 0, [Self.deck([Self.move(4)])]))
    m.advance(Self.context(now: 1, [Self.deck([Self.move(4), Self.move(5)])]))
    m.advance(Self.context(now: 2, [Self.deck([Self.move(0)])]))
    #expect(m.flash(deck: "A", now: 2) == 0 && m.rows(now: 2).isEmpty)
    m.advance(Self.context(now: 3, [Self.deck([Self.move(0), Self.move(1)])]))
    #expect(m.flash(deck: "A", now: 3) == 1)
  }

  // MARK: against a live engine

  @Test func theStageModelReadsTheSourceDecksWalk() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.step()
    let off = try #require(h.ctx.wander.first)
    #expect(h.ctx.wander.map(\.deck) == ["A"])
    #expect(!off.on && off.countdown == nil && off.barInPhrase == nil && off.moves.isEmpty)

    h.deck.setWanderPace(4)
    h.deck.setWander(true)
    h.step()
    let on = try #require(h.ctx.wander.first)
    #expect(on.on && on.pace == 4 && on.countdown == h.deck.wanderCountdown)
    let bar = try #require(on.barInPhrase)
    #expect(bar == (h.deck.wave.tick / 16) % 4)
    #expect(on.phraseProgress == Double(bar) / 4)

    // a move lands: the context carries it and the layer flashes
    h.deck.takeWanderMove(bar: 3, lockedActions: h.rig.dj.lockedActions)
    h.step()
    let moved = try #require(h.ctx.wander.first)
    #expect(moved.moves.count == 1 && moved.step == 1)
    #expect(h.model.layers.wander.flash(deck: "A", now: h.ctx.now) == 1)
    #expect(h.model.layers.wander.rows(now: h.ctx.now).count == 1)

    h.deck.grabWander()
    h.step()
    let paused = try #require(h.ctx.wander.first)
    #expect(paused.paused && paused.barInPhrase.map { $0 < 4 } == true)
  }

  @Test func theMasterSourceReadsEveryDeck() throws {
    let h = try StageHarness(net: ["A", "B"], source: .master)
    defer { h.stop() }
    h.step()
    #expect(h.ctx.wander.map(\.deck) == ["A", "B"])
  }
}
