import DJCore
import Foundation

/// A favorites store in a fresh temporary directory (kept out of the Testing files: importing
/// Foundation next to Testing needs a cross-import overlay Command Line Tools doesn't ship).
func temporaryFavorites() -> FavoritesStore {
  FavoritesStore(
    file: FileManager.default.temporaryDirectory
      .appendingPathComponent("favorites-\(UUID().uuidString)/favorites.json"))
}

/// An Apple Loop installed on this Mac to test with (nil without GarageBand / Logic content).
let installedAppleLoop: URL? = {
  let u = URL(
    fileURLWithPath: "/Library/Audio/Apple Loops/Apple/01 Hip Hop/Chill Hip-Hop Beat 08.caf")
  return FileManager.default.fileExists(atPath: u.path) ? u : nil
}()

/// A loops library over a fresh folder holding a copy of `installedAppleLoop` as
/// `<root>/Apple/Test Pack/…`, with its index in the same temporary folder.
func temporaryLoopLibrary() throws -> StockLoopLibrary {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "loops-\(UUID().uuidString)")
  let pack = dir.appendingPathComponent("root/Apple/Test Pack")
  try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
  if let src = installedAppleLoop {
    try FileManager.default.copyItem(
      at: src, to: pack.appendingPathComponent(src.lastPathComponent))
  }
  return StockLoopLibrary(
    roots: [dir.appendingPathComponent("root")], indexFile: dir.appendingPathComponent("index.json")
  )
}
