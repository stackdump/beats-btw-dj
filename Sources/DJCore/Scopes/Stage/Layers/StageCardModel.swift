// STAGE LAYER PLACEHOLDER: the share-card flash (SPEC mode 19). Replaced wholesale by the
// backgrounds/extras task. Contract: see StageLayerModels.swift.
//
// stage.js flashes the share card for 6 s on a track change when `context.cardOnChange`
// (`context.trackChanged` is true for exactly that frame). This app has no share card, so the
// toolbar button is disabled until this model says it is available.

@MainActor
public final class StageCardModel: StageLayerModel {
  public init() {}

  /// Can the toolbar's card button be used?
  public var isAvailable: Bool { false }

  /// Why not (the button's tooltip while unavailable).
  public var unavailableReason: String {
    "Share-card flash: not ported yet (this app has no share card)."
  }
}
