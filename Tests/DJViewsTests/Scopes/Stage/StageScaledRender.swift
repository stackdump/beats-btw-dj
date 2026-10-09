import AppKit
import SwiftUI

// Rendering at a display scale other than 1 (`renderPixels` in Render.swift is always 1x), for the
// canvas effects that depend on the device pixel ratio: `ImageRenderer` hands its scale to the
// views as `\.displayScale`, just as a Retina window does. (Kept out of files that `import
// Testing`, like Render.swift.)

/// `view` in a `width` x `height` point frame, rendered at `scale` pixels per point (so the
/// result is `width * scale` pixels wide), on the dark colour scheme.
@MainActor
func renderPixelsAt<V: View>(scale: CGFloat, _ view: V, width: Int, height: Int) -> Pixels? {
  let renderer = ImageRenderer(
    content: view.frame(width: CGFloat(width), height: CGFloat(height)).environment(
      \.colorScheme, .dark))
  renderer.scale = scale
  guard let cg = renderer.cgImage else { return nil }
  let w = cg.width
  let h = cg.height
  var data = [UInt8](repeating: 0, count: w * h * 4)
  let ok = data.withUnsafeMutableBytes { raw -> Bool in
    guard
      let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  return ok ? Pixels(width: w, height: h, rgba: data) : nil
}
