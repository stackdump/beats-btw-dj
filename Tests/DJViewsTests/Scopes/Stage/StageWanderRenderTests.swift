import SwiftUI
import Testing

@testable import DJCore
@testable import DJViews

private typealias Sw = StageSwatch

/// The wander layer (StageWanderLayer): the phrase arc, the move flash, the ticker, and nothing
/// at all with the ∿ button off.
@MainActor
struct StageWanderRenderTests {
  static func move(_ step: Int, _ detail: String) -> WanderMove {
    WanderMove(step: step, bar: (step + 1) * 8 - 1, kind: .role, detail: detail)
  }

  /// The rig's last context (real panels and ring) with `wander` in place of the engine's.
  func context(
    _ rig: StageViewRig, wander: [StageWanderDeck], now: Double? = nil, showWander: Bool = true,
    vizLevel: Int = 0
  ) -> StageContext {
    var ctx = rig.model.context
    ctx.wander = wander
    ctx.showWander = showWander
    ctx.vizLevel = vizLevel
    if let now { ctx.now = now }
    return ctx
  }

  /// The layer alone over the stage background.
  func layerPixels(_ ctx: StageContext, _ model: StageWanderModel) throws -> Pixels {
    let view = ZStack {
      StagePalette.background.color
      StageWanderLayer(context: ctx, model: model)
    }
    return try #require(renderPixels(view, width: Int(ctx.width), height: Int(ctx.height)))
  }

  func lit(_ px: Pixels, _ x: Int, _ y: Int) -> Bool {
    let c = px.color(x, y)
    return abs(c.r - Sw.background.0) + abs(c.g - Sw.background.1) + abs(c.b - Sw.background.2)
      > 90
  }

  /// A point on the deck's arc circle, `degrees` clockwise from 12 o'clock.
  func onArc(_ ctx: StageContext, index: Int = 0, degrees: Double) -> (Int, Int) {
    let r = StageWanderPainter.arcRadius(ctx, index: index)
    let t = degrees * .pi / 180
    let c = ctx.ringCenter
    return (Int((c.x + r * sin(t)).rounded()), Int((c.y - r * cos(t)).rounded()))
  }

  func litNear(_ px: Pixels, _ p: (Int, Int)) -> Bool {
    for dx in -1...1 { for dy in -1...1 where lit(px, p.0 + dx, p.1 + dy) { return true } }
    return false
  }

  // MARK: the arc

  @Test func theArcCoversBarInPhraseOverPaceAndNoMore() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    // bar 2 of an 8-bar phrase: a quarter of the circle, 12 o'clock to 3 o'clock
    let deck = StageWanderDeck(deck: "A", on: true, pace: 8, countdown: 6, barInPhrase: 2)
    #expect(deck.phraseProgress == 0.25)
    let ctx = context(rig, wander: [deck])
    let px = try layerPixels(ctx, StageWanderModel())
    savePNG(
      ZStack {
        StagePalette.background.color
        StageWanderLayer(context: ctx, model: StageWanderModel())
      }, width: Int(ctx.width), height: Int(ctx.height), name: "stage-wander-arc")
    for deg in [8.0, 30, 45, 60, 82] {
      #expect(litNear(px, onArc(ctx, degrees: deg)), "on the arc at \(deg)°")
    }
    for deg in [98.0, 135, 180, 225, 270, 315, 352] {
      #expect(!litNear(px, onArc(ctx, degrees: deg)), "past the phrase at \(deg)°")
    }
    // in the deck's tint (DJStyle.deckA, orange): red well above blue at the arc's middle
    let mid = onArc(ctx, degrees: 45)
    let c = px.color(mid.0, mid.1)
    #expect(c.r > 150 && c.r > c.b + 80, "deck A's tint: \(c)")

