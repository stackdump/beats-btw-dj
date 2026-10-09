import Foundation

// The container transform of the stage: the one transform every layer inside the container
// shares (track spin, and tilt's 3D orbit).
//
// stage.js writes `grid.style.transform` once per frame:
//
//     tilt on :  perspective(1400px) rotateX(rx) rotateY(ry) rotateZ(metaRotation)
//     tilt off:  rotateZ(metaRotation)
//
// and copies the very same string onto the flame canvas (`session.flameCanvas.style.transform =
// grid.style.transform`), because that canvas lives outside the grid. Both have the stage's size
// and the default `transform-origin: 50% 50%`, so the pivot is the stage centre. In SwiftUI the
// container view applies the transform to the whole layer group in one go (flame, bolts, meta
// net, pulses, panels), which is what keeps the layers identical by construction.
//
// How it is applied (DJViews, `StageContainer`): a pure rotateZ uses `.rotationEffect` about the
// centre; with tilt on, `.projectionEffect(ProjectionTransform(CATransform3D))` with the matrix
// below (`StageProjection.matrix`), which composes the CSS functions in CSS order. The matrix
// is unit-tested against hand-worked CSS values here, so the view only has to hand it over.

/// `perspective(d) rotateX(a) rotateY(b) rotateZ(c)` about a pivot, in CSS terms.
public struct StageProjection: Equatable, Sendable {
  /// stage.js' perspective in CSS pixels.
  public static let defaultPerspective = 1400.0

  /// Degrees, as in the CSS functions.
  public var rotateX = 0.0
  public var rotateY = 0.0
  public var rotateZ = 0.0
  /// The `perspective()` distance; nil for none (pure 2D rotation).
  public var perspective: Double?

  public init(
    rotateX: Double = 0, rotateY: Double = 0, rotateZ: Double = 0, perspective: Double? = nil
  ) {
    self.rotateX = rotateX
    self.rotateY = rotateY
    self.rotateZ = rotateZ
    self.perspective = perspective
  }

  /// Just the track spin: `rotateZ(metaRotation)`.
  public static func spin(_ degrees: Double) -> StageProjection {
    StageProjection(rotateZ: degrees)
  }

  /// Tilt on: `perspective(1400px) rotateX(rx) rotateY(ry) rotateZ(rz)`.
  public static func tilt(rotateX: Double, rotateY: Double, rotateZ: Double) -> StageProjection {
    StageProjection(
      rotateX: rotateX, rotateY: rotateY, rotateZ: rotateZ, perspective: defaultPerspective)
  }

  /// No X/Y tilt: a plain in-plane rotation a 2D view can apply.
  public var isPlanar: Bool { rotateX == 0 && rotateY == 0 && perspective == nil }

  public static let identity = StageProjection()

  /// 4x4 matrix, row-major, for COLUMN vectors (`p' = M p`): `T(c) * P * Rx * Ry * Rz * T(-c)`
  /// with the pivot `c = (centerX, centerY, 0)`, the CSS `transform-origin`. Rotations are the
  /// CSS definitions (`rotateX(a)` = `rotate3d(1,0,0,a)`, ...); `perspective(d)` is the identity
  /// with `m34 = -1/d` (row 3, column 2 here).
  public func matrix(centerX: Double, centerY: Double) -> [Double] {
    var m = Self.translation(centerX, centerY)
    if let d = perspective, d > 0 {
      var p = Self.identityMatrix
      p[3 * 4 + 2] = -1 / d
      m = Self.multiply(m, p)
    }
    m = Self.multiply(m, Self.rotationX(rotateX))
    m = Self.multiply(m, Self.rotationY(rotateY))
    m = Self.multiply(m, Self.rotationZ(rotateZ))
    return Self.multiply(m, Self.translation(-centerX, -centerY))
  }

