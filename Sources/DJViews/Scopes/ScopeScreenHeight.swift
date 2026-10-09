import AppKit
import SwiftUI

/// Reports the usable height (`visibleFrame`, below the menu bar and above the Dock) of the screen
/// the window is on, now and whenever the window moves to another screen.
///
/// The scope panel's height rule works from "how tall is the space" (scope.js uses
/// `window.innerHeight`). It must not read the WINDOW: the window grows to fit its content, the
/// panel is part of that content, and a panel sized from the window would grow the window, which
/// would grow the panel (`round(0.55 * height)` per round, up to the 640 cap). The screen does not
/// move when the panel appears, so the rule is stable.
struct ScreenHeightReader: NSViewRepresentable {
  var onChange: (Double) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let v = TrackingView()
    v.onChange = onChange
    return v
  }

  func updateNSView(_ v: TrackingView, context: Context) { v.onChange = onChange }

  final class TrackingView: NSView {
    var onChange: ((Double) -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard let w = window else { return }
      report()
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: w, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.report() }
      }
    }

    private func report() {
      guard let h = window?.screen?.visibleFrame.height, h > 0 else { return }
      // never inside a SwiftUI update
      DispatchQueue.main.async { [weak self] in self?.onChange?(Double(h)) }
    }
  }
}
