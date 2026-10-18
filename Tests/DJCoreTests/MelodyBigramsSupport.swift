import Foundation

@testable import DJCore

// Kept out of MelodyBigramsTests.swift: Foundation next to Testing needs the
// _Testing_Foundation overlay, which ships only with Xcode.

/// The checked-in melody-bigrams.json, parsed (with its provenance).
func melodyBigramsFile() throws -> MelodyBigrams.Parsed {
  try MelodyBigrams.parse(Data(MelodyBigrams.loadText().utf8))
}

/// The checked-in file with the first `target` in its text replaced, parsed.
func melodyBigramsEdited(replacing target: String, with replacement: String) throws
  -> MelodyBigrams.Parsed
{
  var text = try MelodyBigrams.loadText()
  if let r = text.range(of: target) { text.replaceSubrange(r, with: replacement) }
  return try MelodyBigrams.parse(Data(text.utf8))
}
