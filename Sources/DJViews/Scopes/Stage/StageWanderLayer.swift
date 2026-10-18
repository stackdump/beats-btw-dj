import DJCore
import SwiftUI

// The Wander walk on the stage (dj's own layer: stage.js has no Wander). OUTSIDE the container,
// above the empty-state message and below the solo and card layers, so it stays upright while
// the diagram turns and tilts. It draws nothing unless the ∿ button is on
// (`StageContext.showWander`), nothing while a solo visualizer shows (the button is hidden then),
// and nothing for a deck that is not wandering. What it draws comes from `StageWanderModel`:
//
//   phrase arc   per wandering deck, round the dark planet at the ring centre (deck A innermost,
//                `arcGap` apart): from 12 o'clock clockwise over `barInPhrase / pace` of the
//                circle and no more, in the deck's tint (DJStyle.deckA / deckB); dashed while the
//                browser wheel holds the walk (paused). Bar 0 of a phrase draws no arc.
//   move flash   a caption ("A · seed 41 → 44") at the top centre, below the menu, fading out
//                linearly over `StageWanderModel.flashSeconds` from the frame the move was seen.
//   ticker       the last 4 moves across the source decks at the bottom left, newest at the
//                bottom, each fading over `StageWanderModel.tickerSeconds`. Skipped at visual
//                level 2 and up (Minimal / Paused), as the fire effects are.

struct StageWanderLayer: View {
  let context: StageContext
  let model: StageWanderModel

  var body: some View {
    StageCanvas { gc, _ in
      StageWanderPainter.draw(&gc, context: context, model: model)
    }
    .allowsHitTesting(false)
  }
}

@MainActor
enum StageWanderPainter {
  /// Stroke width of a phrase arc.
  static let arcWidth = 3.0
  /// Radial distance between two decks' arcs (and from the dark planet to the first).
  static let arcGap = 8.0
  /// The dash of a paused arc.
  static let dash: [CGFloat] = [6, 5]
  /// The caption's baseline band: centred on `captionTop`, one `captionStep` per flashing deck.
  static let captionTop = 64.0
  static let captionStep = 22.0
  static let captionSize = 15.0
  /// The ticker: `tickerInset` from the left and bottom edges, one `tickerStep` per row.
  static let tickerInset = 16.0
  static let tickerStep = 16.0
  static let tickerSize = 11.0
  /// The ticker's opacity at full strength (it is a trail, not news).
  static let tickerOpacity = 0.75

  /// Does the layer draw anything at all this frame?
  static func shows(_ context: StageContext) -> Bool {
    context.showWander && !context.isSolo
  }

  /// Is the ticker drawn at this visual level?
  static func showsTicker(level: Int) -> Bool { StageFramePacer.showsFireEffects(level: level) }

  static func tint(_ deck: String) -> Color {
    switch deck {
    case "A": DJStyle.deckA
    case "B": DJStyle.deckB
    default: StagePalette.arc.color
    }
  }

  /// The decks that get an arc: wandering, with a phrase to show, in context order.
  static func arcDecks(_ context: StageContext) -> [StageWanderDeck] {
    context.wander.filter { $0.on && $0.phraseProgress != nil }
  }

  /// Radius of the `index`th arc: just outside the dark planet (a fallback for a ring without
  /// one).
  static func arcRadius(_ context: StageContext, index: Int) -> Double {
    let planet = context.darkPlanetRadius ?? max(18, context.radius * 0.15)
    return planet + arcGap * Double(index + 1)
  }

  /// The arc of one deck: 12 o'clock clockwise over `progress` of the circle (y down, so
  /// clockwise on screen is increasing angle).
  static func arcPath(center: StagePoint, radius: Double, progress: Double) -> Path {
    let start = -Double.pi / 2
    let sweep = 2 * Double.pi * min(1, max(0, progress))
    var p = Path()
    p.addArc(
      center: CGPoint(x: center.x, y: center.y), radius: radius, startAngle: .radians(start),
      endAngle: .radians(start + sweep), clockwise: false)
    return p
  }

  /// Where the `index`th flash caption is centred.
  static func captionCenter(_ context: StageContext, index: Int) -> CGPoint {
    CGPoint(x: context.width / 2, y: captionTop + captionStep * Double(index))
  }

  /// Where the `index`th of `count` ticker rows sits (its left edge, vertical centre).
  static func tickerOrigin(_ context: StageContext, index: Int, count: Int) -> CGPoint {
    let fromBottom = Double(count - 1 - index)
    return CGPoint(
      x: tickerInset, y: context.height - tickerInset - tickerStep * fromBottom - tickerStep / 2)
  }

  static func draw(_ gc: inout GraphicsContext, context: StageContext, model: StageWanderModel) {
    guard shows(context) else { return }
    let now = context.now

    // Phrase arcs (not over the empty-state message, which sits at the centre).
    if !context.panels.isEmpty {
      for (i, d) in arcDecks(context).enumerated() {
        guard let progress = d.phraseProgress, progress > 0 else { continue }
        let path = arcPath(
          center: context.ringCenter, radius: arcRadius(context, index: i), progress: progress)
        // Butt caps: a round cap would reach past the phrase's end.
        let style = StrokeStyle(lineWidth: arcWidth, lineCap: .butt, dash: d.paused ? dash : [])
        gc.stroke(path, with: .color(tint(d.deck).opacity(0.85)), style: style)
      }
    }

    // Move flashes.
    for (i, f) in model.activeFlashes(now: now).enumerated() {
      let a = model.flash(deck: f.deck, now: now)
      guard a > 0 else { continue }
      let text = gc.resolve(
        Text("\(f.deck) · \(f.move.detail)")
          .font(.system(size: captionSize, weight: .semibold))
          .foregroundStyle(tint(f.deck).opacity(a)))
      gc.draw(text, at: captionCenter(context, index: i), anchor: .center)
    }

    // Ticker.
    guard showsTicker(level: context.vizLevel) else { return }
    let rows = model.rows(now: now)
    for (i, r) in rows.enumerated() {
      let text = gc.resolve(
        Text(r.caption)
          .font(.system(size: tickerSize, design: .monospaced))
          .foregroundStyle(tint(r.deck).opacity(tickerOpacity * r.alpha)))
      gc.draw(text, at: tickerOrigin(context, index: i, count: rows.count), anchor: .leading)
    }
  }
}
