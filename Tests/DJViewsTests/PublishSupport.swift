import Foundation

// Foundation helpers for AppPublishTests: a file that imports Testing can't import Foundation
// under Command Line Tools only (`_Testing_Foundation` is not built), so the file-system
// calls live here and the tests talk in paths.

func makeScratchDir() -> String {
  let u = FileManager.default.temporaryDirectory.appendingPathComponent(
    "dj-publish-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u.path
}

func removeTree(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

func listDirectory(_ path: String) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

func readText(_ path: String) -> String {
  (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
