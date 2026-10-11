import AppKit
import SwiftUI

@testable import DJViews

/// Mounts a view in an `NSHostingView` inside a window that is never shown (no `orderFront`, no
/// screen): SwiftUI runs `onAppear` when the view joins the window and `onDisappear` when it
/// leaves, which `ImageRenderer` never does. `root` can be replaced with a view of the same type
/// (its `@State` stays), which is what a binding change does in the app. (Kept out of files that
/// `import Testing`: it needs Foundation's run loop.)
@MainActor
final class ViewHostHarness<Content: View> {
  private let window: NSWindow
  private let host: NSHostingView<Content>

  init(_ root: Content, width: Double = 900, height: Double = 400) {
    host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
  }

  /// Show another view of the same type (new bindings, same state).
  func replace(_ root: Content) {
    host.rootView = root
    host.layoutSubtreeIfNeeded()
  }

  /// Let SwiftUI deliver its appear/disappear callbacks and run a few frames.
  func settle(_ seconds: Double = 0.25) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Take the view out of the window (what closing it does to its content).
  func unmount() {
    window.contentView = NSView()
    host.removeFromSuperview()
  }
}
