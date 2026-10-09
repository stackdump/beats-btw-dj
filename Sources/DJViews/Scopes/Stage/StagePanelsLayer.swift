import DJCore
import SwiftUI

// The constellation (SPEC mode 7): the ring of live net panels. Part of the stage skeleton, not
// a layer a later mode replaces.
//
// stage.js builds each panel from a canvas (the arcs) and DOM nodes (places, transitions) whose
// look is in petri-note.css; here it is one Canvas, drawn in the same order the DOM stacks:
//
//   panel back (only with the Backs toggle)  ->  arcs + arrowheads  ->  places  ->  tokens
//   ->  transitions (lit ones last)  ->  label (only with the Labels toggle)
//
// Every net is drawn under `translate(origin + t) scale(s) translate(c) rotate(angle)
// translate(-c)`, the transform stage.js sets on `.pn-stage-stage` and replays on its canvas
// (`StagePanelView`), so the arcs and the nodes turn together and an arrowhead stays seated on
// its node at every angle. Sizes and colours are copied from the CSS rules:
//
//   place        `.pn-place-circle`: 50 points across, 3 border #4a90d9, fill #1a1a2e
//   transition   `.pn-transition-rect`: 40 points, 3 border #e94560, radius 6, fill #1a1a2e;
//                `.has-midi`: the lower-right half of the fill is #2d1f3d
//   firing       `.pn-transition.firing`: glow `0 0 8px #e94560` and the 0.1 s scale pulse; lit for
//                100 ms from the fire's AUDIO time (the feed's, not a timer). A transition that
//                carries a note keeps its two-tone body (`.has-midi` wins the cascade over the
//                solid red of `.firing`, see `StageStyle.firingBodyIsSolid`); the red border it
//                always has plus the glow and the pulse are the flash.
//   arcs         #4a90d9 at alpha 0.6, 2 points on screen (`2 / scale` in net units)
//
// LIVE TOKENS. stage.js shows none (its place circle is empty). The engine's marking is drawn
// instead (SPEC: "DRAW live tokens from engine marking"): a place holding tokens gets a disc in
// the place's own blue (#4a90d9, the colour of its border and of the bold 16px text the CSS
// reserves inside the circle); a place holding 2 or more gets a larger disc with the count in
// bold 16px in the node fill colour. There is no token style in canvas.js or the CSS to copy.
//
// Muted panels dim to opacity 0.25 (eased over 280 ms by the model) as a whole group.
//
// The net and the label sit `StageStyle.panelBorder` (1 point) right and down of the panel's
// corner, where the DOM puts them (children of a border-box with a 1px border, `inset: 0`).
//
// The numbers (sizes, glow, token radii) are `StageStyle`, with unit tests.

struct StagePanelsLayer: View {
  let context: StageContext

  var body: some View {
    Canvas { gc, size in
      StagePanelPainter.draw(&gc, context: context)
    }
    .allowsHitTesting(false)
  }
}

enum StagePanelPainter {
  static func draw(_ gc: inout GraphicsContext, context: StageContext) {
    // (An empty stage says so in `StageEmptyLayer`, outside the turning container.)
    for panel in context.panels { drawPanel(gc, panel: panel, context: context) }
  }

  // MARK: a panel

  static func drawPanel(_ gc: GraphicsContext, panel: StagePanel, context: StageContext) {
    var group = gc
    group.opacity = panel.opacity
    group.drawLayer { l in
      if context.showBacks { drawBack(l, panel: panel) }
      if let view = panel.view { drawNet(l, panel: panel, view: view, context: context) }
      if context.showLabels { drawLabel(l, panel: panel) }
    }
  }

  /// `.pn-stage-panel`: radial-gradient(circle at center, #131a33 0%, #070712 100%), a 1px
  /// rgba(74,144,217,0.18) border, radius 10.
  static func drawBack(_ gc: GraphicsContext, panel: StagePanel) {
    let rect = CGRect(x: panel.origin.x, y: panel.origin.y, width: panel.side, height: panel.side)
    let corner = StageStyle.panelCorner
    let shape = Path(roundedRect: rect, cornerRadius: corner)
    let shading = GraphicsContext.Shading.radialGradient(
      Gradient(colors: [StagePalette.backInner.color, StagePalette.backOuter.color]),
      center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
      endRadius: panel.side * 0.5 * 2.0.squareRoot())
    gc.fill(shape, with: shading)
    let half = StageStyle.panelBorder / 2
    gc.stroke(
      Path(roundedRect: rect.insetBy(dx: half, dy: half), cornerRadius: corner - half),
      with: .color(StagePalette.backBorder.color), lineWidth: StageStyle.panelBorder)
  }

