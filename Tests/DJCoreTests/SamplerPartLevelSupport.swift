import Foundation

@testable import DJCore

// Helpers for SamplerPartLevelTests (Foundation stays out of files that import Testing).

/// A part-level cache in a fresh temporary file.
func tempPartLevelCache() -> SamplerPartLevels.Cache {
  SamplerPartLevels.Cache(
    url: FileManager.default.temporaryDirectory.appendingPathComponent(
      "part-levels-\(UUID().uuidString).json"))
}

func removePartLevelCache(_ cache: SamplerPartLevels.Cache) {
  if let url = cache.url { try? FileManager.default.removeItem(at: url) }
}

/// Wall-clock seconds `body` takes.
func secondsTaken(_ body: () throws -> Void) rethrows -> Double {
  let t0 = Date()
  try body()
  return Date().timeIntervalSince(t0)
}

func partLevelFormat(_ format: String, _ x: Double) -> String { String(format: format, x) }
