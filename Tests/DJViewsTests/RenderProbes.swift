import AppKit
import Foundation
import SwiftUI

// Pixel-probing helpers for the render tests of the main-view extras (SPEC modes 22-26).
// Kept out of files that `import Testing` (Foundation + SwiftUI cannot be imported next to it).

/// `renderPixels` at a higher pixel density: one point is `scale` pixels, so a stroke thinner
/// than a point, or the falloff of a glow, can be measured. Pixel (x, y) of the result is the
/// point (x / scale, y / scale).
@MainActor
func renderPixelsScaled<V: View>(_ view: V, width: Int, height: Int, scale: Int) -> Pixels? {
  let renderer = ImageRenderer(
    content: view.frame(width: CGFloat(width), height: CGFloat(height)).environment(
      \.colorScheme, .dark))
  renderer.scale = CGFloat(scale)
  guard let cg = renderer.cgImage else { return nil }
  let w = cg.width
  let h = cg.height
  var data = [UInt8](repeating: 0, count: w * h * 4)
  let space = CGColorSpaceCreateDeviceRGB()
  let ok = data.withUnsafeMutableBytes { raw -> Bool in
    guard
      let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  return ok ? Pixels(width: w, height: h, rgba: data) : nil
}

extension Pixels {
  /// Alpha (0...255) of the pixel under the point `(x, y)` in a render of `scale` pixels per
  /// point; 0 outside the image.
  func alpha(atPoint x: Double, _ y: Double, scale: Int) -> Int {
    let px = Int((x * Double(scale)).rounded(.down))
    let py = Int((y * Double(scale)).rounded(.down))
    guard px >= 0, py >= 0, px < width, py < height else { return 0 }
    return color(px, py).a
  }

  /// The mean alpha on the circle of `radius` points round `centre`, over the angles
  /// `from...to` (radians, 0 along +x, growing clockwise on screen: toward +y).
  func meanAlpha(
    onCircleAround centre: (x: Double, y: Double), radius: Double, from: Double, to: Double,
    samples: Int = 24, scale: Int
  ) -> Double {
    var sum = 0.0
    for k in 0..<samples {
      let a = from + (to - from) * (Double(k) + 0.5) / Double(samples)
      sum += Double(
        alpha(
          atPoint: centre.x + radius * cos(a), centre.y + radius * sin(a), scale: scale))
    }
    return sum / Double(samples)
  }

  /// The largest alpha along the segment of the line through `centre` in direction `dir` (unit),
  /// from `-half` to `+half` points.
  func peakAlpha(
    acrossAt centre: (x: Double, y: Double), direction dir: (x: Double, y: Double), half: Double,
    scale: Int
  ) -> Int {
    var peak = 0
    var t = -half
    while t <= half {
      peak = max(peak, alpha(atPoint: centre.x + t * dir.x, centre.y + t * dir.y, scale: scale))
      t += 0.125
    }
    return peak
  }

  /// How many points, along the same line, the alpha stays at or above `level`.
  func widthAtOrAbove(
    _ level: Int, acrossAt centre: (x: Double, y: Double), direction dir: (x: Double, y: Double),
    half: Double, scale: Int
  ) -> Double {
    var n = 0
    var t = -half
    let step = 0.125
    while t <= half {
      if alpha(atPoint: centre.x + t * dir.x, centre.y + t * dir.y, scale: scale) >= level {
        n += 1
      }
      t += step
    }
    return Double(n) * step
  }
}

/// JS `drawArrowhead(ctx, x1, y1, x2, y2)` for an arc from `a` to `b`: where the head's two
/// wings are, `fraction` of the way from the tip to each wing's end. The tip stops `setBack`
/// short of `b`; the wings leave it at +-30 degrees, `length` long, running back.
func arrowheadWingPoints(
  from a: (x: Double, y: Double), to b: (x: Double, y: Double), setBack: Double, length: Double,
  fraction: Double
) -> [(x: Double, y: Double)] {
  let angle = atan2(b.y - a.y, b.x - a.x)
  let tip = (x: b.x - cos(angle) * setBack, y: b.y - sin(angle) * setBack)
  let reach = length * fraction
  var out: [(x: Double, y: Double)] = []
  for side in [-Double.pi / 6, Double.pi / 6] {
    let wing: Double = angle + side
    let x: Double = tip.x - reach * cos(wing)
    let y: Double = tip.y - reach * sin(wing)
    out.append((x: x, y: y))
  }
  return out
}