  /// `.pn-stage-label`: 11px, uppercase, letter-spacing 0.08em, rgba(255,255,255,0.55), at
  /// (10, 8) from the padding box's corner.
  static func drawLabel(_ gc: GraphicsContext, panel: StagePanel) {
    let size = StageStyle.labelFontSize
    let text = gc.resolve(
      Text(panel.label.uppercased()).font(.system(size: size)).kerning(
        size * StageStyle.labelTracking
      )
      .foregroundStyle(StagePalette.label.color))
    gc.draw(
      text,
      at: CGPoint(
        x: panel.origin.x + StageStyle.panelBorder + StageStyle.labelLeft,
        y: panel.origin.y + StageStyle.panelBorder + StageStyle.labelTop),
      anchor: .topLeading)
  }

  // MARK: the net

  static func drawNet(
    _ gc: GraphicsContext, panel: StagePanel, view: StagePanelView, context: StageContext
  ) {
    var g = gc
    let inset = StageStyle.panelBorder
    g.translateBy(x: panel.origin.x + inset + view.tx, y: panel.origin.y + inset + view.ty)
    g.scaleBy(x: view.scale, y: view.scale)
    g.translateBy(x: view.cx, y: view.cy)
    g.rotate(by: .degrees(panel.angle))
    g.translateBy(x: -view.cx, y: -view.cy)

    drawArcs(g, shape: panel.shape, scale: view.scale)
    drawPlaces(g, panel: panel)
    drawTransitions(g, panel: panel, now: context.audioNow)
  }

  /// Arcs, then their arrowheads: two strokes per panel. stage.js strokes each arc and each
  /// arrowhead on its own at alpha 0.6; what shows is a head seated on its line (the barbs start
  /// ON the line), so heads are stroked apart from the lines and the join is as dark as in the
  /// JS. Lines overlapping lines, and heads overlapping heads, are one stroke here and a shade
  /// lighter than in the JS (per-arc strokes are a thousand draw calls for a 40-panel stage).
  static func drawArcs(_ g: GraphicsContext, shape: StageNetShape, scale: Double) {
    var lines = Path()
    var heads = Path()
    for a in shape.arcs {
      lines.move(to: CGPoint(x: a.x1, y: a.y1))
      lines.addLine(to: CGPoint(x: a.x2, y: a.y2))
      let h = StageArcArrow.head(x1: a.x1, y1: a.y1, x2: a.x2, y2: a.y2)
      heads.move(to: CGPoint(x: h.tipX, y: h.tipY))
      heads.addLine(to: CGPoint(x: h.leftX, y: h.leftY))
      heads.move(to: CGPoint(x: h.tipX, y: h.tipY))
      heads.addLine(to: CGPoint(x: h.rightX, y: h.rightY))
    }
    let style = GraphicsContext.Shading.color(
      StagePalette.arc.withAlpha(StagePalette.arcAlpha).color)
    let width = StageStyle.arcScreenWidth / scale
    g.stroke(lines, with: style, lineWidth: width)
    g.stroke(heads, with: style, lineWidth: width)
  }

  static func drawPlaces(_ g: GraphicsContext, panel: StagePanel) {
    let shape = panel.shape
    var fill = Path()
    var border = Path()
    let outer = StageStyle.placeRadius
    let mid = outer - StageStyle.placeBorder / 2
    for i in 0..<shape.placeIds.count {
      let x = shape.placeX[i]
      let y = shape.placeY[i]
      fill.addEllipse(in: CGRect(x: x - outer, y: y - outer, width: outer * 2, height: outer * 2))
      border.addEllipse(in: CGRect(x: x - mid, y: y - mid, width: mid * 2, height: mid * 2))
    }
    g.fill(fill, with: .color(StagePalette.nodeFill.color))
    g.stroke(border, with: .color(StagePalette.arc.color), lineWidth: StageStyle.placeBorder)

    // Live tokens.
    var dots = Path()
    var counts: [(Int, Double, Double)] = []
    for i in 0..<shape.placeIds.count where i < panel.tokens.count && panel.tokens[i] > 0 {
      let x = shape.placeX[i]
      let y = shape.placeY[i]
      let n = Int(panel.tokens[i].rounded())
      let r = n >= 2 ? StageStyle.tokenRadiusMany : StageStyle.tokenRadius
      dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
      if n >= 2 { counts.append((n, x, y)) }
    }
    g.fill(dots, with: .color(StagePalette.arc.color))
    for (n, x, y) in counts {
      let text = g.resolve(
        Text("\(n)").font(.system(size: StageStyle.tokenCountFontSize, weight: .bold))
          .foregroundStyle(StagePalette.nodeFill.color))
      g.draw(text, at: CGPoint(x: x, y: y), anchor: .center)
    }
  }

