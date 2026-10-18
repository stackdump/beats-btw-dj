import Observation

// The Stage's toolbar state: what the user picked. Observable, so the toolbar and the host
// re-render when a control changes; the per-frame state (panels, springs, particles) is NOT
// here, it lives in `StageModel` and the layers' own models and is read through `StageContext`.
//
// The defaults are what stage.js opens with: Constellation, flow + pulse + flame + bolts on,
// tilt off, panel backs and labels hidden (`hide-backs hide-labels`), void background, scale Fit.

/// A key the stage window forwards to its layers (the arrow keys cycle the visualizer, T flashes
/// the share card; Esc closes the window and belongs to the host).
public enum StageKey: Sendable {
  case left, right, t
}

@MainActor @Observable
public final class StageSettings {
  /// Which deck(s) supply panels: A, B, or the master (panels of both net decks).
  ///
  /// Whatever it is, the stage acquires that source's `ScopeFeed` while it is on screen, and a
  /// feed's acquire also switches its sample tap on (the master's, for `.master`: a render
  /// notification on the live output unit, unverified on hardware). The constellation reads no
  /// audio, so until the corona (which does) lands that tap runs for nothing while the window is
  /// open: an event-only acquire in `ScopeFeed` would let the stage take the sample tap only
  /// while an audio visualizer shows.
  public var source: ScopeSource = .master
  /// The visualizer select. `.shuffle` is a selection; the solo layer picks what shows.
  public var visualizer: StageVisualizer = .constellation
  public var overlays: Set<StageOverlay> = StageOverlay.defaults
  public var scale: StageScale = .loop
  /// Show every riff-group variant (A+B+...) instead of one panel per logical track.
  public var expandVariants = false
  /// Panel background fills (`.pn-stage-panel` back + border). Off by default.
  public var showBacks = false
  /// Track names on the panels. Off by default.
  public var showLabels = false
  /// Flash the share card on every track change.
  public var cardOnChange = false
  public var bgMode: StageBackground = .void
  /// The Wander walk on the stage (phrase arc, move flash, ticker; `StageWanderModel`). On by
  /// default; it draws nothing for a deck that is not wandering.
  public var showWander = true
  /// The toolbar folds into one dot (stage.js starts collapsed).
  public var menuCollapsed = true

  public init() {}

  public func isOn(_ overlay: StageOverlay) -> Bool { overlays.contains(overlay) }

  /// The `data-viz` buttons and the bolts button.
  public func toggle(_ overlay: StageOverlay) {
    if overlays.contains(overlay) {
      overlays.remove(overlay)
    } else {
      overlays.insert(overlay)
    }
  }
}
