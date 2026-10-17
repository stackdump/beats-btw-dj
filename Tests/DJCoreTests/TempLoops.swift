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

/// The files in a library's `removed/`, sorted.
func removedLoopFiles(_ lib: LoopLibrary) -> [String] {
  let removed = lib.dir.appendingPathComponent("removed").path
  return ((try? FileManager.default.contentsOfDirectory(atPath: removed)) ?? []).sorted()
}

/// Make moving clip `id`'s audio into `removed/` fail: a folder in its place there that cannot
/// be cleared (it holds a read-only folder with a file in it). `unblockRemovedAudio` undoes it.
func blockRemovedAudio(_ lib: LoopLibrary, _ id: String) throws {
  let fm = FileManager.default
  let inner = lib.dir.appendingPathComponent("removed/\(id).wav/locked", isDirectory: true)
  try fm.createDirectory(at: inner, withIntermediateDirectories: true)
  try Data("x".utf8).write(to: inner.appendingPathComponent("f"))
  try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inner.path)
}

func unblockRemovedAudio(_ lib: LoopLibrary, _ id: String) {
  let inner = lib.dir.appendingPathComponent("removed/\(id).wav/locked", isDirectory: true)
  try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path)
  try? FileManager.default.removeItem(
    at: lib.dir.appendingPathComponent("removed/\(id).wav", isDirectory: true))
}
