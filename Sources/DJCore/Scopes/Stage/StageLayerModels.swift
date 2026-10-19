// StageLayerModels: the model side of the stage's layer registry. ONE list, every slot present.
//
// THE LAYER CONTRACT (the view side and the z-order are in
// `Sources/DJViews/Scopes/Stage/StageLayerRegistry.swift`; read both headers)
// ===========================================================================
// Every layer of the stage is a pair of files that nobody else touches:
//
//   slot (SPEC modes)            model (DJCore, Scopes/Stage/Layers/)   view (DJViews, Scopes/Stage/)
//   background  (18)             StageBackgroundModel.swift            StageBackgroundLayer.swift
//   flame beams (15)             StageFlameModel.swift                 StageFlameLayer.swift
//   bolts, seeds, halo (17)      StageBoltsModel.swift                 StageBoltsLayer.swift
//   pulse particles (14)         StagePulseModel.swift                 StagePulseLayer.swift
//   tilt (16)                    StageTiltModel.swift                  (the container: StageContainer)
//   wander walk                  StageWanderModel.swift                StageWanderLayer.swift
//   solo visualizers (9-12)      StageSoloModel.swift                  StageSoloLayer.swift
//   blocks (solo, dj)            StageMinecraftModel.swift             StageMinecraftLayer.swift
//   dig (solo, dj)               StageDigModel.swift                   StageDigLayer.swift
//   card flash (19)              StageCardModel.swift                  StageCardLayer.swift
//
// The constellation itself (panels, tokens, flash: modes 7, 13; the meta-net: mode 8; the
// track spin: mode 20) belongs to the stage skeleton: `StageModel`, `StagePanelsLayer`,
// `StageMetaLayer`, `StageEmptyLayer`, `StageToolbar`, `StageView`. They are not layers a later mode
// replaces.
//
// A layer author replaces its two files WHOLESALE and keeps:
//   * the model's type name and a no-argument `init()` (extra parameters need defaults), which
//     is what this file calls;
//   * the view's type name and `init(context: StageContext, model: <ItsModel>)`;
//   * everything the model learns about the frame comes from the `StageContext` it is handed in
//     `advance(_:)`, once per drawn frame, BEFORE the views are drawn. State lives in the model
//     (a reference type), the view is a pure function of (context, model): it draws in a
//     `Canvas` and never mutates the model while drawing.
// A layer must not edit this file, the registry, the host, the toolbar or any other layer. A
// control it needs is already in the toolbar and writes `StageSettings`; a flag it needs is in
// the context. If something is missing, say so in the report instead of editing the skeleton.
//
// Hooks a model may override (defaults do nothing):
//   * `advance(_:)`: the per-frame update. Read `context.fires`, `context.dt`, `context.now`;
//     inject your RNG; no wall clock inside tested functions.
//   * `reset()`: forget accumulated state. The stage calls it on the pulse, flame and bolts
//     models when it rebuilds the panels (stage.js `rebuildStagePanels` clears pulses, bolts,
//     seeds and flame energy); other layers compare `context.epoch` themselves.
//   * `handleKey(_:settings:)`: a key the window forwards (arrow keys, T). Return true if used.
// The solo model also decides what is showing (`resolveVisualizer`, shuffle), the card model
// says whether its toolbar button is usable (`isAvailable`), the tilt model supplies the
// container's 3D numbers (`projection`), each of them documented on the placeholder.

/// A layer's model. Main-actor, a reference type.
@MainActor
public protocol StageLayerModel: AnyObject {
  /// Once per drawn frame, with the frame's complete context.
  func advance(_ context: StageContext)
  /// Forget accumulated state (the panels were rebuilt).
  func reset()
  /// A forwarded key; true if this layer took it.
  func handleKey(_ key: StageKey, settings: StageSettings) -> Bool
}

extension StageLayerModel {
  public func advance(_ context: StageContext) {}
  public func reset() {}
  public func handleKey(_ key: StageKey, settings: StageSettings) -> Bool { false }
}

/// Every layer model of the stage, in z-order from the bottom. Adding a slot is a line here and a
/// line in the DJViews registry; the slots below are all the later modes need.
@MainActor
public final class StageLayerModels {
  public let background: StageBackgroundModel
  public let flame: StageFlameModel
  public let bolts: StageBoltsModel
  public let pulse: StagePulseModel
  public let tilt: StageTiltModel
  public let wander: StageWanderModel
  public let solo: StageSoloModel
  public let minecraft: StageMinecraftModel
  public let dig: StageDigModel
  public let card: StageCardModel

  public init(
    background: StageBackgroundModel = StageBackgroundModel(),
    flame: StageFlameModel = StageFlameModel(),
    bolts: StageBoltsModel = StageBoltsModel(),
    pulse: StagePulseModel = StagePulseModel(),
    tilt: StageTiltModel = StageTiltModel(),
    wander: StageWanderModel = StageWanderModel(),
    solo: StageSoloModel = StageSoloModel(),
    minecraft: StageMinecraftModel = StageMinecraftModel(),
    dig: StageDigModel = StageDigModel(),
    card: StageCardModel = StageCardModel()
  ) {
    self.background = background
    self.flame = flame
    self.bolts = bolts
    self.pulse = pulse
    self.tilt = tilt
    self.wander = wander
    self.solo = solo
    self.minecraft = minecraft
    self.dig = dig
    self.card = card
  }

  /// Bottom to top: the order `advance` runs in and the views stack in.
  public var all: [any StageLayerModel] {
    [background, flame, bolts, pulse, tilt, wander, solo, minecraft, dig, card]
  }

  /// What stage.js clears when it rebuilds the panels. (Not the wander model: a wander swap is a
  /// new track, and its flash must outlive the rebuild it causes.)
  public var clearedOnRebuild: [any StageLayerModel] { [pulse, flame, bolts] }
}