  /// Where the stage point `(x, y)` (z = 0) lands on the screen, with the perspective divide.
  /// Nil when the point is behind the viewer.
  public func project(x: Double, y: Double, centerX: Double, centerY: Double) -> StagePoint? {
    let m = matrix(centerX: centerX, centerY: centerY)
    let vx = m[0] * x + m[1] * y + m[3]
    let vy = m[4] * x + m[5] * y + m[7]
    let w = m[12] * x + m[13] * y + m[15]
    guard w > 1e-9 else { return nil }
    return StagePoint(x: vx / w, y: vy / w)
  }

  // MARK: matrices

  static let identityMatrix: [Double] = [
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  ]

  static func translation(_ x: Double, _ y: Double) -> [Double] {
    var m = identityMatrix
    m[3] = x
    m[7] = y
    return m
  }

  static func rotationX(_ degrees: Double) -> [Double] {
    let a = degrees * Double.pi / 180
    var m = identityMatrix
    m[5] = cos(a)
    m[6] = -sin(a)
    m[9] = sin(a)
    m[10] = cos(a)
    return m
  }

  static func rotationY(_ degrees: Double) -> [Double] {
    let a = degrees * Double.pi / 180
    var m = identityMatrix
    m[0] = cos(a)
    m[2] = sin(a)
    m[8] = -sin(a)
    m[10] = cos(a)
    return m
  }

  static func rotationZ(_ degrees: Double) -> [Double] {
    let a = degrees * Double.pi / 180
    var m = identityMatrix
    m[0] = cos(a)
    m[1] = -sin(a)
    m[4] = sin(a)
    m[5] = cos(a)
    return m
  }

  static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
    var r = [Double](repeating: 0, count: 16)
    for i in 0..<4 {
      for j in 0..<4 {
        var s = 0.0
        for k in 0..<4 { s += a[i * 4 + k] * b[k * 4 + j] }
        r[i * 4 + j] = s
      }
    }
    return r
  }
}

/// CSS `transition: opacity 280ms ease` (muted panels dim rather than snap), driven by `dt`.
public struct StageFade: Equatable, Sendable {
  /// `.pn-stage-panel { transition: opacity 280ms ease }`.
  public static let duration = 0.28
  /// `.pn-stage-panel.muted { opacity: 0.25 }`.
  public static let mutedOpacity = 0.25

  public private(set) var value: Double
  private var from: Double
  private var to: Double
  private var elapsed: Double

  /// Starts settled at `value`.
  public init(value: Double = 1) {
    self.value = value
    from = value
    to = value
    elapsed = Self.duration
  }

  public var target: Double { to }
  public var isSettled: Bool { elapsed >= Self.duration }

  /// Head for `target`. A transition already heading there is left alone; otherwise a new one
  /// starts from the current value.
  public mutating func retarget(_ newTarget: Double) {
    if newTarget == to { return }
    from = value
    to = newTarget
    elapsed = 0
  }

  public mutating func advance(dt: Double) {
    guard elapsed < Self.duration else { return }
    elapsed = min(Self.duration, elapsed + max(0, dt))
    let p = Self.ease(elapsed / Self.duration)
    value = from + (to - from) * p
  }

  /// CSS `ease`: cubic-bezier(0.25, 0.1, 0.25, 1).
  public static func ease(_ t: Double) -> Double { bezier(t, 0.25, 0.1, 0.25, 1) }

  /// CSS `ease-out`: cubic-bezier(0, 0, 0.58, 1).
  public static func easeOut(_ t: Double) -> Double { bezier(t, 0, 0, 0.58, 1) }

  /// A CSS cubic-bezier timing function with end points (0,0) and (1,1): the curve's y at time
  /// `t`, solving x(u) = t by bisection.
  public static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double)
    -> Double
  {
    if t <= 0 { return 0 }
    if t >= 1 { return 1 }
    func b(_ u: Double, _ a: Double, _ c: Double) -> Double {
      let v = 1 - u
      return 3 * v * v * u * a + 3 * v * u * u * c + u * u * u
    }
    var lo = 0.0
    var hi = 1.0
    for _ in 0..<40 {
      let mid = (lo + hi) / 2
      if b(mid, x1, x2) < t { lo = mid } else { hi = mid }
    }
    return b((lo + hi) / 2, y1, y2)
  }
}