  static func roundedRect(cx: Double, cy: Double, half: Double, corner: Double) -> Path {
    Path(
      roundedRect: CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2),
      cornerRadius: corner)
  }

  /// A transition's body, border and (with a note) the lower-right half of the split fill, added
  /// to the batch paths. Centred on (x, y).
  private static func addTransition(
    x: Double, y: Double, hasMidi: Bool, body: inout Path, midi: inout Path, border: inout Path
  ) {
    let half = StageStyle.transitionHalf
    let bw = StageStyle.transitionBorder
    body.addPath(roundedRect(cx: x, cy: y, half: half, corner: StageStyle.transitionCorner))
    border.addPath(
      roundedRect(cx: x, cy: y, half: half - bw / 2, corner: StageStyle.transitionCorner - bw / 2))
    if hasMidi {
      // linear-gradient(135deg, #1a1a2e 50%, #2d1f3d 50%): the half below the anti-diagonal.
      var tri = Path()
      tri.move(to: CGPoint(x: x + half, y: y - half))
      tri.addLine(to: CGPoint(x: x + half, y: y + half))
      tri.addLine(to: CGPoint(x: x - half, y: y + half))
      tri.closeSubpath()
      midi.addPath(tri)
    }
  }

  private static func paintTransitions(
    _ g: GraphicsContext, body: Path, midi: Path, border: Path, solid: Bool
  ) {
    g.fill(body, with: .color(solid ? StagePalette.transition.color : StagePalette.nodeFill.color))
    if !solid && !midi.isEmpty {
      g.drawLayer { l in
        l.clip(to: body)
        l.fill(midi, with: .color(StagePalette.transitionMidi.color))
      }
    }
    g.stroke(
      border, with: .color(StagePalette.transition.color), lineWidth: StageStyle.transitionBorder)
  }

  static func drawTransitions(_ g: GraphicsContext, panel: StagePanel, now: Double) {
    let shape = panel.shape
    var body = Path()
    var midi = Path()
    var border = Path()
    var lit: [Int] = []
    for i in 0..<shape.transitionIds.count {
      if panel.flash(transition: i, now: now) > 0 {
        lit.append(i)
        continue
      }
      addTransition(
        x: shape.transitionX[i], y: shape.transitionY[i], hasMidi: shape.transitionHasMidi[i],
        body: &body, midi: &midi, border: &border)
    }
    paintTransitions(g, body: body, midi: midi, border: border, solid: false)
    for i in lit { drawLit(g, panel: panel, index: i, now: now) }
  }

  /// A transition that just fired: its glow, pulsing in scale, over its normal body. A node with
  /// a note keeps its two-tone fill (see `StageStyle.firingBodyIsSolid`); one without would be
  /// solid red.
  static func drawLit(_ g: GraphicsContext, panel: StagePanel, index i: Int, now: Double) {
    let x = panel.shape.transitionX[i]
    let y = panel.shape.transitionY[i]
    let hasMidi = panel.shape.transitionHasMidi[i]
    let s = panel.pulseScale(transition: i, now: now)
    var l = g
    l.translateBy(x: x, y: y)
    l.scaleBy(x: s, y: s)
    // The glow is a shadow of the node's outline: filled with the border's red underneath (the
    // body is drawn over it), blurred by sigma = half the CSS blur radius.
    let outline = roundedRect(
      cx: 0, cy: 0, half: StageStyle.transitionHalf, corner: StageStyle.transitionCorner)
    l.drawLayer { glow in
      glow.addFilter(
        .shadow(
          color: StagePalette.transition.color, radius: StageStyle.glowSigma, x: 0, y: 0,
          blendMode: .normal, options: []))
      glow.fill(outline, with: .color(StagePalette.transition.color))
    }
    var body = Path()
    var midi = Path()
    var border = Path()
    addTransition(x: 0, y: 0, hasMidi: hasMidi, body: &body, midi: &midi, border: &border)
    paintTransitions(
      l, body: body, midi: midi, border: border,
      solid: StageStyle.firingBodyIsSolid(hasMidi: hasMidi))
  }
}
