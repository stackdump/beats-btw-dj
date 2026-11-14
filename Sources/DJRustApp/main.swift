import AppKit
import DJRustUI
import SwiftUI

// The djandroid port as a Mac app, on the djrust engine (docs/ANDROID-PORT.md).
//   swift run DJRustApp
// The iPad app (apps/ipad) shows the same DJRustRoot.

struct DJRustApp: App {
  @State private var model = RustDJModel()

  var body: some Scene {
    WindowGroup("djrust") {
      DJRustRoot(model: model).frame(minWidth: 420, minHeight: 640)
    }
    .defaultSize(width: 520, height: 900)
  }
}

// unbundled (swift run), a SwiftUI app starts as a background process: make it a regular one
NSApplication.shared.setActivationPolicy(.regular)
DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
DJRustApp.main()
