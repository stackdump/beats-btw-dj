import DJCore
import Foundation

/// A favorites store in a fresh temporary directory (kept out of the Testing files: importing
/// Foundation next to Testing needs a cross-import overlay Command Line Tools doesn't ship).
func temporaryFavorites() -> FavoritesStore {
  FavoritesStore(
    file: FileManager.default.temporaryDirectory
      .appendingPathComponent("favorites-\(UUID().uuidString)/favorites.json"))
}
