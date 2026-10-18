import Foundation

@testable import DJCore

// Kept out of TargetsTableTests.swift: Foundation next to Testing needs the
// _Testing_Foundation overlay, which ships only with Xcode.

/// The checked-in targets.json, parsed again (not `MixTargets.shared`).
func targetsTable() throws -> MixTargets {
  try MixTargets.parse(Data(MixTargets.loadText().utf8))
}

/// The checked-in targets.json with one balance part taken out, parsed.
func targetsWithoutBalancePart(_ part: String) throws -> MixTargets {
  let text = try MixTargets.loadText()
  guard var json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
    var balance = json["balance"] as? [String: Any],
    var parts = balance["default"] as? [String: Any]
  else { throw CocoaError(.fileReadCorruptFile) }
  parts[part] = nil
  balance["default"] = parts
  json["balance"] = balance
  return try MixTargets.parse(JSONSerialization.data(withJSONObject: json))
}

/// The checked-in targets.json with one band filled the way scripts/references.py writes it,
/// parsed.
func targetsWithBand(
  _ metric: String, family: String, value: Double, band: [Double], _ source: String
) throws -> MixTargets {
  let text = try MixTargets.loadText()
  guard var json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
    var bands = json["bands"] as? [String: Any],
    var byFamily = bands[metric] as? [String: Any]
  else { throw CocoaError(.fileReadCorruptFile) }
  byFamily[family] = ["value": value, "band": band, "source": source]
  bands[metric] = byFamily
  json["bands"] = bands
  return try MixTargets.parse(JSONSerialization.data(withJSONObject: json))
}