    // bar 0 draws nothing; a deck that is not wandering draws nothing
    for quiet in [
      StageWanderDeck(deck: "A", on: true, pace: 8, countdown: 8, barInPhrase: 0),
      StageWanderDeck(deck: "A", on: false, pace: 8),
    ] {
      let none = try layerPixels(context(rig, wander: [quiet]), StageWanderModel())
      let blank = none.count(inX: 0..<none.width, y: 0..<none.height) { r, g, b in
        abs(r - 10) + abs(g - 10) + abs(b - 26) > 30
      }
      #expect(blank == 0, "nothing drawn for \(quiet)")
    }
  }

  @Test func aPausedWalksArcIsDashed() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    // half the phrase, playing then paused
    func samples(paused: Bool) throws -> (lit: Int, dark: Int) {
      let deck = StageWanderDeck(
        deck: "A", on: true, paused: paused, pace: 8, countdown: 4, barInPhrase: 4)
      let ctx = context(rig, wander: [deck])
      let px = try layerPixels(ctx, StageWanderModel())
      var n = (lit: 0, dark: 0)
      for deg in stride(from: 4.0, through: 176, by: 1) {
        let p = onArc(ctx, degrees: deg)
        if lit(px, p.0, p.1) { n.lit += 1 } else { n.dark += 1 }
      }
      return n
    }
    let solid = try samples(paused: false)
    let dashed = try samples(paused: true)
    #expect(solid.dark <= 4, "a playing walk's arc is solid: \(solid)")
    #expect(dashed.dark > 30 && dashed.lit > 30, "a paused walk's arc is dashed: \(dashed)")
  }

  @Test func twoDecksGetTwoArcsInTheirOwnTints() throws {
    let rig = try StageViewRig(source: .master)
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let ctx = context(
      rig,
      wander: [
        StageWanderDeck(deck: "A", on: true, pace: 4, countdown: 2, barInPhrase: 2),
        StageWanderDeck(deck: "B", on: true, pace: 4, countdown: 2, barInPhrase: 2),
      ])
    #expect(
      StageWanderPainter.arcRadius(ctx, index: 1) > StageWanderPainter.arcRadius(ctx, index: 0))
    let px = try layerPixels(ctx, StageWanderModel())
    let a = onArc(ctx, index: 0, degrees: 90)
    let b = onArc(ctx, index: 1, degrees: 90)
    let ca = px.color(a.0, a.1)
    let cb = px.color(b.0, b.1)
    #expect(ca.r > ca.b + 60, "A is orange: \(ca)")
    #expect(cb.b > cb.r + 60, "B is blue: \(cb)")
  }

  // MARK: the flash

  /// Lit pixels in the caption band at the top centre.
  func captionPixels(_ px: Pixels) -> Int {
    let cx = px.width / 2
    let y = Int(StageWanderPainter.captionTop)
    return px.count(inX: (cx - 200)..<(cx + 200), y: (y - 12)..<(y + 12)) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 60
    }
  }

  @Test func aNewMoveFlashesItsCaptionAndItIsGoneThreeSecondsLater() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let model = StageWanderModel()
    let before = StageWanderDeck(
      deck: "A", on: true, pace: 8, countdown: 7, barInPhrase: 1, step: 1,
      moves: [Self.move(0, "bass off")])
    let after = StageWanderDeck(
      deck: "A", on: true, pace: 8, countdown: 8, barInPhrase: 0, step: 2,
      moves: [Self.move(0, "bass off"), Self.move(1, "seed 41 → 44")])

    // what the deck had done before the stage saw it is not news
    let first = context(rig, wander: [before], now: 100)
    model.advance(first)
    #expect(captionPixels(try layerPixels(first, model)) == 0)

    // a move: its caption shows
    let moved = context(rig, wander: [after], now: 101)
    model.advance(moved)
    let flashing = try layerPixels(moved, model)
    savePNG(
      ZStack {
        StagePalette.background.color
        StageWanderLayer(context: moved, model: model)
      }, width: Int(moved.width), height: Int(moved.height), name: "stage-wander-flash")
    #expect(captionPixels(flashing) > 60, "caption during the flash: \(captionPixels(flashing))")

    // halfway it is fainter
    let half = context(rig, wander: [after], now: 101 + StageWanderModel.flashSeconds / 2)
    model.advance(half)
    let fading = try layerPixels(half, model)
    let cx = fading.width / 2
    let y = Int(StageWanderPainter.captionTop)
    func peak(_ px: Pixels) -> Int {
      var m = 0
      for x in (cx - 200)..<(cx + 200) {
        for yy in (y - 12)..<(y + 12) { m = max(m, px.color(x, yy).r) }
      }
      return m
    }
    #expect(peak(fading) < peak(flashing), "fading: \(peak(fading)) < \(peak(flashing))")

    // three seconds after the move: gone
    let later = context(rig, wander: [after], now: 104)
    model.advance(later)
    #expect(captionPixels(try layerPixels(later, model)) == 0, "the caption is gone 3 s later")
  }

  // MARK: the ticker

  /// Lit pixels in the ticker's corner at the bottom left.
  func tickerPixels(_ px: Pixels) -> Int {
    px.count(inX: 0..<300, y: (px.height - 90)..<px.height) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 40
    }
  }

  @Test func theTickerTrailsTheMovesAtTheBottomLeftAndIsSkippedAtLowVisualLevels() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let model = StageWanderModel()
    model.advance(
      context(rig, wander: [StageWanderDeck(deck: "A", on: true, step: 0)], now: 10))
    let moves = (0..<5).map { Self.move($0, "move \($0)") }
    let deck = StageWanderDeck(
      deck: "A", on: true, pace: 8, countdown: 8, barInPhrase: 0, step: 5, moves: moves)
    let full = context(rig, wander: [deck], now: 11)
    model.advance(full)
    #expect(model.rows(now: 11).count == StageWanderModel.tickerLimit)
    let shown = try layerPixels(full, model)
    #expect(tickerPixels(shown) > 80, "the ticker is drawn: \(tickerPixels(shown))")
    // its rows stack up from the bottom edge, newest at the bottom
    let rows = model.rows(now: 11).count
    let lastRow = StageWanderPainter.tickerOrigin(full, index: rows - 1, count: rows)
    let firstRow = StageWanderPainter.tickerOrigin(full, index: 0, count: rows)
    #expect(lastRow.y > firstRow.y && lastRow.y < full.height - StageWanderPainter.tickerInset)

    for level in [2, 3] {
      let low = context(rig, wander: [deck], now: 11, vizLevel: level)
      #expect(tickerPixels(try layerPixels(low, model)) == 0, "no ticker at level \(level)")
    }
  }

  // MARK: off

  @Test func withTheButtonOffTheStageIsPixelForPixelWhatItWasWithoutTheLayer() throws {
    let rig = try StageViewRig()
    defer { rig.stop() }
    try rig.run(seconds: 0.5)
    let deck = StageWanderDeck(
      deck: "A", on: true, pace: 8, countdown: 5, barInPhrase: 3, step: 2,
      moves: [Self.move(0, "bass off"), Self.move(1, "drop")])
    // give the rig's own wander model a live flash and ticker
    let base = rig.model.context.now
    rig.model.layers.wander.advance(
      context(rig, wander: [StageWanderDeck(deck: "A", on: true)], now: base))
    rig.model.layers.wander.advance(context(rig, wander: [deck], now: base))
    #expect(rig.model.layers.wander.flash(deck: "A", now: base) == 1)

    func scene(_ ctx: StageContext) throws -> Pixels {
      try #require(
        renderPixels(
          StageScene(model: rig.model, context: ctx), width: Int(rig.width),
          height: Int(rig.height)))
    }
    let today = try scene(context(rig, wander: [], showWander: false))
    let off = try scene(context(rig, wander: [deck], showWander: false))
    let on = try scene(context(rig, wander: [deck], showWander: true))
    savePNG(
      StageScene(model: rig.model, context: context(rig, wander: [deck])),
      width: Int(rig.width), height: Int(rig.height), name: "stage-wander-scene")
    #expect(sameSamples(off.rgba, today.rgba) == .identical, "the ∿ button off draws nothing")
    #expect(sameSamples(on.rgba, today.rgba) != .identical, "and on, the walk is drawn")

    // and a solo visualizer hides it like the button does
    var solo = context(rig, wander: [deck])
    solo.visualizer = .corona
    #expect(!StageWanderPainter.shows(solo))
  }
}
