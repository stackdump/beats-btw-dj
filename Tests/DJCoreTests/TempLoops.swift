import DJCore
import Foundation

// Kept out of the Testing files: importing Foundation next to Testing needs a cross-import
// overlay Command Line Tools doesn't ship (see TempFavorites.swift).

/// A loop library in a fresh temporary directory.
func tempLoopLibrary() -> LoopLibrary {
  LoopLibrary(
    dir: FileManager.default.temporaryDirectory
      .appendingPathComponent("loops-\(UUID().uuidString)", isDirectory: true))
}

func removeLoopLibrary(_ lib: LoopLibrary) { try? FileManager.default.removeItem(at: lib.dir) }

/// The files in a library's directory, sorted.
func loopLibraryFiles(_ lib: LoopLibrary) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: lib.dir.path)) ?? []).sorted()
}
