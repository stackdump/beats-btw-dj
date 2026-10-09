import DJCore
import QuartzCore
import SwiftUI

// The layer container: ONE transform for every layer inside it (see StageLayerRegistry.swift).
//
//   * planar (no tilt): `.rotationEffect(rotateZ)` about the centre of the stage, which is the
//     CSS `rotateZ(metaRotation)` with the default `transform-origin: 50% 50%`.
//   * tilted: `.projectionEffect(ProjectionTransform(CATransform3D))` with the matrix of
//     `StageProjection.matrix` (the CSS functions composed in CSS order about the stage centre).
//     SwiftUI applies a ProjectionTransform in the view's own coordinate space (origin at its
//     top-left), which is why the pivot is baked into the matrix.
//
// `StageProjection` (DJCore) holds the math and is unit-tested; this file only hands it over.

extension StageProjection {
  /// The matrix as a `CATransform3D`. `CATransform3D` multiplies ROW vectors (`p' = p T`), so it
  /// is the transpose of the column-vector matrix: `m34 = -1/d` is `M[3][2]`.
  func caTransform(centerX: Double, centerY: Double) -> CATransform3D {
    let m = matrix(centerX: centerX, centerY: centerY)
    func e(_ row: Int, _ col: Int) -> CGFloat { CGFloat(m[row * 4 + col]) }
    return CATransform3D(
      m11: e(0, 0), m12: e(1, 0), m13: e(2, 0), m14: e(3, 0),
      m21: e(0, 1), m22: e(1, 1), m23: e(2, 1), m24: e(3, 1),
      m31: e(0, 2), m32: e(1, 2), m33: e(2, 2), m34: e(3, 2),
      m41: e(0, 3), m42: e(1, 3), m43: e(2, 3), m44: e(3, 3))
  }
}

struct StageContainer<Content: View>: View {
  let projection: StageProjection
  let width: Double
  let height: Double
  let content: Content

  init(
    projection: StageProjection, width: Double, height: Double,
    @ViewBuilder content: () -> Content
  ) {
    self.projection = projection
    self.width = width
    self.height = height
    self.content = content()
  }

  var body: some View {
    if projection.isPlanar {
      content.rotationEffect(.degrees(projection.rotateZ), anchor: .center)
    } else {
      content.projectionEffect(
        ProjectionTransform(
          projection.caTransform(centerX: width / 2, centerY: height / 2)))
    }
  }
}
