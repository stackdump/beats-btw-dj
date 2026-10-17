import AppKit
import SwiftUI

/// Draw a SwiftUI view in a real (offscreen, never shown) window and write it as a PNG, the
/// way the control socket's `screenshot` captures the app's window: unlike `ImageRenderer`,
/// AppKit controls (buttons, sliders, toggles) draw as themselves. Only when asked, like
/// `savePNG`: `make swift-shots SHOT_DIR=… FILTER=…`. Returns the file written.
@MainActor
@discardableResult
func saveWindowPNG<V: View>(_ view: V, width: Int, height: Int, name: String) -> String? {
  guard let path = ProcessInfo.processInfo.environment["DJ_SHOT_DIR"], !path.isEmpty else {
    return nil
  }
  _ = NSApplication.shared
  let size = NSSize(width: width, height: height)
  let window = NSWindow(
    contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: .darkAqua)
  let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: CGFloat(height)))
  host.frame = NSRect(origin: .zero, size: size)
  window.contentView = host
  // a few layout passes: state measured on the first (the panels' height) lands on the next
  for _ in 0..<3 {
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  }
  guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
  host.cacheDisplay(in: host.bounds, to: rep)
  guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
  let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("\(name).png")
  try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  do { try png.write(to: url) } catch { return nil }
  window.contentView = nil
  return url.path
}
