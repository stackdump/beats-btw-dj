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
        // A DJ booth is dark: the decks' tints and the rings are drawn for it.
        .preferredColorScheme(.dark)
        .task { model.start() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
          model.stop()
        }
    }
    // The content scrolls (ContentView), so the window no longer sizes itself to it: open at a
    // size that shows two decks with their section columns (the wide layout) and the bottom bar,
    // and resize freely down to the minimum above (narrower stacks each deck's sections).
    .defaultSize(width: 1440, height: 900)
    // The Stage (SPEC modes 7…21): a full-window visualization of the decks' nets, opened by the
    // "Stage" button next to "Scopes".
    Window(StageWindow.title, id: StageWindow.id) {
      StageWindowView(app: model)
        .frame(minWidth: 760, minHeight: 480)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 1100, height: 760)
  }
}
