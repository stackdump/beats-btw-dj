import Foundation

// Writes a one-note Standard MIDI File into a fresh temp directory for `importScore`'s test.
// Kept out of files that `import Testing` (Foundation next to Testing needs the Xcode-only overlay).
func writeTempMidi() throws -> (dir: String, path: String) {
  let bytes: [UInt8] =
    Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 1, 0x01, 0xE0] + Array("MTrk".utf8)
    + [0, 0, 0, 13, 0x00, 0x90, 0x3C, 0x64, 0x83, 0x60, 0x80, 0x3C, 0x00, 0x00, 0xFF, 0x2F, 0x00]
  let dir = NSTemporaryDirectory() + "dj-import-\(UUID().uuidString)"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let path = dir + "/one-note.mid"
  try Data(bytes).write(to: URL(fileURLWithPath: path))
  return (dir, path)
}

func removeTemp(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
