import Testing

@testable import DJCore

struct BuildInfoTests {
  @Test func noBundleValuesMeansDev() {
    #expect(BuildInfo(info: nil) == .dev)
    #expect(BuildInfo(info: [:]).id == "dev")
    // A plist that isn't ours (a test runner's) doesn't count either.
    let runner = BuildInfo(info: ["CFBundleIdentifier": "com.apple.xctest", "CFBundleVersion": "1"])
    #expect(runner.isDev)
  }

  @Test func readsTheStampedPlist() throws {
    let b = BuildInfo(info: [
      "CFBundleIdentifier": "se.vevr.dj", "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "1a2b3c4-dirty", "DJBuildDate": "2026-10-11T12:34:56Z",
    ])
    #expect(b.version == "0.1.0")
    #expect(b.build == "1a2b3c4-dirty")
    #expect(b.id == "0.1.0+1a2b3c4-dirty")
    #expect(try #require(b.date).timeIntervalSince1970 == 1_791_722_096)
    #expect(b.dateString == "2026-10-11T12:34:56Z")
  }

  @Test func aBadDateIsDropped() {
    let b = BuildInfo(info: [
      "CFBundleIdentifier": "se.vevr.dj", "CFBundleVersion": "unknown", "DJBuildDate": "yesterday",
    ])
    #expect(b.build == "unknown")
    #expect(b.date == nil)
    #expect(b.id == "dev+unknown")
  }
}
