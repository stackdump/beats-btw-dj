import AppKit
import DJCore
import SwiftUI

@testable import DJViews

/// Mounts any view in an `NSHostingView` inside a window that is never shown, so SwiftUI runs
/// `onAppear` / `onChange` / `onDisappear` (which `ImageRenderer` never does). Kept out of files
/// that `import Testing`: it needs Foundation's run loop.
@MainActor
final class HostHarness<V: View> {
  private let window: NSWindow
  private let host: NSHostingView<V>

  init(_ view: V, width: Double = 400, height: Double = 100) {
    host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
  }

  /// Let SwiftUI deliver its callbacks.
  func settle(_ seconds: Double = 0.25) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Replace the content (what a state change does to the view tree).
  func update(_ view: V) {
    host.rootView = view
    host.layoutSubtreeIfNeeded()
  }

  func unmount() {
    window.contentView = NSView()
    host.removeFromSuperview()
  }
}

/// Counts how many times a `ScopeCanvas` draws while the run loop spins.
@MainActor
final class DrawCounter {
  var draws = 0
}

/// A steady clock a test moves by hand (the perf monitor's injected clock).
final class TestClock: @unchecked Sendable {
  var now = 1000.0
  func advance(ms: Double) { now += ms / 1000 }
}

/// A clock that moves on every reading, so whatever is timed with it takes `stepMs` per reading:
/// a draw that begins and ends a span books `stepMs`, and a window of such draws is a slow one
/// without any real waiting.
final class TickClock: @unchecked Sendable {
  var now = 1000.0
  let stepMs: Double
  init(stepMs: Double) { self.stepMs = stepMs }
  func read() -> Double {
    now += stepMs / 1000
    return now
  }
}

/// The size a view asks for when nothing constrains it (what `fixedSize()` would give it).
@MainActor
func idealSize<V: View>(of view: V) -> CGSize {
  let host = NSHostingView(rootView: view)
  return host.fittingSize
}

/// Counts how often `IntervalProbe` builds its body, and what interval it got last.
@MainActor
final class BodyCounter {
  var bodies = 0
  var lastInterval = 0.0
}

/// A view that does what the small animations do in their body: ask the hub in the environment
/// for the interval of an animation with its own 30 fps.
struct IntervalProbe: View {
  @Environment(\.scopeHub) private var hub
  let counter: BodyCounter

  var body: some View {
    counter.bodies += 1
    counter.lastInterval = hub?.interval(cappedAt: 1.0 / 30) ?? 0
    return Color.clear
  }
}
