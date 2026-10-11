import Foundation

/// Which build is running, as `scripts/bundle-app.sh` stamped it into Info.plist:
/// `CFBundleShortVersionString`, `CFBundleVersion` (short commit, `-dirty` with tracked
/// changes) and `DJBuildDate` (ISO-8601 UTC). Unbundled (`swift run`, `swift test`, `djctl`)
/// there is no such plist and everything reads "dev".
public struct BuildInfo: Equatable, Sendable {
  public var version: String
  public var build: String
  public var date: Date?

  /// Bundle identifier `bundle-app.sh` writes; any other plist (a test runner's) is not ours.
  public static let bundleID = "se.vevr.dj"
  public static let dev = BuildInfo(version: "dev", build: "dev", date: nil)
  public static let current = BuildInfo(info: Bundle.main.infoDictionary)

  public init(version: String, build: String, date: Date?) {
    self.version = version
    self.build = build
    self.date = date
  }

  public init(info: [String: Any]?) {
    guard let info, info["CFBundleIdentifier"] as? String == Self.bundleID else {
      self = .dev
      return
    }
    self.init(
      version: info["CFBundleShortVersionString"] as? String ?? "dev",
      build: info["CFBundleVersion"] as? String ?? "dev",
      date: (info["DJBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
  }

  public var isDev: Bool { self == .dev }

  /// One string for the UI and MCP's `serverInfo.version`: `0.1.0+1a2b3c4` (semver build
  /// metadata), or "dev".
  public var id: String { isDev ? "dev" : "\(version)+\(build)" }

  public var dateString: String? { date.map { ISO8601DateFormatter().string(from: $0) } }
}
