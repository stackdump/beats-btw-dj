// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "dj-vevr-se",
  // macOS 15 is also what makes swift-testing's macros compile.
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DJCore", targets: ["DJCore"]),
    .executable(name: "djctl", targets: ["djctl"]),
    .executable(name: "DJApp", targets: ["DJApp"]),
  ],
  targets: [
    // Device profiles, jog parsing, CoreMIDI input. No UI, no audio graph yet.
    .target(
      name: "DJCore",
      resources: [.copy("Resources/profiles")]
    ),
    // CLI: ports / monitor — the Swift twin of the Go tool, for hardware checks.
    .executableTarget(name: "djctl", dependencies: ["DJCore"]),
    // SwiftUI app. `make app` wraps it in a .app bundle.
    .executableTarget(name: "DJApp", dependencies: ["DJCore"]),
    .testTarget(name: "DJCoreTests", dependencies: ["DJCore"]),
  ]
)
