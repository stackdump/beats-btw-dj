import AppKit
import DJCore
import SwiftUI

@testable import DJViews

/// Mounts a `StageView` in an `NSHostingView` inside a window that is never shown (no
/// `orderFront`, no screen): SwiftUI runs `onAppear` when the view joins the window and
/// `onDisappear` when it leaves, which `ImageRenderer` never does. (Kept out of files that
/// `import Testing`: it needs Foundation's run loop.)
@MainActor
final class StageHostHarness {
  private let window: NSWindow
  private let host: NSHostingView<StageView>

  init(model: StageModel, width: Double = 400, height: Double = 300) {
    host = NSHostingView(rootView: StageView(model: model))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
  }

  /// Let SwiftUI deliver its appear/disappear callbacks.
  func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }

  /// Take the stage out of the window (what closing it does to its content).
  func unmount() {
    window.contentView = NSView()
    host.removeFromSuperview()
  }
}
