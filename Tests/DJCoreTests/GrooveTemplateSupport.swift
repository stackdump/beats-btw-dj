import Foundation

@testable import DJCore

// Kept out of GrooveTemplateTests.swift: Foundation next to Testing needs the
// _Testing_Foundation overlay, which ships only with Xcode.

/// The checked-in grooves.json, parsed (with its provenance).
func grooveTable() throws -> GrooveTemplate.Parsed {
  try GrooveTemplate.parse(Data(GrooveTemplate.loadText().utf8))
}

/// A file of this repo by its path from the root.
func repoText(_ path: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
