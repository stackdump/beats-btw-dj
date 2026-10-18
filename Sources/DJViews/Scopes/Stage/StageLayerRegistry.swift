import DJCore
import SwiftUI

// StageLayerRegistry: the view side of the stage's layer registry. ONE list, every slot present,
// in z-order. (The model side is `StageLayerModels` in DJCore; read its header too.)
//
// THE LAYER CONTRACT, VIEW SIDE
// =============================
// Each slot is a view that takes `init(context: StageContext, model: <ItsModel>)` and is a pure
// function of those two: a `Canvas` that draws in STAGE coordinates (the window, y down; the
// same space as `StageContext`). A layer author replaces its own view file and its own model
// file wholesale and touches nothing else; this file and `StageView` are written once.
//
// Z-order, bottom to top (stage.js DOM order and z-index):
//
//   background                    OUTSIDE the container: does not spin or tilt
//   +- container (rotateZ(metaRotation), plus tilt's perspective when on) -------------------+
//   |  flame beams                 StageFlameLayer   (mode 15)   all five layers share the    |
//   |  bolts, seeds, halo          StageBoltsLayer   (mode 17)   container's transform, so   |
//   |  meta-net                    StageMetaLayer    (mode 8)    they move and tilt as one:  |
//   |  pulse particles             StagePulseLayer   (mode 14)   that is the "flame canvas   |
//   |  panels                      StagePanelsLayer  (mode 7)    mirrors the grid" of the JS |
//   +---------------------------------------------------------------------------------------+
//   empty-state message           OUTSIDE the container (upright while the diagram turns); only
//                                 with no panels and no solo visualizer (StageEmptyLayer)
//   wander walk                   OUTSIDE the container (upright); only with the ∿ button on and
//                                 no solo visualizer (StageWanderLayer)
//   solo visualizers              OUTSIDE the container; the container is not drawn while one
//                                 is showing (`viz-solo`: grid opacity 0, flame display none)
//   card flash                    OUTSIDE the container
//   chrome (toolbar, stats, help) the host, above everything
//
// The container transform comes from the model once per frame (`StageTiltModel.projection`):
// a pure `rotateZ` is applied with `.rotationEffect` about the stage centre; with tilt on, the
// 4x4 matrix of `StageProjection` (CSS `perspective(1400px) rotateX rotateY rotateZ`, origin the
// stage centre) goes through `.projectionEffect(ProjectionTransform(CATransform3D))`. Either way
// ONE modifier wraps ALL five layers, so every layer transforms identically by construction.
// Coordinates the model hands out (`nodeCenterInStage`, `StageFire.origin`) are the
// PRE-transform ones, like the JS: never feed projected coordinates back.
//
// Adding a layer is one line here (and one in `StageLayerModels`).

struct StageLayerStack: View {
  let context: StageContext
  let models: StageLayerModels

  var body: some View {
    ZStack {
      StageBackgroundLayer(context: context, model: models.background)

      if !context.isSolo {
        StageContainer(
          projection: models.tilt.projection(metaRotation: context.metaRotation),
          width: context.width, height: context.height
        ) {
          ZStack {
            StageFlameLayer(context: context, model: models.flame)
            StageBoltsLayer(context: context, model: models.bolts)
            StageMetaLayer(context: context)
            StagePulseLayer(context: context, model: models.pulse)
            StagePanelsLayer(context: context)
          }
        }
      }

      if !context.isSolo { StageEmptyLayer(context: context) }
      if StageWanderPainter.shows(context) {
        StageWanderLayer(context: context, model: models.wander)
      }

      StageSoloLayer(context: context, model: models.solo)
      StageCardLayer(context: context, model: models.card)
    }
  }
}
