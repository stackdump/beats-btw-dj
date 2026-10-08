import AppKit
import SwiftUI

/// Render a SwiftUI view to pixels, so layout and drawing can be asserted on instead of
/// eyeballed. (Kept out of files that `import Testing`: SwiftUI/AppKit pull in Foundation.)
struct Pixels {
  let width: Int
  let height: Int
  let rgba: [UInt8]

  func color(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let i = (y * width + x) * 4
    return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
  }

  /// Is the pixel close to `c` (0–255 per channel, tolerance `tol`)?
  func near(_ x: Int, _ y: Int, _ c: (Int, Int, Int), tol: Int = 40) -> Bool {
    let p = color(x, y)
    return abs(p.r - c.0) <= tol && abs(p.g - c.1) <= tol && abs(p.b - c.2) <= tol
  }

  /// Count of pixels in a column range matching a predicate.
  func count(inX xs: Range<Int>, y ys: Range<Int>, where f: (Int, Int, Int) -> Bool) -> Int {
    var n = 0
    for y in ys { for x in xs where f(color(x, y).r, color(x, y).g, color(x, y).b) { n += 1 } }
    return n
  }
}

@MainActor
func renderPixels<V: View>(_ view: V, width: Int, height: Int) -> Pixels? {
  let renderer = ImageRenderer(
    content: view.frame(width: CGFloat(width), height: CGFloat(height)).environment(
      \.colorScheme, .dark))
  renderer.scale = 1
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

/// Write a PNG next to the build for a human to look at (not asserted).
@MainActor
func savePNG<V: View>(_ view: V, width: Int, height: Int, name: String) {
  print("SHOT: start \(name)")
  let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height)))
  renderer.scale = 2
  guard let cg = renderer.cgImage else {
    print("SHOT: no cgImage")
    return
  }
  let rep = NSBitmapImageRep(cgImage: cg)
  guard let png = rep.representation(using: .png, properties: [:]) else {
    print("SHOT: no png")
    return
  }
  // Only when asked: DJ_SHOT_DIR=/some/dir swift test …
  let path =
    ProcessInfo.processInfo.environment["DJ_SHOT_DIR"]
    ?? "/private/tmp/claude-501/-Users-myork-Workspace-dj-vevr-se/204e49f8-1d95-43c8-acb9-b79c69198b55/scratchpad/shots"
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  do { try png.write(to: dir.appendingPathComponent("\(name).png")) } catch {
    print("SHOT: \(error)")
  }
}
