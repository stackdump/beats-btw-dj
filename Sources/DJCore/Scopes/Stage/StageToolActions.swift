// The stage toolbar's toggle buttons as a table: which button writes which flag of
// `StageSettings`. The toolbar view lays out one button per row of this table and nothing else
// decides what a button does, so the wiring is unit-tested here rather than through the SwiftUI
// buttons (which do not render offscreen).

/// One of the toolbar's round toggle buttons (stage.js `.pn-stage-menu` buttons).
public enum StageToolAction: String, CaseIterable, Sendable {
  case flow, pulse, flame, tilt, expand, backs, labels, card, bolts

  /// The buttons left of the card button, in toolbar order: the four `data-viz` overlays, then
  /// expand, backs and labels.
  public static let beforeCard: [StageToolAction] = [
    .flow, .pulse, .flame, .tilt, .expand, .backs, .labels,
  ]

  /// The buttons the CSS hides while a solo visualizer shows (`.viz-solo [data-viz]`,
  /// `.pn-stage-expand`, `-backs`, `-labels`, `-bolts`): everything but the card button.
  public static let hiddenWhileSolo: Set<StageToolAction> = [
    .flow, .pulse, .flame, .tilt, .expand, .backs, .labels, .bolts,
  ]

  /// The glyph on the button.
  public var glyph: String {
    switch self {
    case .flow: "◌"
    case .pulse: "◎"
    case .flame: "▼"
    case .tilt: "⊝"
    case .expand: "⇄"
    case .backs: "■"
    case .labels: "A"
    case .card: "✎"
    // (with the text-presentation selector: the emoji glyph would ignore the toolbar's colour)
    case .bolts: "⚡\u{FE0E}"
    }
  }

  /// The tooltip (stage.js `title`s). The card button's is given by the card model while it is
  /// unavailable.
  public var help: String {
    switch self {
    case .flow: "Flow — panels drift"
    case .pulse: "Pulse — beats fade toward center"
    case .flame: "Flame — radial equalizer from center"
    case .tilt: "Tilt — 3D perspective rotation"
    case .expand: "Show all slot variants (A+B+…)"
    case .backs: "Show/hide panel backgrounds"
    case .labels: "Show/hide track labels"
    case .card: "Flash the share card on every track change (T)"
    case .bolts: "Lightning during macros (flame mode)"
    }
  }

  /// The overlay this button toggles, for the five that are overlays.
  public var overlay: StageOverlay? {
    switch self {
    case .flow: .flow
    case .pulse: .pulse
    case .flame: .flame
    case .tilt: .tilt
    case .bolts: .bolts
    case .expand, .backs, .labels, .card: nil
    }
  }

  @MainActor
  public func isOn(_ s: StageSettings) -> Bool {
    switch self {
    case .flow, .pulse, .flame, .tilt, .bolts: s.isOn(overlay!)
    case .expand: s.expandVariants
    case .backs: s.showBacks
    case .labels: s.showLabels
    case .card: s.cardOnChange
    }
  }

  /// What a press does: flips exactly this button's flag.
  @MainActor
  public func toggle(_ s: StageSettings) {
    switch self {
    case .flow, .pulse, .flame, .tilt, .bolts: s.toggle(overlay!)
    case .expand: s.expandVariants.toggle()
    case .backs: s.showBacks.toggle()
    case .labels: s.showLabels.toggle()
    case .card: s.cardOnChange.toggle()
    }
  }
}
