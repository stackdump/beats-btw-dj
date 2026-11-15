import AppKit
import DJRustMIDI
import DJRustUI
import SwiftUI

// The djandroid port as a Mac app, on the djrust engine (docs/ANDROID-PORT.md).
//   swift run DJRustApp
// The iPad app (apps/ipad) shows the same DJRustRoot.

struct DJRustApp: App {
  @State private var model: RustDJModel
  /// The DJ controllers plugged in (DJCore's profiles: the Inpulse 200 MK3, APC mini, MPK mini).
  @State private var controllers: RustControllers

  init() {
    let m = RustDJModel()
    _model = State(initialValue: m)
    _controllers = State(initialValue: RustControllers(model: m))
  }

  var body: some Scene {
    WindowGroup("djrust") {
      DJRustRoot(model: model).frame(minWidth: 420, minHeight: 640)
        .task { controllers.start() }
    }
    // wide enough for both decks and the mixer side by side (narrower: the seven tabs)
    .defaultSize(width: 1240, height: 900)
  }
}

// unbundled (swift run), a SwiftUI app starts as a background process: make it a regular one
NSApplication.shared.setActivationPolicy(.regular)
DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
DJRustApp.main()
