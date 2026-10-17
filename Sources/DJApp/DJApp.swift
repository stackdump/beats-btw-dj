import AppKit
import DJCore
import DJViews
import SwiftUI

/// Owns the shutdown: a deck keeps playing as long as the process lives, so closing the window
/// quits, and the engine is stopped from the delegate rather than from a view (a view's
/// `onReceive` is gone once its window has closed, and `stop()` then never ran).
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = MainActor.assumeIsolated { AppModel() }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { model.stop() }
  }
}

@main
struct DJApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  private var model: AppModel { delegate.model }

  init() {
    // Run unbundled (`swift run DJApp`) as a normal foreground app with a Dock icon.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
  }

  var body: some Scene {
    WindowGroup("dj-vevr-se") {
      // a fixed minimum, not one measured from the content each frame (`WindowRoot`)
      WindowRoot(
        minSize: CGSize(width: 720, height: 460), idealSize: CGSize(width: 1440, height: 900)
      ) {
        ContentView(model: model)
      }
      // A DJ booth is dark: the decks' tints and the rings are drawn for it.
      .preferredColorScheme(.dark)
      .task { model.start() }
    }
    // The content scrolls (ContentView), so the window no longer sizes itself to it: open at a
    // size that shows two decks with their section columns (the wide layout) and the bottom bar,
    // and resize freely down to the minimum above (narrower stacks each deck's sections).
    .defaultSize(width: 1440, height: 900)
    // View ▸ Soundboard (⇧⌘B): the loops as big pads, a panel under the decks.
    .commands {
      CommandGroup(after: .toolbar) {
        Button("Soundboard") { model.toggleSoundboard() }
          .keyboardShortcut("b", modifiers: [.command, .shift])
      }
    }
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
