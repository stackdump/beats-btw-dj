import AppKit
import DJCore
import DJViews
import SwiftUI

@main
struct DJApp: App {
  @State private var model = AppModel()

  init() {
    // Run unbundled (`swift run DJApp`) as a normal foreground app with a Dock icon.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
  }

  var body: some Scene {
    WindowGroup("dj-vevr-se") {
      ContentView(model: model)
        .frame(minWidth: 720, minHeight: 460)
        .task { model.start() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
          model.stop()
        }
    }
  }
}
