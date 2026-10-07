import Foundation

// Kept out of files that `import Testing`: importing Foundation next to
// Testing needs the _Testing_Foundation overlay, which ships only with Xcode.

/// Distinct messages captured from the real hardware, keyed by device.
func capturedMessages() throws -> [String: [[UInt8]]] {
  guard
    let url = Bundle.module.url(
      forResource: "captured-messages", withExtension: "json", subdirectory: "Fixtures")
  else { throw CocoaError(.fileNoSuchFile) }
  return try JSONDecoder().decode([String: [[UInt8]]].self, from: Data(contentsOf: url))
}
