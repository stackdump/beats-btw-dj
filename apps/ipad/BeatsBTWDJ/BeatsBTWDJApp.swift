import DJRustUI
import SwiftUI

// The iPad app: djandroid's pages (DJRustUI) on the djrust engine (djmobileFFI.xcframework's
// ios-arm64 slice). Built from apps/ipad/BeatsBTWDJ.xcodeproj; see docs/IPAD.md.

@main
struct BeatsBTWDJApp: App {
  @State private var model = RustDJModel(soundFontDir: BeatsBTWDJApp.soundFonts)

  /// Documents/soundfonts: visible in the Files app ("On My iPad › beats-btw-dj"), so .sf2 banks
  /// can be dropped in from a Mac or AirDrop.
  static var soundFonts: String {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("soundfonts").path
  }

  var body: some Scene {
    WindowGroup { DJRustRoot(model: model) }
  }
}
