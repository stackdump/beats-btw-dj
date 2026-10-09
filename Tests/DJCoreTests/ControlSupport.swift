import Foundation

// Foundation helpers for ControlTests (kept out of files that `import Testing`; see
// FixtureLoader.swift).

/// A fresh socket path. sun_path is 104 bytes, so not under the long temp dir.
func tempSocketPath() -> String { "/tmp/djc-\(UUID().uuidString.prefix(8)).sock" }

func posixMode(_ path: String) -> Int? {
  try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
}

func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
