// The numbers of the constellation's look that come from petri-note.css, as values with unit
// tests (the drawing itself is in DJViews and only reads them). Colours are `StagePalette`.
//
// Sizes are in NET units: points before the panel's fit scale (`StagePanelView.scale`), because
// the CSS sizes the nodes in px inside `.pn-stage-stage`, which stage.js scales as a whole.

public enum StageStyle {
  // MARK: nodes

  /// `.pn-place-circle`: 50px across.
  public static let placeRadius = 25.0
  /// `border: 3px solid #4a90d9` on the place and on the transition.
  public static let placeBorder = 3.0
  /// `.pn-transition-rect`: 40px across.
  public static let transitionHalf = 20.0
  public static let transitionBorder = 3.0
  /// `border-radius: 6px`.
  public static let transitionCorner = 6.0

  /// `.pn-transition.firing .pn-transition-rect { box-shadow: 0 0 8px #e94560 }`. A CSS blur
  /// radius is TWICE the Gaussian's standard deviation (CSS Backgrounds 3, "box-shadow blur"),
  /// while SwiftUI's `.shadow(radius:)` and the graphics context's shadow filter take the
  /// deviation itself: the glow is drawn with `glowSigma`, half of the 8.
  public static let glowBlur = 8.0
  public static var glowSigma: Double { glowBlur / 2 }

  /// What a fired transition's body looks like.
  ///
  /// petri-note.css has two rules of equal specificity (0,3,0) that both set the transition
  /// rect's `background`: `.pn-transition.firing .pn-transition-rect { background: #e94560 }`
  /// (line 2173) and `.pn-transition.has-midi .pn-transition-rect { background:
  /// linear-gradient(...) }` (line 2190). The later one wins, so a transition that carries a note
  /// keeps its dark two-tone body while it fires and shows only the glow, the scale pulse and the
  /// red border it always has. And only a transition with a note ever fires (the engine posts
  /// `transition-fired` for un-muted MIDI), so in beats the solid red body of `.firing` never
  /// shows. A node without a note would be solid red; kept for completeness.
  public static func firingBodyIsSolid(hasMidi: Bool) -> Bool { !hasMidi }

  // MARK: live tokens (not in beats: the engine's marking, drawn)

  /// A place holding one token: a disc of the place's own blue.
  public static let tokenRadius = 10.0
  /// A place holding two or more: a larger disc with the count in bold.
  public static let tokenRadiusMany = 15.0
  /// `.pn-place-circle`'s reserved text: `font-size: 16px; font-weight: bold`.
  public static let tokenCountFontSize = 16.0

  // MARK: panels

  /// `.pn-stage-panel { border-radius: 10px }`.
  public static let panelCorner = 10.0
  /// `.pn-stage-panel { border: 1px solid ... }` with `box-sizing: border-box`. The panel's
  /// children (`.pn-stage-canvas`, `.pn-stage-stage`, `.pn-stage-label`) are `position: absolute;
  /// inset: 0`, which sits in the PADDING box: the net and the label are drawn this far right and
  /// down of the panel's corner. (`layoutPanel` and `nodeCenterInStage` ignore it, so the model's
  /// node centres are this much up and left of the drawn nodes, in stage.js as here.)
  public static let panelBorder = 1.0
  /// `.pn-stage-label { top: 8px; left: 10px }` (inside the padding box).
  public static let labelLeft = 10.0
  public static let labelTop = 8.0
  /// `font-size: 11px; letter-spacing: 0.08em`.
  public static let labelFontSize = 11.0
  public static let labelTracking = 0.08

  /// `ctx.lineWidth = 2 / view.scale`: arcs are 2 points wide on screen.
  public static let arcScreenWidth = 2.0
  /// The meta-net's lines and circles (`stroke-width: 2`).
  public static let metaStrokeWidth = 2.0
}

/// What an empty stage says (stage.js has no such state: there is always a project; here a deck
/// may hold a sample, or nothing). Drawn upright, outside the turning container.
public enum StageEmptyState {
  public static func message(hasNet: Bool, source: ScopeSource) -> String {
    if hasNet { return "Waiting for the first bar…" }
    switch source {
    case .deck: return "Stage needs a net deck — load a track on \(source.label)"
    case .master: return "Stage needs a net deck — load a track on a deck"
    }
  }
}
