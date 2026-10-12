import DJCore
import Foundation

// Foundation lives here, not next to Testing (no _Testing_Foundation under the Command Line
// Tools).

/// A beats fixture from the DJCore tests (built by the real JS: scripts/beats-*.mjs).
func beatsFixture(_ name: String) throws -> JSONValue {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("DJCoreTests/Fixtures/beats/\(name).json")
  return try JSONValue.parse(try String(contentsOf: url, encoding: .utf8))
}
