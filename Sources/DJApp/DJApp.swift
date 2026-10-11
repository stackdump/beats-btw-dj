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
    // The Stage (SPEC modes 7…21): a full-window visualization of the decks' nets, opened by the
    // "Stage" button next to "Scopes".
    Window(StageWindow.title, id: StageWindow.id) {
      StageWindowView(app: model)
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 1100, height: 760)
  }
}
