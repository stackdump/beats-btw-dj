import Foundation

// Foundation helpers for SoundFontTests (a file importing both Testing and Foundation needs
// the cross-import overlay, which the Command Line Tools don't ship).

func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

/// A scratch directory holding empty files named `files`, removed after `body`.
func withScratchDir(files: [String], _ body: (String) throws -> Void) throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  for n in files {
    FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data())
  }
  try body(dir.path)
}
