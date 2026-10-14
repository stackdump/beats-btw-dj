import Foundation

/// Sessions on disk, named by CID: `<dir>/<cid>.json` holds the canonical envelope, so the
/// file is its own checksum — `load(cid:)` re-hashes and refuses anything that doesn't
/// match its name.
public struct SessionStore {
  public let directory: URL

  public init(directory: URL = SessionStore.defaultDirectory) { self.directory = directory }

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/sessions", isDirectory: true)
  }

  /// Write the session; returns its CID and file.
  @discardableResult
  public func save(_ session: Session) throws -> (cid: String, url: URL) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cid = session.cid
    let url = directory.appendingPathComponent("\(cid).json")
    try Data((session.canonical + "\n").utf8).write(to: url, options: .atomic)
    return (cid, url)
  }

  public func load(cid: String) throws -> Session {
    let text = try String(
      contentsOf: directory.appendingPathComponent("\(cid).json"), encoding: .utf8)
    return try Session.decode(text.trimmingCharacters(in: .whitespacesAndNewlines), cid: cid)
  }

  /// CIDs stored here, newest first.
  public func list() -> [String] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.filter { $0.pathExtension == "json" }
      .sorted {
        let a =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        let b =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return a > b
      }
      .map { $0.deletingPathExtension().lastPathComponent }
  }

  /// Render to a WAV file (16-bit PCM by default).
  public static func exportWAV(
    _ session: Session, to url: URL, float32: Bool = false, roleFilter: RoleFilter? = nil,
    samples: @escaping (String) -> SampleBuffer? = { _ in nil }
  ) throws {
    let audio = try SessionPlayer(session: session, roleFilter: roleFilter, samples: samples)
      .render()
    try WAV.encode(audio, float32: float32).write(to: url, options: .atomic)
  }
}
